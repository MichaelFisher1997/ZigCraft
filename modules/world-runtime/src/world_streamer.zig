//! World streamer - handles asynchronous chunk loading and unloading.
//!
//! This module manages the lifecycle of chunks around the player, coordinating
//! generation, meshing, and GPU upload through a multi-threaded job system.
//!
//! ## Chunk State Machine
//!
//! Chunks flow through the following states:
//! ```
//! missing -> generating -> generated -> meshing -> mesh_ready -> uploading -> renderable
//!    ^                                                                    |
//!    |                    (dirty flag triggers remesh)                    |
//!    +--------------------------------------------------------------------+
//! ```
//!
//! - **missing**: Chunk not yet loaded or queued
//! - **generating**: Terrain generation job in progress (worker thread)
//! - **generated**: Terrain data ready, awaiting mesh job
//! - **meshing**: Mesh building job in progress (worker thread)
//! - **mesh_ready**: Mesh data built, awaiting GPU upload
//! - **uploading**: Mesh being uploaded to GPU (main thread)
//! - **renderable**: Ready for drawing
//!
//! ## Dual Queue Architecture
//!
//! The streamer uses two independent job queues with dedicated worker pools:
//! - **gen_queue** (4 workers): Terrain generation via `processGenJob`
//! - **mesh_queue** (3 workers): Mesh building via `processMeshJob`
//!
//! This separation prevents meshing from blocking generation and allows
//! independent prioritization.
//!
//! ## Thread Safety
//!
//! - ChunkStorage is protected by `chunks_mutex` (shared/exclusive locking)
//! - Workers read/write chunk data under lock protection
//! - GPU uploads happen on the main thread via `processUploads()`
//! - Never call RHI or windowing from worker threads
//!
//! ## Predictive Loading
//!
//! PlayerMovement tracking enables priority weighting based on velocity:
//! - Chunks in movement direction get lower distance weight (higher priority)
//! - Chunks behind the player get higher distance weight (lower priority)
//! - This improves perceived loading speed during fast travel

const std = @import("std");
const Vec3 = @import("engine-math").Vec3;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const ChunkKey = world_core.ChunkKey;
const worldToChunkFromFloat = world_core.worldToChunkFromFloat;
const CHUNK_UNLOAD_BUFFER = world_core.CHUNK_UNLOAD_BUFFER;
const world_meshing = @import("world-meshing");
const ChunkStorage = world_meshing.ChunkStorage;
const NeighborChunks = world_meshing.NeighborChunks;
const engine_core = @import("engine-core");
const JobQueue = engine_core.JobQueue;
const WorkerPool = engine_core.WorkerPool;
const Generator = @import("world-worldgen").Generator;
const GlobalVertexAllocator = world_meshing.GlobalVertexAllocator;
const LODManager = @import("world-lod").LODManager;
const ChunkResolver = @import("world-lod").ChunkResolver;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const log = @import("engine-core").log;
const SaveManager = @import("world-persistence").SaveManager;
const GpuBlockBuffer = world_meshing.GpuBlockBuffer;
const GpuMesher = @import("gpu_mesher.zig").GpuMesher;
const WorldMutationCoordinator = @import("world_mutation.zig").WorldMutationCoordinator;
const GpuAccelerationCoordinator = @import("gpu_acceleration_coordinator.zig").GpuAccelerationCoordinator;
const ChunkQueueCoordinator = @import("chunk_queue_coordinator.zig").ChunkQueueCoordinator;
const LODStreamingCoordinator = @import("world-lod").LODStreamingCoordinator;
const QueueStats = @import("world-lod").lod_streaming_coordinator.QueueStats;
const build_options = @import("world_runtime_options");

/// Buffer distance beyond render_distance for chunk unloading.
/// Prevents thrashing when player moves near chunk boundaries.
// const CHUNK_UNLOAD_BUFFER: i32 = 1;

