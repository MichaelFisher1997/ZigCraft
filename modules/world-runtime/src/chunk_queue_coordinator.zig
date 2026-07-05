//! Chunk generation, meshing, and upload queue coordination.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const ChunkKey = world_core.ChunkKey;
const CHUNK_UNLOAD_BUFFER = world_core.CHUNK_UNLOAD_BUFFER;
const world_meshing = @import("world-meshing");
const ChunkStorage = world_meshing.ChunkStorage;
const NeighborChunks = world_meshing.NeighborChunks;
const engine_core = @import("engine-core");
const JobQueue = engine_core.JobQueue;
const Job = engine_core.Job;
const RingBuffer = engine_core.ring_buffer.RingBuffer;
const Generator = @import("world-worldgen").Generator;
const GlobalVertexAllocator = world_meshing.GlobalVertexAllocator;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const log = @import("engine-core").log;
const SaveManager = @import("world-persistence").SaveManager;
const LoadResult = @import("world-persistence").LoadResult;
const GpuAccelerationCoordinator = @import("gpu_acceleration_coordinator.zig").GpuAccelerationCoordinator;
const LODManager = @import("world-lod").LODManager;
const LODColumnProvenance = @import("world-core").LODColumnProvenance;

pub const ChunkQueueCoordinator = struct {
    allocator: std.mem.Allocator,
    storage: *ChunkStorage,
    generator: Generator,
    atlas: *const TextureAtlas,
    gen_queue: *JobQueue,
    mesh_queue: *JobQueue,
    upload_queue: RingBuffer(ChunkKey),
    vertex_allocator: *GlobalVertexAllocator,
    gpu: *GpuAccelerationCoordinator,
    max_uploads_per_frame: usize,
    save_manager: ?*SaveManager = null,
    // Optional LOD manager fed chunk-derived data after generation/load.
    lod_manager: ?*LODManager = null,

    chunks_generated_total: std.atomic.Value(u64) = .init(0),
    chunks_meshed_total: std.atomic.Value(u64) = .init(0),
    chunks_uploaded_total: std.atomic.Value(u64) = .init(0),
    last_pc_x: std.atomic.Value(i32) = .init(0),
    last_pc_z: std.atomic.Value(i32) = .init(0),
    effective_render_dist: std.atomic.Value(i32) = .init(0),

    pub fn init(allocator: std.mem.Allocator, storage: *ChunkStorage, generator: Generator, atlas: *const TextureAtlas, gen_queue: *JobQueue, mesh_queue: *JobQueue, vertex_allocator: *GlobalVertexAllocator, max_uploads_per_frame: usize, gpu: *GpuAccelerationCoordinator) !ChunkQueueCoordinator {
        return .{
            .allocator = allocator,
            .storage = storage,
            .generator = generator,
            .atlas = atlas,
            .gen_queue = gen_queue,
            .mesh_queue = mesh_queue,
            .upload_queue = try RingBuffer(ChunkKey).init(allocator, 256),
            .vertex_allocator = vertex_allocator,
            .gpu = gpu,
            .max_uploads_per_frame = max_uploads_per_frame,
        };
    }

    pub fn deinit(self: *ChunkQueueCoordinator) void {
        self.upload_queue.deinit();
    }

    pub fn setSaveManager(self: *ChunkQueueCoordinator, sm: ?*SaveManager) void {
        self.save_manager = sm;
    }

    pub fn setLODManager(self: *ChunkQueueCoordinator, mgr: ?*LODManager) void {
        self.lod_manager = mgr;
    }

    pub fn setView(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, render_dist: i32) void {
        self.last_pc_x.store(pc_x, .release);
        self.last_pc_z.store(pc_z, .release);
        self.effective_render_dist.store(render_dist, .release);
    }

    pub fn resetPausedChunks(self: *ChunkQueueCoordinator) void {
        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const chunk = &entry.value_ptr.*.chunk;
            if (chunk.state == .queued_for_generation or chunk.state == .generating) {
                chunk.state = .missing;
            } else if (chunk.state == .queued_for_mesh or chunk.state == .meshing or chunk.state == .uploading) {
                chunk.state = .generated;
            }
        }
    }

    pub fn scanForMissingChunks(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, render_dist: i32) !void {
        var cz: i32 = pc_z - render_dist;
        while (cz <= pc_z + render_dist) : (cz += 1) {
            var cx: i32 = pc_x - render_dist;
            while (cx <= pc_x + render_dist) : (cx += 1) {
                const dx = cx - pc_x;
                const dz = cz - pc_z;
                const dist_sq = dx * dx + dz * dz;

                if (dist_sq > render_dist * render_dist) continue;

                const data = try self.storage.getOrCreate(cx, cz);

                switch (data.chunk.state) {
                    .missing => {
                        self.gen_queue.push(.{
                            .type = .chunk_generation,
                            .dist_sq = dist_sq,
                            .data = .{ .chunk = .{ .x = cx, .z = cz, .job_token = data.chunk.job_token } },
                        }) catch continue;
                        data.chunk.state = .queued_for_generation;
                    },
                    else => {},
                }
            }
        }
    }

    pub fn processChunkStates(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, render_dist: i32, frame_counter: u64) void {
        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        var mesh_iter = self.storage.iteratorUnsafe();
        while (mesh_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            if (data.chunk.state == .generated) {
                const dx = data.chunk.chunk_x - pc_x;
                const dz = data.chunk.chunk_z - pc_z;
                if (dx * dx + dz * dz <= render_dist * render_dist) {
                    self.mesh_queue.push(.{
                        .type = .chunk_meshing,
                        .dist_sq = dx * dx + dz * dz,
                        .data = .{ .chunk = .{ .x = data.chunk.chunk_x, .z = data.chunk.chunk_z, .job_token = data.chunk.job_token } },
                    }) catch continue;
                    data.chunk.state = .queued_for_mesh;
                }
            } else if (data.chunk.state == .mesh_ready) {
                data.chunk.state = .uploading;
                self.upload_queue.push(key) catch {
                    data.chunk.state = .mesh_ready;
                    continue;
                };
            } else if (data.chunk.state == .renderable) {
                if (data.chunk.dirty) {
                    data.chunk.dirty = false;
                    data.chunk.state = .generated;
                } else if (data.render.mesh.solid_allocation == null and data.render.mesh.cutout_allocation == null and data.render.mesh.fluid_allocation == null and data.chunk.mesh_attempts < 3) {
                    data.chunk.mesh_attempts += 1;
                    log.log.warn("CHUNK_RECOVERY: ({},{}) renderable with no allocations, re-meshing (attempt {})", .{ data.chunk.chunk_x, data.chunk.chunk_z, data.chunk.mesh_attempts });
                    data.chunk.state = .generated;
                }
            } else if (data.chunk.state == .generating and !data.chunk.isPinned() and frame_counter % 120 == 0) {
                const dx = data.chunk.chunk_x - pc_x;
                const dz = data.chunk.chunk_z - pc_z;
                const max_dist = render_dist + CHUNK_UNLOAD_BUFFER;
                if (dx * dx + dz * dz <= max_dist * max_dist) {
                    data.chunk.job_token += 1;
                    data.chunk.state = .missing;
                    log.log.warn("CHUNK_STUCK: ({},{}) in generating state too long, resetting to missing", .{ data.chunk.chunk_x, data.chunk.chunk_z });
                }
            } else if (data.chunk.state == .uploading and frame_counter % 60 == 0) {
                const dx = data.chunk.chunk_x - pc_x;
                const dz = data.chunk.chunk_z - pc_z;
                if (dx * dx + dz * dz <= render_dist * render_dist) {
                    data.chunk.mesh_attempts +|= 1;
                    if (data.chunk.mesh_attempts < 3) {
                        log.log.warn("CHUNK_UPLOAD_STUCK: ({},{}) in uploading state too long, resetting to generated (attempt {})", .{ data.chunk.chunk_x, data.chunk.chunk_z, data.chunk.mesh_attempts });
                        data.chunk.state = .generated;
                    } else {
                        log.log.warn("CHUNK_UPLOAD_STUCK: ({},{}) exceeded max upload recovery attempts ({}), leaving as uploading", .{ data.chunk.chunk_x, data.chunk.chunk_z, data.chunk.mesh_attempts });
                    }
                }
            }
        }
    }

    pub fn processUploads(self: *ChunkQueueCoordinator) void {
        var uploads: usize = 0;
        while (!self.upload_queue.isEmpty() and uploads < self.max_uploads_per_frame) {
            const key = self.upload_queue.pop() orelse break;
            if (self.storage.get(key.x, key.z)) |data| {
                if (data.chunk.state != .uploading) continue;

                // Main-thread invariant: only this upload path mutates `.uploading`
                // chunks until GPU meshing finalization runs from the render graph.
                if (!self.gpu.queueGpuMesh(data)) {
                    data.render.mesh.upload(self.vertex_allocator);

                    if (data.render.mesh.diag_tile0_count > 0) {
                        log.log.warn("TILE0_MESH: chunk ({},{}) has {}/{} vertices with tile_id=0 (WHITE)", .{
                            data.chunk.chunk_x,                data.chunk.chunk_z,
                            data.render.mesh.diag_tile0_count, data.render.mesh.diag_total_verts,
                        });
                    }

                    if (data.render.mesh.ready) {
                        data.chunk.state = .renderable;
                        data.chunk.dirty = false;
                        _ = self.chunks_uploaded_total.fetchAdd(1, .monotonic);
                    } else {
                        log.log.warn("CHUNK_UPLOAD: ({},{}) upload FAILED (ready=false), reverting to mesh_ready | solid={} cutout={} fluid={}", .{
                            key.x,                                     key.z,
                            data.render.mesh.solid_allocation != null, data.render.mesh.cutout_allocation != null,
                            data.render.mesh.fluid_allocation != null,
                        });
                        data.chunk.state = .mesh_ready;
                    }
                }
                uploads += 1;
            }
        }
    }

    pub fn processGenJob(ctx: *anyopaque, job: Job) void {
        const self: *ChunkQueueCoordinator = @ptrCast(@alignCast(ctx));
        const cx = job.data.chunk.x;
        const cz = job.data.chunk.z;

        self.storage.chunks_mutex.lockShared();
        const chunk_data = self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz }) orelse {
            self.storage.chunks_mutex.unlockShared();
            return;
        };

        const pc_x = self.last_pc_x.load(.acquire);
        const pc_z = self.last_pc_z.load(.acquire);
        const render_dist = self.effective_render_dist.load(.acquire);
        const dx = cx - pc_x;
        const dz = cz - pc_z;
        const max_dist = render_dist + CHUNK_UNLOAD_BUFFER;
        if (dx * dx + dz * dz > max_dist * max_dist) {
            self.storage.chunks_mutex.unlockShared();

            self.storage.chunks_mutex.lock();
            if (self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz })) |data| {
                if ((data.chunk.state == .queued_for_generation or data.chunk.state == .generating) and data.chunk.job_token == job.data.chunk.job_token) {
                    data.chunk.state = .missing;
                }
            }
            self.storage.chunks_mutex.unlock();
            return;
        }

        chunk_data.chunk.pin();
        self.storage.chunks_mutex.unlockShared();

        defer chunk_data.chunk.unpin();

        self.storage.chunks_mutex.lock();
        if (self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz })) |data| {
            if (data.chunk.state == .queued_for_generation and data.chunk.job_token == job.data.chunk.job_token) {
                data.chunk.state = .generating;
            } else if (data.chunk.state != .generating or data.chunk.job_token != job.data.chunk.job_token) {
                self.storage.chunks_mutex.unlock();
                return;
            }
        } else {
            self.storage.chunks_mutex.unlock();
            return;
        }
        self.storage.chunks_mutex.unlock();

        if (chunk_data.chunk.state == .generating and chunk_data.chunk.job_token == job.data.chunk.job_token) {
            const load_result = blk: {
                const sm = self.save_manager orelse break :blk LoadResult.not_found;
                break :blk sm.loadChunk(cx, cz, &chunk_data.chunk);
            };

            if (load_result != .success) {
                if (load_result == .read_error or load_result == .corrupt_data) {
                    log.log.warn("Save load failed for chunk ({}, {}): {}, regenerating", .{ cx, cz, load_result });
                }
                self.generator.generate(&chunk_data.chunk, &self.gen_queue.abort_worker);
                if (self.gen_queue.abort_worker) {
                    self.storage.chunks_mutex.lock();
                    chunk_data.chunk.state = .missing;
                    self.storage.chunks_mutex.unlock();
                    return;
                }
            }

            self.storage.chunks_mutex.lock();
            if (!chunk_data.chunk.generated) {
                log.log.warn("CHUNK_GEN_FAILED: ({},{}) generator returned without setting generated=true, resetting to missing", .{ cx, cz });
                chunk_data.chunk.state = .missing;
            } else {
                var non_air_count: u32 = 0;
                for (chunk_data.chunk.blocks) |block| {
                    if (block != .air) non_air_count += 1;
                }
                if (non_air_count == 0) {
                    log.log.warn("CHUNK_GEN_EMPTY: ({},{}) generated chunk has ZERO non-air blocks, resetting to missing", .{ cx, cz });
                    chunk_data.chunk.generated = false;
                    chunk_data.chunk.state = .missing;
                } else {
                    chunk_data.chunk.state = .generated;
                    _ = self.chunks_generated_total.fetchAdd(1, .monotonic);
                }
            }
            self.storage.chunks_mutex.unlock();
            if (chunk_data.chunk.generated) {
                self.markNeighborsForRemesh(cx, cz);
                // Feed the real chunk into the LOD system so distant terrain is
                // derived from actual blocks (chunk_derived provenance) instead
                // of worldgen sampling. The chunk is pinned for this call.
                if (engine_core.envFlag("ZIGCRAFT_LOD_CHUNK_INGEST", false)) {
                    if (self.lod_manager) |mgr| {
                        mgr.ingestChunk(cx, cz, &chunk_data.chunk, .chunk_derived);
                    }
                }
            }
        }
    }

    pub fn processMeshJob(ctx: *anyopaque, job: Job) void {
        const self: *ChunkQueueCoordinator = @ptrCast(@alignCast(ctx));
        const cx = job.data.chunk.x;
        const cz = job.data.chunk.z;

        self.storage.chunks_mutex.lockShared();
        const chunk_data = self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz }) orelse {
            self.storage.chunks_mutex.unlockShared();
            return;
        };

        const pc_x = self.last_pc_x.load(.acquire);
        const pc_z = self.last_pc_z.load(.acquire);
        const render_dist = self.effective_render_dist.load(.acquire);
        const dx = cx - pc_x;
        const dz = cz - pc_z;
        const max_dist = render_dist + CHUNK_UNLOAD_BUFFER;
        if (dx * dx + dz * dz > max_dist * max_dist) {
            self.storage.chunks_mutex.unlockShared();

            self.storage.chunks_mutex.lock();
            if (self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz })) |data| {
                if ((data.chunk.state == .queued_for_mesh or data.chunk.state == .meshing) and data.chunk.job_token == job.data.chunk.job_token) {
                    data.chunk.state = .generated;
                }
            }
            self.storage.chunks_mutex.unlock();
            return;
        }

        chunk_data.chunk.pin();
        const neighbors = NeighborChunks{
            .north = if (self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz - 1 })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .south = if (self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz + 1 })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .east = if (self.storage.chunks.get(ChunkKey{ .x = cx + 1, .z = cz })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .west = if (self.storage.chunks.get(ChunkKey{ .x = cx - 1, .z = cz })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
        };
        self.storage.chunks_mutex.unlockShared();

        defer {
            chunk_data.chunk.unpin();
            if (neighbors.north) |n| @as(*Chunk, @constCast(n)).unpin();
            if (neighbors.south) |s| @as(*Chunk, @constCast(s)).unpin();
            if (neighbors.east) |e| @as(*Chunk, @constCast(e)).unpin();
            if (neighbors.west) |w| @as(*Chunk, @constCast(w)).unpin();
        }

        self.storage.chunks_mutex.lock();
        if (self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz })) |data| {
            if (data.chunk.state == .queued_for_mesh and data.chunk.job_token == job.data.chunk.job_token) {
                data.chunk.state = .meshing;
            } else if (data.chunk.state != .meshing or data.chunk.job_token != job.data.chunk.job_token) {
                self.storage.chunks_mutex.unlock();
                return;
            }
        } else {
            self.storage.chunks_mutex.unlock();
            return;
        }
        self.storage.chunks_mutex.unlock();

        if (chunk_data.chunk.state == .meshing and chunk_data.chunk.job_token == job.data.chunk.job_token) {
            if (self.gpu.shouldUseGpuMeshReadyPath()) {
                self.storage.chunks_mutex.lock();
                chunk_data.chunk.state = .mesh_ready;
                self.storage.chunks_mutex.unlock();
                _ = self.chunks_meshed_total.fetchAdd(1, .monotonic);
                return;
            }
            chunk_data.render.mesh.buildWithNeighbors(&chunk_data.chunk, neighbors, self.atlas) catch |err| {
                log.log.errWithTrace("Mesh build failed for chunk ({}, {}): {}", .{ cx, cz, err });
                self.storage.chunks_mutex.lock();
                chunk_data.chunk.state = .generated;
                self.storage.chunks_mutex.unlock();
                return;
            };
            if (self.mesh_queue.abort_worker) {
                self.storage.chunks_mutex.lock();
                chunk_data.chunk.state = .generated;
                self.storage.chunks_mutex.unlock();
                return;
            }
            self.storage.chunks_mutex.lock();
            chunk_data.chunk.state = .mesh_ready;
            self.storage.chunks_mutex.unlock();
            _ = self.chunks_meshed_total.fetchAdd(1, .monotonic);
        }
    }

    fn markNeighborsForRemesh(self: *ChunkQueueCoordinator, cx: i32, cz: i32) void {
        const offsets = [_][2]i32{ .{ 0, 1 }, .{ 0, -1 }, .{ 1, 0 }, .{ -1, 0 } };

        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        for (offsets) |off| {
            if (self.storage.chunks.get(ChunkKey{ .x = cx + off[0], .z = cz + off[1] })) |data| {
                switch (data.chunk.state) {
                    .renderable => data.chunk.state = .generated,
                    .mesh_ready, .uploading, .meshing => data.chunk.dirty = true,
                    else => {},
                }
            }
        }
    }
};

