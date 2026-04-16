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
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Chunk = @import("chunk.zig").Chunk;
const ChunkKey = @import("chunk_storage.zig").ChunkKey;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const NeighborChunks = @import("chunk_mesh.zig").NeighborChunks;
const JobQueue = @import("../engine/core/job_system.zig").JobQueue;
const WorkerPool = @import("../engine/core/job_system.zig").WorkerPool;
const Job = @import("../engine/core/job_system.zig").Job;
const RingBuffer = @import("../engine/core/ring_buffer.zig").RingBuffer;
const Generator = @import("worldgen/generator_interface.zig").Generator;
const worldToChunkFromFloat = @import("chunk.zig").worldToChunkFromFloat;
const CHUNK_UNLOAD_BUFFER = @import("chunk.zig").CHUNK_UNLOAD_BUFFER;
const GlobalVertexAllocator = @import("chunk_allocator.zig").GlobalVertexAllocator;
const LODManager = @import("lod_manager.zig").LODManager;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const log = @import("../engine/core/log.zig");
const SaveManager = @import("persistence/save_manager.zig").SaveManager;
const LoadResult = @import("persistence/save_manager.zig").LoadResult;
const GpuBlockBuffer = @import("gpu_block_buffer.zig").GpuBlockBuffer;
const GpuMesher = @import("gpu_mesher.zig").GpuMesher;
const build_options = @import("build_options");

/// Buffer distance beyond render_distance for chunk unloading.
/// Prevents thrashing when player moves near chunk boundaries.
// const CHUNK_UNLOAD_BUFFER: i32 = 1;

/// Player movement tracking for predictive chunk loading
pub const PlayerMovement = struct {
    /// Normalized movement direction (0,0 if stationary)
    dir_x: f32 = 0,
    dir_z: f32 = 0,
    /// Speed in blocks/second
    speed: f32 = 0,
    /// Last position for velocity calculation
    last_pos: Vec3 = Vec3.init(0, 0, 0),
    /// Whether we have valid velocity data
    has_velocity: bool = false,

    /// Update with new position, returns true if direction changed significantly
    pub fn update(self: *PlayerMovement, pos: Vec3, dt: f32) bool {
        if (dt <= 0.001) return false;

        const dx = pos.x - self.last_pos.x;
        const dz = pos.z - self.last_pos.z;
        self.last_pos = pos;

        const dist = @sqrt(dx * dx + dz * dz);
        self.speed = dist / dt;

        // Only track direction if moving fast enough (> 2 blocks/sec)
        if (self.speed < 2.0) {
            self.has_velocity = false;
            return false;
        }

        const old_dx = self.dir_x;
        const old_dz = self.dir_z;

        self.dir_x = dx / dist;
        self.dir_z = dz / dist;
        self.has_velocity = true;

        // Check if direction changed significantly (> 45 degrees)
        const dot = old_dx * self.dir_x + old_dz * self.dir_z;
        return dot < 0.707; // cos(45°)
    }

    /// Calculate priority weight for a chunk based on movement direction.
    /// Returns a multiplier: < 1.0 for chunks ahead, > 1.0 for chunks behind.
    pub fn priorityWeight(self: *const PlayerMovement, chunk_dx: i32, chunk_dz: i32) f32 {
        if (!self.has_velocity) return 1.0;

        const cdx: f32 = @floatFromInt(chunk_dx);
        const cdz: f32 = @floatFromInt(chunk_dz);
        const dist = @sqrt(cdx * cdx + cdz * cdz);
        if (dist < 0.001) return 0.5; // Player's chunk gets high priority

        // Dot product with movement direction: 1.0 = ahead, -1.0 = behind
        const dot = (cdx * self.dir_x + cdz * self.dir_z) / dist;

        // Map [-1, 1] to [0.5, 1.5] - chunks ahead get 0.5x distance weight
        return 1.0 - dot * 0.5;
    }
};

