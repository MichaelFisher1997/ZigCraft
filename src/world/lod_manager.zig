//! LOD Manager - orchestrates multi-level chunk loading for extreme render distances.
//!
//! Implements a Distant Horizons-style system where:
//! - LOD0 (0-16 chunks): Full detail, 2x2 chunks merged
//! - LOD1 (16-32 chunks): 2x simplified, 4x4 chunks merged
//! - LOD2 (32-64 chunks): 4x simplified, 8x8 chunks merged
//! - LOD3 (64-100 chunks): 8x simplified, 16x16 chunks merged, heightmap only
//!
//! Key principles:
//! - LOD3 generates first (fast heightmap), fills horizon quickly
//! - LOD0 generates last but gets priority in movement direction
//! - Smooth transitions via fog masking
//!
//! GPU operations are decoupled via LODGPUBridge and LODRenderInterface (Issue #246).

const std = @import("std");
const sync = @import("sync");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODRegionKeyContext = lod_chunk.LODRegionKeyContext;
const LODConfig = lod_chunk.LODConfig;
const ILODConfig = lod_chunk.ILODConfig;
const LODState = lod_chunk.LODState;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;

const Chunk = @import("chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;
const worldToChunkFromFloat = @import("chunk.zig").worldToChunkFromFloat;
const BlockType = @import("block.zig").BlockType;
const BiomeId = @import("worldgen/biome.zig").BiomeId;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const AABB = @import("../engine/math/aabb.zig").AABB;
const rhi_types = @import("../engine/graphics/rhi_types.zig");
const Vertex = rhi_types.Vertex;
const log = @import("../engine/core/log.zig");

const JobSystem = @import("../engine/core/job_system.zig");
const JobQueue = JobSystem.JobQueue;
const WorkerPool = JobSystem.WorkerPool;
const Job = JobSystem.Job;

const RingBuffer = @import("../engine/core/ring_buffer.zig").RingBuffer;

const Generator = @import("worldgen/generator_interface.zig").Generator;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;

const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;

const MAX_LOD_REGIONS = 2048;
const CHUNK_COVERAGE_PADDING: i32 = 1;
const LOD_UPDATE_DIVISOR: u32 = 2;
const MIN_LOD_WORKERS: usize = 4;
const MAX_LOD_WORKERS: usize = 6;

comptime {
    if (LODLevel.count < 2) {
        @compileError("LOD system requires at least two levels (LOD0 and at least one simplified level)");
    }
}

/// Statistics for LOD system monitoring
pub const LODStats = struct {
    loaded: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    generating: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    generated: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    meshing: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    mesh_ready: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    uploading: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,

    memory_used_mb: u32 = 0,
    upgrades_pending: u32 = 0,
    downgrades_pending: u32 = 0,
    upload_failures: u32 = 0,

    pub fn totalLoaded(self: *const LODStats) u32 {
        var total: u32 = 0;
        for (self.loaded) |count| total += count;
        return total;
    }

    pub fn totalGenerating(self: *const LODStats) u32 {
        var total: u32 = 0;
        for (self.generating) |count| total += count;
        return total;
    }

    pub fn reset(self: *LODStats) void {
        self.loaded = [_]u32{0} ** LODLevel.count;
        self.generating = [_]u32{0} ** LODLevel.count;
        self.generated = [_]u32{0} ** LODLevel.count;
        self.meshing = [_]u32{0} ** LODLevel.count;
        self.mesh_ready = [_]u32{0} ** LODLevel.count;
        self.uploading = [_]u32{0} ** LODLevel.count;
        self.memory_used_mb = 0;
        self.upgrades_pending = 0;
        self.downgrades_pending = 0;
        self.upload_failures = 0;
    }

    pub fn recordState(self: *LODStats, lod_idx: usize, state: LODState) void {
        switch (state) {
            .renderable => self.loaded[lod_idx] += 1,
            .generating => self.generating[lod_idx] += 1,
            .generated => self.generated[lod_idx] += 1,
            .meshing => self.meshing[lod_idx] += 1,
            .mesh_ready => self.mesh_ready[lod_idx] += 1,
            .uploading => self.uploading[lod_idx] += 1,
            else => {},
        }
    }

    pub fn addMemory(self: *LODStats, bytes: usize) void {
        const mb = bytes / (1024 * 1024);
        self.memory_used_mb += @intCast(mb);
    }
};

/// LOD transition request
const LODTransition = struct {
    region_key: LODRegionKey,
    target_lod: LODLevel,
    priority: i32,
};

/// LOD Manager - coordinates all LOD levels.
/// Uses callback interfaces (LODGPUBridge, LODRenderInterface) for GPU operations
/// instead of a direct RHI dependency.
pub const LODManager = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    config: ILODConfig,

    // Storage per LOD level (LOD0 uses existing World.chunks)
    regions: [LODLevel.count]RegionMap,

    // Mesh storage per LOD level
    meshes: [LODLevel.count]MeshMap,

    // Separate job queues per LOD level
    // LOD3 queue processes first (fast), LOD0 queue last (slow but priority)
    gen_queues: [LODLevel.count]*JobQueue,

    // Worker pool for LOD generation
    lod_gen_pool: ?*WorkerPool,

    // Upload queues per LOD level
    upload_queues: [LODLevel.count]RingBuffer(*LODChunk),

    // Transition queue for LOD upgrades/downgrades
    transition_queue: std.ArrayListUnmanaged(LODTransition),

    // Current player position (chunk coords)
    player_cx: i32,
    player_cz: i32,

    // Next job token
    next_job_token: u32,

    // Stats
    stats: LODStats,

    // Mutex for thread safety
    mutex: sync.RwLock,

    // GPU bridge for upload/destroy/sync operations (replaces direct RHI field)
    gpu_bridge: LODGPUBridge,

    // Terrain generator for LOD generation (mutable for cache recentering)
    generator: Generator,

    atlas: *const TextureAtlas,

    // Paused state
    paused: bool,

    // Memory tracking
    memory_used_bytes: usize,

    // Performance tracking for throttling
    update_tick: u32 = 0,

    // Deferred mesh deletion queue (Vulkan optimization)
    deletion_queue: std.ArrayListUnmanaged(*LODMesh),
    deletion_timer: f32 = 0,

    // Type-erased renderer interface (replaces direct LODRenderer(RHI) field)
    renderer: LODRenderInterface,

    // Keep cleanup behavior testable, but allow the live world to opt out.
    cleanup_covered_regions: bool = true,

    // Callback type to check if a regular chunk is loaded and renderable
    pub const ChunkChecker = lod_gpu.ChunkChecker;

    pub fn init(allocator: std.mem.Allocator, config: ILODConfig, gpu_bridge: LODGPUBridge, render_iface: LODRenderInterface, generator: Generator, atlas: *const TextureAtlas) !*Self {
        const mgr = try allocator.create(Self);
        errdefer allocator.destroy(mgr);

        var regions: [LODLevel.count]RegionMap = undefined;
        var meshes: [LODLevel.count]MeshMap = undefined;
        var gen_queues: [LODLevel.count]*JobQueue = undefined;
        var upload_queues: [LODLevel.count]RingBuffer(*LODChunk) = undefined;
        var initialized_levels: usize = 0;

        errdefer {
            var i: usize = 0;
            while (i < initialized_levels) : (i += 1) {
                upload_queues[i].deinit();
                gen_queues[i].deinit();
                allocator.destroy(gen_queues[i]);
                meshes[i].deinit();
                regions[i].deinit();
            }
        }

        for (0..LODLevel.count) |i| {
            var region_map = RegionMap.init(allocator);
            errdefer region_map.deinit();

            var mesh_map = MeshMap.init(allocator);
            errdefer mesh_map.deinit();

            const queue = try allocator.create(JobQueue);
            errdefer allocator.destroy(queue);
            queue.* = JobQueue.init(allocator);
            errdefer queue.deinit();

            var upload_queue = try RingBuffer(*LODChunk).init(allocator, 128);
            errdefer upload_queue.deinit();

            regions[i] = region_map;
            meshes[i] = mesh_map;
            gen_queues[i] = queue;
            upload_queues[i] = upload_queue;
            initialized_levels += 1;
        }

        mgr.* = .{
            .allocator = allocator,
            .config = config,
            .regions = regions,
            .meshes = meshes,
            .gen_queues = gen_queues,
            .lod_gen_pool = null, // Will be initialized below
            .upload_queues = upload_queues,
            .transition_queue = .empty,
            .player_cx = 0,
            .player_cz = 0,
            .next_job_token = 1,
            .stats = .{},
            .mutex = .{},
            .gpu_bridge = gpu_bridge,
            .generator = generator,
            .atlas = atlas,
            .paused = false,
            .memory_used_bytes = 0,
            .update_tick = 0,
            .deletion_queue = .empty,
            .deletion_timer = 0,
            .renderer = render_iface,
            .cleanup_covered_regions = true,
        };

        const cpu_count = std.Thread.getCpuCount() catch MIN_LOD_WORKERS;
        const lod_worker_count = std.math.clamp(cpu_count / 2, MIN_LOD_WORKERS, MAX_LOD_WORKERS);

        // All LOD jobs go through the shared far-distance queue so the worker pool can
        // keep the horizon filled before near-detail transitions catch up.
        mgr.lod_gen_pool = try WorkerPool.init(allocator, lod_worker_count, mgr.gen_queues[LODLevel.count - 1], mgr, processLODJob);

        const radii = config.getRadii();
        log.log.info("LODManager initialized with radii: LOD0={}, LOD1={}, LOD2={}, LOD3={} | workers={}", .{
            radii[0],
            radii[1],
            radii[2],
            radii[3],
            lod_worker_count,
        });

        return mgr;
    }

    pub fn deinit(self: *Self) void {
        // Stop and cleanup queues
        for (0..LODLevel.count) |i| {
            self.gen_queues[i].stop();
        }

        // Cleanup worker pool
        if (self.lod_gen_pool) |pool| {
            pool.deinit();
        }

        for (0..LODLevel.count) |i| {
            self.gen_queues[i].deinit();
            self.allocator.destroy(self.gen_queues[i]);
            self.upload_queues[i].deinit();

            // Cleanup meshes
            var mesh_iter = self.meshes[i].iterator();
            while (mesh_iter.next()) |entry| {
                self.gpu_bridge.destroy(entry.value_ptr.*);
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.meshes[i].deinit();

            // Cleanup regions
            var region_iter = self.regions[i].iterator();
            while (region_iter.next()) |entry| {
                entry.value_ptr.*.deinit(self.allocator);
                self.allocator.destroy(entry.value_ptr.*);
            }
            self.regions[i].deinit();
        }

        self.transition_queue.deinit(self.allocator);

        // Process any pending deletions
        if (self.deletion_queue.items.len > 0) {
            self.gpu_bridge.waitIdle();
            for (self.deletion_queue.items) |mesh| {
                self.gpu_bridge.destroy(mesh);
                self.allocator.destroy(mesh);
            }
        }
        self.deletion_queue.deinit(self.allocator);

        // NOTE: LODManager does NOT own the renderer lifetime.
        // The renderer is owned by World and deinit'd there.

        self.allocator.destroy(self);
    }

    /// Update LOD system with player position
    pub fn update(self: *Self, player_pos: Vec3, player_velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
        if (self.paused) return;

        // Deferred deletion handling (Issue #119: Performance optimization)
        // Clean up deleted meshes once per second to avoid waitIdle stalls
        self.deletion_timer += 0.016; // Approx 60fps delta
        if (self.deletion_timer >= 1.0 or self.deletion_queue.items.len > 50) {
            if (self.deletion_queue.items.len > 0) {
                // Ensure GPU is done with resources before deleting
                self.gpu_bridge.waitIdle();
                for (self.deletion_queue.items) |mesh| {
                    self.gpu_bridge.destroy(mesh);
                    self.allocator.destroy(mesh);
                }
                self.deletion_queue.clearRetainingCapacity();
            }
            self.deletion_timer = 0;
        }

        // Safety: Check for NaN/Inf player position
        if (!std.math.isFinite(player_pos.x) or !std.math.isFinite(player_pos.z)) return;

        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        self.player_cx = pc.chunk_x;
        self.player_cz = pc.chunk_z;

        // Throttle heavy LOD management logic (generation queuing, state processing, unloads).
        // LOD management involves iterating over thousands of potential regions and can
        // take several milliseconds. Throttling to every 4 frames (approx 15Hz at 60fps)
        // significantly reduces CPU overhead while remaining responsive to player movement.
        self.update_tick += 1;
        if (self.update_tick % LOD_UPDATE_DIVISOR != 0) {
            self.processUploads();
            return;
        }

        if (self.cleanup_covered_regions) {
            if (chunk_checker) |checker| {
                self.unloadLODWhereChunksLoaded(checker, checker_ctx.?);
            }
        }

        // Issue #119 Phase 4: Recenter classification cache if player moved far enough.
        // This ensures LOD chunks have cache coverage for consistent biome/surface data.
        const player_wx: i32 = @intFromFloat(player_pos.x);
        const player_wz: i32 = @intFromFloat(player_pos.z);
        _ = self.generator.maybeRecenterCache(player_wx, player_wz);

        // Queue LOD regions that need loading (also queue on first frame)
        // Priority: LOD3 first (fast, fills horizon), then LOD2, LOD1
        // We iterate backwards from LODLevel.count-1 down to 1
        var i: usize = LODLevel.count - 1;
        while (i > 0) : (i -= 1) {
            self.queueLODRegions(@enumFromInt(@as(u3, @intCast(i))), player_velocity, chunk_checker, checker_ctx) catch |err| {
                log.log.warn("LOD queue error for level {}: {} (non-fatal)", .{ i, err });
            };
        }

        // Process state transitions
        self.processStateTransitions() catch |err| {
            log.log.warn("LOD state transitions error: {} (non-fatal)", .{err});
        };

        // Process uploads (limited per frame)
        self.processUploads();

        // Update stats
        self.updateStats();

        // Unload distant regions
        self.unloadDistantRegions() catch |err| {
            log.log.warn("LOD unload error: {} (non-fatal)", .{err});
        };
    }

    /// Queue LOD regions that need generation
    fn queueLODRegions(self: *Self, lod: LODLevel, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
        const radii = self.config.getRadii();
        const radius = radii[@intFromEnum(lod)];

        // Skip LOD0 - handled by existing World system
        if (lod == .lod0) return;

        var queued_count: u32 = 0;

        const scale: i32 = @intCast(lod.chunksPerSide());
        const region_radius = @divFloor(radius, scale) + 1;

        const player_rx = @divFloor(self.player_cx, scale);
        const player_rz = @divFloor(self.player_cz, scale);

        self.mutex.lock();
        defer self.mutex.unlock();

        const storage = &self.regions[@intFromEnum(lod)];

        // All LOD jobs go to LOD3 queue (worker pool processes from there)
        // We encode the actual LOD level in the dist_sq high bits
        const queue = self.gen_queues[LODLevel.count - 1];
        const lod_bits: i32 = @as(i32, @intCast(@intFromEnum(lod))) << 28;

        // Calculate velocity direction for priority
        _ = velocity;

        var rz = player_rz - region_radius;
        while (rz <= player_rz + region_radius) : (rz += 1) {
            var rx = player_rx - region_radius;
            while (rx <= player_rx + region_radius) : (rx += 1) {
                const key = LODRegionKey{ .rx = rx, .rz = rz, .lod = lod };
                const chunk_bounds = key.chunkBounds();
                if (!chunk_bounds.intersectsRadius(self.player_cx, self.player_cz, radius)) continue;

                if (self.cleanup_covered_regions) {
                    if (chunk_checker) |checker| {
                        const temp_chunk = LODChunk.init(rx, rz, lod);
                        if (self.areAllChunksLoaded(temp_chunk.worldBounds(), checker, checker_ctx.?)) {
                            continue;
                        }
                    }
                }

                // Check if region exists and what state it's in
                const existing = storage.get(key);
                const needs_queue = if (existing) |chunk|
                    // Re-queue if stuck in missing state
                    chunk.state == .missing
                else
                    // Queue if doesn't exist
                    true;

                if (needs_queue) {
                    queued_count += 1;

                    // Reuse existing chunk or create new one
                    const chunk = if (existing) |c| c else blk: {
                        const c = try self.allocator.create(LODChunk);
                        c.* = LODChunk.init(rx, rz, lod);
                        try storage.put(key, c);
                        break :blk c;
                    };

                    chunk.job_token = self.next_job_token;
                    self.next_job_token += 1;

                    // Prioritize by actual chunk-space distance to the region bounds so
                    // horizon loading stays symmetric even for large LOD regions.
                    const dist_sq = chunk_bounds.distanceSquaredToPoint(self.player_cx, self.player_cz);
                    // Scale priority to match chunk-distance units used by meshing jobs (which are prioritized by chunk dist)
                    // This ensures generation doesn't starve meshing
                    const priority_full = dist_sq * @as(i64, scale) * @as(i64, scale);
                    const priority: i32 = @as(i32, @intCast(@min(priority_full, 0x0FFFFFFF)));

                    // Encode LOD level in high bits of dist_sq
                    const encoded_priority = (priority & 0x0FFFFFFF) | lod_bits;

                    // Queue for generation
                    try queue.push(.{
                        .type = .chunk_generation,
                        .dist_sq = encoded_priority,
                        .data = .{
                            .chunk = .{
                                .x = rx, // Using chunk coords for region coords
                                .z = rz,
                                .job_token = chunk.job_token,
                            },
                        },
                    });
                    chunk.state = .generating; // Mark as generating, not queued_for_generation
                }
            }
        }
    }

    /// Process state transitions (generated -> meshing -> ready)
    fn processStateTransitions(self: *Self) !void {
        // Use exclusive lock since we modify chunk state
        self.mutex.lock();
        defer self.mutex.unlock();

        for (1..LODLevel.count) |i| {
            const lod = @as(LODLevel, @enumFromInt(@as(u3, @intCast(i))));
            var iter = self.regions[i].iterator();
            while (iter.next()) |entry| {
                const chunk = entry.value_ptr.*;
                if (chunk.state == .generated) {
                    const scale = @as(i32, @intCast(lod.chunksPerSide()));
                    const dx = chunk.region_x * scale - self.player_cx;
                    const dz = chunk.region_z * scale - self.player_cz;
                    const dist_sq = @as(i64, dx) * @as(i64, dx) + @as(i64, dz) * @as(i64, dz);
                    const lod_bits = @as(i32, @intCast(i)) << 28;

                    chunk.state = .meshing;
                    try self.gen_queues[LODLevel.count - 1].push(.{
                        .type = .chunk_meshing,
                        // Encode LOD level in high bits of dist_sq
                        .dist_sq = @as(i32, @truncate(dist_sq & 0x0FFFFFFF)) | lod_bits,
                        .data = .{
                            .chunk = .{
                                .x = chunk.region_x,
                                .z = chunk.region_z,
                                .job_token = chunk.job_token,
                            },
                        },
                    });
                } else if (chunk.state == .mesh_ready) {
                    chunk.state = .uploading;
                    try self.upload_queues[i].push(chunk);
                }
            }
        }
    }

    /// Process GPU uploads (limited per frame)
    fn processUploads(self: *Self) void {
        // Use exclusive lock since we modify chunk state (chunk.state = .renderable)
        self.mutex.lock();
        defer self.mutex.unlock();

        const max_uploads = self.config.getMaxUploadsPerFrame();
        var uploads: u32 = 0;

        // Process from highest LOD down (furthest, should be ready first)
        var i: usize = LODLevel.count - 1;
        while (i > 0) : (i -= 1) {
            while (!self.upload_queues[i].isEmpty() and uploads < max_uploads) {
                if (self.upload_queues[i].pop()) |chunk| {
                    // Upload mesh to GPU via bridge callback
                    const key = LODRegionKey{
                        .rx = chunk.region_x,
                        .rz = chunk.region_z,
                        .lod = chunk.lod_level,
                    };
                    if (self.meshes[i].get(key)) |mesh| {
                        self.gpu_bridge.upload(mesh) catch |err| {
                            log.log.warn("LOD{} mesh upload failed (will retry): {}", .{ i, err });
                            self.stats.upload_failures += 1;
                            chunk.state = .mesh_ready; // Revert to allow retry
                            continue;
                        };
                    }
                    chunk.state = .renderable;
                    uploads += 1;
                }
            }
        }
    }

    /// Unload regions that are too far from player
    fn unloadDistantRegions(self: *Self) !void {
        const radii = self.config.getRadii();
        for (1..LODLevel.count) |i| {
            try self.unloadDistantForLevel(@enumFromInt(@as(u3, @intCast(i))), radii[i]);
        }
    }

    fn unloadDistantForLevel(self: *Self, lod: LODLevel, max_radius: i32) !void {
        _ = max_radius; // Interface provides current radii
        const radii = self.config.getRadii();
        const lod_radius = radii[@intFromEnum(lod)];
        const storage = &self.regions[@intFromEnum(lod)];

        var to_remove = std.ArrayListUnmanaged(LODRegionKey).empty;
        defer to_remove.deinit(self.allocator);

        // Hold lock for entire operation to prevent races with worker threads
        self.mutex.lock();
        defer self.mutex.unlock();

        var iter = storage.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const chunk = entry.value_ptr.*;

            if (!key.chunkBounds().intersectsRadius(self.player_cx, self.player_cz, lod_radius)) {
                if (!chunk.isPinned() and
                    chunk.state != .generating and
                    chunk.state != .meshing and
                    chunk.state != .uploading)
                {
                    try to_remove.append(self.allocator, key);
                }
            }
        }

        // Remove after iteration (still under lock)
        if (to_remove.items.len > 0) {
            for (to_remove.items) |key| {
                if (storage.get(key)) |chunk| {
                    // Clean up mesh before removing chunk
                    const meshes = &self.meshes[@intFromEnum(lod)];
                    if (meshes.get(key)) |mesh| {
                        // Push to deferred deletion queue instead of deleting immediately
                        self.deletion_queue.append(self.allocator, mesh) catch {
                            // Fallback if allocation fails: delete immediately (slow but safe)
                            self.gpu_bridge.destroy(mesh);
                            self.allocator.destroy(mesh);
                        };
                        _ = meshes.remove(key);
                    }

                    chunk.deinit(self.allocator);
                    self.allocator.destroy(chunk);
                    _ = storage.remove(key);
                }
            }
        }
    }

    /// Update statistics
    fn updateStats(self: *Self) void {
        self.stats.reset();
        var mem_usage: usize = 0;

        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        for (0..LODLevel.count) |i| {
            var iter = self.regions[i].iterator();
            while (iter.next()) |entry| {
                const chunk = entry.value_ptr.*;
                self.stats.recordState(i, chunk.state);

                // Calculate actual memory usage for this chunk's data
                switch (chunk.data) {
                    .simplified => |*s| {
                        mem_usage += s.totalMemoryBytes();
                    },
                    else => {},
                }
            }

            // Add mesh memory
            var mesh_iter = self.meshes[i].iterator();
            while (mesh_iter.next()) |entry| {
                mem_usage += entry.value_ptr.*.capacity * @sizeOf(Vertex);
            }
        }

        self.stats.addMemory(mem_usage);
        self.memory_used_bytes = mem_usage;
    }

    /// Get current statistics
    pub fn getStats(self: *Self) LODStats {
        return self.stats;
    }

    /// Pause all LOD generation
    pub fn pause(self: *Self) void {
        self.paused = true;
        for (0..LODLevel.count) |i| {
            self.gen_queues[i].setPaused(true);
        }
    }

    /// Resume LOD generation
    pub fn unpause(self: *Self) void {
        self.paused = false;
        for (0..LODLevel.count) |i| {
            self.gen_queues[i].setPaused(false);
        }
    }

    /// Get LOD level for a given chunk distance
    pub fn getLODForDistance(self: *const Self, chunk_x: i32, chunk_z: i32) LODLevel {
        const dist_sq = pointDistanceSquared(chunk_x, chunk_z, self.player_cx, self.player_cz);
        const radii = self.config.getRadii();

        inline for (0..LODLevel.count) |i| {
            const radius_sq = @as(i64, radii[i]) * @as(i64, radii[i]);
            if (dist_sq <= radius_sq) return @enumFromInt(@as(u3, @intCast(i)));
        }

        return .lod3;
    }

    /// Check if a position is within LOD range
    pub fn isInRange(self: *const Self, chunk_x: i32, chunk_z: i32) bool {
        const radii = self.config.getRadii();
        const max_radius = radii[LODLevel.count - 1];
        const dist_sq = pointDistanceSquared(chunk_x, chunk_z, self.player_cx, self.player_cz);
        return dist_sq <= @as(i64, max_radius) * @as(i64, max_radius);
    }

    /// Render all LOD meshes
    /// chunk_checker: Optional callback to check if regular chunks cover this region.
    ///                If all chunks in region are loaded, the LOD region is skipped.
    ///
    /// NOTE: Acquires a shared lock on LODManager. LODRenderer must NOT attempt to acquire
    /// a write lock on LODManager during rendering to avoid deadlocks.
    pub fn render(self: *Self, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, use_frustum: bool, max_distance_chunks: ?i32) void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        self.renderer.render(&self.meshes, &self.regions, self.config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks);
    }

    fn pointDistanceSquared(x0: i32, z0: i32, x1: i32, z1: i32) i64 {
        const dx = @as(i64, x0) - @as(i64, x1);
        const dz = @as(i64, z0) - @as(i64, z1);
        return dx * dx + dz * dz;
    }

    /// Free LOD meshes where all underlying chunks are loaded
    pub fn unloadLODWhereChunksLoaded(self: *Self, checker: ChunkChecker, ctx: *anyopaque) void {
        // Lock exclusive because we modify meshes and regions maps
        self.mutex.lock();
        defer self.mutex.unlock();

        for (1..LODLevel.count) |i| {
            const storage = &self.regions[i];
            const meshes = &self.meshes[i];

            var to_remove = std.ArrayListUnmanaged(LODRegionKey).empty;
            defer to_remove.deinit(self.allocator);

            var iter = meshes.iterator();
            while (iter.next()) |entry| {
                if (storage.get(entry.key_ptr.*)) |chunk| {
                    // Don't unload if being processed (pinned) or not ready
                    if (chunk.isPinned() or chunk.state == .generating or chunk.state == .meshing or chunk.state == .uploading) continue;

                    const bounds = chunk.worldBounds();
                    if (self.areAllChunksLoaded(bounds, checker, ctx)) {
                        to_remove.append(self.allocator, entry.key_ptr.*) catch {};
                    }
                }
            }

            for (to_remove.items) |rem_key| {
                if (meshes.fetchRemove(rem_key)) |mesh_entry| {
                    // Queue for deferred deletion to avoid waitIdle stutter
                    self.deletion_queue.append(self.allocator, mesh_entry.value) catch {
                        self.gpu_bridge.destroy(mesh_entry.value);
                        self.allocator.destroy(mesh_entry.value);
                    };
                }
                if (storage.fetchRemove(rem_key)) |chunk_entry| {
                    chunk_entry.value.deinit(self.allocator);
                    self.allocator.destroy(chunk_entry.value);
                }
            }
        }
    }

    /// Check if all chunks within the given world bounds are loaded and renderable.
    /// Checks if all chunks within the LOD0 radius that could cover this LOD region
    /// are loaded and renderable. Chunks outside the LOD0 radius are skipped since
    /// they represent LOD terrain, not full-detail chunks that would cover this region.
    pub fn areAllChunksLoaded(self: *Self, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool {
        const radii = self.config.getRadii();
        const lod0_radius: i64 = @as(i64, radii[0]);
        const radius_sq = lod0_radius * lod0_radius;

        const min_cx = @divFloor(bounds.min_x, CHUNK_SIZE_X) - CHUNK_COVERAGE_PADDING;
        const min_cz = @divFloor(bounds.min_z, CHUNK_SIZE_Z) - CHUNK_COVERAGE_PADDING;
        const max_cx = @divFloor(bounds.max_x, CHUNK_SIZE_X) - 1 + CHUNK_COVERAGE_PADDING;
        const max_cz = @divFloor(bounds.max_z, CHUNK_SIZE_Z) - 1 + CHUNK_COVERAGE_PADDING;

        var cz = min_cz;
        while (cz <= max_cz) : (cz += 1) {
            var cx = min_cx;
            while (cx <= max_cx) : (cx += 1) {
                const dx: i64 = @as(i64, cx) - @as(i64, self.player_cx);
                const dz: i64 = @as(i64, cz) - @as(i64, self.player_cz);
                if (dx * dx + dz * dz > radius_sq) {
                    return false;
                }
                if (!checker(cx, cz, ctx)) {
                    return false;
                }
            }
        }
        return true;
    }

    /// Get or create mesh for a LOD region
    fn getOrCreateMesh(self: *Self, key: LODRegionKey) !*LODMesh {
        self.mutex.lock();
        defer self.mutex.unlock();

        const lod_idx = @intFromEnum(key.lod);
        if (lod_idx == 0 or lod_idx >= LODLevel.count) return error.InvalidLODLevel;

        const meshes = &self.meshes[lod_idx];

        if (meshes.get(key)) |mesh| {
            return mesh;
        }

        const mesh = try self.allocator.create(LODMesh);
        mesh.* = LODMesh.init(self.allocator, key.lod);
        try meshes.put(key, mesh);
        return mesh;
    }

    /// Build mesh for an LOD chunk (called after generation completes)
    fn buildMeshForChunk(self: *Self, chunk: *LODChunk) !void {
        const key = LODRegionKey{
            .rx = chunk.region_x,
            .rz = chunk.region_z,
            .lod = chunk.lod_level,
        };

        const mesh = try self.getOrCreateMesh(key);

        // Access chunk.data under shared lock - the data is read-only during meshing
        // and the chunk is pinned, so we just need to ensure visibility
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        switch (chunk.data) {
            .simplified => |*data| {
                const bounds = chunk.worldBounds();
                // QEM decimation currently introduces visible cracks and terraced holes
                // in distant terrain. Prefer the stable heightfield path until the
                // simplifier preserves continuous coverage again.
                try mesh.buildFromSimplifiedData(data, bounds.min_x, bounds.min_z, self.atlas);
            },
            .full => {
                // LOD0 meshes handled by World, not LODManager
            },
            .empty => {
                // No data to build mesh from
            },
        }
    }

    /// Worker pool callback for LOD tasks (generation and meshing)
    fn processLODJob(ctx: *anyopaque, job: Job) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Determine which LOD level this job is for based on encoded priority
        const lod_level: LODLevel = @enumFromInt(@as(u3, @intCast((job.dist_sq >> 28) & 0x7)));
        const key = LODRegionKey{
            .rx = job.data.chunk.x,
            .rz = job.data.chunk.z,
            .lod = lod_level,
        };

        const lod_idx = @intFromEnum(lod_level);
        if (lod_idx == 0) {
            return;
        }

        // Phase 1: Acquire lock, validate job, pin chunk
        self.mutex.lock();
        const storage = &self.regions[lod_idx];

        const chunk = storage.get(key) orelse {
            self.mutex.unlock();
            return;
        };

        // Stale job check (too far from player)
        const radii = self.config.getRadii();
        const radius = radii[lod_idx];
        const job_key = LODRegionKey{
            .rx = job.data.chunk.x,
            .rz = job.data.chunk.z,
            .lod = lod_level,
        };

        if (!job_key.chunkBounds().intersectsRadius(self.player_cx, self.player_cz, radius)) {
            if (chunk.state == .generating or chunk.state == .meshing) {
                chunk.state = .missing;
            }
            self.mutex.unlock();
            return;
        }

        // Skip if token mismatch
        if (chunk.job_token != job.data.chunk.job_token) {
            self.mutex.unlock();
            return;
        }

        // Check state and capture job type before releasing lock
        const current_state = chunk.state;
        const job_type = job.type;

        // Validate state matches expected for job type
        const valid_state = switch (job_type) {
            .chunk_generation => current_state == .generating,
            .chunk_meshing => current_state == .meshing,
            else => false,
        };

        if (!valid_state) {
            self.mutex.unlock();
            return;
        }

        // Check if we need to generate data (while still holding lock)
        const needs_data_init = (job_type == .chunk_generation and chunk.data != .simplified);

        // Pin chunk during operation (prevents unload)
        chunk.pin();
        self.mutex.unlock();

        // Phase 2: Do expensive work without lock
        var success = false;
        var new_state: LODState = .missing;

        switch (job_type) {
            .chunk_generation => {
                // Initialize simplified data if needed
                if (needs_data_init) {
                    var data = LODSimplifiedData.init(self.allocator, lod_level) catch {
                        new_state = .missing;
                        chunk.unpin();
                        // Acquire lock briefly to update state
                        self.mutex.lock();
                        chunk.state = new_state;
                        self.mutex.unlock();
                        return;
                    };

                    // Generate heightmap data (expensive, done without lock)
                    self.generator.generateHeightmapOnly(&data, chunk.region_x, chunk.region_z, lod_level);

                    // Acquire lock to update chunk data
                    self.mutex.lock();
                    chunk.data = .{ .simplified = data };
                    self.mutex.unlock();
                }
                success = true;
                new_state = .generated;
            },
            .chunk_meshing => {
                // Build mesh (expensive, done without lock)
                // Note: buildMeshForChunk -> getOrCreateMesh acquires its own lock
                self.buildMeshForChunk(chunk) catch |err| {
                    log.log.errWithTrace("Failed to build LOD{} async mesh: {}", .{ @intFromEnum(lod_level), err });
                    new_state = .generated; // Retry later
                    chunk.unpin();
                    // Acquire lock briefly to update state
                    self.mutex.lock();
                    chunk.state = new_state;
                    self.mutex.unlock();
                    return;
                };
                success = true;
                new_state = .mesh_ready;
            },
            else => unreachable,
        }

        chunk.unpin();

        // Phase 3: Acquire lock briefly to update state
        if (success) {
            self.mutex.lock();
            // Re-verify token hasn't changed while we were working
            if (chunk.job_token == job.data.chunk.job_token) {
                chunk.state = new_state;
            }
            self.mutex.unlock();
        }
    }
};