pub const PlayerMovement = @import("world-lod").lod_streaming_coordinator.PlayerMovement;

pub const WorldStreamer = struct {
    allocator: std.mem.Allocator,
    storage: *ChunkStorage,
    generator: Generator,
    atlas: *const TextureAtlas,

    gen_queue: *JobQueue,
    mesh_queue: *JobQueue,
    gen_pool: *WorkerPool,
    mesh_pool: *WorkerPool,
    queue_coordinator: ChunkQueueCoordinator,
    lod_coordinator: LODStreamingCoordinator,
    gpu_acceleration: GpuAccelerationCoordinator,

    vertex_allocator: *GlobalVertexAllocator,

    paused: bool = false,
    save_manager: ?*SaveManager = null,

    frame_counter: u64 = 0,
    has_scanned_missing_chunks: bool = false,
    last_missing_scan_pc_x: i32 = 0,
    last_missing_scan_pc_z: i32 = 0,
    last_missing_scan_render_dist: i32 = 0,
    last_diag_generated: u64 = 0,
    last_diag_meshed: u64 = 0,
    last_diag_uploaded: u64 = 0,

    const MIN_GEN_WORKERS = 2;
    const MAX_GEN_WORKERS = 4;
    const MIN_MESH_WORKERS = 2;
    const MAX_MESH_WORKERS = 6;
    const MIN_LOD_WORKERS = 2;
    const MAX_LOD_WORKERS = 6;

    pub fn init(allocator: std.mem.Allocator, storage: *ChunkStorage, generator: Generator, atlas: *const TextureAtlas, render_distance: i32, lod_enabled: bool, vertex_allocator: *GlobalVertexAllocator, max_uploads_per_frame: usize, gpu_block_buffer: ?*GpuBlockBuffer, gpu_mesher: ?*GpuMesher) !*WorldStreamer {
        const streamer = try allocator.create(WorldStreamer);
        errdefer allocator.destroy(streamer);

        // Reserve LOD capacity from the same CPU budget as full-detail work
        // while preserving the foreground pool caps. This leaves capacity for
        // the main thread and graphics driver.
        // This keeps horizon generation responsive without creating two pools
        // that each try to saturate every core.
        const cpu_count = std.Thread.getCpuCount() catch MIN_GEN_WORKERS + MIN_MESH_WORKERS;
        const total_budget = @max(@as(usize, 4), cpu_count -| 1);
        const requested_lod_workers = if (lod_enabled)
            std.math.clamp(cpu_count / 2, MIN_LOD_WORKERS, MAX_LOD_WORKERS)
        else
            0;
        const lod_worker_reserve = @min(requested_lod_workers, total_budget -| (MIN_GEN_WORKERS + MIN_MESH_WORKERS));
        const foreground_budget = total_budget - lod_worker_reserve;
        const default_gen = std.math.clamp(foreground_budget / 2, MIN_GEN_WORKERS, MAX_GEN_WORKERS);
        const default_mesh = std.math.clamp(foreground_budget - default_gen, MIN_MESH_WORKERS, MAX_MESH_WORKERS);
        const gen_worker_count = engine_core.envInt("ZIGCRAFT_GEN_WORKERS", default_gen);
        const mesh_worker_count = engine_core.envInt("ZIGCRAFT_MESH_WORKERS", default_mesh);

        const gen_queue = try allocator.create(JobQueue);
        gen_queue.* = JobQueue.init(allocator);
        errdefer {
            gen_queue.deinit();
            allocator.destroy(gen_queue);
        }

        const mesh_queue = try allocator.create(JobQueue);
        mesh_queue.* = JobQueue.init(allocator);
        errdefer {
            mesh_queue.deinit();
            allocator.destroy(mesh_queue);
        }

        streamer.* = .{
            .allocator = allocator,
            .storage = storage,
            .generator = generator,
            .atlas = atlas,
            .gen_queue = gen_queue,
            .mesh_queue = mesh_queue,
            .gen_pool = undefined,
            .mesh_pool = undefined,
            .queue_coordinator = undefined,
            .lod_coordinator = LODStreamingCoordinator.init(render_distance),
            .gpu_acceleration = GpuAccelerationCoordinator.init(gpu_block_buffer, gpu_mesher),
            .vertex_allocator = vertex_allocator,
            .last_diag_generated = 0,
            .last_diag_meshed = 0,
            .last_diag_uploaded = 0,
        };

        streamer.queue_coordinator = try ChunkQueueCoordinator.init(allocator, storage, generator, atlas, gen_queue, mesh_queue, vertex_allocator, max_uploads_per_frame, &streamer.gpu_acceleration);
        errdefer streamer.queue_coordinator.deinit();

        log.log.info("WorldStreamer workers: gen={} mesh={} lod_reserve={} (cpu={})", .{ gen_worker_count, mesh_worker_count, lod_worker_reserve, cpu_count });

        streamer.gen_pool = try WorkerPool.init(allocator, gen_worker_count, gen_queue, &streamer.queue_coordinator, ChunkQueueCoordinator.processGenJob);
        errdefer streamer.gen_pool.deinit();

        streamer.mesh_pool = try WorkerPool.init(allocator, mesh_worker_count, mesh_queue, &streamer.queue_coordinator, ChunkQueueCoordinator.processMeshJob);
        errdefer streamer.mesh_pool.deinit();

        try streamer.warmupInitialChunks();

        return streamer;
    }

    pub fn deinit(self: *WorldStreamer) void {
        self.gen_queue.stop();
        self.mesh_queue.stop();

        self.gen_pool.deinit();
        self.mesh_pool.deinit();

        self.gen_queue.deinit();
        self.mesh_queue.deinit();
        self.allocator.destroy(self.gen_queue);
        self.allocator.destroy(self.mesh_queue);

        self.queue_coordinator.deinit();
        self.allocator.destroy(self);
    }

    pub fn setPaused(self: *WorldStreamer, paused: bool) void {
        self.paused = paused;
        self.gen_queue.setPaused(paused);
        self.mesh_queue.setPaused(paused);

        if (paused) {
            self.queue_coordinator.resetPausedChunks();
        } else {
            self.lod_coordinator.forceRescan();
        }
    }

    pub fn setRenderDistance(self: *WorldStreamer, distance: i32) void {
        _ = self.lod_coordinator.setRenderDistance(distance);
    }

    pub fn getActiveRenderDistance(self: *const WorldStreamer) i32 {
        return self.lod_coordinator.getActiveRenderDistance();
    }

    pub fn isStartupBusy(self: *WorldStreamer, target_render_dist: i32) bool {
        return self.lod_coordinator.isStartupBusy(self.getStats(), target_render_dist);
    }

    fn warmupInitialChunks(self: *WorldStreamer) !void {
        const warmup_radius: i32 = 1;

        var cz: i32 = -warmup_radius;
        while (cz <= warmup_radius) : (cz += 1) {
            var cx: i32 = -warmup_radius;
            while (cx <= warmup_radius) : (cx += 1) {
                const data = try self.storage.getOrCreate(cx, cz);
                if (data.chunk.generated) continue;

                data.chunk.state = .generating;
                self.generator.generate(&data.chunk, null) catch |err| {
                    log.log.warn("STARTUP_WARMUP_GEN_FAILED: ({},{}) {}", .{ cx, cz, err });
                    data.chunk.state = .missing;
                    continue;
                };
                if (!data.chunk.generated) {
                    data.chunk.state = .missing;
                    continue;
                }
                data.chunk.state = .generated;
            }
        }

        cz = -warmup_radius;
        while (cz <= warmup_radius) : (cz += 1) {
            var cx: i32 = -warmup_radius;
            while (cx <= warmup_radius) : (cx += 1) {
                const data = self.storage.get(cx, cz) orelse continue;
                if (!data.chunk.generated) continue;

                const neighbors = NeighborChunks{
                    .north = if (self.storage.get(cx, cz - 1)) |n| &n.chunk else null,
                    .south = if (self.storage.get(cx, cz + 1)) |s| &s.chunk else null,
                    .east = if (self.storage.get(cx + 1, cz)) |e| &e.chunk else null,
                    .west = if (self.storage.get(cx - 1, cz)) |w| &w.chunk else null,
                };

                data.render.mesh.buildWithNeighbors(&data.chunk, neighbors, self.atlas) catch |err| {
                    log.log.warn("STARTUP_WARMUP_MESH_FAILED: ({},{}) {}", .{ cx, cz, err });
                    data.chunk.state = .generated;
                    continue;
                };

                data.chunk.state = .mesh_ready;
                data.render.mesh.upload(self.vertex_allocator);
                if (data.render.mesh.ready) {
                    data.chunk.state = .renderable;
                    data.chunk.dirty = false;
                    _ = self.queue_coordinator.chunks_uploaded_total.fetchAdd(1, .monotonic);
                } else {
                    data.chunk.state = .generated;
                }
            }
        }
    }

    pub fn setLODManager(self: *WorldStreamer, lod_manager: ?*LODManager) void {
        self.lod_coordinator.setLODManager(lod_manager);
        self.queue_coordinator.setLODManager(lod_manager);
        if (lod_manager) |mgr| {
            // Resolver lets deferred ingestions fetch resident chunks. The
            // returned pointer is consumed synchronously within the manager's
            // main-thread update, so it does not need pinning.
            mgr.setChunkResolver(.{
                .ptr = self.storage,
                .resolve_fn = resolveChunkFromStorage,
            });
        }
    }

    pub fn setSaveManager(self: *WorldStreamer, sm: ?*SaveManager) void {
        self.save_manager = sm;
        self.queue_coordinator.setSaveManager(sm);
    }

    pub fn requestDirtyRemesh(self: *WorldStreamer, center_cx: i32, center_cz: i32) void {
        self.queue_coordinator.requestDirtyRemesh(center_cx, center_cz);
    }

    pub fn enqueueMutationLighting(self: *WorldStreamer, mutation: *WorldMutationCoordinator, result: WorldMutationCoordinator.MutationResult) !void {
        if (result.lighting_update == .none) {
            self.requestDirtyRemesh(result.chunk_x, result.chunk_z);
            return;
        }

        const context = try self.allocator.create(MutationLightingJob);
        errdefer self.allocator.destroy(context);
        context.* = .{
            .allocator = self.allocator,
            .mutation = mutation,
            .queue_coordinator = &self.queue_coordinator,
            .result = result,
        };
        const queued = try self.mesh_queue.tryPush(.{
            .type = .generic,
            .priority = -1,
            .data = .{ .generic = .{
                .context = context,
                .process_fn = processMutationLighting,
                .cleanup_fn = cleanupMutationLighting,
            } },
        });
        if (!queued) {
            self.allocator.destroy(context);
            try mutation.updateLighting(result);
            self.requestDirtyRemesh(result.chunk_x, result.chunk_z);
        }
    }

    pub fn updateFrame(self: *WorldStreamer, player_pos: Vec3, dt: f32) !void {
        if (self.paused) return;

        self.frame_counter += 1;

        self.updateStreaming(player_pos, dt) catch |err| {
            log.log.warn("updateStreaming error (non-fatal): {}", .{err});
        };
        self.queue_coordinator.processUploads();
        self.processUnloads(player_pos) catch |err| {
            log.log.warn("processUnloads error (non-fatal): {}", .{err});
        };
        if (self.frame_counter % 300 == 0) {
            self.logChunkStateSummary();
        }
    }

    fn logChunkStateSummary(self: *WorldStreamer) void {
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        var counts = [_]u32{0} ** 10;
        var renderable_no_alloc: u32 = 0;
        var renderable_not_ready: u32 = 0;
        var total: u32 = 0;

        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const data = entry.value_ptr.*;
            total += 1;
            switch (data.chunk.state) {
                .missing => counts[0] += 1,
                .queued_for_generation => counts[1] += 1,
                .generating => counts[2] += 1,
                .generated => counts[3] += 1,
                .queued_for_mesh => counts[4] += 1,
                .meshing => counts[5] += 1,
                .mesh_ready => counts[6] += 1,
                .uploading => counts[7] += 1,
                .renderable => {
                    counts[8] += 1;
                    if (data.render.mesh.solid_allocation == null and data.render.mesh.cutout_allocation == null and data.render.mesh.fluid_allocation == null) {
                        renderable_no_alloc += 1;
                    }
                    if (!data.render.mesh.ready) {
                        renderable_not_ready += 1;
                    }
                },
                .unloading => counts[9] += 1,
            }
        }

        if (build_options.startup_diagnostic_seconds == 0) {
            log.log.info("CHUNK_STATES [frame={}]: total={} | missing={} qgen={} gen={} gentd={} qmesh={} meshing={} mready={} uploading={} renderable={} unloading={} | no_alloc={} not_ready={}", .{
                self.frame_counter,  total,
                counts[0],           counts[1],
                counts[2],           counts[3],
                counts[4],           counts[5],
                counts[6],           counts[7],
                counts[8],           counts[9],
                renderable_no_alloc, renderable_not_ready,
            });

            if (renderable_no_alloc > 0) {
                log.log.warn("  {} chunks renderable with no allocations (max 3 recovery attempts)", .{renderable_no_alloc});
            }

            if (self.lod_coordinator.lod_manager) |lod_mgr| {
                const lod0_r = lod_mgr.config.getChunkRenderRadius();
                const pc_x = self.lod_coordinator.last_pc.x;
                const pc_z = self.lod_coordinator.last_pc.z;
                const check_dirs = [_][2]i32{ .{ lod0_r, 0 }, .{ -lod0_r, 0 }, .{ 0, lod0_r }, .{ 0, -lod0_r } };
                var renderable_at_boundary: u32 = 0;
                var missing_at_boundary: u32 = 0;
                for (check_dirs) |dir| {
                    const cx = pc_x + dir[0];
                    const cz = pc_z + dir[1];
                    if (self.storage.chunks.get(.{ .x = cx, .z = cz })) |data| {
                        if (data.chunk.state == .renderable or data.render.mesh.solid_allocation != null) {
                            renderable_at_boundary += 1;
                        } else {
                            if (missing_at_boundary == 0) {
                                log.log.warn("  BOUNDARY_CHUNK: ({},{}) state={} (expected renderable)", .{ cx, cz, data.chunk.state });
                            }
                            missing_at_boundary += 1;
                        }
                    } else {
                        if (missing_at_boundary == 0) {
                            log.log.warn("  BOUNDARY_CHUNK: ({},{}) NOT IN STORAGE", .{ cx, cz });
                        }
                        missing_at_boundary += 1;
                    }
                }
                if (missing_at_boundary > 0) {
                    log.log.warn("  BOUNDARY: {}/4 chunks at LOD0 boundary (r={}) are NOT renderable", .{ missing_at_boundary, lod0_r });
                }
            }
        }
    }

    fn updateStreaming(self: *WorldStreamer, player_pos: Vec3, dt: f32) !void {
        self.gpu_acceleration.refreshForceCpuMeshing(self.frame_counter, self.storage);

        const frame = self.lod_coordinator.beginFrame(self.storage, self.gen_queue, self.mesh_queue, player_pos, dt, self.frame_counter);
        self.queue_coordinator.setView(frame.pc_x, frame.pc_z, frame.render_dist);

        if (self.frame_counter % 600 == 0) {
            self.logMissingChunkDiagnostic(frame.pc_x, frame.pc_z);
        }

        // The required chunk set changes only after crossing a chunk boundary or
        // changing view distance. A periodic scan remains as a safety net for a
        // failed queue insertion without taking the storage writer lock every frame.
        const needs_missing_scan = !self.has_scanned_missing_chunks or
            self.last_missing_scan_pc_x != frame.pc_x or
            self.last_missing_scan_pc_z != frame.pc_z or
            self.last_missing_scan_render_dist != frame.render_dist or
            self.frame_counter % 60 == 0;
        if (needs_missing_scan) {
            self.queue_coordinator.scanForMissingChunks(frame.pc_x, frame.pc_z, frame.render_dist, frame.movement) catch |err| {
                log.log.warn("scanForMissingChunks error (non-fatal): {}", .{err});
            };
            self.has_scanned_missing_chunks = true;
            self.last_missing_scan_pc_x = frame.pc_x;
            self.last_missing_scan_pc_z = frame.pc_z;
            self.last_missing_scan_render_dist = frame.render_dist;
        }
        self.queue_coordinator.processChunkStates(frame.pc_x, frame.pc_z, frame.render_dist, self.frame_counter);
        self.lod_coordinator.updateLOD(player_pos, self.storage);

        if (!self.lod_coordinator.startup_mesh_finalized and !self.isStartupBusy(self.lod_coordinator.render_distance)) {
            self.finalizeStartupArea(frame.pc_x, frame.pc_z, 1);
            self.lod_coordinator.startup_mesh_finalized = true;
        }
    }

    fn finalizeStartupArea(self: *WorldStreamer, pc_x: i32, pc_z: i32, radius: i32) void {
        var cz = pc_z - radius;
        while (cz <= pc_z + radius) : (cz += 1) {
            var cx = pc_x - radius;
            while (cx <= pc_x + radius) : (cx += 1) {
                self.finalizeChunkMesh(cx, cz);
            }
        }
    }

    fn finalizeChunkMesh(self: *WorldStreamer, cx: i32, cz: i32) void {
        self.storage.chunks_mutex.lockShared();
        const chunk_data = self.storage.chunks.get(.{ .x = cx, .z = cz }) orelse {
            self.storage.chunks_mutex.unlockShared();
            return;
        };

        if (!chunk_data.chunk.generated and chunk_data.chunk.state != .renderable) {
            self.storage.chunks_mutex.unlockShared();
            return;
        }

        chunk_data.chunk.pin();
        const neighbors = NeighborChunks{
            .north = if (self.storage.chunks.get(.{ .x = cx, .z = cz - 1 })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .south = if (self.storage.chunks.get(.{ .x = cx, .z = cz + 1 })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .east = if (self.storage.chunks.get(.{ .x = cx + 1, .z = cz })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
            .west = if (self.storage.chunks.get(.{ .x = cx - 1, .z = cz })) |d| d: {
                d.chunk.pin();
                break :d &d.chunk;
            } else null,
        };
        self.storage.chunks_mutex.unlockShared();

        defer {
            chunk_data.chunk.unpin();
            if (neighbors.north) |n| @constCast(n).unpin();
            if (neighbors.south) |s| @constCast(s).unpin();
            if (neighbors.east) |e| @constCast(e).unpin();
            if (neighbors.west) |w| @constCast(w).unpin();
        }

        chunk_data.render.mesh.buildWithNeighbors(&chunk_data.chunk, neighbors, self.atlas) catch |err| {
            log.log.warn("STARTUP_FINALIZE_MESH_FAILED: ({},{}) {}", .{ cx, cz, err });
            return;
        };
        chunk_data.render.mesh.upload(self.vertex_allocator);

        self.storage.chunks_mutex.lock();
        if (self.storage.chunks.get(.{ .x = cx, .z = cz })) |data| {
            data.chunk.state = .renderable;
            data.chunk.dirty = false;
            data.chunk.mesh_attempts = 0;
        }
        self.storage.chunks_mutex.unlock();
    }

    fn processUnloads(self: *WorldStreamer, player_pos: Vec3) !void {
        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        const render_dist_unload = self.lod_coordinator.targetRenderDistance();
        const unload_dist_sq = (render_dist_unload + CHUNK_UNLOAD_BUFFER) * (render_dist_unload + CHUNK_UNLOAD_BUFFER);

        self.storage.chunks_mutex.lock();
        var to_remove = std.ArrayListUnmanaged(ChunkKey).empty;
        defer to_remove.deinit(self.allocator);

        var unload_iter = self.storage.iteratorUnsafe();
        while (unload_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            const dx = key.x - pc.chunk_x;
            const dz = key.z - pc.chunk_z;
            if (dx * dx + dz * dz > unload_dist_sq) {
                if (data.chunk.state != .generating and data.chunk.state != .meshing and
                    data.chunk.state != .uploading and
                    !data.chunk.isPinned())
                {
                    try to_remove.append(self.allocator, key);
                }
            }
        }

        for (to_remove.items) |key| {
            if (self.save_manager) |sm| {
                if (self.storage.chunks.get(key)) |data| {
                    if (data.chunk.modified and data.chunk.generated) {
                        data.chunk.pin();
                        sm.enqueueSave(&data.chunk);
                        data.chunk.modified = false;
                        data.chunk.unpin();
                    }
                }
            }
            self.gpu_acceleration.freeChunk(key.x, key.z);
            _ = self.storage.removeUnlocked(key.x, key.z, self.vertex_allocator);
        }
        self.storage.chunks_mutex.unlock();
    }

    fn logMissingChunkDiagnostic(self: *WorldStreamer, pc_x: i32, pc_z: i32) void {
        const target_render_dist = self.lod_coordinator.targetRenderDistance();
        const render_dist = @min(self.getActiveRenderDistance(), target_render_dist);

        var counts = [_]u32{0} ** 10;
        var missing_keys = std.ArrayListUnmanaged(ChunkKey).empty;
        defer missing_keys.deinit(self.allocator);

        self.storage.chunks_mutex.lockShared();
        var cz: i32 = pc_z - render_dist;
        while (cz <= pc_z + render_dist) : (cz += 1) {
            var cx: i32 = pc_x - render_dist;
            while (cx <= pc_x + render_dist) : (cx += 1) {
                const dx = cx - pc_x;
                const dz = cz - pc_z;
                if (dx * dx + dz * dz > render_dist * render_dist) continue;

                if (self.storage.chunks.get(.{ .x = cx, .z = cz })) |data| {
                    switch (data.chunk.state) {
                        .missing => counts[0] += 1,
                        .queued_for_generation => counts[1] += 1,
                        .generating => counts[2] += 1,
                        .generated => counts[3] += 1,
                        .queued_for_mesh => counts[4] += 1,
                        .meshing => counts[5] += 1,
                        .mesh_ready => counts[6] += 1,
                        .uploading => counts[7] += 1,
                        .renderable => counts[8] += 1,
                        .unloading => counts[9] += 1,
                    }
                } else {
                    counts[0] += 1;
                    missing_keys.append(self.allocator, .{ .x = cx, .z = cz }) catch {};
                }
            }
        }
        self.storage.chunks_mutex.unlockShared();

        const generated_total = self.queue_coordinator.chunks_generated_total.load(.monotonic);
        const meshed_total = self.queue_coordinator.chunks_meshed_total.load(.monotonic);
        const uploaded_total = self.queue_coordinator.chunks_uploaded_total.load(.monotonic);
        const generated_delta = generated_total - self.last_diag_generated;
        const meshed_delta = meshed_total - self.last_diag_meshed;
        const uploaded_delta = uploaded_total - self.last_diag_uploaded;
        self.last_diag_generated = generated_total;
        self.last_diag_meshed = meshed_total;
        self.last_diag_uploaded = uploaded_total;

        log.log.info("CHUNK_DIAG [frame={}] pc=({},{}) rd={}/{} | missing={} qgen={} gen={} gentd={} qmesh={} mesh={} mready={} upload={} render={} unload={} | not_in_storage={} | throughput gen={}/{} mesh={}/{} upload={}/{}", .{
            self.frame_counter,     pc_x,            pc_z,            render_dist,  target_render_dist,
            counts[0],              counts[1],       counts[2],       counts[3],    counts[4],
            counts[5],              counts[6],       counts[7],       counts[8],    counts[9],
            missing_keys.items.len, generated_delta, generated_total, meshed_delta, meshed_total,
            uploaded_delta,         uploaded_total,
        });

        if (missing_keys.items.len > 0 and missing_keys.items.len <= 20) {
            var buf: [512]u8 = undefined;
            var len: usize = 0;
            const prefix = "  NOT_IN_STORAGE: ";
            @memcpy(buf[0..prefix.len], prefix);
            len = prefix.len;
            for (missing_keys.items) |k| {
                const txt = std.fmt.bufPrint(buf[len..], "({},{}) ", .{ k.x, k.z }) catch break;
                len += txt.len;
            }
            log.log.info("{s}", .{buf[0..len]});
        }

        const pipeline_busy = counts[1] > 0 or counts[2] > 0 or counts[4] > 0 or counts[5] > 0;
        if (!pipeline_busy and (counts[3] > 0 or counts[6] > 0 or counts[7] > 0)) {
            log.log.warn("  stalled chunks: generated={} mesh_ready={} uploading={} (should be 0 at steady state)", .{
                counts[3], counts[6], counts[7],
            });
        }
    }

    pub fn getStats(self: *WorldStreamer) QueueStats {
        self.gen_queue.mutex.lock();
        const gen_count = self.gen_queue.jobs.count();
        self.gen_queue.mutex.unlock();

        self.mesh_queue.mutex.lock();
        const mesh_count = self.mesh_queue.jobs.count();
        self.mesh_queue.mutex.unlock();

        return .{
            .gen_queue = gen_count,
            .mesh_queue = mesh_count,
            .upload_queue = self.queue_coordinator.upload_queue.count(),
        };
    }
};

const MutationLightingJob = struct {
    allocator: std.mem.Allocator,
    mutation: *WorldMutationCoordinator,
    queue_coordinator: *ChunkQueueCoordinator,
    result: WorldMutationCoordinator.MutationResult,
};

fn processMutationLighting(raw_context: *anyopaque) void {
    const context: *MutationLightingJob = @ptrCast(@alignCast(raw_context));
    context.mutation.updateLighting(context.result) catch |err| {
        log.log.warn("BLOCK_LIGHTING_ERROR: ({},{}) update failed: {}", .{ context.result.chunk_x, context.result.chunk_z, err });
    };
    context.queue_coordinator.requestDirtyRemesh(context.result.chunk_x, context.result.chunk_z);
    const allocator = context.allocator;
    allocator.destroy(context);
}

fn cleanupMutationLighting(raw_context: *anyopaque) void {
    const context: *MutationLightingJob = @ptrCast(@alignCast(raw_context));
    const allocator = context.allocator;
    allocator.destroy(context);
}

/// ChunkResolver callback: look up a resident, generated chunk by coordinate.
/// The returned pointer is only valid for synchronous use on the main thread
/// (it is not pinned); the LOD manager consumes it immediately within update().
fn resolveChunkFromStorage(ptr: *anyopaque, cx: i32, cz: i32) ?*const world_core.Chunk {
    const storage: *ChunkStorage = @ptrCast(@alignCast(ptr));
    storage.chunks_mutex.lockShared();
    defer storage.chunks_mutex.unlockShared();
    const entry = storage.chunks.get(ChunkKey{ .x = cx, .z = cz }) orelse return null;
    if (!entry.chunk.generated) return null;
    return &entry.chunk;
}
