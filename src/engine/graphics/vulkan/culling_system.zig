const std = @import("std");
const c = @import("../../c.zig").c;
const rhi_pkg = @import("../rhi.zig");
const log = @import("../core/log.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const VulkanContext = @import("vulkan/rhi_context_types.zig").VulkanContext;
const Utils = @import("vulkan/utils.zig");

pub const CULLING_SHADER_PATH = "assets/shaders/vulkan/culling.comp.spv";
pub const MAX_CULLABLE_CHUNKS: usize = 16384;
pub const WORKGROUP_SIZE: u32 = 64;

pub const ChunkCullData = extern struct {
    min_point: [4]f32,
    max_point: [4]f32,
};

const FrustumPushConstants = extern struct {
    planes: [6][4]f32,
};

pub const CullingSystem = struct {
    allocator: std.mem.Allocator,
    rhi: rhi_pkg.RHI,
    vk_ctx: *VulkanContext,

    aabb_buffer: Utils.VulkanBuffer = .{},
    command_buffer: Utils.VulkanBuffer = .{},
    counter_buffer: Utils.VulkanBuffer = .{},
    counter_readback_buffer: Utils.VulkanBuffer = .{},

    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_set: c.VkDescriptorSet = null,
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    max_chunks: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        rhi: rhi_pkg.RHI,
        max_chunks: usize,
    ) !*CullingSystem {
        const self = try allocator.create(CullingSystem);
        errdefer allocator.destroy(self);

        const vk_ctx: *VulkanContext = @ptrCast(@alignCast(rhi.ptr));
        const clamped_max = std.math.clamp(max_chunks, 1, MAX_CULLABLE_CHUNKS);

        self.* = .{
            .allocator = allocator,
            .rhi = rhi,
            .vk_ctx = vk_ctx,
            .max_chunks = clamped_max,
        };

        const aabb_size = clamped_max * @sizeOf(ChunkCullData);
        self.aabb_buffer = try Utils.createVulkanBuffer(
            &vk_ctx.vulkan_device,
            aabb_size,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        errdefer self.destroyBuffers();

        const cmd_size = @sizeOf(u32) * 4 + clamped_max * @sizeOf(c.VkDrawIndirectCommand);
        self.command_buffer = try Utils.createVulkanBuffer(
            &vk_ctx.vulkan_device,
            cmd_size,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );
        errdefer self.destroyBuffers();

        self.counter_buffer = try Utils.createVulkanBuffer(
            &vk_ctx.vulkan_device,
            16,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
        );
        errdefer self.destroyBuffers();

        self.counter_readback_buffer = try Utils.createVulkanBuffer(
            &vk_ctx.vulkan_device,
            16,
            c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        errdefer self.destroyBuffers();

        try ensureShaderFileExists(CULLING_SHADER_PATH);

        errdefer self.deinitComputeResources();
        try self.initComputeResources();

        return self;
    }

    pub fn deinit(self: *CullingSystem) void {
        self.deinitComputeResources();
        self.destroyBuffers();
        self.allocator.destroy(self);
    }

    pub fn updateAABBData(self: *CullingSystem, chunks: []const ChunkCullData) void {
        if (self.aabb_buffer.mapped_ptr == null) return;
        const copy_len = @min(chunks.len, self.max_chunks) * @sizeOf(ChunkCullData);
        if (copy_len == 0) return;
        @memcpy(
            @as([*]u8, @ptrCast(self.aabb_buffer.mapped_ptr.?))[0..copy_len],
            @as([*]const u8, @ptrCast(chunks.ptr))[0..copy_len],
        );
    }

    pub fn dispatch(
        self: *CullingSystem,
        view_proj: Mat4,
        chunk_count: u32,
    ) void {
        if (chunk_count == 0) return;
        const cmd = self.vk_ctx.frames.command_buffers[self.vk_ctx.frames.current_frame];
        if (cmd == null) return;

        self.resetCounter(cmd);

        var host_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        host_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        host_barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT;
        host_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_HOST_BIT,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1,
            &host_barrier,
            0,
            null,
            0,
            null,
        );

        const push = extractFrustumPlanes(view_proj);

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_set, 0, null);
        c.vkCmdPushConstants(cmd, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(FrustumPushConstants), &push);

        const groups = divCeil(chunk_count, WORKGROUP_SIZE);
        c.vkCmdDispatch(cmd, groups, 1, 1);

        var compute_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        compute_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        compute_barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        compute_barrier.dstAccessMask = c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT | c.VK_ACCESS_TRANSFER_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            1,
            &compute_barrier,
            0,
            null,
            0,
            null,
        );
    }

    pub fn readVisibleCount(self: *CullingSystem) u32 {
        if (self.counter_readback_buffer.mapped_ptr == null) return 0;
        const ptr: *align(1) u32 = @ptrCast(@alignCast(self.counter_readback_buffer.mapped_ptr.?));
        return ptr.*;
    }

    fn resetCounter(self: *CullingSystem, cmd: c.VkCommandBuffer) void {
        const zero: u32 = 0;
        c.vkCmdFillBuffer(cmd, self.counter_buffer.buffer, 0, 16, zero);

        var fill_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        fill_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        fill_barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        fill_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1,
            &fill_barrier,
            0,
            null,
            0,
            null,
        );
    }

    fn initComputeResources(self: *CullingSystem) !void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 3 },
        };

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = 1;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes;
        try Utils.checkVk(c.vkCreateDescriptorPool(vk, &pool_info, null, &self.descriptor_pool));

        const bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = bindings.len;
        layout_info.pBindings = &bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));

        var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = self.descriptor_pool;
        alloc_info.descriptorSetCount = 1;
        alloc_info.pSetLayouts = &self.descriptor_set_layout;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info, &self.descriptor_set));

        self.updateDescriptorSets();

        var pc_range = std.mem.zeroes(c.VkPushConstantRange);
        pc_range.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        pc_range.offset = 0;
        pc_range.size = @sizeOf(FrustumPushConstants);

        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &self.descriptor_set_layout;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &pc_range;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipeline_layout_info, null, &self.pipeline_layout));

        const shader_module = try loadShaderModule(vk, CULLING_SHADER_PATH, self.allocator);
        defer c.vkDestroyShaderModule(vk, shader_module, null);

        var stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
        stage.module = shader_module;
        stage.pName = "main";

        var pipeline_info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pipeline_info.stage = stage;
        pipeline_info.layout = self.pipeline_layout;
        try Utils.checkVk(c.vkCreateComputePipelines(vk, null, 1, &pipeline_info, null, &self.pipeline));
    }

    fn updateDescriptorSets(self: *CullingSystem) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        var aabb_info = c.VkDescriptorBufferInfo{
            .buffer = self.aabb_buffer.buffer,
            .offset = 0,
            .range = self.max_chunks * @sizeOf(ChunkCullData),
        };
        var cmd_info = c.VkDescriptorBufferInfo{
            .buffer = self.command_buffer.buffer,
            .offset = 0,
            .range = c.VK_WHOLE_SIZE,
        };
        var counter_info = c.VkDescriptorBufferInfo{
            .buffer = self.counter_buffer.buffer,
            .offset = 0,
            .range = 16,
        };

        var writes: [3]c.VkWriteDescriptorSet = undefined;

        writes[0] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[0].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[0].dstSet = self.descriptor_set;
        writes[0].dstBinding = 0;
        writes[0].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[0].descriptorCount = 1;
        writes[0].pBufferInfo = &aabb_info;

        writes[1] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[1].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[1].dstSet = self.descriptor_set;
        writes[1].dstBinding = 1;
        writes[1].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[1].descriptorCount = 1;
        writes[1].pBufferInfo = &cmd_info;

        writes[2] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[2].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[2].dstSet = self.descriptor_set;
        writes[2].dstBinding = 2;
        writes[2].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[2].descriptorCount = 1;
        writes[2].pBufferInfo = &counter_info;

        c.vkUpdateDescriptorSets(vk, writes.len, &writes[0], 0, null);
    }

    fn deinitComputeResources(self: *CullingSystem) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;
        if (self.pipeline != null) c.vkDestroyPipeline(vk, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.descriptor_set_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(vk, self.descriptor_pool, null);

        self.pipeline = null;
        self.pipeline_layout = null;
        self.descriptor_set_layout = null;
        self.descriptor_pool = null;
        self.descriptor_set = null;
    }

    fn destroyBuffers(self: *CullingSystem) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        if (self.aabb_buffer.buffer != null) c.vkDestroyBuffer(vk, self.aabb_buffer.buffer, null);
        if (self.aabb_buffer.memory != null) c.vkFreeMemory(vk, self.aabb_buffer.memory, null);
        if (self.command_buffer.buffer != null) c.vkDestroyBuffer(vk, self.command_buffer.buffer, null);
        if (self.command_buffer.memory != null) c.vkFreeMemory(vk, self.command_buffer.memory, null);
        if (self.counter_buffer.buffer != null) c.vkDestroyBuffer(vk, self.counter_buffer.buffer, null);
        if (self.counter_buffer.memory != null) c.vkFreeMemory(vk, self.counter_buffer.memory, null);
        if (self.counter_readback_buffer.buffer != null) c.vkDestroyBuffer(vk, self.counter_readback_buffer.buffer, null);
        if (self.counter_readback_buffer.memory != null) c.vkFreeMemory(vk, self.counter_readback_buffer.memory, null);

        self.aabb_buffer = .{};
        self.command_buffer = .{};
        self.counter_buffer = .{};
        self.counter_readback_buffer = .{};
    }
};

