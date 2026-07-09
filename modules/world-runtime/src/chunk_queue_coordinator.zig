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
const WorldLightingEngine = @import("lighting_engine.zig").WorldLightingEngine;
const LODManager = @import("world-lod").LODManager;
const LODColumnProvenance = @import("world-core").LODColumnProvenance;

/// A pending chunk transition reference captured by a worker when it flips a
/// chunk into the `.generated` state. The main thread later drains the queue
/// and pushes the mesh job. Carries the job_token so stale entries (chunk was
/// reset to `.missing` in the meantime) can be discarded cheaply.
const PendingMeshRef = struct {
    x: i32,
    z: i32,
    job_token: u32,
};

const ChunkRevisions = struct {
    content: u64,
    light: u64,

    fn capture(chunk: *const Chunk) ChunkRevisions {
        return .{
            .content = chunk.content_revision.load(.acquire),
            .light = chunk.light_revision.load(.acquire),
        };
    }

    fn matches(self: ChunkRevisions, chunk: *const Chunk) bool {
        return self.content == chunk.content_revision.load(.acquire) and self.light == chunk.light_revision.load(.acquire);
    }
};

const MeshInputRevisions = struct {
    target: ChunkRevisions,
    north: ?ChunkRevisions,
    south: ?ChunkRevisions,
    east: ?ChunkRevisions,
    west: ?ChunkRevisions,

    fn capture(target: *const Chunk, neighbors: NeighborChunks) MeshInputRevisions {
        return .{
            .target = .capture(target),
            .north = if (neighbors.north) |chunk| .capture(chunk) else null,
            .south = if (neighbors.south) |chunk| .capture(chunk) else null,
            .east = if (neighbors.east) |chunk| .capture(chunk) else null,
            .west = if (neighbors.west) |chunk| .capture(chunk) else null,
        };
    }

    fn matches(self: MeshInputRevisions, target: *const Chunk, neighbors: NeighborChunks) bool {
        return self.target.matches(target) and
            matchesOptional(self.north, neighbors.north) and
            matchesOptional(self.south, neighbors.south) and
            matchesOptional(self.east, neighbors.east) and
            matchesOptional(self.west, neighbors.west);
    }

    fn matchesOptional(captured: ?ChunkRevisions, current: ?*const Chunk) bool {
        if (captured) |revisions| return if (current) |chunk| revisions.matches(chunk) else false;
        return current == null;
    }
};

