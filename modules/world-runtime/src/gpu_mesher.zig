//! GPU mesher that builds chunk vertices via compute, then copies completed
//! batches into the persistent megabuffer on the following frame.

const std = @import("std");
const fs = @import("fs");
const log = @import("engine-core").log;
const rhi_pkg = @import("engine-rhi").rhi;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const GpuBlockBuffer = @import("world-meshing").GpuBlockBuffer;
const ChunkStorage = @import("world-meshing").ChunkStorage;
const GlobalVertexAllocator = @import("world-meshing").GlobalVertexAllocator;
const VertexAllocation = @import("world-meshing").VertexAllocation;

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
    pub const RemeshCallback = *const fn (context: *anyopaque, cx: i32, cz: i32, job_token: u32) void;

    allocator: std.mem.Allocator,
    rhi: rhi_pkg.RHI,
    rm: rhi_pkg.ResourceManager,
    compute: rhi_pkg.IComputeContext,
    available: bool,

    pipeline: rhi_pkg.ComputePipeline = .{},

    output_handles: [MAX_FRAMES_IN_FLIGHT]rhi_pkg.BufferHandle,
    result_buffers: [MAX_FRAMES_IN_FLIGHT]rhi_pkg.ComputeBuffer,
    block_props_buffer: rhi_pkg.ComputeBuffer,

    mesh_queue: std.ArrayListUnmanaged(ChunkMeshRequest),
    submitted: [MAX_FRAMES_IN_FLIGHT]std.ArrayListUnmanaged(ChunkMeshRequest),

    stats: GpuMesherStats,
    remesh_context: ?*anyopaque = null,
    remesh_callback: ?RemeshCallback = null,

    pub fn init(
        allocator: std.mem.Allocator,
        rhi: rhi_pkg.RHI,
        atlas: *const TextureAtlas,
        gpu_block_buffer: *GpuBlockBuffer,
    ) !*GpuMesher {
        const self = try allocator.create(GpuMesher);
        errdefer allocator.destroy(self);

        const rm = rhi.resourceManager();
        const output_size = @as(usize, MAX_GPU_MESH_BATCH) * @as(usize, MAX_VERTICES_PER_CHUNK) * @as(usize, VERTEX_SIZE);
        const result_size = MAX_GPU_MESH_BATCH * @sizeOf(MeshBuildResult);

        self.* = .{
            .allocator = allocator,
            .rhi = rhi,
            .rm = rm,
            .compute = rhi.compute(),
            .available = false,
            .output_handles = .{ 0, 0 },
            .result_buffers = .{rhi_pkg.ComputeBuffer{}} ** MAX_FRAMES_IN_FLIGHT,
            .block_props_buffer = .{},
            .mesh_queue = .empty,
            .submitted = .{ .empty, .empty },
            .stats = .{},
        };

        errdefer self.deinit();

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            self.output_handles[i] = try rm.createBuffer(output_size, .storage);
            self.result_buffers[i] = try self.compute.createComputeBuffer(result_size, true);
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
        for (&self.result_buffers) |*buf| self.compute.destroyComputeBuffer(buf);
        self.compute.destroyComputeBuffer(&self.block_props_buffer);
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

    pub fn setRemeshCallback(self: *GpuMesher, context: ?*anyopaque, callback: ?RemeshCallback) void {
        self.remesh_context = context;
        self.remesh_callback = callback;
    }

    fn finalizeCompletedMeshes(self: *GpuMesher, vertex_allocator: *GlobalVertexAllocator, storage: *ChunkStorage) void {
        const fi = self.rhi.query().getFrameIndex();
        const prev_fi = (fi + MAX_FRAMES_IN_FLIGHT - 1) % MAX_FRAMES_IN_FLIGHT;
        if (self.submitted[prev_fi].items.len == 0) return;

        if (!self.compute.waitForFrameFence(prev_fi)) {
            log.log.warn("GPU_MESHER: frame fence wait failed for frame {} (missing fence, timeout, or GPU/device error); deferring finalize this frame", .{prev_fi});
            return;
        }

        if (!self.compute.hasCommandBuffer()) return;

        const src = rhi_pkg.ComputeBufferBinding{ .buffer = self.output_handles[prev_fi] };
        const dst = rhi_pkg.ComputeBufferBinding{ .buffer = vertex_allocator.buffer };
        const results = self.getMappedResults(prev_fi) orelse {
            log.log.warn("GPU_MESHER_FINALIZE: no mapped results for prev_fi={}", .{prev_fi});
            return;
        };

        var remesh_requests: [MAX_GPU_MESH_BATCH]ChunkMeshRequest = undefined;
        var remesh_count: usize = 0;

        storage.chunks_mutex.lock();

        for (self.submitted[prev_fi].items, 0..) |req, idx| {
            if (idx >= results.len) break;
            const result = results[idx];

            if (storage.chunks.get(.{ .x = req.cx, .z = req.cz })) |data| {
                if (data.chunk.job_token != req.job_token) continue;

                if (result.overflow_mask != 0) {
                    log.log.warn("GpuMesher overflow for chunk ({}, {}), falling back to CPU meshing", .{ req.cx, req.cz });
                    data.chunk.force_cpu_mesh = true;
                    data.chunk.state = .generated;
                    remesh_requests[remesh_count] = req;
                    remesh_count += 1;
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
                    data.chunk.force_cpu_mesh = true;
                    data.chunk.state = .generated;
                    remesh_requests[remesh_count] = req;
                    remesh_count += 1;
                    continue;
                }
                if (result.cutout_count > 0 and cutout_alloc == null) {
                    log.log.warn("GPU_MESHER: ({},{}) FAILED to reserve cutout allocation ({} verts)", .{ req.cx, req.cz, result.cutout_count });
                    freeTempAllocations(vertex_allocator, solid_alloc, cutout_alloc, fluid_alloc);
                    data.chunk.force_cpu_mesh = true;
                    data.chunk.state = .generated;
                    remesh_requests[remesh_count] = req;
                    remesh_count += 1;
                    continue;
                }
                if (result.fluid_count > 0 and fluid_alloc == null) {
                    log.log.warn("GPU_MESHER: ({},{}) FAILED to reserve fluid allocation ({} verts)", .{ req.cx, req.cz, result.fluid_count });
                    freeTempAllocations(vertex_allocator, solid_alloc, cutout_alloc, fluid_alloc);
                    data.chunk.force_cpu_mesh = true;
                    data.chunk.state = .generated;
                    remesh_requests[remesh_count] = req;
                    remesh_count += 1;
                    continue;
                }

                const request_base_vertices = @as(u64, @intCast(idx)) * @as(u64, MAX_VERTICES_PER_CHUNK);

                if (solid_alloc) |alloc| {
                    copyVertexRange(self, src, dst, request_base_vertices, alloc.offset, result.solid_count);
                    vertexReadBarrier(self, dst, alloc.offset, result.solid_count);
                }
                if (cutout_alloc) |alloc| {
                    copyVertexRange(self, src, dst, request_base_vertices + MAX_PASS_VERTICES, alloc.offset, result.cutout_count);
                    vertexReadBarrier(self, dst, alloc.offset, result.cutout_count);
                }
                if (fluid_alloc) |alloc| {
                    copyVertexRange(self, src, dst, request_base_vertices + (MAX_PASS_VERTICES * 2), alloc.offset, result.fluid_count);
                    vertexReadBarrier(self, dst, alloc.offset, result.fluid_count);
                }

                data.render.mesh.replaceAllocations(vertex_allocator, solid_alloc, cutout_alloc, fluid_alloc);
                data.chunk.state = if (data.chunk.dirty) .generated else .renderable;
                if (data.chunk.dirty) {
                    remesh_requests[remesh_count] = req;
                    remesh_count += 1;
                }
                self.stats.vertices_produced += result.solid_count + result.cutout_count + result.fluid_count;
            }
        }

        self.submitted[prev_fi].clearRetainingCapacity();
        storage.chunks_mutex.unlock();

        if (self.remesh_context) |context| if (self.remesh_callback) |callback| {
            for (remesh_requests[0..remesh_count]) |req| {
                callback(context, req.cx, req.cz, req.job_token);
            }
        };
    }

    fn dispatchQueuedMeshes(self: *GpuMesher, gpu_block_buffer: *GpuBlockBuffer) void {
        const fi = self.rhi.query().getFrameIndex();
        self.submitted[fi].clearRetainingCapacity();

        if (self.mesh_queue.items.len == 0) return;
        if (!self.compute.hasCommandBuffer()) return;

        self.submitted[fi].appendSlice(self.allocator, self.mesh_queue.items) catch return;

        const result_size: u64 = MAX_GPU_MESH_BATCH * @sizeOf(MeshBuildResult);
        self.compute.fillBuffer(self.result_buffers[fi], 0, result_size, 0);
        self.compute.bufferBarrier(.{ .compute = self.result_buffers[fi] }, rhi_pkg.PIPELINE_STAGE_TRANSFER_BIT, rhi_pkg.PIPELINE_STAGE_COMPUTE_SHADER_BIT, rhi_pkg.ACCESS_TRANSFER_WRITE_BIT, rhi_pkg.ACCESS_SHADER_READ_BIT | rhi_pkg.ACCESS_SHADER_WRITE_BIT, 0, result_size);

        self.compute.bindComputePipeline(self.pipeline);
        self.compute.bindDescriptorSet(self.pipeline, fi);

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
            self.compute.pushConstants(self.pipeline, 0, @sizeOf(MeshPushConstants), &push);
            self.compute.dispatch(CHUNK_Y, 1, 1);
        }

        self.compute.bufferBarrier(.{ .compute = self.result_buffers[fi] }, rhi_pkg.PIPELINE_STAGE_COMPUTE_SHADER_BIT, rhi_pkg.PIPELINE_STAGE_HOST_BIT, rhi_pkg.ACCESS_SHADER_WRITE_BIT, rhi_pkg.ACCESS_HOST_READ_BIT, 0, result_size);
        self.compute.bufferBarrier(.{ .buffer = self.output_handles[fi] }, rhi_pkg.PIPELINE_STAGE_COMPUTE_SHADER_BIT, rhi_pkg.PIPELINE_STAGE_TRANSFER_BIT, rhi_pkg.ACCESS_SHADER_WRITE_BIT, rhi_pkg.ACCESS_TRANSFER_READ_BIT, 0, outputBufferSize());

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

        self.block_props_buffer = try self.compute.createComputeBuffer(total_size, true);

        if (self.block_props_buffer.mapped_ptr) |ptr| {
            const base: [*]u8 = @ptrCast(ptr);
            var packed_props: [MAX_BLOCK_TYPES]u32 = std.mem.zeroes([MAX_BLOCK_TYPES]u32);
            var colors_r: [MAX_BLOCK_TYPES]f32 = std.mem.zeroes([MAX_BLOCK_TYPES]f32);
            var colors_g: [MAX_BLOCK_TYPES]f32 = std.mem.zeroes([MAX_BLOCK_TYPES]f32);
            var colors_b: [MAX_BLOCK_TYPES]f32 = std.mem.zeroes([MAX_BLOCK_TYPES]f32);
            var tiles_top: [MAX_BLOCK_TYPES]u32 = std.mem.zeroes([MAX_BLOCK_TYPES]u32);
            var tiles_bottom: [MAX_BLOCK_TYPES]u32 = std.mem.zeroes([MAX_BLOCK_TYPES]u32);
            var tiles_side: [MAX_BLOCK_TYPES]u32 = std.mem.zeroes([MAX_BLOCK_TYPES]u32);

            const block_registry = @import("world-core").BLOCK_REGISTRY;
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
        self.pipeline = try self.compute.createComputePipeline(self.allocator, MESH_SHADER_PATH, 4, @sizeOf(MeshPushConstants));
        self.updateDescriptorSets(gpu_block_buffer);
    }

    fn updateDescriptorSets(self: *GpuMesher, gpu_block_buffer: *GpuBlockBuffer) void {
        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const buffers = [_]rhi_pkg.ComputeBufferBinding{
                .{ .buffer = gpu_block_buffer.getBufferHandle() },
                .{ .compute = self.block_props_buffer },
                .{ .buffer = self.output_handles[i] },
                .{ .compute = self.result_buffers[i] },
            };
            self.compute.updateComputeDescriptors(self.pipeline, i, &buffers);
        }
    }

    fn deinitComputeResources(self: *GpuMesher) void {
        self.compute.destroyComputePipeline(&self.pipeline);
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

fn copyVertexRange(self: *GpuMesher, src_buffer: rhi_pkg.ComputeBufferBinding, dst_buffer: rhi_pkg.ComputeBufferBinding, src_vertex_offset: u64, dst_byte_offset: usize, count: u32) void {
    if (count == 0) return;
    self.compute.copyBuffer(src_buffer, dst_buffer, src_vertex_offset * VERTEX_SIZE, dst_byte_offset, @as(u64, count) * VERTEX_SIZE);
}

fn vertexReadBarrier(self: *GpuMesher, buffer: rhi_pkg.ComputeBufferBinding, dst_byte_offset: usize, count: u32) void {
    if (count == 0) return;
    self.compute.bufferBarrier(buffer, rhi_pkg.PIPELINE_STAGE_TRANSFER_BIT, rhi_pkg.PIPELINE_STAGE_VERTEX_INPUT_BIT, rhi_pkg.ACCESS_TRANSFER_WRITE_BIT, rhi_pkg.ACCESS_VERTEX_ATTRIBUTE_READ_BIT, dst_byte_offset, @as(u64, count) * VERTEX_SIZE);
}

fn outputBufferSize() u64 {
    return @as(u64, MAX_GPU_MESH_BATCH) * @as(u64, MAX_VERTICES_PER_CHUNK) * @as(u64, VERTEX_SIZE);
}

fn slotOrMissing(slot: ?usize) i32 {
    return if (slot) |s| @intCast(s) else -1;
}

fn ensureShaderFileExists(path: []const u8) !void {
    fs.cwd().access(path, .{}) catch |err| {
        log.log.errWithTrace("Mesh shader artifact missing: {s} ({})", .{ path, err });
        log.log.err("Run `nix develop --command zig build` to regenerate Vulkan SPIR-V shaders.", .{});
        return err;
    };
}
