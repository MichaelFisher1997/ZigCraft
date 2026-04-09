//! GPU compute mesher - dispatches compute shader to generate chunk meshes on GPU.
//!
//! Reads block data from GpuBlockBuffer and produces vertex data via a compute
//! shader (mesh.comp). Eliminates the CPU meshing bottleneck for chunks that
//! have been uploaded to the GPU block buffer.
//!
//! ## Architecture
//!
//! ```
//! [GpuBlockBuffer] → [mesh.comp] → [Vertex Output Buffer] → [Draw]
//!                                        ↑
//!                [Block Registry Buffer] ─┘
//! ```
//!
//! ## Step 1 (Current)
//!
//! - Basic face culling: emit 1 quad per visible face (no greedy merge)
//! - Cross block support (flowers, saplings, etc.)
//! - Three render passes: solid, cutout, fluid
//! - Per-chunk dispatch with push constants for neighbor data
//! - 1-frame readback lag for vertex counts

const std = @import("std");
const c = @import("../c.zig").c;
const rhi_pkg = @import("../engine/graphics/rhi.zig");
const log = @import("../engine/core/log.zig");
const VulkanContext = @import("../engine/graphics/vulkan/rhi_context_types.zig").VulkanContext;
const Utils = @import("../engine/graphics/vulkan/utils.zig");
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const block_registry = @import("block_registry.zig");
const GpuBlockBuffer = @import("gpu_block_buffer.zig").GpuBlockBuffer;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_VOLUME = @import("chunk.zig").CHUNK_VOLUME;

pub const MESH_SHADER_PATH = "assets/shaders/vulkan/mesh.comp.spv";
pub const WORKGROUP_SIZE: u32 = 256;
const MAX_FRAMES_IN_FLIGHT = rhi_pkg.MAX_FRAMES_IN_FLIGHT;

const VERTEX_SIZE_U32 = 8;

pub const GpuBlockInfo = extern struct {
    flags: u32,
    color: u32,
    tile_top: u32,
    tile_bottom: u32,
    tile_side: u32,
};

const MeshPushConstants = extern struct {
    chunk_slot: u32,
    neighbor_north_slot: u32,
    neighbor_south_slot: u32,
    neighbor_east_slot: u32,
    neighbor_west_slot: u32,
    chunk_x: i32,
    chunk_z: i32,
    render_pass: u32,
};

pub const ChunkMeshDispatch = struct {
    chunk_slot: u32,
    neighbor_north_slot: u32,
    neighbor_south_slot: u32,
    neighbor_east_slot: u32,
    neighbor_west_slot: u32,
    chunk_x: i32,
    chunk_z: i32,
};

pub const ChunkMeshResult = struct {
    vertex_counts: [3]u32,
    chunk_x: i32,
    chunk_z: i32,
};

const MAX_OUTPUT_VERTICES: usize = 4 * 1024 * 1024;
const INVALID_SLOT: u32 = 0xFFFFFFFF;

