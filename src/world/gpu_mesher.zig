//! GPU-driven compute meshing system (Issue #391).
//!
//! Dispatches a compute shader that reads chunk block data from the GpuBlockBuffer
//! and produces vertex data directly on the GPU, bypassing CPU meshing entirely.
//!
//! ## Architecture
//!
//! ```
//! [GpuBlockBuffer] → [mesh_build.comp] → [Vertex Output Buffer] → [DrawIndirect]
//!                                         ↑
//!                        [BlockProps SSBO] ← compile-time registry
//! ```
//!
//! ## Integration Points
//!
//! - `MeshBuildPass` in `RenderGraph` dispatches before OpaquePass
//! - `WorldRenderer` switches between GPU and CPU draw paths
//! - `WorldStreamer` skips CPU mesh jobs when GPU mesher is active

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("../engine/core/log.zig");
const rhi_mod = @import("../engine/graphics/rhi.zig");
const VulkanContext = @import("../engine/graphics/vulkan/rhi_context_types.zig").VulkanContext;
const Utils = @import("../engine/graphics/vulkan/utils.zig");
const GpuBlockBuffer = @import("gpu_block_buffer.zig").GpuBlockBuffer;
const block_registry = @import("block_registry.zig");
const BlockType = @import("block.zig").BlockType;
const MAX_FRAMES_IN_FLIGHT = rhi_mod.MAX_FRAMES_IN_FLIGHT;

pub const MESH_BUILD_SHADER_PATH = "assets/shaders/vulkan/mesh_build.comp.spv";
pub const WORKGROUP_SIZE: u32 = 256;
pub const CHUNK_VOLUME: u32 = 16 * 256 * 16;
pub const MAX_VERTEX_BUFFER_SIZE: usize = 512 * 1024 * 1024; // 512MB
pub const VERTEX_SIZE_WORDS: u32 = 8; // 32 bytes / 4 bytes per word

pub const INVALID_SLOT: u32 = 0xFFFFFFFF;

const VulkanDevice = @import("../engine/graphics/vulkan_device.zig").VulkanDevice;

pub const ChunkMeshRequest = struct {
    cx: i32,
    cz: i32,
    center_slot: u32,
    north_slot: u32,
    south_slot: u32,
    east_slot: u32,
    west_slot: u32,
};

pub const MeshBuildResult = struct {
    solid_vertex_count: u32,
    cutout_vertex_count: u32,
    fluid_vertex_count: u32,
};

const PushConstants = extern struct {
    center_slot: u32,
    north_slot: u32,
    south_slot: u32,
    east_slot: u32,
    west_slot: u32,
};

const CounterBuffer = extern struct {
    solid_vertex_count: u32,
    _pad0: u32,
    cutout_vertex_count: u32,
    _pad1: u32,
    fluid_vertex_count: u32,
    _pad2: u32,
    solid_vertex_base: u32,
    _pad3: u32,
    cutout_vertex_base: u32,
    _pad4: u32,
    fluid_vertex_base: u32,
    _pad5: u32,
};

