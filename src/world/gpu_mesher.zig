//! GPU mesher that builds chunk vertices via compute, then copies completed
//! batches into the persistent megabuffer on the following frame.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("../engine/core/log.zig");
const rhi_pkg = @import("../engine/graphics/rhi.zig");
const VulkanContext = @import("../engine/graphics/vulkan/rhi_context_types.zig").VulkanContext;
const Utils = @import("../engine/graphics/vulkan/utils.zig");
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const GpuBlockBuffer = @import("gpu_block_buffer.zig").GpuBlockBuffer;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const GlobalVertexAllocator = @import("chunk_allocator.zig").GlobalVertexAllocator;
const VertexAllocation = @import("chunk_allocator.zig").VertexAllocation;

pub const MESH_SHADER_PATH = "assets/shaders/vulkan/mesh.comp.spv";
pub const MAX_GPU_MESH_BATCH: usize = 32;
pub const MAX_PASS_VERTICES: u32 = 65536;
pub const MAX_VERTICES_PER_CHUNK: u32 = MAX_PASS_VERTICES * 3;
pub const VERTEX_SIZE: u32 = @sizeOf(rhi_pkg.Vertex);
pub const CHUNK_Y: u32 = 256;
pub const MAX_FRAMES_IN_FLIGHT = rhi_pkg.MAX_FRAMES_IN_FLIGHT;
pub const MAX_BLOCK_TYPES = 256;

const MeshPushConstants = extern struct {
    chunk_slot: u32,
    request_index: u32,
    output_offset: u32,
    neighbor_north_slot: i32,
    neighbor_south_slot: i32,
    neighbor_east_slot: i32,
    neighbor_west_slot: i32,
};

const MeshBuildResult = extern struct {
    solid_count: u32,
    cutout_count: u32,
    fluid_count: u32,
    overflow_mask: u32,
};

pub const ChunkMeshRequest = struct {
    cx: i32,
    cz: i32,
    gpu_slot: usize,
    job_token: u32,
};

pub const GpuMesherStats = struct {
    chunks_dispatched: u32 = 0,
    vertices_produced: u32 = 0,
    available: bool = false,
};