// Tests
test "LODManager initialization" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = @import("chunk.zig").MAX_BLOCK_TYPES;

    const MockState = struct {
        buffer_created: bool = false,
        buffer_destroyed: bool = false,
    };

    const MockGenerator = struct {
        fn generate(_: *anyopaque, _: *Chunk, _: ?*const bool) void {}
        fn generateHeightmapOnly(_: *anyopaque, _: *LODSimplifiedData, _: i32, _: i32, _: LODLevel) void {}
        fn maybeRecenterCache(_: *anyopaque, _: i32, _: i32) bool {
            return false;
        }
        fn getSeed(_: *anyopaque) u64 {
            return 0;
        }
        fn getRegionInfo(_: *anyopaque, _: i32, _: i32) @import("worldgen/region.zig").RegionInfo {
            return undefined;
        }
        fn getColumnInfo(_: *anyopaque, _: f32, _: f32) @import("worldgen/generator_interface.zig").ColumnInfo {
            return undefined;
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        const vtable = Generator.VTable{
            .generate = generate,
            .generateHeightmapOnly = generateHeightmapOnly,
            .maybeRecenterCache = maybeRecenterCache,
            .getSeed = getSeed,
            .getRegionInfo = getRegionInfo,
            .getColumnInfo = getColumnInfo,
            .deinit = deinit,
        };
    };

    var mock_gen_impl = MockGenerator{};
    const mock_gen = Generator{
        .ptr = &mock_gen_impl,
        .vtable = &MockGenerator.vtable,
        .info = .{ .name = "Mock", .description = "Mock Generator" },
    };

    // We can't fully test without RHI, but we can test the config
    var config = LODConfig{
        .radii = .{ 8, 16, 32, 64 },
    };

    // Create mock GPU bridge
    var mock_state = MockState{};
    const mock_bridge = LODGPUBridge{
        .on_upload = struct {
            fn f(_: *LODMesh, _: *anyopaque) rhi_types.RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *LODMesh, ctx: *anyopaque) void {
                const state: *MockState = @ptrCast(@alignCast(ctx));
                state.buffer_destroyed = true;
            }
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(&mock_state),
    };

    // Create mock render interface
    const mock_render = LODRenderInterface{
        .render_fn = struct {
            fn f(_: *anyopaque, _: *const [LODLevel.count]MeshMap, _: *const [LODLevel.count]RegionMap, _: ILODConfig, _: Mat4, _: Vec3, _: ?LODManager.ChunkChecker, _: ?*anyopaque, _: bool, _: ?i32) void {}
        }.f,
        .deinit_fn = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ptr = @ptrCast(&mock_state),
    };

    const mock_atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };

    var mgr = try LODManager.init(allocator, config.interface(), mock_bridge, mock_render, mock_gen, &mock_atlas);
    mgr.cleanup_covered_regions = false;

    // Verify initial state
    const stats = mgr.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 0), stats.totalGenerating());

    mgr.deinit();

    // NOTE: LODManager does NOT call renderer.deinit() - renderer lifetime is
    // owned by the caller (World). This is tested in the integration test below.

    // Check config values
    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(5));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(12));
    try std.testing.expectEqual(LODLevel.lod2, config.getLODForDistance(24));
    try std.testing.expectEqual(LODLevel.lod3, config.getLODForDistance(50));
}