pub const GpuMesher = struct {
    allocator: std.mem.Allocator,
    vk_ctx: *VulkanContext,
    gpu_block_buffer: *GpuBlockBuffer,
    enabled: bool,

    vertex_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    counter_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    counter_readback_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    block_props_buffer: Utils.VulkanBuffer,

    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    dirty_chunks: std.ArrayListUnmanaged(ChunkMeshRequest),
    last_results: MeshBuildResult,

    pub fn init(allocator: std.mem.Allocator, vk_ctx: *VulkanContext, gpu_block_buffer: *GpuBlockBuffer) !*GpuMesher {
        const self = try allocator.create(GpuMesher);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .vk_ctx = vk_ctx,
            .gpu_block_buffer = gpu_block_buffer,
            .enabled = true,
            .vertex_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .counter_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .counter_readback_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .block_props_buffer = .{},
            .descriptor_sets = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet),
            .dirty_chunks = .empty,
            .last_results = .{ .solid_vertex_count = 0, .cutout_vertex_count = 0, .fluid_vertex_count = 0 },
        };

        errdefer self.destroyBuffers();
        errdefer self.deinitComputeResources();

        const vertex_buf_size = MAX_VERTEX_BUFFER_SIZE;
        const counter_buf_size = @sizeOf(CounterBuffer);

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.vertex_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                vertex_buf_size,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            );

            self.counter_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                counter_buf_size,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT | c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            );

            self.counter_readback_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                counter_buf_size,
                c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );
        }

        try self.uploadBlockProps();

        ensureShaderFileExists(MESH_BUILD_SHADER_PATH) catch {
            log.log.warn("GPU mesher shader not found, disabling compute meshing", .{});
            self.enabled = false;
            return self;
        };

        try self.initComputeResources();

        log.log.info("GpuMesher initialized (vertex buffer={}MB)", .{vertex_buf_size / (1024 * 1024)});
        return self;
    }

    pub fn deinit(self: *GpuMesher) void {
        self.deinitComputeResources();
        self.destroyBuffers();
        self.dirty_chunks.deinit(self.allocator);
        if (self.block_props_buffer.buffer != null) {
            const vk = self.vk_ctx.vulkan_device.vk_device;
            if (self.block_props_buffer.mapped_ptr != null) {
                c.vkUnmapMemory(vk, self.block_props_buffer.memory);
            }
            if (self.block_props_buffer.buffer != null) c.vkDestroyBuffer(vk, self.block_props_buffer.buffer, null);
            if (self.block_props_buffer.memory != null) c.vkFreeMemory(vk, self.block_props_buffer.memory, null);
        }
        self.allocator.destroy(self);
    }

    pub fn markDirty(self: *GpuMesher, req: ChunkMeshRequest) void {
        for (self.dirty_chunks.items) |existing| {
            if (existing.cx == req.cx and existing.cz == req.cz) return;
        }
        self.dirty_chunks.append(self.allocator, req) catch {
            log.log.warn("GpuMesher: failed to queue dirty chunk ({}, {})", .{ req.cx, req.cz });
        };
    }

    pub fn clearDirtyChunks(self: *GpuMesher) void {
        self.dirty_chunks.clearRetainingCapacity();
    }

    pub fn dispatchChunk(self: *GpuMesher, req: ChunkMeshRequest) void {
        const fi = self.vk_ctx.frames.current_frame;
        const cmd = self.vk_ctx.frames.command_buffers[fi];
        if (cmd == null) return;

        self.resetCounters(cmd.?, fi);

        const push = PushConstants{
            .center_slot = req.center_slot,
            .north_slot = req.north_slot,
            .south_slot = req.south_slot,
            .east_slot = req.east_slot,
            .west_slot = req.west_slot,
        };

        c.vkCmdBindPipeline(cmd.?, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        c.vkCmdBindDescriptorSets(cmd.?, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[fi], 0, null);
        c.vkCmdPushConstants(cmd.?, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(PushConstants), &push);

        const groups = divCeil(CHUNK_VOLUME, WORKGROUP_SIZE);
        c.vkCmdDispatch(cmd.?, groups, 1, 1);

        var barrier = std.mem.zeroes(c.VkMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT | c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd.?,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT | c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT,
            0,
            1,
            &barrier,
            0,
            null,
            0,
            null,
        );

        self.copyCountersToReadback(cmd.?, fi);
    }

    pub fn dispatchAll(self: *GpuMesher) void {
        if (!self.enabled) return;
        if (self.dirty_chunks.items.len == 0) return;

        for (self.dirty_chunks.items) |req| {
            self.dispatchChunk(req);
        }
    }

    pub fn readResults(self: *GpuMesher) MeshBuildResult {
        if (!self.enabled) return .{ .solid_vertex_count = 0, .cutout_vertex_count = 0, .fluid_vertex_count = 0 };
        const fi = self.vk_ctx.frames.current_frame;
        const prev_fi = (fi + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT;
        const buf = &self.counter_readback_buffers[prev_fi];
        if (buf.mapped_ptr == null) return .{ .solid_vertex_count = 0, .cutout_vertex_count = 0, .fluid_vertex_count = 0 };

        const ptr: *align(1) CounterBuffer = @ptrCast(@alignCast(buf.mapped_ptr.?));
        self.last_results = .{
            .solid_vertex_count = ptr.solid_vertex_count,
            .cutout_vertex_count = ptr.cutout_vertex_count,
            .fluid_vertex_count = ptr.fluid_vertex_count,
        };
        return self.last_results;
    }

    pub fn getVertexBuffer(self: *GpuMesher, frame_index: usize) ?c.VkBuffer {
        if (!self.enabled) return null;
        return self.vertex_buffers[frame_index].buffer;
    }

    pub fn getVertexBufferSize() usize {
        return MAX_VERTEX_BUFFER_SIZE;
    }

    fn resetCounters(self: *GpuMesher, cmd: c.VkCommandBuffer, frame_index: usize) void {
        c.vkCmdFillBuffer(cmd, self.counter_buffers[frame_index].buffer, 0, @sizeOf(CounterBuffer), 0);

        var barrier = std.mem.zeroes(c.VkMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1,
            &barrier,
            0,
            null,
            0,
            null,
        );
    }

    fn copyCountersToReadback(self: *GpuMesher, cmd: c.VkCommandBuffer, frame_index: usize) void {
        const src = self.counter_buffers[frame_index];
        const dst = self.counter_readback_buffers[frame_index];

        var copy_region = std.mem.zeroes(c.VkBufferCopy);
        copy_region.srcOffset = 0;
        copy_region.dstOffset = 0;
        copy_region.size = @sizeOf(CounterBuffer);
        c.vkCmdCopyBuffer(cmd, src.buffer, dst.buffer, 1, &copy_region);

        var barrier = std.mem.zeroes(c.VkMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            c.VK_PIPELINE_STAGE_HOST_BIT,
            0,
            1,
            &barrier,
            0,
            null,
            0,
            null,
        );
    }

    fn uploadBlockProps(self: *GpuMesher) !void {
        const num_blocks: usize = 256;
        const entry_size = @sizeOf(u32) * 5; // flags, color, tile_top, tile_side, tile_bottom
        const total_size = num_blocks * entry_size;

        var data = try self.allocator.alloc(u32, num_blocks * 5);
        defer self.allocator.free(data);

        @setEvalBranchQuota(10000);
        comptime var field_idx: usize = 0;
        inline while (field_idx < @typeInfo(BlockType).@"enum".fields.len) : (field_idx += 1) {
            const field = @typeInfo(BlockType).@"enum".fields[field_idx];
            if (field.name[0] == '_') continue;
            const bt = @field(BlockType, field.name);
            const id: usize = @intFromEnum(bt);
            const def = block_registry.getBlockDefinition(bt);

            var flags: u32 = 0;
            if (def.is_solid) flags |= 1;
            if (def.is_transparent) flags |= 2;
            if (def.is_fluid) flags |= 4;
            if (def.render_shape == .cross) flags |= 8;
            const pass_val: u32 = switch (def.render_pass) {
                .solid => 0,
                .cutout => 1,
                .fluid => 2,
                .translucent => 0,
            };
            flags |= pass_val << 4;

            data[id * 5 + 0] = flags;

            const r: u32 = @intFromFloat(@round(@max(0.0, @min(1.0, def.default_color[0])) * 255.0));
            const g: u32 = @intFromFloat(@round(@max(0.0, @min(1.0, def.default_color[1])) * 255.0));
            const b: u32 = @intFromFloat(@round(@max(0.0, @min(1.0, def.default_color[2])) * 255.0));
            data[id * 5 + 1] = r | (g << 8) | (b << 16) | (255 << 24);

            data[id * 5 + 2] = 0;
            data[id * 5 + 3] = 0;
            data[id * 5 + 4] = 0;
        }

        self.block_props_buffer = try Utils.createVulkanBuffer(
            &self.vk_ctx.vulkan_device,
            total_size,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        if (self.block_props_buffer.mapped_ptr) |ptr| {
            const dst_bytes: [*]u8 = @ptrCast(ptr);
            const src_bytes: [*]const u8 = @ptrCast(data.ptr);
            @memcpy(dst_bytes[0..total_size], src_bytes[0..total_size]);
        }
    }

    pub fn updateTileIds(self: *GpuMesher, tile_data: []const u32) void {
        if (self.block_props_buffer.mapped_ptr == null) return;
        if (tile_data.len != 256 * 3) return;

        const ptr: [*]u32 = @ptrCast(@alignCast(self.block_props_buffer.mapped_ptr.?));
        for (0..256) |i| {
            ptr[i * 5 + 2] = tile_data[i * 3 + 0]; // tile_top
            ptr[i * 5 + 3] = tile_data[i * 3 + 1]; // tile_side
            ptr[i * 5 + 4] = tile_data[i * 3 + 2]; // tile_bottom
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
        pc_range.size = @sizeOf(PushConstants);

        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &self.descriptor_set_layout;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &pc_range;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipeline_layout_info, null, &self.pipeline_layout));

        const shader_module = try loadShaderModule(vk, MESH_BUILD_SHADER_PATH, self.allocator);
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

        const block_buf = self.vk_ctx.resources.buffers.get(self.gpu_block_buffer.getBufferHandle()) orelse return;

        var writes: [4 * MAX_FRAMES_IN_FLIGHT]c.VkWriteDescriptorSet = undefined;
        var block_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var props_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var vertex_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var counter_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var n: usize = 0;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            block_infos[i] = c.VkDescriptorBufferInfo{
                .buffer = block_buf.buffer,
                .offset = 0,
                .range = c.VK_WHOLE_SIZE,
            };
            props_infos[i] = c.VkDescriptorBufferInfo{
                .buffer = self.block_props_buffer.buffer.?,
                .offset = 0,
                .range = 256 * 5 * @sizeOf(u32),
            };
            vertex_infos[i] = c.VkDescriptorBufferInfo{
                .buffer = self.vertex_buffers[i].buffer.?,
                .offset = 0,
                .range = c.VK_WHOLE_SIZE,
            };
            counter_infos[i] = c.VkDescriptorBufferInfo{
                .buffer = self.counter_buffers[i].buffer.?,
                .offset = 0,
                .range = @sizeOf(CounterBuffer),
            };

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.descriptor_sets[i];
            writes[n].dstBinding = 0;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &block_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.descriptor_sets[i];
            writes[n].dstBinding = 1;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &props_infos[i];
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

    fn destroyBuffers(self: *GpuMesher) void {
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            unmapAndDestroy(&self.vk_ctx.vulkan_device, &self.vertex_buffers[i]);
            unmapAndDestroy(&self.vk_ctx.vulkan_device, &self.counter_buffers[i]);
            unmapAndDestroy(&self.vk_ctx.vulkan_device, &self.counter_readback_buffers[i]);
        }
        self.vertex_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
        self.counter_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
        self.counter_readback_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
    }
};

fn unmapAndDestroy(device: *const @import("../engine/graphics/vulkan_device.zig").VulkanDevice, buf: *Utils.VulkanBuffer) void {
    const vk = device.vk_device;
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
        log.log.errWithTrace("Mesh build shader artifact missing: {s} ({})", .{ path, err });
        log.log.err("Run `nix develop --command zig build` to regenerate Vulkan SPIR-V shaders.", .{});
        return err;
    };
}

fn divCeil(v: u32, d: u32) u32 {
    return @divFloor(v + d - 1, d);
}