pub const GpuMesher = struct {
    allocator: std.mem.Allocator,
    rhi: rhi_pkg.RHI,
    rm: rhi_pkg.ResourceManager,
    vk_ctx: *VulkanContext,
    available: bool,

    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    output_handles: [MAX_FRAMES_IN_FLIGHT]rhi_pkg.BufferHandle,
    result_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    block_props_buffer: Utils.VulkanBuffer,

    mesh_queue: std.ArrayListUnmanaged(ChunkMeshRequest),
    submitted: [MAX_FRAMES_IN_FLIGHT]std.ArrayListUnmanaged(ChunkMeshRequest),

    stats: GpuMesherStats,

    pub fn init(
        allocator: std.mem.Allocator,
        rhi: rhi_pkg.RHI,
        atlas: *const TextureAtlas,
        gpu_block_buffer: *GpuBlockBuffer,
    ) !*GpuMesher {
        const self = try allocator.create(GpuMesher);
        errdefer allocator.destroy(self);

        const rm = rhi.resourceManager();
        const vk_ctx: *VulkanContext = @ptrCast(@alignCast(rhi.ptr));
        const output_size = @as(usize, MAX_GPU_MESH_BATCH) * @as(usize, MAX_VERTICES_PER_CHUNK) * @as(usize, VERTEX_SIZE);
        const result_size = MAX_GPU_MESH_BATCH * @sizeOf(MeshBuildResult);

        self.* = .{
            .allocator = allocator,
            .rhi = rhi,
            .rm = rm,
            .vk_ctx = vk_ctx,
            .available = false,
            .descriptor_sets = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet),
            .output_handles = .{ 0, 0 },
            .result_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .block_props_buffer = .{},
            .mesh_queue = .empty,
            .submitted = .{ .empty, .empty },
            .stats = .{},
        };

        errdefer self.deinit();

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.output_handles[i] = try rm.createBuffer(output_size, .storage);
            self.result_buffers[i] = try Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                result_size,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            );
        }

        try self.createBlockPropsBuffer(atlas);
        try ensureShaderFileExists(MESH_SHADER_PATH);
        try self.initComputeResources(gpu_block_buffer);

        self.available = true;
        self.stats.available = true;
        return self;
    }

    pub fn deinit(self: *GpuMesher) void {
        self.deinitComputeResources();
        for (self.output_handles) |handle| {
            if (handle != 0) self.rm.destroyBuffer(handle);
        }
        for (&self.result_buffers) |*buf| destroyVulkanBuffer(self.vk_ctx.vulkan_device.vk_device, buf);
        destroyVulkanBuffer(self.vk_ctx.vulkan_device.vk_device, &self.block_props_buffer);
        self.mesh_queue.deinit(self.allocator);
        for (&self.submitted) |*items| items.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn queueMesh(self: *GpuMesher, cx: i32, cz: i32, gpu_slot: usize, job_token: u32) bool {
        if (!self.available) return false;
        if (self.mesh_queue.items.len >= MAX_GPU_MESH_BATCH) return false;

        for (self.mesh_queue.items) |queued| {
            if (queued.cx == cx and queued.cz == cz) return true;
        }

        self.mesh_queue.append(self.allocator, .{ .cx = cx, .cz = cz, .gpu_slot = gpu_slot, .job_token = job_token }) catch return false;
        return true;
    }

    pub fn process(self: *GpuMesher, vertex_allocator: *GlobalVertexAllocator, storage: *ChunkStorage, gpu_block_buffer: *GpuBlockBuffer) void {
        if (!self.available) return;
        self.finalizeCompletedMeshes(vertex_allocator, storage);
        self.dispatchQueuedMeshes(gpu_block_buffer);
    }

    pub fn getStats(self: *const GpuMesher) GpuMesherStats {
        return self.stats;
    }

    fn finalizeCompletedMeshes(self: *GpuMesher, vertex_allocator: *GlobalVertexAllocator, storage: *ChunkStorage) void {
        const fi = self.vk_ctx.frames.current_frame;
        const prev_fi = (fi + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT;
        if (self.submitted[prev_fi].items.len == 0) return;

        _ = c.vkWaitForFences(self.vk_ctx.vulkan_device.vk_device, 1, &self.vk_ctx.frames.in_flight_fences[prev_fi], c.VK_TRUE, std.math.maxInt(u64));

        const cmd = self.vk_ctx.frames.command_buffers[fi];
        if (cmd == null) return;

        const src = self.vk_ctx.resources.buffers.get(self.output_handles[prev_fi]) orelse return;
        const dst = self.vk_ctx.resources.buffers.get(vertex_allocator.buffer) orelse return;
        const results = self.getMappedResults(prev_fi) orelse {
            log.log.warn("GPU_MESHER_FINALIZE: no mapped results for prev_fi={}", .{prev_fi});
            return;
        };

        var copied_any = false;

        storage.chunks_mutex.lock();
        defer storage.chunks_mutex.unlock();

        for (self.submitted[prev_fi].items, 0..) |req, idx| {
            if (idx >= results.len) break;
            const result = results[idx];

            if (storage.chunks.get(.{ .x = req.cx, .z = req.cz })) |data| {
                if (data.chunk.job_token != req.job_token) continue;

                if (result.overflow_mask != 0) {
                    log.log.warn("GpuMesher overflow for chunk ({}, {}), falling back to CPU meshing", .{ req.cx, req.cz });
                    data.chunk.state = .generated;
                    continue;
                }

                var solid_alloc: ?VertexAllocation = null;
                var cutout_alloc: ?VertexAllocation = null;
                var fluid_alloc: ?VertexAllocation = null;

                solid_alloc = reserveCopyAllocation(vertex_allocator, result.solid_count) catch null;
                cutout_alloc = reserveCopyAllocation(vertex_allocator, result.cutout_count) catch null;
                fluid_alloc = reserveCopyAllocation(vertex_allocator, result.fluid_count) catch null;

                if (result.solid_count > 0 and solid_alloc == null) {
                    log.log.warn("GPU_MESHER: ({},{}) FAILED to reserve solid allocation ({} verts)", .{ req.cx, req.cz, result.solid_count });
                    freeTempAllocations(vertex_allocator, solid_alloc, cutout_alloc, fluid_alloc);
                    data.chunk.state = .generated;
                    continue;
                }
                if (result.cutout_count > 0 and cutout_alloc == null) {
                    log.log.warn("GPU_MESHER: ({},{}) FAILED to reserve cutout allocation ({} verts)", .{ req.cx, req.cz, result.cutout_count });
                    freeTempAllocations(vertex_allocator, solid_alloc, cutout_alloc, fluid_alloc);
                    data.chunk.state = .generated;
                    continue;
                }
                if (result.fluid_count > 0 and fluid_alloc == null) {
                    log.log.warn("GPU_MESHER: ({},{}) FAILED to reserve fluid allocation ({} verts)", .{ req.cx, req.cz, result.fluid_count });
                    freeTempAllocations(vertex_allocator, solid_alloc, cutout_alloc, fluid_alloc);
                    data.chunk.state = .generated;
                    continue;
                }

                const request_base_vertices = @as(u64, @intCast(idx)) * @as(u64, MAX_VERTICES_PER_CHUNK);

                if (solid_alloc) |alloc| {
                    copyVertexRange(cmd, src.buffer, dst.buffer, request_base_vertices, alloc.offset, result.solid_count);
                    copied_any = true;
                }
                if (cutout_alloc) |alloc| {
                    copyVertexRange(cmd, src.buffer, dst.buffer, request_base_vertices + MAX_PASS_VERTICES, alloc.offset, result.cutout_count);
                    copied_any = true;
                }
                if (fluid_alloc) |alloc| {
                    copyVertexRange(cmd, src.buffer, dst.buffer, request_base_vertices + (MAX_PASS_VERTICES * 2), alloc.offset, result.fluid_count);
                    copied_any = true;
                }

                data.mesh.replaceAllocations(vertex_allocator, solid_alloc, cutout_alloc, fluid_alloc);
                data.chunk.state = .renderable;
                data.chunk.dirty = false;
                self.stats.vertices_produced += result.solid_count + result.cutout_count + result.fluid_count;
            }
        }

        if (copied_any) {
            var barrier = std.mem.zeroes(c.VkMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT;
            c.vkCmdPipelineBarrier(
                cmd,
                c.VK_PIPELINE_STAGE_TRANSFER_BIT,
                c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT,
                0,
                1,
                &barrier,
                0,
                null,
                0,
                null,
            );
        }

        self.submitted[prev_fi].clearRetainingCapacity();
    }

    fn dispatchQueuedMeshes(self: *GpuMesher, gpu_block_buffer: *GpuBlockBuffer) void {
        const fi = self.vk_ctx.frames.current_frame;
        self.submitted[fi].clearRetainingCapacity();

        if (self.mesh_queue.items.len == 0) return;
        const cmd = self.vk_ctx.frames.command_buffers[fi];
        if (cmd == null) return;

        self.submitted[fi].appendSlice(self.allocator, self.mesh_queue.items) catch return;

        const result_buf = self.result_buffers[fi].buffer;
        const result_size: c.VkDeviceSize = MAX_GPU_MESH_BATCH * @sizeOf(MeshBuildResult);
        c.vkCmdFillBuffer(cmd, result_buf, 0, result_size, 0);
        {
            var fill_barrier = std.mem.zeroes(c.VkMemoryBarrier);
            fill_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
            fill_barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            fill_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT;
            c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &fill_barrier, 0, null, 0, null);
        }

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[fi], 0, null);

        for (self.mesh_queue.items, 0..) |req, idx| {
            const n_slot = gpu_block_buffer.getSlotForChunk(req.cx, req.cz - 1);
            const s_slot = gpu_block_buffer.getSlotForChunk(req.cx, req.cz + 1);
            const e_slot = gpu_block_buffer.getSlotForChunk(req.cx + 1, req.cz);
            const w_slot = gpu_block_buffer.getSlotForChunk(req.cx - 1, req.cz);
            const push = MeshPushConstants{
                .chunk_slot = @intCast(req.gpu_slot),
                .request_index = @intCast(idx),
                .output_offset = @intCast(idx * @as(usize, MAX_VERTICES_PER_CHUNK)),
                .neighbor_north_slot = slotOrMissing(n_slot),
                .neighbor_south_slot = slotOrMissing(s_slot),
                .neighbor_east_slot = slotOrMissing(e_slot),
                .neighbor_west_slot = slotOrMissing(w_slot),
            };
            c.vkCmdPushConstants(cmd, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(MeshPushConstants), &push);
            c.vkCmdDispatch(cmd, CHUNK_Y, 1, 1);
        }

        var barrier = std.mem.zeroes(c.VkMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_HOST_READ_BIT | c.VK_ACCESS_TRANSFER_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            c.VK_PIPELINE_STAGE_HOST_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
            0,
            1,
            &barrier,
            0,
            null,
            0,
            null,
        );

        self.stats.chunks_dispatched = @intCast(self.mesh_queue.items.len);
        self.mesh_queue.clearRetainingCapacity();
    }

    fn zeroResults(self: *GpuMesher, frame_index: usize) void {
        if (self.result_buffers[frame_index].mapped_ptr) |ptr| {
            const bytes = @as([*]u8, @ptrCast(ptr))[0 .. MAX_GPU_MESH_BATCH * @sizeOf(MeshBuildResult)];
            @memset(bytes, 0);
        } else {
            log.log.warn("GPU_MESHER: zeroResults called but result_buffers[{}] has no mapped_ptr!", .{frame_index});
        }
    }

    fn getMappedResults(self: *GpuMesher, frame_index: usize) ?[]const MeshBuildResult {
        if (self.result_buffers[frame_index].mapped_ptr) |ptr| {
            const results: [*]const MeshBuildResult = @ptrCast(@alignCast(ptr));
            return results[0..MAX_GPU_MESH_BATCH];
        }
        return null;
    }

    fn createBlockPropsBuffer(self: *GpuMesher, atlas: *const TextureAtlas) !void {
        const packed_size = MAX_BLOCK_TYPES * @sizeOf(u32);
        const channel_size = MAX_BLOCK_TYPES * @sizeOf(f32);
        const tile_array_size = MAX_BLOCK_TYPES * @sizeOf(u32);
        const total_size = packed_size + (channel_size * 3) + (tile_array_size * 3);

        self.block_props_buffer = try Utils.createVulkanBuffer(
            &self.vk_ctx.vulkan_device,
            total_size,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        if (self.block_props_buffer.mapped_ptr) |ptr| {
            const base: [*]u8 = @ptrCast(ptr);
            var packed_props: [MAX_BLOCK_TYPES]u32 = std.mem.zeroes([MAX_BLOCK_TYPES]u32);
            var colors_r: [MAX_BLOCK_TYPES]f32 = std.mem.zeroes([MAX_BLOCK_TYPES]f32);
            var colors_g: [MAX_BLOCK_TYPES]f32 = std.mem.zeroes([MAX_BLOCK_TYPES]f32);
            var colors_b: [MAX_BLOCK_TYPES]f32 = std.mem.zeroes([MAX_BLOCK_TYPES]f32);
            var tiles_top: [MAX_BLOCK_TYPES]u32 = std.mem.zeroes([MAX_BLOCK_TYPES]u32);
            var tiles_bottom: [MAX_BLOCK_TYPES]u32 = std.mem.zeroes([MAX_BLOCK_TYPES]u32);
            var tiles_side: [MAX_BLOCK_TYPES]u32 = std.mem.zeroes([MAX_BLOCK_TYPES]u32);

            const block_registry = @import("block_registry.zig").BLOCK_REGISTRY;
            for (0..MAX_BLOCK_TYPES) |i| {
                const def = block_registry[i];
                const atlas_tiles = atlas.getTilesForBlock(@intCast(i));

                var p: u32 = 0;
                if (def.is_solid) p |= 0x1;
                if (def.is_transparent) p |= 0x2;
                if (def.is_fluid) p |= 0x4;
                if (def.is_tintable) p |= 0x8;
                const rp: u32 = switch (def.render_pass) {
                    .solid => 0,
                    .cutout => 1,
                    .fluid => 2,
                    .translucent => 1,
                };
                p |= rp << 4;
                packed_props[i] = p;
                colors_r[i] = def.default_color[0];
                colors_g[i] = def.default_color[1];
                colors_b[i] = def.default_color[2];
                tiles_top[i] = atlas_tiles.top;
                tiles_bottom[i] = atlas_tiles.bottom;
                tiles_side[i] = atlas_tiles.side;
            }

            @memcpy(base[0..packed_size], std.mem.sliceAsBytes(&packed_props));
            @memcpy(base[packed_size .. packed_size + channel_size], std.mem.sliceAsBytes(&colors_r));
            @memcpy(base[packed_size + channel_size .. packed_size + (channel_size * 2)], std.mem.sliceAsBytes(&colors_g));
            @memcpy(base[packed_size + (channel_size * 2) .. packed_size + (channel_size * 3)], std.mem.sliceAsBytes(&colors_b));
            @memcpy(base[packed_size + (channel_size * 3) .. packed_size + (channel_size * 3) + tile_array_size], std.mem.sliceAsBytes(&tiles_top));
            @memcpy(base[packed_size + (channel_size * 3) + tile_array_size .. packed_size + (channel_size * 3) + (tile_array_size * 2)], std.mem.sliceAsBytes(&tiles_bottom));
            @memcpy(base[packed_size + (channel_size * 3) + (tile_array_size * 2) .. total_size], std.mem.sliceAsBytes(&tiles_side));
        }
    }

    fn initComputeResources(self: *GpuMesher, gpu_block_buffer: *GpuBlockBuffer) !void {
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
        for (&layouts) |*layout| layout.* = self.descriptor_set_layout;

        var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = self.descriptor_pool;
        alloc_info.descriptorSetCount = MAX_FRAMES_IN_FLIGHT;
        alloc_info.pSetLayouts = &layouts;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info, &self.descriptor_sets));

        self.updateDescriptorSets(gpu_block_buffer);

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

    fn updateDescriptorSets(self: *GpuMesher, gpu_block_buffer: *GpuBlockBuffer) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;
        const block_buf_handle = gpu_block_buffer.getBufferHandle();
        const native_block_buf: c.VkBuffer = if (self.vk_ctx.resources.buffers.get(block_buf_handle)) |vb| vb.buffer else null;

        var writes: [4 * MAX_FRAMES_IN_FLIGHT]c.VkWriteDescriptorSet = undefined;
        var block_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var props_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var output_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var result_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var n: usize = 0;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const output_vk = self.vk_ctx.resources.buffers.get(self.output_handles[i]) orelse continue;

            block_infos[i] = .{ .buffer = native_block_buf, .offset = 0, .range = c.VK_WHOLE_SIZE };
            props_infos[i] = .{ .buffer = self.block_props_buffer.buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
            output_infos[i] = .{ .buffer = output_vk.buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };
            result_infos[i] = .{ .buffer = self.result_buffers[i].buffer, .offset = 0, .range = c.VK_WHOLE_SIZE };

            const set = self.descriptor_sets[i];
            writes[n] = descriptorWrite(set, 0, &block_infos[i]);
            n += 1;
            writes[n] = descriptorWrite(set, 1, &props_infos[i]);
            n += 1;
            writes[n] = descriptorWrite(set, 2, &output_infos[i]);
            n += 1;
            writes[n] = descriptorWrite(set, 3, &result_infos[i]);
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
    }
};