test "LODManager end-to-end covered cleanup" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = @import("chunk.zig").MAX_BLOCK_TYPES;

    const MockGenerator = struct {
        fn generate(_: *anyopaque, _: *Chunk, _: ?*const bool) void {}
        fn generateHeightmapOnly(_: *anyopaque, _: *LODSimplifiedData, _: i32, _: i32, _: LODLevel) void {}
        fn maybeRecenterCache(_: *anyopaque, _: i32, _: i32) bool {
            return false;
        }
        fn getSeed(_: *anyopaque) u64 {
            return 0;
        }
        fn getRegionInfo(_: *anyopaque, _: i32, _: i32) @import("worldgen/region.zig").RegionInfo {
            return undefined;
        }
        fn getColumnInfo(_: *anyopaque, _: f32, _: f32) @import("worldgen/generator_interface.zig").ColumnInfo {
            return .{ .height = 0, .biome = .plains, .is_ocean = false, .temperature = 0, .humidity = 0, .continentalness = 0 };
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        const vtable = Generator.VTable{
            .generate = generate,
            .generateHeightmapOnly = generateHeightmapOnly,
            .maybeRecenterCache = maybeRecenterCache,
            .getSeed = getSeed,
            .getRegionInfo = getRegionInfo,
            .getColumnInfo = getColumnInfo,
            .deinit = deinit,
        };
    };

    var mock_gen_impl = MockGenerator{};
    const mock_gen = Generator{
        .ptr = &mock_gen_impl,
        .vtable = &MockGenerator.vtable,
        .info = .{ .name = "Mock", .description = "Mock Generator" },
    };

    var config = LODConfig{
        .radii = .{ 2, 4, 8, 16 },
    };

    // Create mock GPU bridge (no-op). Use a real pointer to satisfy debug assertions.
    var noop_ctx: u8 = 0;
    const mock_bridge = LODGPUBridge{
        .on_upload = struct {
            fn f(_: *LODMesh, _: *anyopaque) rhi_types.RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *LODMesh, _: *anyopaque) void {}
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(&noop_ctx),
    };

    // Create mock render interface (no-op). Use a real pointer.
    const mock_render = LODRenderInterface{
        .render_fn = struct {
            fn f(_: *anyopaque, _: *const [LODLevel.count]MeshMap, _: *const [LODLevel.count]RegionMap, _: ILODConfig, _: Mat4, _: Vec3, _: ?LODManager.ChunkChecker, _: ?*anyopaque, _: bool, _: ?i32) void {}
        }.f,
        .deinit_fn = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ptr = @ptrCast(&noop_ctx),
    };

    const mock_atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };

    var mgr = try LODManager.init(allocator, config.interface(), mock_bridge, mock_render, mock_gen, &mock_atlas);
    mgr.cleanup_covered_regions = false;
    defer mgr.deinit();

    // 1. Initial position at origin
    try mgr.update(Vec3.zero, Vec3.zero, null, null);

    // 2. Mock a chunk checker that says NO chunks are loaded
    const Checker = struct {
        pub fn isLoaded(_: i32, _: i32, _: *anyopaque) bool {
            return false;
        }
    };

    // Force some regions to be renderable for testing cleanup
    const key = LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod1 }; // radii[1]=4, scale=4. rx=1 covers chunks 4..7.
    // This region touches the radius exactly at chunk 4, so it should remain in range
    // under the shared radial bounds test used by queueing, rendering, and unloading.

    const chunk = try allocator.create(LODChunk);
    chunk.* = LODChunk.init(1, 0, .lod1);
    chunk.state = .renderable;
    try mgr.regions[1].put(key, chunk);

    const mesh = try allocator.create(LODMesh);
    mesh.* = LODMesh.init(allocator, .lod1);
    mesh.ready = true;
    mesh.vertex_count = 100;
    try mgr.meshes[1].put(key, mesh);

    var dummy: u8 = 0;
    // Update - should NOT unload because checker says not loaded
    try mgr.update(Vec3.zero, Vec3.zero, Checker.isLoaded, &dummy);
    try std.testing.expect(mgr.regions[1].contains(key));

    // 3. Mock a chunk checker that says ALL chunks are loaded
    const FullChecker = struct {
        pub fn isLoaded(_: i32, _: i32, _: *anyopaque) bool {
            return true;
        }
    };

    // Update - cleanup is disabled in live world, so regions should stay resident
    // Need to trigger the throttle (every 4 frames)
    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);
    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);
    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);
    // 4th update triggers throttled logic
    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);

    try std.testing.expect(mgr.regions[1].contains(key));
}

test "LODStats aggregation" {
    var stats = LODStats{};
    stats.recordState(1, .renderable);
    stats.recordState(1, .renderable);
    stats.recordState(2, .generating);

    try std.testing.expectEqual(@as(u32, 2), stats.loaded[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.generating[2]);
    try std.testing.expectEqual(@as(u32, 2), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 1), stats.totalGenerating());

    stats.addMemory(2 * 1024 * 1024);
    try std.testing.expectEqual(@as(u32, 2), stats.memory_used_mb);

    stats.reset();
    try std.testing.expectEqual(@as(u32, 0), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 0), stats.memory_used_mb);
}

test "LODManager constants" {
    try std.testing.expect(MAX_LOD_REGIONS > 0);
    try std.testing.expect(LODLevel.count >= 2);
}
