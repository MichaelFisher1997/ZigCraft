//! Dedicated same-frame compute culling and MDI compaction for distant terrain.
const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const rhi = @import("engine-rhi");
const culling = rhi.culling;
const VulkanContext = @import("rhi_context_types.zig").VulkanContext;
const Utils = @import("utils.zig");

pub const SHADER_PATH = "assets/shaders/vulkan/lod_culling.comp.spv";
pub const WORKGROUP_SIZE: u32 = 64;
pub const MAX_LOD_LEVELS: usize = 5;
const FRAME_COUNT = rhi.MAX_FRAMES_IN_FLIGHT;

const LODCullingSystem = struct {
    allocator: std.mem.Allocator,
    ctx: *VulkanContext,
    capacity: usize,
    candidates: [FRAME_COUNT]Utils.VulkanBuffer,
    counters: [FRAME_COUNT]rhi.BufferHandle,
    counter_readbacks: [FRAME_COUNT]Utils.VulkanBuffer,
    terrain_ids: [FRAME_COUNT]Utils.VulkanBuffer,
    water_ids: [FRAME_COUNT]Utils.VulkanBuffer,
    terrain_instances: [FRAME_COUNT]rhi.BufferHandle,
    water_instances: [FRAME_COUNT]rhi.BufferHandle,
    terrain_indirect: [FRAME_COUNT]rhi.BufferHandle,
    water_indirect: [FRAME_COUNT]rhi.BufferHandle,
    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [FRAME_COUNT]c.VkDescriptorSet = std.mem.zeroes([FRAME_COUNT]c.VkDescriptorSet),
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,
    validate: bool,
    expected_counts: [FRAME_COUNT][MAX_LOD_LEVELS * 2]u32 = undefined,
    expected_valid: [FRAME_COUNT]bool = [_]bool{false} ** FRAME_COUNT,
    expected_ids: [FRAME_COUNT][2]std.ArrayListUnmanaged(u32) = undefined,
    validation_mismatch_count: u32 = 0,

    fn init(allocator: std.mem.Allocator, ctx: *VulkanContext, requested_capacity: usize) !*LODCullingSystem {
        const self = try allocator.create(LODCullingSystem);
        errdefer allocator.destroy(self);
        const capacity = std.math.clamp(requested_capacity, 1, 2048);
        self.* = .{
            .allocator = allocator,
            .ctx = ctx,
            .capacity = capacity,
            .candidates = std.mem.zeroes([FRAME_COUNT]Utils.VulkanBuffer),
            .counters = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .counter_readbacks = std.mem.zeroes([FRAME_COUNT]Utils.VulkanBuffer),
            .terrain_ids = std.mem.zeroes([FRAME_COUNT]Utils.VulkanBuffer),
            .water_ids = std.mem.zeroes([FRAME_COUNT]Utils.VulkanBuffer),
            .terrain_instances = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .water_instances = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .terrain_indirect = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .water_indirect = [_]rhi.BufferHandle{0} ** FRAME_COUNT,
            .validate = envEnabled("ZIGCRAFT_LOD_GPU_CULLING_VALIDATE"),
            .expected_ids = undefined,
        };
        for (&self.expected_ids) |*per_frame| {
            for (per_frame) |*ids| ids.* = .empty;
        }
        errdefer self.deinit();

        const candidate_bytes = capacity * @sizeOf(culling.LODCullCandidate);
        const stream_instances = capacity * MAX_LOD_LEVELS * @sizeOf(rhi.InstanceData);
        const stream_commands = capacity * MAX_LOD_LEVELS * @sizeOf(rhi.DrawIndirectCommand);
        for (0..FRAME_COUNT) |i| {
            self.candidates[i] = try Utils.createVulkanBuffer(&ctx.vulkan_device, candidate_bytes, c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            self.counters[i] = try ctx.resources.createBuffer(MAX_LOD_LEVELS * 2 * @sizeOf(u32), .storage);
            self.counter_readbacks[i] = try Utils.createVulkanBuffer(&ctx.vulkan_device, MAX_LOD_LEVELS * 2 * @sizeOf(u32), c.VK_BUFFER_USAGE_TRANSFER_DST_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            self.terrain_ids[i] = try Utils.createVulkanBuffer(&ctx.vulkan_device, capacity * MAX_LOD_LEVELS * @sizeOf(u32), c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            self.water_ids[i] = try Utils.createVulkanBuffer(&ctx.vulkan_device, capacity * MAX_LOD_LEVELS * @sizeOf(u32), c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT, c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT);
            self.terrain_instances[i] = try ctx.resources.createBuffer(stream_instances, .storage);
            self.water_instances[i] = try ctx.resources.createBuffer(stream_instances, .storage);
            self.terrain_indirect[i] = try ctx.resources.createBuffer(stream_commands, .indirect);
            self.water_indirect[i] = try ctx.resources.createBuffer(stream_commands, .indirect);
        }
        try self.initPipeline();
        return self;
    }

    fn deinit(self: *LODCullingSystem) void {
        self.destroyPipeline();
        const device = self.ctx.vulkan_device.vk_device;
        for (0..FRAME_COUNT) |i| {
            destroyNative(device, &self.candidates[i]);
            if (self.counters[i] != 0) self.ctx.resources.destroyBuffer(self.counters[i]);
            destroyNative(device, &self.counter_readbacks[i]);
            destroyNative(device, &self.terrain_ids[i]);
            destroyNative(device, &self.water_ids[i]);
            for (&self.expected_ids[i]) |*ids| ids.deinit(self.allocator);
            if (self.terrain_instances[i] != 0) self.ctx.resources.destroyBuffer(self.terrain_instances[i]);
            if (self.water_instances[i] != 0) self.ctx.resources.destroyBuffer(self.water_instances[i]);
            if (self.terrain_indirect[i] != 0) self.ctx.resources.destroyBuffer(self.terrain_indirect[i]);
            if (self.water_indirect[i] != 0) self.ctx.resources.destroyBuffer(self.water_indirect[i]);
        }
        self.allocator.destroy(self);
    }

    fn dispatch(self: *LODCullingSystem, frame_index: usize, input: []const culling.LODCullCandidate, config: culling.LODCullDispatch) bool {
        if (frame_index >= FRAME_COUNT or input.len > self.capacity or input.len == 0) return false;
        self.validatePrevious(frame_index);
        const command_buffer = self.ctx.frames.command_buffers[frame_index];
        if (command_buffer == null or self.candidates[frame_index].mapped_ptr == null) return false;
        @memcpy(@as([*]u8, @ptrCast(self.candidates[frame_index].mapped_ptr.?))[0 .. input.len * @sizeOf(culling.LODCullCandidate)], std.mem.sliceAsBytes(input));

        _ = self.lookup(self.terrain_instances[frame_index]) orelse return false;
        _ = self.lookup(self.water_instances[frame_index]) orelse return false;
        const terrain_indirect = self.lookup(self.terrain_indirect[frame_index]) orelse return false;
        const water_indirect = self.lookup(self.water_indirect[frame_index]) orelse return false;
        const cmd = command_buffer;
        const counter_bytes = MAX_LOD_LEVELS * 2 * @sizeOf(u32);
        const stream_command_bytes = self.capacity * MAX_LOD_LEVELS * @sizeOf(rhi.DrawIndirectCommand);
        const counters = self.lookup(self.counters[frame_index]) orelse return false;
        c.vkCmdFillBuffer(cmd, counters.buffer, 0, counter_bytes, 0);
        c.vkCmdFillBuffer(cmd, terrain_indirect.buffer, 0, stream_command_bytes, 0);
        c.vkCmdFillBuffer(cmd, water_indirect.buffer, 0, stream_command_bytes, 0);
        var transfer_to_compute = std.mem.zeroes(c.VkMemoryBarrier);
        transfer_to_compute.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        transfer_to_compute.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        transfer_to_compute.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT | c.VK_PIPELINE_STAGE_HOST_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &transfer_to_compute, 0, null, 0, null);

        var push = config;
        push.candidate_count = @intCast(input.len);
        push.max_commands_per_lod = @intCast(self.capacity);
        if (self.validate) {
            self.expected_counts[frame_index] = tryExpectedIds(self, frame_index, input, push) catch return false;
            self.expected_valid[frame_index] = true;
        }
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[frame_index], 0, null);
        c.vkCmdPushConstants(cmd, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(culling.LODCullDispatch), &push);
        c.vkCmdDispatch(cmd, @divFloor(@as(u32, @intCast(input.len)) + WORKGROUP_SIZE - 1, WORKGROUP_SIZE), 1, 1);

        if (self.validate) {
            var compute_to_copy = std.mem.zeroes(c.VkMemoryBarrier);
            compute_to_copy.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
            compute_to_copy.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
            compute_to_copy.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT | c.VK_ACCESS_HOST_READ_BIT;
            c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT | c.VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &compute_to_copy, 0, null, 0, null);
            var copy = std.mem.zeroes(c.VkBufferCopy);
            copy.size = counter_bytes;
            c.vkCmdCopyBuffer(cmd, counters.buffer, self.counter_readbacks[frame_index].buffer, 1, &copy);
            var copy_to_host = std.mem.zeroes(c.VkMemoryBarrier);
            copy_to_host.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
            copy_to_host.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            copy_to_host.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
            c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_HOST_BIT, 0, 1, &copy_to_host, 0, null, 0, null);
        }

        var compute_to_draw = std.mem.zeroes(c.VkMemoryBarrier);
        compute_to_draw.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        compute_to_draw.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        compute_to_draw.dstAccessMask = c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT | c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT | c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT, 0, 1, &compute_to_draw, 0, null, 0, null);
        return true;
    }

    fn lookup(self: *LODCullingSystem, handle: rhi.BufferHandle) ?Utils.VulkanBuffer {
        return self.ctx.resources.buffers.get(handle);
    }

    fn validatePrevious(self: *LODCullingSystem, frame_index: usize) void {
        if (!self.validate or !self.expected_valid[frame_index]) return;
        const mapped = self.counter_readbacks[frame_index].mapped_ptr orelse return;
        const actual: *align(1) const [MAX_LOD_LEVELS * 2]u32 = @ptrCast(mapped);
        var mismatch = false;
        for (self.expected_counts[frame_index], actual.*) |expected, observed| {
            if (expected != observed) mismatch = true;
        }
        mismatch = mismatch or !idsMatch(self.expected_ids[frame_index][0].items, self.terrain_ids[frame_index].mapped_ptr.?, actual.*, self.capacity, 0) or !idsMatch(self.expected_ids[frame_index][1].items, self.water_ids[frame_index].mapped_ptr.?, actual.*, self.capacity, MAX_LOD_LEVELS);
        if (mismatch) {
            self.validation_mismatch_count +%= 1;
            @import("engine-core").log.log.warn("LOD GPU culling validation mismatch frame_slot={} expected={any} actual={any}", .{ frame_index, self.expected_counts[frame_index], actual.* });
        }
        self.expected_valid[frame_index] = false;
    }

    fn initPipeline(self: *LODCullingSystem) !void {
        const vk = self.ctx.vulkan_device.vk_device;
        var pool_sizes = [_]c.VkDescriptorPoolSize{.{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 8 * FRAME_COUNT }};
        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = FRAME_COUNT;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes;
        try Utils.checkVk(c.vkCreateDescriptorPool(vk, &pool_info, null, &self.descriptor_pool));
        var bindings: [8]c.VkDescriptorSetLayoutBinding = undefined;
        for (&bindings, 0..) |*binding, i| binding.* = .{ .binding = @intCast(i), .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null };
        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = bindings.len;
        layout_info.pBindings = &bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_layout));
        var layouts = [_]c.VkDescriptorSetLayout{self.descriptor_layout} ** FRAME_COUNT;
        var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = self.descriptor_pool;
        alloc_info.descriptorSetCount = FRAME_COUNT;
        alloc_info.pSetLayouts = &layouts;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info, &self.descriptor_sets));
        self.updateDescriptors();
        var range = std.mem.zeroes(c.VkPushConstantRange);
        range.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        range.size = @sizeOf(culling.LODCullDispatch);
        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &self.descriptor_layout;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &range;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipeline_layout_info, null, &self.pipeline_layout));
        const module = try loadShader(vk, self.allocator);
        defer c.vkDestroyShaderModule(vk, module, null);
        var stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
        stage.module = module;
        stage.pName = "main";
        var info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
        info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        info.stage = stage;
        info.layout = self.pipeline_layout;
        try Utils.checkVk(c.vkCreateComputePipelines(vk, null, 1, &info, null, &self.pipeline));
    }

    fn updateDescriptors(self: *LODCullingSystem) void {
        var writes: [8 * FRAME_COUNT]c.VkWriteDescriptorSet = undefined;
        var infos: [8 * FRAME_COUNT]c.VkDescriptorBufferInfo = undefined;
        var n: usize = 0;
        for (0..FRAME_COUNT) |fi| {
            const buffers = [_]c.VkBuffer{
                self.candidates[fi].buffer,
                self.lookup(self.terrain_instances[fi]).?.buffer,
                self.lookup(self.water_instances[fi]).?.buffer,
                self.lookup(self.terrain_indirect[fi]).?.buffer,
                self.lookup(self.water_indirect[fi]).?.buffer,
                self.lookup(self.counters[fi]).?.buffer,
                self.terrain_ids[fi].buffer,
                self.water_ids[fi].buffer,
            };
            for (buffers, 0..) |buffer, binding| {
                infos[n] = .{ .buffer = buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
                writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
                writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes[n].dstSet = self.descriptor_sets[fi];
                writes[n].dstBinding = @intCast(binding);
                writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
                writes[n].descriptorCount = 1;
                writes[n].pBufferInfo = &infos[n];
                n += 1;
            }
        }
        c.vkUpdateDescriptorSets(self.ctx.vulkan_device.vk_device, @intCast(n), &writes, 0, null);
    }

    fn destroyPipeline(self: *LODCullingSystem) void {
        const vk = self.ctx.vulkan_device.vk_device;
        if (self.pipeline != null) c.vkDestroyPipeline(vk, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
        if (self.descriptor_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.descriptor_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(vk, self.descriptor_pool, null);
    }
};

const VTABLE = culling.ILODCullingSystem.VTable{
    .deinit = struct {
        fn call(ptr: *anyopaque) void {
            (@as(*LODCullingSystem, @ptrCast(@alignCast(ptr)))).deinit();
        }
    }.call,
    .dispatch = struct {
        fn call(ptr: *anyopaque, frame: usize, candidates: []const culling.LODCullCandidate, config: culling.LODCullDispatch) bool {
            return (@as(*LODCullingSystem, @ptrCast(@alignCast(ptr)))).dispatch(frame, candidates, config);
        }
    }.call,
    .instanceBuffer = struct {
        fn call(ptr: *anyopaque, frame: usize, fluid: bool) rhi.BufferHandle {
            const self: *LODCullingSystem = @ptrCast(@alignCast(ptr));
            return if (fluid) self.water_instances[frame] else self.terrain_instances[frame];
        }
    }.call,
    .indirectBuffer = struct {
        fn call(ptr: *anyopaque, frame: usize, fluid: bool) rhi.BufferHandle {
            const self: *LODCullingSystem = @ptrCast(@alignCast(ptr));
            return if (fluid) self.water_indirect[frame] else self.terrain_indirect[frame];
        }
    }.call,
    .countBuffer = struct {
        fn call(ptr: *anyopaque, frame: usize) rhi.BufferHandle {
            const self: *LODCullingSystem = @ptrCast(@alignCast(ptr));
            return self.counters[frame];
        }
    }.call,
    .diagnostics = struct {
        fn call(ptr: *anyopaque) culling.LODCullDiagnostics {
            const self: *LODCullingSystem = @ptrCast(@alignCast(ptr));
            return .{ .validation_mismatch_count = self.validation_mismatch_count };
        }
    }.call,
};

pub fn create(allocator: std.mem.Allocator, ctx: *VulkanContext, capacity: usize) !rhi.ILODCullingSystem {
    const system = try LODCullingSystem.init(allocator, ctx, capacity);
    return .{ .ptr = system, .vtable = &VTABLE };
}

fn destroyNative(device: c.VkDevice, buffer: *Utils.VulkanBuffer) void {
    if (buffer.mapped_ptr != null) c.vkUnmapMemory(device, buffer.memory);
    if (buffer.buffer != null) c.vkDestroyBuffer(device, buffer.buffer, null);
    if (buffer.memory != null) c.vkFreeMemory(device, buffer.memory, null);
    buffer.* = .{};
}

fn loadShader(device: c.VkDevice, allocator: std.mem.Allocator) !c.VkShaderModule {
    const bytes = try fs.cwd().readFileAlloc(SHADER_PATH, allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len % 4 != 0) return error.InvalidShader;
    var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = bytes.len;
    info.pCode = @ptrCast(@alignCast(bytes.ptr));
    var module: c.VkShaderModule = null;
    try Utils.checkVk(c.vkCreateShaderModule(device, &info, null, &module));
    return module;
}

fn cpuExpectedCounts(input: []const culling.LODCullCandidate, config: culling.LODCullDispatch) [MAX_LOD_LEVELS * 2]u32 {
    var counts = [_]u32{0} ** (MAX_LOD_LEVELS * 2);
    for (input) |candidate| {
        if (!cpuVisible(candidate, config)) continue;
        const lod = @min(candidate.lod_and_padding[0], MAX_LOD_LEVELS - 1);
        if (candidate.terrain_command.vertexCount != 0 and counts[lod] < config.max_commands_per_lod) counts[lod] += 1;
        const water_index = MAX_LOD_LEVELS + lod;
        if (candidate.water_command.vertexCount != 0 and counts[water_index] < config.max_commands_per_lod) counts[water_index] += 1;
    }
    return counts;
}

fn tryExpectedIds(self: *LODCullingSystem, frame_index: usize, input: []const culling.LODCullCandidate, config: culling.LODCullDispatch) ![MAX_LOD_LEVELS * 2]u32 {
    var counts = [_]u32{0} ** (MAX_LOD_LEVELS * 2);
    const stream_len = self.capacity * MAX_LOD_LEVELS;
    for (&self.expected_ids[frame_index]) |*ids| {
        try ids.resize(self.allocator, stream_len);
        @memset(ids.items, std.math.maxInt(u32));
    }
    for (input, 0..) |candidate, candidate_id| {
        if (!cpuVisible(candidate, config)) continue;
        const lod = @min(candidate.lod_and_padding[0], MAX_LOD_LEVELS - 1);
        const terrain_slot = lod * self.capacity + counts[lod];
        if (candidate.terrain_command.vertexCount != 0 and counts[lod] < config.max_commands_per_lod) {
            self.expected_ids[frame_index][0].items[terrain_slot] = @intCast(candidate_id);
            counts[lod] += 1;
        }
        const water_count_index = MAX_LOD_LEVELS + lod;
        const water_slot = lod * self.capacity + counts[water_count_index];
        if (candidate.water_command.vertexCount != 0 and counts[water_count_index] < config.max_commands_per_lod) {
            self.expected_ids[frame_index][1].items[water_slot] = @intCast(candidate_id);
            counts[water_count_index] += 1;
        }
    }
    return counts;
}

fn idsMatch(expected: []const u32, mapped: *anyopaque, counts: [MAX_LOD_LEVELS * 2]u32, capacity: usize, count_base: usize) bool {
    const actual: [*]align(1) const u32 = @ptrCast(mapped);
    for (0..MAX_LOD_LEVELS) |lod| {
        const base = lod * capacity;
        const count = @min(@as(usize, counts[count_base + lod]), capacity);
        var index: usize = 0;
        while (index < count) : (index += 1) {
            const actual_id = actual[base + index];
            var found = false;
            var expected_index: usize = 0;
            while (expected_index < count) : (expected_index += 1) {
                if (expected[base + expected_index] == actual_id) {
                    found = true;
                    break;
                }
            }
            if (!found) return false;
        }
    }
    return true;
}

fn cpuVisible(candidate: culling.LODCullCandidate, config: culling.LODCullDispatch) bool {
    for (config.planes) |plane| {
        const x = if (plane[0] >= 0) candidate.max_point[0] else candidate.min_point[0];
        const y = if (plane[1] >= 0) candidate.max_point[1] else candidate.min_point[1];
        const z = if (plane[2] >= 0) candidate.max_point[2] else candidate.min_point[2];
        if (plane[0] * x + plane[1] * y + plane[2] * z + plane[3] < 0) return false;
    }
    if (config.max_distance_blocks <= 0) return true;
    const dx: f32 = if (candidate.min_point[0] > 0) candidate.min_point[0] else if (candidate.max_point[0] < 0) candidate.max_point[0] else 0;
    const dz: f32 = if (candidate.min_point[2] > 0) candidate.min_point[2] else if (candidate.max_point[2] < 0) candidate.max_point[2] else 0;
    return dx * dx + dz * dz <= config.max_distance_blocks * config.max_distance_blocks;
}

fn envEnabled(name: [:0]const u8) bool {
    return @import("engine-core").envFlag(name, false);
}

test "LOD culling CPU validation mirrors terrain and water stream partitioning" {
    var candidate = std.mem.zeroes(culling.LODCullCandidate);
    candidate.min_point = .{ -1, -1, -1, 0 };
    candidate.max_point = .{ 1, 1, 1, 0 };
    candidate.terrain_command.vertexCount = 3;
    candidate.water_command.vertexCount = 6;
    candidate.lod_and_padding[0] = 2;
    const planes = [_][4]f32{.{ 0, 0, 0, 1 }} ** 6;
    const counts = cpuExpectedCounts(&.{candidate}, .{ .planes = planes, .candidate_count = 1, .max_distance_blocks = 10, .max_commands_per_lod = 4 });
    try std.testing.expectEqual(@as(u32, 1), counts[2]);
    try std.testing.expectEqual(@as(u32, 1), counts[MAX_LOD_LEVELS + 2]);
}

test "LOD culling validation compares candidate sets independent of atomic order" {
    var expected = [_]u32{std.math.maxInt(u32)} ** (MAX_LOD_LEVELS * 2);
    expected[0] = 4;
    expected[1] = 9;
    const actual = [_]u32{ 9, 4 } ++ ([_]u32{0} ** (MAX_LOD_LEVELS * 2 - 2));
    const counts = [_]u32{2} ++ ([_]u32{0} ** (MAX_LOD_LEVELS * 2 - 1));
    try std.testing.expect(idsMatch(&expected, @ptrCast(@constCast(&actual)), counts, 2, 0));
}