fn reserveCopyAllocation(vertex_allocator: *GlobalVertexAllocator, count: u32) !?VertexAllocation {
    if (count == 0) return null;
    return try vertex_allocator.reserve(count);
}

fn freeTempAllocations(vertex_allocator: *GlobalVertexAllocator, solid: ?VertexAllocation, cutout: ?VertexAllocation, fluid: ?VertexAllocation) void {
    if (solid) |alloc| vertex_allocator.free(alloc);
    if (cutout) |alloc| vertex_allocator.free(alloc);
    if (fluid) |alloc| vertex_allocator.free(alloc);
}

fn copyVertexRange(cmd: c.VkCommandBuffer, src_buffer: c.VkBuffer, dst_buffer: c.VkBuffer, src_vertex_offset: u64, dst_byte_offset: usize, count: u32) void {
    if (count == 0) return;
    var region = std.mem.zeroes(c.VkBufferCopy);
    region.srcOffset = src_vertex_offset * VERTEX_SIZE;
    region.dstOffset = dst_byte_offset;
    region.size = @as(u64, count) * VERTEX_SIZE;
    c.vkCmdCopyBuffer(cmd, src_buffer, dst_buffer, 1, &region);
}

fn slotOrMissing(slot: ?usize) i32 {
    return if (slot) |s| @intCast(s) else -1;
}

fn descriptorWrite(set: c.VkDescriptorSet, binding: u32, info: *const c.VkDescriptorBufferInfo) c.VkWriteDescriptorSet {
    var write = std.mem.zeroes(c.VkWriteDescriptorSet);
    write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = set;
    write.dstBinding = binding;
    write.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
    write.descriptorCount = 1;
    write.pBufferInfo = info;
    return write;
}

fn destroyVulkanBuffer(vk: c.VkDevice, buf: *Utils.VulkanBuffer) void {
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
        log.log.errWithTrace("Mesh shader artifact missing: {s} ({})", .{ path, err });
        log.log.err("Run `nix develop --command zig build` to regenerate Vulkan SPIR-V shaders.", .{});
        return err;
    };
}