/// How often (in frames) the slow recovery scan runs. The dominant transitions
/// (.generated -> queued_for_mesh and .mesh_ready -> uploading) are handled
/// every frame by the pending queues; the scan only catches stuck chunks and
/// any state that was reset outside the worker path (e.g. resetPausedChunks).
const RECOVERY_SCAN_PERIOD: u64 = 60;

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

    // Pending transition queues. Workers append under the respective mutex
    // when they flip a chunk into `.generated` or `.mesh_ready`; the main
    // thread drains these each frame. This replaces the per-frame full-storage
    // scan that previously held chunks_mutex exclusive while iterating every
    // loaded chunk (often 1500+ at high render distance).
    pending_mesh_mutex: engine_core.sync.Mutex = .{},
    pending_mesh_incoming: std.ArrayListUnmanaged(PendingMeshRef) = .empty,
    pending_upload_mutex: engine_core.sync.Mutex = .{},
    pending_upload_incoming: std.ArrayListUnmanaged(ChunkKey) = .empty,

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
        self.pending_mesh_incoming.deinit(self.allocator);
        self.pending_upload_incoming.deinit(self.allocator);
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

    fn weightedDistanceSq(dist_sq: i32, movement: anytype, dx: i32, dz: i32) i32 {
        const weighted = @as(f32, @floatFromInt(dist_sq)) * movement.priorityWeight(dx, dz);
        return @max(0, @as(i32, @intFromFloat(@min(weighted, @as(f32, @floatFromInt(std.math.maxInt(i32)))))));
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

    pub fn scanForMissingChunks(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, render_dist: i32, movement: anytype) !void {
        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        var cz: i32 = pc_z - render_dist;
        while (cz <= pc_z + render_dist) : (cz += 1) {
            var cx: i32 = pc_x - render_dist;
            while (cx <= pc_x + render_dist) : (cx += 1) {
                const dx = cx - pc_x;
                const dz = cz - pc_z;
                const dist_sq = dx * dx + dz * dz;

                if (dist_sq > render_dist * render_dist) continue;

                const key = ChunkKey{ .x = cx, .z = cz };
                const data = self.storage.chunks.get(key) orelse data: {
                    const created = try self.storage.createChunkDataUnlocked(cx, cz);
                    try self.storage.chunks.put(key, created);
                    break :data created;
                };

                switch (data.chunk.state) {
                    .missing => {
                        const priority_dist_sq = weightedDistanceSq(dist_sq, movement, dx, dz);
                        self.gen_queue.push(.{
                            .type = .chunk_generation,
                            .dist_sq = priority_dist_sq,
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
        // Fast path: drain the per-state transition queues that workers
        // appended to. This is O(pending_count) and avoids holding the
        // storage's exclusive lock while iterating every loaded chunk.
        self.drainPendingMesh(pc_x, pc_z, render_dist);
        self.drainPendingUpload();

        // Slow path: a throttled recovery scan that catches stuck chunks and
        // any state reset outside the worker path. Previously this ran every
        // frame; now it runs every RECOVERY_SCAN_PERIOD frames.
        if (frame_counter % RECOVERY_SCAN_PERIOD != 0) return;

        // Fixed-size scratch for chunks the scan flips back to `.generated`
        // (dirty / no-allocations recovery). Sized generously; overflow is
        // silently dropped and picked up by the next scan.
        var recovery_enqueue: [64]PendingMeshRef = undefined;
        var recovery_count: usize = 0;

        self.storage.chunks_mutex.lock();

        var mesh_iter = self.storage.iteratorUnsafe();
        while (mesh_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            if (data.chunk.state == .generated) {
                // Safety net in case a worker's pending-mesh notification was
                // lost (e.g. allocation failure on append).
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
                // Safety net for lost pending-upload notifications.
                data.chunk.state = .uploading;
                self.upload_queue.push(key) catch {
                    data.chunk.state = .mesh_ready;
                    continue;
                };
            } else if (data.chunk.state == .renderable) {
                if (data.chunk.dirty) {
                    data.chunk.dirty = false;
                    data.chunk.state = .generated;
                    if (recovery_count < recovery_enqueue.len) {
                        recovery_enqueue[recovery_count] = .{ .x = data.chunk.chunk_x, .z = data.chunk.chunk_z, .job_token = data.chunk.job_token };
                        recovery_count += 1;
                    }
                } else if (data.render.mesh.solid_allocation == null and data.render.mesh.cutout_allocation == null and data.render.mesh.fluid_allocation == null and data.chunk.mesh_attempts < 3) {
                    data.chunk.mesh_attempts += 1;
                    log.log.warn("CHUNK_RECOVERY: ({},{}) renderable with no allocations, re-meshing (attempt {})", .{ data.chunk.chunk_x, data.chunk.chunk_z, data.chunk.mesh_attempts });
                    data.chunk.state = .generated;
                    if (recovery_count < recovery_enqueue.len) {
                        recovery_enqueue[recovery_count] = .{ .x = data.chunk.chunk_x, .z = data.chunk.chunk_z, .job_token = data.chunk.job_token };
                        recovery_count += 1;
                    }
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
                        if (recovery_count < recovery_enqueue.len) {
                            recovery_enqueue[recovery_count] = .{ .x = data.chunk.chunk_x, .z = data.chunk.chunk_z, .job_token = data.chunk.job_token };
                            recovery_count += 1;
                        }
                    } else {
                        log.log.warn("CHUNK_UPLOAD_STUCK: ({},{}) exceeded max upload recovery attempts ({}), leaving as uploading", .{ data.chunk.chunk_x, data.chunk.chunk_z, data.chunk.mesh_attempts });
                    }
                }
            }
        }
        self.storage.chunks_mutex.unlock();

        // Enqueue recovery flips outside the storage lock to avoid a
        // lock-order inversion with the pending mutexes (the drain path
        // acquires pending_mutex first, then chunks_mutex).
        for (recovery_enqueue[0..recovery_count]) |ref| {
            self.enqueuePendingMesh(ref.x, ref.z, ref.job_token);
        }
    }

    /// Worker-facing helper: notify the main thread that a chunk is now in the
    /// `.generated` state and needs a mesh job. Safe to call from any thread;
    /// takes a brief spinlock and never blocks on the storage mutex.
    pub fn enqueuePendingMesh(self: *ChunkQueueCoordinator, cx: i32, cz: i32, job_token: u32) void {
        self.pending_mesh_mutex.lock();
        defer self.pending_mesh_mutex.unlock();
        self.pending_mesh_incoming.append(self.allocator, .{ .x = cx, .z = cz, .job_token = job_token }) catch return;
    }

    /// Worker-facing helper: notify the main thread that a chunk is now in the
    /// `.mesh_ready` state and needs to be uploaded.
    pub fn enqueuePendingUpload(self: *ChunkQueueCoordinator, cx: i32, cz: i32) void {
        self.pending_upload_mutex.lock();
        defer self.pending_upload_mutex.unlock();
        self.pending_upload_incoming.append(self.allocator, .{ .x = cx, .z = cz }) catch return;
    }

    fn drainPendingMesh(self: *ChunkQueueCoordinator, pc_x: i32, pc_z: i32, render_dist: i32) void {
        // Swap-and-clear under the pending mutex, then process outside it so
        // worker appends are unblocked as quickly as possible.
        var local: std.ArrayListUnmanaged(PendingMeshRef) = .empty;
        self.pending_mesh_mutex.lock();
        local.appendSlice(self.allocator, self.pending_mesh_incoming.items) catch {
            self.pending_mesh_mutex.unlock();
            return;
        };
        self.pending_mesh_incoming.clearRetainingCapacity();
        self.pending_mesh_mutex.unlock();
        defer local.deinit(self.allocator);

        if (local.items.len == 0) return;

        // Single exclusive-lock batch to validate state + flip to queued.
        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        for (local.items) |ref| {
            const data = self.storage.chunks.get(.{ .x = ref.x, .z = ref.z }) orelse continue;
            if (data.chunk.state != .generated or data.chunk.job_token != ref.job_token) continue;
            const dx = ref.x - pc_x;
            const dz = ref.z - pc_z;
            const dist_sq = dx * dx + dz * dz;
            if (dist_sq > render_dist * render_dist) continue;
            self.mesh_queue.push(.{
                .type = .chunk_meshing,
                .dist_sq = dist_sq,
                .data = .{ .chunk = .{ .x = ref.x, .z = ref.z, .job_token = ref.job_token } },
            }) catch continue;
            data.chunk.state = .queued_for_mesh;
        }
    }

    fn drainPendingUpload(self: *ChunkQueueCoordinator) void {
        var local: std.ArrayListUnmanaged(ChunkKey) = .empty;
        self.pending_upload_mutex.lock();
        local.appendSlice(self.allocator, self.pending_upload_incoming.items) catch {
            self.pending_upload_mutex.unlock();
            return;
        };
        self.pending_upload_incoming.clearRetainingCapacity();
        self.pending_upload_mutex.unlock();
        defer local.deinit(self.allocator);

        if (local.items.len == 0) return;

        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        for (local.items) |key| {
            const data = self.storage.chunks.get(key) orelse continue;
            if (data.chunk.state != .mesh_ready) continue;
            data.chunk.state = .uploading;
            self.upload_queue.push(key) catch {
                data.chunk.state = .mesh_ready;
            };
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
                        self.enqueuePendingUpload(key.x, key.z);
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

            if (load_result != .success and load_result != .success_relight_required) {
                if (load_result == .read_error or load_result == .corrupt_data) {
                    log.log.warn("Save load failed for chunk ({}, {}): {}, regenerating", .{ cx, cz, load_result });
                }
                self.generator.generate(&chunk_data.chunk, &self.gen_queue.abort_worker) catch |err| {
                    log.log.warn("CHUNK_GEN_ERROR: ({},{}) generator failed: {}", .{ cx, cz, err });
                    self.storage.chunks_mutex.lock();
                    chunk_data.chunk.state = .missing;
                    chunk_data.chunk.generated = false;
                    self.storage.chunks_mutex.unlock();
                    return;
                };
                if (self.gen_queue.abort_worker) {
                    self.storage.chunks_mutex.lock();
                    chunk_data.chunk.state = .missing;
                    self.storage.chunks_mutex.unlock();
                    return;
                }
            }

            var lighting = WorldLightingEngine.init(self.storage, self.allocator);
            lighting.reconcileChunkArrival(cx, cz) catch |err| {
                log.log.warn("CHUNK_LIGHTING_ERROR: ({},{}) relight failed: {}", .{ cx, cz, err });
            };

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
                self.enqueuePendingMesh(cx, cz, chunk_data.chunk.job_token);
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

        const mesh_revisions = MeshInputRevisions.capture(&chunk_data.chunk, neighbors);

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
                const publishable = if (self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz })) |data|
                    data.chunk.state == .meshing and data.chunk.job_token == job.data.chunk.job_token and mesh_revisions.matches(&data.chunk, neighbors)
                else
                    false;
                chunk_data.chunk.state = if (publishable) .mesh_ready else .generated;
                self.storage.chunks_mutex.unlock();
                if (!publishable) {
                    self.enqueuePendingMesh(cx, cz, chunk_data.chunk.job_token);
                    return;
                }
                self.enqueuePendingUpload(cx, cz);
                _ = self.chunks_meshed_total.fetchAdd(1, .monotonic);
                return;
            }
            chunk_data.render.mesh.buildWithNeighbors(&chunk_data.chunk, neighbors, self.atlas) catch |err| {
                log.log.errWithTrace("Mesh build failed for chunk ({}, {}): {}", .{ cx, cz, err });
                self.storage.chunks_mutex.lock();
                chunk_data.chunk.state = .generated;
                self.storage.chunks_mutex.unlock();
                self.enqueuePendingMesh(cx, cz, chunk_data.chunk.job_token);
                return;
            };
            if (self.mesh_queue.abort_worker) {
                self.storage.chunks_mutex.lock();
                chunk_data.chunk.state = .generated;
                self.storage.chunks_mutex.unlock();
                self.enqueuePendingMesh(cx, cz, chunk_data.chunk.job_token);
                return;
            }
            self.storage.chunks_mutex.lock();
            const publishable = if (self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz })) |data|
                data.chunk.state == .meshing and data.chunk.job_token == job.data.chunk.job_token and mesh_revisions.matches(&data.chunk, neighbors)
            else
                false;
            chunk_data.chunk.state = if (publishable) .mesh_ready else .generated;
            self.storage.chunks_mutex.unlock();
            if (!publishable) {
                self.enqueuePendingMesh(cx, cz, chunk_data.chunk.job_token);
                return;
            }
            self.enqueuePendingUpload(cx, cz);
            _ = self.chunks_meshed_total.fetchAdd(1, .monotonic);
        }
    }

    fn markNeighborsForRemesh(self: *ChunkQueueCoordinator, cx: i32, cz: i32) void {
        const offsets = [_][2]i32{ .{ 0, 1 }, .{ 0, -1 }, .{ 1, 0 }, .{ -1, 0 } };

        var enqueue_refs: [4]PendingMeshRef = undefined;
        var enqueue_count: usize = 0;

        self.storage.chunks_mutex.lock();
        for (offsets) |off| {
            if (self.storage.chunks.get(ChunkKey{ .x = cx + off[0], .z = cz + off[1] })) |data| {
                switch (data.chunk.state) {
                    .renderable => {
                        data.chunk.state = .generated;
                        enqueue_refs[enqueue_count] = .{ .x = data.chunk.chunk_x, .z = data.chunk.chunk_z, .job_token = data.chunk.job_token };
                        enqueue_count += 1;
                    },
                    .mesh_ready, .uploading, .meshing => data.chunk.dirty = true,
                    else => {},
                }
            }
        }
        self.storage.chunks_mutex.unlock();

        // Enqueue outside chunks_mutex to keep lock ordering consistent with
        // drainPendingMesh (pending mutex first, then chunks_mutex).
        for (enqueue_refs[0..enqueue_count]) |ref| {
            self.enqueuePendingMesh(ref.x, ref.z, ref.job_token);
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