pub const GpuMesher = struct {
    allocator: std.mem.Allocator,
    vk_ctx: *VulkanContext,

    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    block_registry_buffer: Utils.VulkanBuffer,
    counter_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    counter_readback_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    vertex_output_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,

    pending_dispatches: std.ArrayListUnmanaged(ChunkMeshDispatch),
    pending_results: std.ArrayListUnmanaged(ChunkMeshResult),
    prev_frame_dispatches: std.ArrayListUnmanaged(ChunkMeshDispatch),
    prev_frame_results: std.ArrayListUnmanaged(ChunkMeshResult),

    gpu_block_buffer: *GpuBlockBuffer,
    block_data_vk_buffer: c.VkBuffer,

    pub fn init(
        allocator: std.mem.Allocator,
        rhi: rhi_pkg.RHI,
        gpu_block_buffer: *GpuBlockBuffer,
        atlas: *const TextureAtlas,
    ) !*GpuMesher {
        const self = try allocator.create(GpuMesher);
        errdefer allocator.destroy(self);

        const vk_ctx: *VulkanContext = @ptrCast(@alignCast(rhi.ptr));

        self.* = .{
            .allocator = allocator,
            .vk_ctx = vk_ctx,
            .descriptor_sets = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet),
            .block_registry_buffer = .{},
            .counter_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .counter_readback_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .vertex_output_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .pending_dispatches = .empty,
            .pending_results = .empty,
            .prev_frame_dispatches = .empty,
            .prev_frame_results = .empty,
            .gpu_block_buffer = gpu_block_buffer,
            .block_data_vk_buffer = vk_ctx.resources.getNativeBuffer(gpu_block_buffer.getBufferHandle()) orelse @as(c.VkBuffer, @ptrFromInt(0)),
        };

        const registry_size = 256 * @sizeOf(GpuBlockInfo);
        self.block_registry_buffer = try Utils.createVulkanBuffer(
            &vk_ctx.vulkan_device,
            registry_size,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        errdefer unmapAndDestroy(vk_ctx.vulkan_device.vk_device, &self.block_registry_buffer);

        self.uploadBlockRegistry(atlas);

        const vertex_buf_size = MAX_OUTPUT_VERTICES * VERTEX_SIZE_U32 * @sizeOf(u32);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.vertex_output_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                vertex_buf_size,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            );

            self.counter_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                @sizeOf(u32) * 4,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            );

            self.counter_readback_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                @sizeOf(u32) * 4,
                c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );
        }
        errdefer self.destroyAllBuffers();

        try ensureShaderFileExists(MESH_SHADER_PATH);
        try self.initComputeResources();

        log.log.info("GpuMesher initialized (output_buffer={}MB, max_vertices={})", .{ vertex_buf_size / (1024 * 1024), MAX_OUTPUT_VERTICES });

        return self;
    }

    pub fn deinit(self: *GpuMesher) void {
        self.deinitComputeResources();
        self.destroyAllBuffers();

        self.pending_dispatches.deinit(self.allocator);
        self.pending_results.deinit(self.allocator);
        self.prev_frame_dispatches.deinit(self.allocator);
        self.prev_frame_results.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn beginFrame(self: *GpuMesher) void {
        const fi = self.vk_ctx.frames.current_frame;
        const cmd = self.vk_ctx.frames.command_buffers[fi] orelse return;

        c.vkCmdFillBuffer(cmd, self.counter_buffers[fi].buffer, 0, @sizeOf(u32), 0);

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

        self.prev_frame_dispatches.clearRetainingCapacity();
        self.prev_frame_results.clearRetainingCapacity();
    }

    pub fn enqueueChunk(self: *GpuMesher, dispatch: ChunkMeshDispatch) !void {
        try self.pending_dispatches.append(self.allocator, dispatch);
    }

    pub fn dispatchPending(self: *GpuMesher, render_pass: u32) void {
        const fi = self.vk_ctx.frames.current_frame;
        const cmd = self.vk_ctx.frames.command_buffers[fi] orelse return;

        if (self.pending_dispatches.items.len == 0) return;

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[fi], 0, null);

        for (self.pending_dispatches.items) |dispatch| {
            var push = MeshPushConstants{
                .chunk_slot = dispatch.chunk_slot,
                .neighbor_north_slot = dispatch.neighbor_north_slot,
                .neighbor_south_slot = dispatch.neighbor_south_slot,
                .neighbor_east_slot = dispatch.neighbor_east_slot,
                .neighbor_west_slot = dispatch.neighbor_west_slot,
                .chunk_x = dispatch.chunk_x,
                .chunk_z = dispatch.chunk_z,
                .render_pass = render_pass,
            };
            c.vkCmdPushConstants(cmd, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(MeshPushConstants), &push);

            const groups = divCeil(CHUNK_VOLUME, WORKGROUP_SIZE);
            c.vkCmdDispatch(cmd, groups, 1, 1);
        }

        self.pending_dispatches.clearRetainingCapacity();
    }

    pub fn endFrame(self: *GpuMesher) void {
        const fi = self.vk_ctx.frames.current_frame;
        const cmd = self.vk_ctx.frames.command_buffers[fi] orelse return;

        var compute_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        compute_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        compute_barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        compute_barrier.dstAccessMask = c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | c.VK_ACCESS_TRANSFER_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            1,
            &compute_barrier,
            0,
            null,
            0,
            null,
        );

        self.copyCounterToReadback(cmd, fi);
    }

    pub fn readbackResults(self: *GpuMesher, frame_index: usize) u32 {
        const buf = &self.counter_readback_buffers[frame_index];
        if (buf.mapped_ptr == null) return 0;
        const ptr: *align(1) u32 = @ptrCast(@alignCast(buf.mapped_ptr.?));
        return ptr.*;
    }

    pub fn getOutputBuffer(self: *const GpuMesher, frame_index: usize) c.VkBuffer {
        return self.vertex_output_buffers[frame_index].buffer;
    }

    pub fn swapFrameState(self: *GpuMesher) void {
        const tmp_dispatches = self.prev_frame_dispatches;
        self.prev_frame_dispatches = self.pending_dispatches;
        self.pending_dispatches = tmp_dispatches;
        self.pending_dispatches.clearRetainingCapacity();

        const tmp_results = self.prev_frame_results;
        self.prev_frame_results = self.pending_results;
        self.pending_results = tmp_results;
        self.pending_results.clearRetainingCapacity();
    }

    fn uploadBlockRegistry(self: *GpuMesher, atlas: *const TextureAtlas) void {
        if (self.block_registry_buffer.mapped_ptr == null) return;

        const ptr: [*]GpuBlockInfo = @ptrCast(@alignCast(self.block_registry_buffer.mapped_ptr.?));

        for (0..256) |block_id| {
            const def = block_registry.getBlockDefinition(@enumFromInt(@as(u8, @intCast(block_id))));
            const tiles = atlas.getTilesForBlock(@intCast(block_id));

            var flags: u32 = 0;
            if (def.is_solid) flags |= 1;
            if (def.is_transparent) flags |= 2;
            if (def.is_fluid) flags |= 4;

            const pass_val: u32 = switch (def.render_pass) {
                .solid => 0,
                .cutout => 1,
                .fluid => 2,
                .translucent => 3,
            };
            flags |= pass_val << 3;

            const shape_val: u32 = switch (def.render_shape) {
                .cube => 0,
                .cross => 1,
            };
            flags |= shape_val << 5;

            const color = encodeColorF32(def.default_color);

            ptr[block_id] = .{
                .flags = flags,
                .color = color,
                .tile_top = tiles.top,
                .tile_bottom = tiles.bottom,
                .tile_side = tiles.side,
            };
        }
    }

    fn initComputeResources(self: *GpuMesher) !void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 4 * MAX_FRAMES_IN_FLIGHT },
        };

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = MAX_FRAMES_IN_FLIGHT;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes;
        try Utils.checkVk(c.vkCreateDescriptorPool(vk, &pool_info, null, &self.descriptor_pool));

        const bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = bindings.len;
        layout_info.pBindings = &bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));

        var layouts = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSetLayout);
        for (&layouts) |*l| l.* = self.descriptor_set_layout;

        var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = self.descriptor_pool;
        alloc_info.descriptorSetCount = MAX_FRAMES_IN_FLIGHT;
        alloc_info.pSetLayouts = &layouts;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info, &self.descriptor_sets));

        self.updateAllDescriptorSets();

        var pc_range = std.mem.zeroes(c.VkPushConstantRange);
        pc_range.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        pc_range.offset = 0;
        pc_range.size = @sizeOf(MeshPushConstants);

        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &self.descriptor_set_layout;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &pc_range;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipeline_layout_info, null, &self.pipeline_layout));

        const shader_module = try loadShaderModule(vk, MESH_SHADER_PATH, self.allocator);
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

    fn updateAllDescriptorSets(self: *GpuMesher) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;
        const registry_size: u32 = @intCast(256 * @sizeOf(GpuBlockInfo));
        const vertex_buf_size: u32 = @intCast(MAX_OUTPUT_VERTICES * VERTEX_SIZE_U32 * @sizeOf(u32));

        var writes: [4 * MAX_FRAMES_IN_FLIGHT]c.VkWriteDescriptorSet = undefined;
        var block_buf_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var registry_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var vertex_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var counter_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var n: usize = 0;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            block_buf_infos[i] = .{
                .buffer = self.block_data_vk_buffer,
                .offset = 0,
                .range = c.VK_WHOLE_SIZE,
            };
            registry_infos[i] = .{
                .buffer = self.block_registry_buffer.buffer,
                .offset = 0,
                .range = registry_size,
            };
            vertex_infos[i] = .{
                .buffer = self.vertex_output_buffers[i].buffer,
                .offset = 0,
                .range = vertex_buf_size,
            };
            counter_infos[i] = .{
                .buffer = self.counter_buffers[i].buffer,
                .offset = 0,
                .range = @sizeOf(u32) * 4,
            };

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.descriptor_sets[i];
            writes[n].dstBinding = 0;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &block_buf_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.descriptor_sets[i];
            writes[n].dstBinding = 1;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &registry_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.descriptor_sets[i];
            writes[n].dstBinding = 2;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &vertex_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.descriptor_sets[i];
            writes[n].dstBinding = 3;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &counter_infos[i];
            n += 1;
        }

        c.vkUpdateDescriptorSets(vk, @intCast(n), &writes[0], 0, null);
    }

    fn deinitComputeResources(self: *GpuMesher) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;
        if (self.pipeline != null) c.vkDestroyPipeline(vk, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.descriptor_set_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(vk, self.descriptor_pool, null);

        self.pipeline = null;
        self.pipeline_layout = null;
        self.descriptor_set_layout = null;
        self.descriptor_pool = null;
        self.descriptor_sets = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet);
    }

    fn destroyAllBuffers(self: *GpuMesher) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        unmapAndDestroy(vk, &self.block_registry_buffer);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            unmapAndDestroy(vk, &self.vertex_output_buffers[i]);
            unmapAndDestroy(vk, &self.counter_buffers[i]);
            unmapAndDestroy(vk, &self.counter_readback_buffers[i]);
        }

        self.block_registry_buffer = .{};
        self.vertex_output_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
        self.counter_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
        self.counter_readback_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
    }

    fn copyCounterToReadback(self: *GpuMesher, cmd: c.VkCommandBuffer, frame_index: usize) void {
        const src = self.counter_buffers[frame_index];
        const dst = self.counter_readback_buffers[frame_index];

        var copy_region = std.mem.zeroes(c.VkBufferCopy);
        copy_region.srcOffset = 0;
        copy_region.dstOffset = 0;
        copy_region.size = @sizeOf(u32) * 4;
        c.vkCmdCopyBuffer(cmd, src.buffer, dst.buffer, 1, &copy_region);

        var copy_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        copy_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        copy_barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        copy_barrier.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_HOST_BIT,
            0,
            1,
            &copy_barrier,
            0,
            null,
            0,
            null,
        );
    }
};

fn encodeColorF32(col: [3]f32) u32 {
    const r: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, col[0])) * 255.0));
    const g: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, col[1])) * 255.0));
    const b: u8 = @intFromFloat(@round(@max(0.0, @min(1.0, col[2])) * 255.0));
    return @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16) | (@as(u32, @as(u8, 255)) << 24);
}

fn unmapAndDestroy(vk: c.VkDevice, buf: *Utils.VulkanBuffer) void {
    if (buf.mapped_ptr != null) {
        c.vkUnmapMemory(vk, buf.memory);
        buf.mapped_ptr = null;
    }
    if (buf.buffer != null) c.vkDestroyBuffer(vk, buf.buffer, null);
    if (buf.memory != null) c.vkFreeMemory(vk, buf.memory, null);
    buf.* = .{};
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
        log.log.errWithTrace("Mesh compute shader artifact missing: {s} ({})", .{ path, err });
        log.log.err("Run `nix develop --command zig build` to regenerate Vulkan SPIR-V shaders.", .{});
        return err;
    };
}

fn divCeil(v: u32, d: u32) u32 {
    return @divFloor(v + d - 1, d);
}