pub const WorldStreamer = struct {
    allocator: std.mem.Allocator,
    storage: *ChunkStorage,
    generator: Generator,
    atlas: *const TextureAtlas,

    gen_queue: *JobQueue,
    mesh_queue: *JobQueue,
    gen_pool: *WorkerPool,
    mesh_pool: *WorkerPool,
    upload_queue: RingBuffer(ChunkKey),

    player_movement: PlayerMovement,
    last_pc: struct { x: i32, z: i32 },
    render_distance: i32,

    vertex_allocator: *GlobalVertexAllocator,
    lod_manager: ?*LODManager,
    max_uploads_per_frame: usize,

    paused: bool = false,
    save_manager: ?*SaveManager = null,

    gpu_block_buffer: ?*GpuBlockBuffer,
    gpu_mesher: ?*GpuMesher,

    frame_counter: u64 = 0,
    effective_render_dist: i32 = 0,

    /// When true, forces CPU meshing even if GPU mesher is available.
    /// Set via ZIGCRAFT_FORCE_CPU_MESHING=1 env var at runtime.
    force_cpu_meshing: bool = false,

    const MIN_GEN_WORKERS = 6;
    const MAX_GEN_WORKERS = 10;
    const MIN_MESH_WORKERS = 4;
    const MAX_MESH_WORKERS = 6;

    pub fn init(allocator: std.mem.Allocator, storage: *ChunkStorage, generator: Generator, atlas: *const TextureAtlas, render_distance: i32, vertex_allocator: *GlobalVertexAllocator, max_uploads_per_frame: usize, gpu_block_buffer: ?*GpuBlockBuffer, gpu_mesher: ?*GpuMesher) !*WorldStreamer {
        const streamer = try allocator.create(WorldStreamer);
        const cpu_count = std.Thread.getCpuCount() catch MIN_GEN_WORKERS + MIN_MESH_WORKERS;
        const gen_worker_count = std.math.clamp((cpu_count * 2) / 3, MIN_GEN_WORKERS, MAX_GEN_WORKERS);
        const mesh_worker_count = std.math.clamp(cpu_count / 3, MIN_MESH_WORKERS, MAX_MESH_WORKERS);

        const gen_queue = try allocator.create(JobQueue);
        gen_queue.* = JobQueue.init(allocator);

        const mesh_queue = try allocator.create(JobQueue);
        mesh_queue.* = JobQueue.init(allocator);

        streamer.* = .{
            .allocator = allocator,
            .storage = storage,
            .generator = generator,
            .atlas = atlas,
            .gen_queue = gen_queue,
            .mesh_queue = mesh_queue,
            .gen_pool = undefined,
            .mesh_pool = undefined,
            .upload_queue = try RingBuffer(ChunkKey).init(allocator, 256),
            .player_movement = .{},
            .last_pc = .{ .x = 9999, .z = 9999 },
            .render_distance = render_distance,
            .vertex_allocator = vertex_allocator,
            .lod_manager = null,
            .max_uploads_per_frame = max_uploads_per_frame,
            .gpu_block_buffer = gpu_block_buffer,
            .gpu_mesher = gpu_mesher,
        };

        log.log.info("WorldStreamer workers: gen={} mesh={} (cpu={})", .{ gen_worker_count, mesh_worker_count, cpu_count });

        streamer.gen_pool = try WorkerPool.init(allocator, gen_worker_count, gen_queue, streamer, processGenJob);
        streamer.mesh_pool = try WorkerPool.init(allocator, mesh_worker_count, mesh_queue, streamer, processMeshJob);

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

        self.upload_queue.deinit();
        self.allocator.destroy(self);
    }

    pub fn setPaused(self: *WorldStreamer, paused: bool) void {
        self.paused = paused;
        self.gen_queue.setPaused(paused);
        self.mesh_queue.setPaused(paused);

        if (paused) {
            // Reset chunks that were waiting for generation or meshing
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
        } else {
            // Force chunk rescan on next update
            self.last_pc = .{ .x = 9999, .z = 9999 };
        }
    }

    pub fn setRenderDistance(self: *WorldStreamer, distance: i32) void {
        if (self.render_distance != distance) {
            self.render_distance = distance;
            // Force chunk rescan on next update
            self.last_pc = .{ .x = 9999, .z = 9999 };
        }
    }

    pub fn setLODManager(self: *WorldStreamer, lod_manager: ?*LODManager) void {
        self.lod_manager = lod_manager;
    }

    pub fn setSaveManager(self: *WorldStreamer, sm: ?*SaveManager) void {
        self.save_manager = sm;
    }

    pub fn updateFrame(self: *WorldStreamer, player_pos: Vec3, dt: f32) !void {
        if (self.paused) return;

        self.frame_counter += 1;

        self.updateStreaming(player_pos, dt) catch |err| {
            log.log.warn("updateStreaming error (non-fatal): {}", .{err});
        };
        self.processUploads();
        self.processUnloads(player_pos) catch |err| {
            log.log.warn("processUnloads error (non-fatal): {}", .{err});
        };
        self.checkAutoSave();

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
                    if (data.mesh.solid_allocation == null and data.mesh.cutout_allocation == null and data.mesh.fluid_allocation == null) {
                        renderable_no_alloc += 1;
                    }
                    if (!data.mesh.ready) {
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

            if (self.lod_manager) |lod_mgr| {
                const radii = lod_mgr.config.getRadii();
                const lod0_r = radii[0];
                const pc_x = self.last_pc.x;
                const pc_z = self.last_pc.z;
                const check_dirs = [_][2]i32{ .{ lod0_r, 0 }, .{ -lod0_r, 0 }, .{ 0, lod0_r }, .{ 0, -lod0_r } };
                var renderable_at_boundary: u32 = 0;
                var missing_at_boundary: u32 = 0;
                for (check_dirs) |dir| {
                    const cx = pc_x + dir[0];
                    const cz = pc_z + dir[1];
                    if (self.storage.chunks.get(.{ .x = cx, .z = cz })) |data| {
                        if (data.chunk.state == .renderable or data.mesh.solid_allocation != null) {
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
        _ = self.player_movement.update(player_pos, dt);

        // Check for runtime GPU mesher disable
        if (self.gpu_mesher != null and self.frame_counter % 30 == 0) {
            const env_val = std.posix.getenv("ZIGCRAFT_FORCE_CPU_MESHING");
            const new_force_cpu = if (env_val) |val|
                !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
            else
                false;
            if (new_force_cpu != self.force_cpu_meshing) {
                self.force_cpu_meshing = new_force_cpu;
                if (new_force_cpu) {
                    log.log.warn("FORCE_CPU_MESHING: GPU mesher disabled at runtime, resetting mesh-ready/uploading chunks for CPU re-mesh", .{});
                    // Reset chunks that were queued for GPU meshing so they go through CPU path
                    self.storage.chunks_mutex.lock();
                    var reset_iter = self.storage.iteratorUnsafe();
                    while (reset_iter.next()) |entry| {
                        const chunk = &entry.value_ptr.*.chunk;
                        if (chunk.state == .mesh_ready or chunk.state == .uploading) {
                            chunk.state = .generated;
                        }
                    }
                    self.storage.chunks_mutex.unlock();
                }
            }
        }

        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        const moved = pc.chunk_x != self.last_pc.x or pc.chunk_z != self.last_pc.z;

        if (self.frame_counter % 600 == 0) {
            self.logMissingChunkDiagnostic(pc.chunk_x, pc.chunk_z);
        }

        const render_dist = if (self.lod_manager) |mgr| @min(self.render_distance, mgr.config.getRadii()[0]) else self.render_distance;
        self.effective_render_dist = render_dist;

        if (moved) {
            self.last_pc = .{ .x = pc.chunk_x, .z = pc.chunk_z };

            self.gen_queue.updatePlayerPos(pc.chunk_x, pc.chunk_z) catch {};
            self.mesh_queue.updatePlayerPos(pc.chunk_x, pc.chunk_z) catch {};
        }

        // Keep the generation queue hot while moving or recovering stale jobs.
        // A full scan is cheap relative to chunk generation and avoids leaving
        // boundary chunks idle in `.missing` until the next periodic rescan.
        self.scanForMissingChunks(pc.chunk_x, pc.chunk_z, render_dist) catch |err| {
            log.log.warn("scanForMissingChunks error (non-fatal): {}", .{err});
        };

        self.storage.chunks_mutex.lock();
        var mesh_iter = self.storage.iteratorUnsafe();

        while (mesh_iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const data = entry.value_ptr.*;
            if (data.chunk.state == .generated) {
                const dx = data.chunk.chunk_x - pc.chunk_x;
                const dz = data.chunk.chunk_z - pc.chunk_z;
                if (dx * dx + dz * dz <= render_dist * render_dist) {
                    self.mesh_queue.push(.{
                        .type = .chunk_meshing,
                        .dist_sq = dx * dx + dz * dz,
                        .data = .{
                            .chunk = .{
                                .x = data.chunk.chunk_x,
                                .z = data.chunk.chunk_z,
                                .job_token = data.chunk.job_token,
                            },
                        },
                    }) catch {
                        continue;
                    };
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
                } else if (data.mesh.solid_allocation == null and data.mesh.cutout_allocation == null and data.mesh.fluid_allocation == null and data.chunk.mesh_attempts < 3) {
                    data.chunk.mesh_attempts += 1;
                    log.log.warn("CHUNK_RECOVERY: ({},{}) renderable with no allocations, re-meshing (attempt {})", .{ data.chunk.chunk_x, data.chunk.chunk_z, data.chunk.mesh_attempts });
                    data.chunk.state = .generated;
                }
            } else if (data.chunk.state == .generating and self.frame_counter % 120 == 0) {
                const dx = data.chunk.chunk_x - pc.chunk_x;
                const dz = data.chunk.chunk_z - pc.chunk_z;
                const max_dist = render_dist + CHUNK_UNLOAD_BUFFER;
                if (dx * dx + dz * dz <= max_dist * max_dist) {
                    data.chunk.job_token += 1;
                    data.chunk.state = .missing;
                    log.log.warn("CHUNK_STUCK: ({},{}) in generating state too long, resetting to missing", .{ data.chunk.chunk_x, data.chunk.chunk_z });
                }
            } else if (data.chunk.state == .uploading and self.frame_counter % 60 == 0) {
                const dx = data.chunk.chunk_x - pc.chunk_x;
                const dz = data.chunk.chunk_z - pc.chunk_z;
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
        self.storage.chunks_mutex.unlock();

        if (self.lod_manager) |lod_mgr| {
            const velocity = Vec3.init(
                self.player_movement.dir_x * self.player_movement.speed,
                0,
                self.player_movement.dir_z * self.player_movement.speed,
            );
            lod_mgr.update(player_pos, velocity, ChunkStorage.isChunkRenderable, self.storage) catch |err| {
                log.log.warn("LOD update error (non-fatal): {}", .{err});
            };
        }
    }

    fn scanForMissingChunks(self: *WorldStreamer, pc_x: i32, pc_z: i32, render_dist: i32) !void {
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
                            .data = .{
                                .chunk = .{
                                    .x = cx,
                                    .z = cz,
                                    .job_token = data.chunk.job_token,
                                },
                            },
                        }) catch continue;
                        data.chunk.state = .queued_for_generation;
                    },
                    else => {},
                }
            }
        }
    }

    fn processUploads(self: *WorldStreamer) void {
        var uploads: usize = 0;
        while (!self.upload_queue.isEmpty() and uploads < self.max_uploads_per_frame) {
            const key = self.upload_queue.pop() orelse break;
            if (self.storage.get(key.x, key.z)) |data| {
                if (data.chunk.state != .uploading) {
                    continue;
                }

                if (self.gpu_mesher != null and !self.force_cpu_meshing) {
                    if (self.gpu_block_buffer) |buf| {
                        const slot = if (buf.getSlotForChunk(data.chunk.chunk_x, data.chunk.chunk_z)) |existing|
                            existing
                        else
                            buf.allocate(data.chunk.chunk_x, data.chunk.chunk_z) catch |err| {
                                log.log.err("GpuBlockBuffer allocation failed for chunk ({}, {}): {}", .{ data.chunk.chunk_x, data.chunk.chunk_z, err });
                                data.chunk.state = .generated;
                                continue;
                            };

                        const blocks_slice: []const u8 = @as([]const u8, @ptrCast(&data.chunk.blocks));
                        buf.upload(slot, blocks_slice) catch |upload_err| {
                            log.log.err("GpuBlockBuffer upload failed for chunk ({}, {}): {}", .{ data.chunk.chunk_x, data.chunk.chunk_z, upload_err });
                            buf.free(slot);
                            data.chunk.state = .generated;
                            continue;
                        };

                        if (self.gpu_mesher.?.queueMesh(data.chunk.chunk_x, data.chunk.chunk_z, slot, data.chunk.job_token)) {
                            data.chunk.state = .uploading;
                        } else {
                            data.chunk.state = .mesh_ready;
                        }
                    }
                } else {
                    data.mesh.upload(self.vertex_allocator);

                    if (data.mesh.diag_tile0_count > 0) {
                        log.log.warn("TILE0_MESH: chunk ({},{}) has {}/{} vertices with tile_id=0 (WHITE)", .{
                            data.chunk.chunk_x,         data.chunk.chunk_z,
                            data.mesh.diag_tile0_count, data.mesh.diag_total_verts,
                        });
                    }

                    if (data.mesh.ready) {
                        data.chunk.state = .renderable;
                        data.chunk.dirty = false;
                    } else {
                        log.log.warn("CHUNK_UPLOAD: ({},{}) upload FAILED (ready=false), reverting to mesh_ready | solid={} cutout={} fluid={}", .{
                            key.x,                              key.z,
                            data.mesh.solid_allocation != null, data.mesh.cutout_allocation != null,
                            data.mesh.fluid_allocation != null,
                        });
                        data.chunk.state = .mesh_ready;
                    }
                }
                uploads += 1;
            } else {
                continue;
            }
        }
    }

    fn processUnloads(self: *WorldStreamer, player_pos: Vec3) !void {
        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        const render_dist_unload = if (self.lod_manager) |mgr| @min(self.render_distance, mgr.config.getRadii()[0]) else self.render_distance;
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
            if (self.gpu_block_buffer) |buf| {
                _ = buf.freeByChunk(key.x, key.z);
            }
            _ = self.storage.removeUnlocked(key.x, key.z, self.vertex_allocator);
        }
        self.storage.chunks_mutex.unlock();
    }

    fn processGenJob(ctx: *anyopaque, job: Job) void {
        const self: *WorldStreamer = @ptrCast(@alignCast(ctx));
        const cx = job.data.chunk.x;
        const cz = job.data.chunk.z;

        self.storage.chunks_mutex.lockShared();
        const chunk_data = self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz }) orelse {
            self.storage.chunks_mutex.unlockShared();
            return;
        };

        const dx = cx - self.last_pc.x;
        const dz = cz - self.last_pc.z;
        const max_dist = self.effective_render_dist + CHUNK_UNLOAD_BUFFER;
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

        if ((chunk_data.chunk.state == .queued_for_generation or chunk_data.chunk.state == .generating) and chunk_data.chunk.job_token == job.data.chunk.job_token) {
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
                // Validate: check that the chunk has at least some non-air blocks
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
                }
            }
            self.storage.chunks_mutex.unlock();
            if (chunk_data.chunk.generated) {
                self.markNeighborsForRemesh(cx, cz);
            }
        }
    }

    fn processMeshJob(ctx: *anyopaque, job: Job) void {
        const self: *WorldStreamer = @ptrCast(@alignCast(ctx));
        const cx = job.data.chunk.x;
        const cz = job.data.chunk.z;

        self.storage.chunks_mutex.lockShared();
        const chunk_data = self.storage.chunks.get(ChunkKey{ .x = cx, .z = cz }) orelse {
            self.storage.chunks_mutex.unlockShared();
            return;
        };

        const dx = cx - self.last_pc.x;
        const dz = cz - self.last_pc.z;
        const max_dist = self.effective_render_dist + CHUNK_UNLOAD_BUFFER;
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

        if ((chunk_data.chunk.state == .queued_for_mesh or chunk_data.chunk.state == .meshing) and chunk_data.chunk.job_token == job.data.chunk.job_token) {
            if (self.gpu_mesher != null and !self.force_cpu_meshing) {
                self.storage.chunks_mutex.lock();
                chunk_data.chunk.state = .mesh_ready;
                self.storage.chunks_mutex.unlock();
                return;
            }
            chunk_data.mesh.buildWithNeighbors(&chunk_data.chunk, neighbors, self.atlas) catch |err| {
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
        }
    }

    fn markNeighborsForRemesh(self: *WorldStreamer, cx: i32, cz: i32) void {
        const offsets = [_][2]i32{ .{ 0, 1 }, .{ 0, -1 }, .{ 1, 0 }, .{ -1, 0 } };

        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        for (offsets) |off| {
            if (self.storage.chunks.get(ChunkKey{ .x = cx + off[0], .z = cz + off[1] })) |data| {
                switch (data.chunk.state) {
                    .renderable => {
                        // Neighbor was meshed before this chunk existed, so it may still
                        // expose boundary faces that should now be culled.
                        data.chunk.state = .generated;
                    },
                    .mesh_ready, .uploading, .meshing => {
                        // Let the in-flight mesh finish, then immediately remesh once it
                        // returns to the renderable state.
                        data.chunk.dirty = true;
                    },
                    else => {},
                }
            }
        }
    }

    fn logMissingChunkDiagnostic(self: *WorldStreamer, pc_x: i32, pc_z: i32) void {
        const render_dist = if (self.lod_manager) |mgr| @min(self.render_distance, mgr.config.getRadii()[0]) else self.render_distance;

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

        log.log.info("CHUNK_DIAG [frame={}] pc=({},{}) rd={} | missing={} qgen={} gen={} gentd={} qmesh={} mesh={} mready={} upload={} render={} unload={} | not_in_storage={}", .{
            self.frame_counter, pc_x,      pc_z,                   render_dist,
            counts[0],          counts[1], counts[2],              counts[3],
            counts[4],          counts[5], counts[6],              counts[7],
            counts[8],          counts[9], missing_keys.items.len,
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

        if (counts[3] > 0 or counts[6] > 0 or counts[7] > 0) {
            log.log.warn("  stalled chunks: generated={} mesh_ready={} uploading={} (should be 0 at steady state)", .{
                counts[3], counts[6], counts[7],
            });
        }
    }

    fn checkAutoSave(self: *WorldStreamer) void {
        const sm = self.save_manager orelse return;
        if (!sm.shouldAutoSave()) return;

        var dirty_keys = std.ArrayListUnmanaged(ChunkKey).empty;
        defer dirty_keys.deinit(self.allocator);

        self.storage.chunks_mutex.lockShared();
        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const chunk = &entry.value_ptr.*.chunk;
            if (chunk.modified and chunk.generated) {
                chunk.pin();
                sm.enqueueSave(chunk);
                dirty_keys.append(self.allocator, entry.key_ptr.*) catch {};
            }
        }
        self.storage.chunks_mutex.unlockShared();

        sm.markAutoSaved();

        const failed = sm.flush();

        self.storage.chunks_mutex.lockShared();
        for (dirty_keys.items) |key| {
            if (self.storage.chunks.get(key)) |data| {
                const should_remark = for (failed) |f| {
                    if (f.x == key.x and f.z == key.z) break true;
                } else false;
                if (!should_remark) data.chunk.modified = false;
                data.chunk.unpin();
            }
        }
        self.storage.chunks_mutex.unlockShared();
    }

    pub fn getStats(self: *WorldStreamer) struct { gen_queue: usize, mesh_queue: usize, upload_queue: usize } {
        self.gen_queue.mutex.lock();
        const gen_count = self.gen_queue.jobs.count();
        self.gen_queue.mutex.unlock();

        self.mesh_queue.mutex.lock();
        const mesh_count = self.mesh_queue.jobs.count();
        self.mesh_queue.mutex.unlock();

        return .{
            .gen_queue = gen_count,
            .mesh_queue = mesh_count,
            .upload_queue = self.upload_queue.count(),
        };
    }

    test "stale generation job resets chunk to missing" {
        const testing = std.testing;

        var storage = ChunkStorage.init(testing.allocator);
        defer storage.deinitWithoutRHI();

        const data = try storage.getOrCreate(64, 0);
        data.chunk.state = .generating;
        data.chunk.job_token = 7;

        var streamer: WorldStreamer = undefined;
        streamer.storage = &storage;
        streamer.last_pc = .{ .x = 0, .z = 0 };
        streamer.effective_render_dist = 8;

        processGenJob(&streamer, .{
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

        var streamer: WorldStreamer = undefined;
        streamer.storage = &storage;
        streamer.last_pc = .{ .x = 0, .z = 0 };
        streamer.effective_render_dist = 8;

        processMeshJob(&streamer, .{
            .type = .chunk_meshing,
            .dist_sq = 0,
            .data = .{ .chunk = .{ .x = 64, .z = 0, .job_token = 11 } },
        });

        try testing.expectEqual(Chunk.State.generated, data.chunk.state);
    }
};