fn extractFrustumPlanes(vp: Mat4) FrustumPushConstants {
    const m = vp.data;
    var planes: [6][4]f32 = undefined;

    planes[0] = .{ m[3][0] + m[0][0], m[3][1] + m[0][1], m[3][2] + m[0][2], m[3][3] + m[0][3] };
    planes[1] = .{ m[3][0] - m[0][0], m[3][1] - m[0][1], m[3][2] - m[0][2], m[3][3] - m[0][3] };
    planes[2] = .{ m[3][0] - m[1][0], m[3][1] - m[1][1], m[3][2] - m[1][2], m[3][3] - m[1][3] };
    planes[3] = .{ m[3][0] + m[1][0], m[3][1] + m[1][1], m[3][2] + m[1][2], m[3][3] + m[1][3] };
    planes[4] = .{ m[3][0] + m[2][0], m[3][1] + m[2][1], m[3][2] + m[2][2], m[3][3] + m[2][3] };
    planes[5] = .{ m[3][0] - m[2][0], m[3][1] - m[2][1], m[3][2] - m[2][2], m[3][3] - m[2][3] };

    for (&planes) |*plane| {
        const len = @sqrt(plane[0] * plane[0] + plane[1] * plane[1] + plane[2] * plane[2]);
        if (len > 0.0001) {
            plane[0] /= len;
            plane[1] /= len;
            plane[2] /= len;
            plane[3] /= len;
        }
    }

    return .{ .planes = planes };
}

fn loadShaderModule(vk: c.VkDevice, path: []const u8, allocator: std.mem.Allocator) !c.VkShaderModule {
    const bytes = try std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(16 * 1024 * 1024));
    defer allocator.free(bytes);
    if (bytes.len % 4 != 0) return error.InvalidShader;

    var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = bytes.len;
    info.pCode = @ptrCast(@alignCast(bytes.ptr));

    var module: c.VkShaderModule = null;
    try Utils.checkVk(c.vkCreateShaderModule(vk, &info, null, &module));
    return module;
}

fn ensureShaderFileExists(path: []const u8) !void {
    std.fs.cwd().access(path, .{}) catch |err| {
        log.log.errWithTrace("Culling shader artifact missing: {s} ({})", .{ path, err });
        log.log.err("Run `nix develop --command zig build` to regenerate Vulkan SPIR-V shaders.", .{});
        return err;
    };
}

fn divCeil(v: u32, d: u32) u32 {
    return @divFloor(v + d - 1, d);
}