test "stale generation job resets chunk to missing" {
    const testing = std.testing;

    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data = try storage.getOrCreate(64, 0);
    data.chunk.state = .generating;
    data.chunk.job_token = 7;

    var gpu = GpuAccelerationCoordinator.init(null, null);
    var coordinator = ChunkQueueCoordinator{
        .allocator = testing.allocator,
        .storage = &storage,
        .generator = undefined,
        .atlas = undefined,
        .gen_queue = undefined,
        .mesh_queue = undefined,
        .upload_queue = try RingBuffer(ChunkKey).init(testing.allocator, 16),
        .vertex_allocator = undefined,
        .gpu = &gpu,
        .max_uploads_per_frame = 8,
        .last_pc_x = std.atomic.Value(i32).init(0),
        .last_pc_z = std.atomic.Value(i32).init(0),
        .effective_render_dist = std.atomic.Value(i32).init(8),
    };
    defer coordinator.deinit();

    ChunkQueueCoordinator.processGenJob(&coordinator, .{
        .type = .chunk_generation,
        .dist_sq = 0,
        .data = .{ .chunk = .{ .x = 64, .z = 0, .job_token = 7 } },
    });

    try testing.expectEqual(Chunk.State.missing, data.chunk.state);
}

test "stale mesh job resets chunk to generated" {
    const testing = std.testing;

    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data = try storage.getOrCreate(64, 0);
    data.chunk.state = .meshing;
    data.chunk.generated = true;
    data.chunk.job_token = 11;

    var gpu = GpuAccelerationCoordinator.init(null, null);
    var coordinator = ChunkQueueCoordinator{
        .allocator = testing.allocator,
        .storage = &storage,
        .generator = undefined,
        .atlas = undefined,
        .gen_queue = undefined,
        .mesh_queue = undefined,
        .upload_queue = try RingBuffer(ChunkKey).init(testing.allocator, 16),
        .vertex_allocator = undefined,
        .gpu = &gpu,
        .max_uploads_per_frame = 8,
        .last_pc_x = std.atomic.Value(i32).init(0),
        .last_pc_z = std.atomic.Value(i32).init(0),
        .effective_render_dist = std.atomic.Value(i32).init(8),
    };
    defer coordinator.deinit();

    ChunkQueueCoordinator.processMeshJob(&coordinator, .{
        .type = .chunk_meshing,
        .dist_sq = 0,
        .data = .{ .chunk = .{ .x = 64, .z = 0, .job_token = 11 } },
    });

    try testing.expectEqual(Chunk.State.generated, data.chunk.state);
}
