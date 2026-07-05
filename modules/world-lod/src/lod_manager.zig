//! LOD Manager - orchestrates multi-level chunk loading for extreme render distances.
//!
//! Implements a Distant Horizons-style system where:
//! - LOD0 (0-16 chunks): Full detail, 2x2 chunks merged
//! - LOD1 (16-32 chunks): 2x simplified, 4x4 chunks merged
//! - LOD2 (32-64 chunks): 4x simplified, 8x8 chunks merged
//! - LOD3 (64-100 chunks): 8x simplified, 16x16 chunks merged, heightmap only
//!
//! Key principles:
//! - Near/fine LODs are queued first so coarse parents do not dominate mid-ground
//! - Coarse LODs remain available as fallback while finer children stream
//! - Smooth transitions via fog masking
//!
//! GPU operations are decoupled via LODGPUBridge and LODRenderInterface (Issue #246).

const std = @import("std");
const fs = @import("fs");
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
pub const LODStats = @import("lod_stats.zig").LODStats;

const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const worldToChunkFromFloat = world_core.worldToChunkFromFloat;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const ChunkMesh = @import("world-meshing").ChunkMesh;
const math = @import("engine-math");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Frustum = math.Frustum;
const AABB = math.AABB;
const Vertex = @import("engine-rhi").Vertex;
const engine_core = @import("engine-core");
const log = engine_core.log;

const JobSystem = engine_core.job_system;
const JobQueue = JobSystem.JobQueue;
const WorkerPool = JobSystem.WorkerPool;
const Job = JobSystem.Job;

const RingBuffer = engine_core.ring_buffer.RingBuffer;

const LODGenerator = @import("lod_generator.zig").LODGenerator;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const TextureAtlas = @import("engine-assets").TextureAtlas;

const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const LODRenderLayer = lod_gpu.LODRenderLayer;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const lod_scheduler = @import("lod_scheduler.zig");
const lod_cache = @import("lod_cache.zig");
const lod_store = @import("lod_store.zig");
const lod_ingest = @import("lod_ingest.zig");
const LODColumnProvenance = world_core.LODColumnProvenance;

/// Chunk coordinate key for the pending-ingestion and edit-dirty sets.
const ChunkCoordKey = struct {
    cx: i32,
    cz: i32,

    pub fn hash(self: ChunkCoordKey) u64 {
        const ux: u64 = @bitCast(@as(i64, self.cx));
        const uz: u64 = @bitCast(@as(i64, self.cz));
        return ux ^ (uz *% 0x9e3779b97f4a7c15);
    }
    pub fn eql(a: ChunkCoordKey, b: ChunkCoordKey) bool {
        return a.cx == b.cx and a.cz == b.cz;
    }
};

const ChunkCoordKeyContext = struct {
    pub fn hash(self: @This(), key: ChunkCoordKey) u64 {
        _ = self;
        return key.hash();
    }
    pub fn eql(self: @This(), a: ChunkCoordKey, b: ChunkCoordKey) bool {
        _ = self;
        return a.eql(b);
    }
};

const ChunkCoordSet = std.HashMap(ChunkCoordKey, void, ChunkCoordKeyContext, std.hash_map.default_max_load_percentage);

/// Optional callback used to resolve a loaded chunk by coordinate when
/// replaying deferred ingestions (e.g. a chunk that finished loading before
/// its containing LOD region had source data, or a debounced edit). Wired from
/// `World` via `setChunkResolver`.
pub const ChunkResolver = struct {
    ptr: *anyopaque,
    resolve_fn: *const fn (ptr: *anyopaque, cx: i32, cz: i32) ?*const Chunk,

    pub fn resolve(self: ChunkResolver, cx: i32, cz: i32) ?*const Chunk {
        return self.resolve_fn(self.ptr, cx, cz);
    }
};

/// A deferred chunk-derived ingestion waiting for its containing LOD region to
/// have source data. `pending_levels` is a bitmask of LOD levels (bit i set)
/// that still need to receive this chunk's contribution.
const PendingIngestion = struct {
    cx: i32,
    cz: i32,
    provenance: LODColumnProvenance,
    pending_levels: u8,
    ttl: u16,
};

pub const MAX_LOD_REGIONS = 2048;
const CHUNK_COVERAGE_PADDING: i32 = 1;
const LOD_UPDATE_DIVISOR: u32 = 2;
const MIN_LOD_WORKERS: usize = 4;
const MAX_LOD_WORKERS: usize = 6;
const MAX_MEMORY_EVICTIONS_PER_UPDATE: usize = 32;
const MAX_MESH_DELETIONS_PER_SWEEP: usize = 64;
const DELETION_SWEEP_SECONDS: f32 = 1.0;
const DEFAULT_LOD_UPLOAD_BUDGET_BYTES: usize = 32 * 1024 * 1024;
const LOD_UPLOAD_BUDGET_ENV = "ZIGCRAFT_LOD_UPLOAD_BUDGET_MB";

// Chunk-derived ingestion tuning (issue #752 Phase 2).
const MAX_PENDING_INGESTIONS: usize = 4096;
const MAX_DRAIN_BATCH: usize = 16;
const PENDING_INGESTION_TTL: u16 = 240; // ~4s @ 60fps drain cadence
const EDIT_FLUSH_COOLDOWN: f32 = 1.0; // coalesce rapid edits before re-ingesting
const LOD_FRAME_DT_APPROX: f32 = 0.016;

fn lodUploadBudgetBytes() usize {
    const raw = engine_core.getenv(LOD_UPLOAD_BUDGET_ENV) orelse return DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
    const mb = std.fmt.parseUnsigned(usize, raw, 10) catch return DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
    if (mb == 0) return std.math.maxInt(usize);
    return std.math.mul(usize, mb, 1024 * 1024) catch DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
}

fn wouldExceedUploadBudget(uploaded_bytes: usize, pending_bytes: usize, budget_bytes: usize, uploads: u32) bool {
    if (budget_bytes == 0 or budget_bytes == std.math.maxInt(usize)) return false;
    if (pending_bytes == 0 or uploads == 0) return false;
    if (uploaded_bytes >= budget_bytes) return true;
    return pending_bytes > budget_bytes - uploaded_bytes;
}

const PlayerChunkPos = struct {
    cx: i32,
    cz: i32,
};

fn isUploadPressureError(err: anyerror) bool {
    return switch (err) {
        error.OutOfMemory, error.PendingCopyOverflow => true,
        else => false,
    };
}

comptime {
    if (LODLevel.count < 2) {
        @compileError("LOD system requires at least two levels (LOD0 and at least one simplified level)");
    }
}

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

    // Current player position (chunk coords), read by worker threads for stale-job checks.
    player_cx: std.atomic.Value(i32),
    player_cz: std.atomic.Value(i32),

    // Next job token
    next_job_token: u32,

    // Stats
    stats: LODStats,
    cache_hits: u32,
    cache_misses: u32,

    // Mutex for thread safety
    mutex: sync.RwLock,

    // GPU bridge for upload/destroy/sync operations (replaces direct RHI field)
    gpu_bridge: LODGPUBridge,

    // Terrain generator for LOD generation (mutable for cache recentering)
    generator: LODGenerator,

    atlas: *const TextureAtlas,

    // Paused state
    paused: bool,

    // Teardown abort flag: set true ONLY in deinit() so in-flight LOD heightmap
    // generation jobs abort early and the worker-pool join doesn't block for
    // seconds on non-interruptible coarse-LOD jobs. Never set during normal
    // play or map pause, so LOD generation runs uninterrupted.
    //
    // Atomic: written on the main thread (deinit) with .release, read from
    // worker threads inside the heightmap loop with .acquire. This both
    // establishes proper cross-thread ordering and prevents the compiler from
    // hoisting the read out of the generation loop (which would silently break
    // the abort in ReleaseFast).
    stop_flag: std.atomic.Value(bool),

    // Memory tracking
    memory_used_bytes: usize,

    // Performance tracking for throttling
    update_tick: u32 = 0,

    // Deferred mesh deletion queue (Vulkan optimization)
    deletion_queue: std.ArrayListUnmanaged(*LODMesh),
    deletion_timer: f32 = 0,

    // Type-erased renderer interface (replaces direct LODRenderer(RHI) field)
    renderer: LODRenderInterface,

    // Optional save directory for generated LOD source data.
    cache_dir_path: ?[]const u8,
    logged_legacy_cache_notice: bool,
    store_mutex: sync.Mutex,

    // Keep cleanup behavior testable, but allow the live world to opt out.
    cleanup_covered_regions: bool = true,

    // -- Chunk-derived LOD ingestion (issue #752 Phase 2) --
    // Pending chunk ingestions whose containing LOD region did not yet have
    // source data when the chunk finished generating/loading. Drained from
    // update() once the regions appear.
    pending_ingestions: std.ArrayListUnmanaged(PendingIngestion),
    // Debounced player-edit coordinates awaiting re-ingestion with the
    // `edited` provenance. Drained from update() on a cooldown.
    edit_dirty: ChunkCoordSet,
    // Separate mutex guarding pending_ingestions / edit_dirty. Held briefly;
    // never held while acquiring `mutex` (avoids cross-lock deadlocks).
    ingestion_mutex: sync.Mutex,
    chunk_resolver: ?ChunkResolver,
    edit_cooldown: f32,
    // Cap on deferred ingestion records to bound memory under rapid movement.
    ingestion_drain_per_frame: u32,
    // Memory-pressure hysteresis (issue #752 Phase 4.5): under sustained budget
    // pressure, finer LOD radii are dynamically shrunk so evicted regions do
    // not immediately re-queue. Re-expands gradually once memory drops below
    // 80% of budget. The coarsest (horizon) level is never shrunk.
    radius_shrink_chunks: [LODLevel.count]i32,

    // Callback type to check if a regular chunk is loaded and renderable
    pub const ChunkChecker = lod_gpu.ChunkChecker;

    fn storePlayerChunkPos(self: *Self, cx: i32, cz: i32) void {
        self.player_cx.store(cx, .release);
        self.player_cz.store(cz, .release);
    }

    fn loadPlayerChunkPos(self: *const Self) PlayerChunkPos {
        return .{
            .cx = self.player_cx.load(.acquire),
            .cz = self.player_cz.load(.acquire),
        };
    }

    pub fn init(allocator: std.mem.Allocator, config: ILODConfig, gpu_bridge: LODGPUBridge, render_iface: LODRenderInterface, generator: LODGenerator, atlas: *const TextureAtlas) !*Self {
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
            .player_cx = std.atomic.Value(i32).init(0),
            .player_cz = std.atomic.Value(i32).init(0),
            .next_job_token = 1,
            .stats = .{},
            .cache_hits = 0,
            .cache_misses = 0,
            .mutex = .{},
            .gpu_bridge = gpu_bridge,
            .generator = generator,
            .atlas = atlas,
            .paused = false,
            .stop_flag = std.atomic.Value(bool).init(false),
            .memory_used_bytes = 0,
            .update_tick = 0,
            .deletion_queue = .empty,
            .deletion_timer = 0,
            .renderer = render_iface,
            .cleanup_covered_regions = true,
            .cache_dir_path = null,
            .logged_legacy_cache_notice = false,
            .store_mutex = .{},
            .pending_ingestions = .empty,
            .edit_dirty = ChunkCoordSet.init(allocator),
            .ingestion_mutex = .{},
            .chunk_resolver = null,
            .edit_cooldown = 0.0,
            .ingestion_drain_per_frame = 4,
            .radius_shrink_chunks = [_]i32{0} ** LODLevel.count,
        };

        const cpu_count = std.Thread.getCpuCount() catch MIN_LOD_WORKERS;
        const lod_worker_count = std.math.clamp(cpu_count / 2, MIN_LOD_WORKERS, MAX_LOD_WORKERS);

        // All LOD jobs go through one shared queue. LOD-aware priority bits keep
        // fine near-detail jobs ahead of coarse fallback regions.
        mgr.lod_gen_pool = try WorkerPool.init(allocator, lod_worker_count, mgr.gen_queues[LODLevel.count - 1], mgr, processLODJob);

        const radii = config.getRadii();
        log.log.info("LODManager initialized with radii: {any} | workers={}", .{
            radii,
            lod_worker_count,
        });

        return mgr;
    }

    pub fn deinit(self: *Self) void {
        // Abort any in-flight heightmap jobs BEFORE joining the worker pool.
        // Coarse-LOD heightmap generation can take seconds per region and is
        // only interruptible via this flag (checked inside the generation loop).
        // This is the ONLY place stop_flag is set: normal pause()/unpause() and
        // map-open leave it false so LOD generation runs uninterrupted.
        self.stop_flag.store(true, .release);

        // Stop and cleanup queues
        for (0..LODLevel.count) |i| {
            self.gen_queues[i].stop();
        }

        // Cleanup worker pool. In-flight heightmap jobs were aborted by
        // stop_flag above, so this join completes promptly.
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

        // Process any pending deletions after all LOD users have stopped.
        self.processMeshDeletions(std.math.maxInt(usize));
        self.deletion_queue.deinit(self.allocator);

        if (self.cache_dir_path) |path| {
            self.allocator.free(path);
        }

        self.pending_ingestions.deinit(self.allocator);
        self.edit_dirty.deinit();

        // NOTE: LODManager does NOT own the renderer lifetime.
        // The renderer is owned by World and deinit'd there.

        self.allocator.destroy(self);
    }

    pub fn enableCache(self: *Self, save_dir_path: []const u8) !void {
        const cache_dir_path = try self.allocator.dupe(u8, save_dir_path);
        errdefer self.allocator.free(cache_dir_path);

        const live_header = lod_store.StoreHeader{
            .seed = self.generator.seed,
            .generator_identity_hash = self.generator.identity_hash,
            .generator_version = self.generator.version,
        };

        if (try lod_store.readHeader(self.allocator, save_dir_path)) |stored_header| {
            if (stored_header.seed != live_header.seed) {
                // Seed mismatch => the entire store is foreign; discard all.
                log.log.warn("LOD store seed mismatch; discarding foreign LOD source store", .{});
                try lod_store.deleteStore(self.allocator, save_dir_path);
            } else if (stored_header.lod_data_version != live_header.lod_data_version) {
                log.log.warn("LOD store data version changed; discarding stale LOD source store", .{});
                try lod_store.deleteStore(self.allocator, save_dir_path);
            } else if (stored_header.generator_identity_hash != live_header.generator_identity_hash or
                stored_header.generator_version != live_header.generator_version)
            {
                // Generator changed but seed is the same: worldgen-sampled LOD
                // is stale, but chunk-derived columns reflect real saved chunks
                // and remain valid. Cached payloads are keyed by generator
                // identity/version, so the old data is naturally ignored on
                // read (cache miss) and regenerated with the new generator;
                // `setGeneratedColumn` is provenance-aware, so regeneration
                // preserves any chunk_derived/edited columns. We still delete
                // the orphaned old-keyed store for disk hygiene.
                log.log.warn("LOD store generator mismatch; regenerating stale worldgen LOD (chunk-derived data re-ingested from saved chunks)", .{});
                try lod_store.deleteStore(self.allocator, save_dir_path);
            }
        }

        try lod_store.writeHeader(self.allocator, save_dir_path, live_header);

        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.cache_dir_path) |old_path| {
            self.allocator.free(old_path);
        }
        self.cache_dir_path = cache_dir_path;
        self.logged_legacy_cache_notice = false;
        log.log.info("LOD source store enabled at '{s}/lod'", .{cache_dir_path});
    }

    // ----------------------------------------------------------------------
    // Chunk-derived LOD ingestion (issue #752 Phase 2)
    // ----------------------------------------------------------------------

    /// Wire a chunk resolver so deferred ingestions can fetch chunk data when
    /// their containing LOD region later becomes ready.
    pub fn setChunkResolver(self: *Self, resolver: ChunkResolver) void {
        self.ingestion_mutex.lock();
        defer self.ingestion_mutex.unlock();
        self.chunk_resolver = resolver;
    }

    /// Ingest a real chunk into every LOD level whose region contains it. The
    /// chunk is downsampled into each region's source data with the given
    /// provenance; higher provenance always wins. Regions that are missing or
    /// currently in-flight are recorded as pending and replayed from
    /// `update()`. Safe to call from the generation worker thread; the caller
    /// must pin the chunk for the duration of the call.
    pub fn ingestChunk(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance) void {
        const pending_mask = self.applyIngestionToRegions(cx, cz, chunk, provenance);
        if (pending_mask != 0) {
            self.ingestion_mutex.lock();
            self.recordPendingLocked(cx, cz, provenance, pending_mask);
            self.ingestion_mutex.unlock();
        }
    }

    /// Record a deferred ingestion without a chunk pointer. The chunk is
    /// resolved later via `chunk_resolver` from `update()`. Used for chunk
    /// loads that happen before their LOD region exists.
    pub fn requestIngestion(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance) void {
        self.ingestion_mutex.lock();
        defer self.ingestion_mutex.unlock();
        var mask: u8 = 0;
        const active = lod_chunk.activeLODCount(self.config);
        var i: usize = 1;
        while (i < active) : (i += 1) mask |= @as(u8, 1) << @intCast(i);
        self.recordPendingLocked(cx, cz, provenance, mask);
    }

    /// Notify the LOD system that a block edit affected chunk (cx, cz).
    /// Coalesced on a short cooldown and re-ingested with the `edited`
    /// provenance so distant terrain reflects player changes after teleport.
    pub fn markChunkEdited(self: *Self, cx: i32, cz: i32) void {
        self.ingestion_mutex.lock();
        defer self.ingestion_mutex.unlock();
        self.edit_dirty.put(.{ .cx = cx, .cz = cz }, {}) catch |err| {
            log.log.warn("Failed to track edited chunk for LOD ingestion ({}, {}): {}", .{ cx, cz, err });
        };
    }

    /// Apply one chunk's contribution to every LOD region that already has
    /// source data and is not in-flight. Returns a bitmask of LOD levels that
    /// could not be applied (region missing, not yet generated, or meshing)
    /// so the caller can record them as pending.
    fn applyIngestionToRegions(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance) u8 {
        var pending_mask: u8 = 0;
        const active = lod_chunk.activeLODCount(self.config);

        self.mutex.lock();
        defer self.mutex.unlock();

        var i: usize = 1;
        while (i < active) : (i += 1) {
            const lod: LODLevel = @enumFromInt(@as(u3, @intCast(i)));
            const key = LODRegionKey.fromChunkCoords(cx, cz, lod);
            const lod_chunk_ptr = self.regions[i].get(key) orelse {
                pending_mask |= @as(u8, 1) << @intCast(i);
                continue;
            };
            switch (lod_chunk_ptr.data) {
                .simplified => |*data| {
                    // Defer if a mesh/generation/upload job is mid-flight for
                    // this region: writing source data concurrently with a
                    // mesh job reading it (under the shared lock) would race.
                    if (lod_chunk_ptr.state == .generating or
                        lod_chunk_ptr.state == .meshing or
                        lod_chunk_ptr.state == .uploading)
                    {
                        pending_mask |= @as(u8, 1) << @intCast(i);
                        continue;
                    }
                    const region_size: i32 = @intCast(world_core.regionSizeBlocks(lod));
                    const min_x: i32 = lod_chunk_ptr.region_x * region_size;
                    const min_z: i32 = lod_chunk_ptr.region_z * region_size;
                    const written = lod_ingest.downsampleChunkIntoRegion(chunk, cx, cz, data, min_x, min_z, region_size, provenance);
                    if (written == 0) continue;
                    lod_chunk_ptr.dirty = true;
                    lod_chunk_ptr.store_dirty = true;
                    lod_chunk_ptr.updateHeightBoundsFromData();
                    // Force a remesh of already-rendered regions so the new
                    // chunk-derived data becomes visible.
                    self.demoteRegionForRemesh(key, lod_chunk_ptr);
                },
                else => {
                    // Region exists but has no source data yet (not generated).
                    pending_mask |= @as(u8, 1) << @intCast(i);
                },
            }
        }
        return pending_mask;
    }

    /// Assumes `ingestion_mutex` held. Coalesces by coordinate, keeping the
    /// most authoritative provenance and the union of pending level bits.
    fn recordPendingLocked(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance, mask: u8) void {
        for (self.pending_ingestions.items) |*entry| {
            if (entry.cx == cx and entry.cz == cz) {
                entry.pending_levels |= mask;
                entry.ttl = PENDING_INGESTION_TTL;
                if (provenance.canOverwrite(entry.provenance)) entry.provenance = provenance;
                return;
            }
        }
        if (self.pending_ingestions.items.len >= MAX_PENDING_INGESTIONS) {
            _ = self.pending_ingestions.orderedRemove(0);
        }
        self.pending_ingestions.append(self.allocator, .{
            .cx = cx,
            .cz = cz,
            .provenance = provenance,
            .pending_levels = mask,
            .ttl = PENDING_INGESTION_TTL,
        }) catch |err| {
            log.log.warn("Failed to defer LOD ingestion for chunk ({}, {}): {}", .{ cx, cz, err });
        };
    }

    /// Re-record a pending entry from outside the lock (decay applied by
    /// caller). Coalesces with any existing entry for the coordinate.
    fn rerecordPending(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance, mask: u8, ttl: u16) void {
        self.ingestion_mutex.lock();
        defer self.ingestion_mutex.unlock();
        for (self.pending_ingestions.items) |*entry| {
            if (entry.cx == cx and entry.cz == cz) {
                entry.pending_levels |= mask;
                entry.ttl = @max(entry.ttl, ttl);
                if (provenance.canOverwrite(entry.provenance)) entry.provenance = provenance;
                return;
            }
        }
        if (self.pending_ingestions.items.len >= MAX_PENDING_INGESTIONS) {
            _ = self.pending_ingestions.orderedRemove(0);
        }
        self.pending_ingestions.append(self.allocator, .{
            .cx = cx,
            .cz = cz,
            .provenance = provenance,
            .pending_levels = mask,
            .ttl = ttl,
        }) catch |err| {
            log.log.warn("Failed to requeue deferred LOD ingestion for chunk ({}, {}): {}", .{ cx, cz, err });
        };
    }

    /// Decay TTL of every pending entry, dropping expired ones. Assumes
    /// `ingestion_mutex` held.
    fn decayPendingLocked(self: *Self) void {
        var write: usize = 0;
        for (self.pending_ingestions.items) |entry| {
            const ttl = if (entry.ttl > 0) entry.ttl - 1 else 0;
            if (ttl > 0 and entry.pending_levels != 0) {
                var e = entry;
                e.ttl = ttl;
                self.pending_ingestions.items[write] = e;
                write += 1;
            }
        }
        self.pending_ingestions.shrinkRetainingCapacity(write);
    }

    /// Replay deferred ingestions: snapshot all pending under the ingestion
    /// lock, resolve each chunk, and re-apply. Unresolved or still-in-flight
    /// levels are re-recorded with a decayed TTL.
    fn drainPendingIngestions(self: *Self) void {
        var snapshot = std.ArrayListUnmanaged(PendingIngestion).empty;
        {
            self.ingestion_mutex.lock();
            defer self.ingestion_mutex.unlock();
            if (self.pending_ingestions.items.len == 0) return;
            snapshot.appendSlice(self.allocator, self.pending_ingestions.items) catch {
                self.decayPendingLocked();
                return;
            };
            self.pending_ingestions.clearRetainingCapacity();
        }
        defer snapshot.deinit(self.allocator);

        const resolver = self.chunk_resolver;
        const limit = @min(snapshot.items.len, self.ingestion_drain_per_frame);

        // Process the head of the snapshot; defer the tail with a decayed TTL.
        var i: usize = 0;
        while (i < snapshot.items.len) : (i += 1) {
            const entry = snapshot.items[i];
            if (entry.pending_levels == 0) continue;
            if (i >= limit) {
                const ttl = if (entry.ttl > 0) entry.ttl - 1 else 0;
                if (ttl > 0) self.rerecordPending(entry.cx, entry.cz, entry.provenance, entry.pending_levels, ttl);
                continue;
            }
            const chunk = if (resolver) |r| r.resolve(entry.cx, entry.cz) else null;
            if (chunk) |c| {
                const remaining = self.applyIngestionToRegions(entry.cx, entry.cz, c, entry.provenance);
                if (remaining != 0) {
                    const ttl = if (entry.ttl > 0) entry.ttl - 1 else 0;
                    if (ttl > 0) self.rerecordPending(entry.cx, entry.cz, entry.provenance, remaining, ttl);
                }
            } else {
                const ttl = if (entry.ttl > 0) entry.ttl - 1 else 0;
                if (ttl > 0) self.rerecordPending(entry.cx, entry.cz, entry.provenance, entry.pending_levels, ttl);
            }
        }
    }

    /// Flush debounced player edits: re-ingest edited chunks with the `edited`
    /// provenance. Runs on a cooldown so rapid edits coalesce into one rebuild.
    fn flushEditedChunks(self: *Self) void {
        self.edit_cooldown -= LOD_FRAME_DT_APPROX;
        if (self.edit_cooldown > 0.0) return;

        var snapshot = std.ArrayListUnmanaged(ChunkCoordKey).empty;
        {
            self.ingestion_mutex.lock();
            defer self.ingestion_mutex.unlock();
            if (self.edit_dirty.count() == 0) return;
            var it = self.edit_dirty.keyIterator();
            while (it.next()) |k| {
                snapshot.append(self.allocator, k.*) catch break;
            }
            self.edit_dirty.clearRetainingCapacity();
        }
        defer snapshot.deinit(self.allocator);

        const resolver = self.chunk_resolver;
        for (snapshot.items) |k| {
            if (resolver) |r| {
                if (r.resolve(k.cx, k.cz)) |chunk| {
                    _ = self.applyIngestionToRegions(k.cx, k.cz, chunk, .edited);
                    continue;
                }
            }
            // Chunk not resident now: defer until the resolver can fetch it.
            self.requestIngestion(k.cx, k.cz, .edited);
        }
        self.edit_cooldown = EDIT_FLUSH_COOLDOWN;
    }

    /// Persist at most one dirty region's source data to the LOD store per
    /// frame. Serializes under the manager lock, then writes outside it so file
    /// I/O does not block LOD state updates.
    fn flushDirtyStores(self: *Self) void {
        const save_dir_path = self.cacheDirPathSnapshot() orelse return;
        defer self.allocator.free(save_dir_path);

        var write_key: ?LODRegionKey = null;
        var write_bytes: ?[]u8 = null;

        {
            self.mutex.lock();
            defer self.mutex.unlock();

            const active = lod_chunk.activeLODCount(self.config);
            var i: usize = 1;
            while (i < active) : (i += 1) {
                var it = self.regions[i].iterator();
                while (it.next()) |entry| {
                    const lcp = entry.value_ptr.*;
                    if (!lcp.store_dirty) continue;
                    switch (lcp.data) {
                        .simplified => |*data| {
                            const key = LODRegionKey{ .rx = lcp.region_x, .rz = lcp.region_z, .lod = lcp.lod_level };
                            const cache_key = self.cacheKey(key);
                            const bytes = lod_cache.serialize(data, cache_key, self.allocator) catch |err| {
                                log.log.warn("Failed to serialize LOD{} cache ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
                                return;
                            };
                            lcp.store_dirty = false;
                            write_key = key;
                            write_bytes = bytes;
                        },
                        else => {},
                    }
                    break; // one region per frame keeps frame cost bounded
                }
                if (write_bytes != null) break;
            }
        }

        const key = write_key orelse return;
        const bytes = write_bytes orelse return;
        defer self.allocator.free(bytes);

        const cache_key = self.cacheKey(key);
        self.writeStorePayload(save_dir_path, cache_key, bytes) catch |err| {
            log.log.warn("Failed to write LOD{} store ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
            self.mutex.lock();
            if (self.regions[@intFromEnum(key.lod)].get(key)) |chunk| {
                chunk.store_dirty = true;
            }
            self.mutex.unlock();
        };
    }

    /// Update LOD system with player position
    pub fn update(self: *Self, player_pos: Vec3, player_velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
        if (self.paused) return;

        // Deferred deletion handling. LOD meshes do not carry frame fences yet,
        // so destruction still waits for idle, but the bounded sweep prevents
        // unreachable GPU/CPU resources from accumulating through long sessions.
        self.deletion_timer += LOD_FRAME_DT_APPROX;
        if (self.deletion_timer >= DELETION_SWEEP_SECONDS) {
            self.processMeshDeletions(MAX_MESH_DELETIONS_PER_SWEEP);
            self.deletion_timer = 0;
        }

        // Safety: Check for NaN/Inf player position
        if (!std.math.isFinite(player_pos.x) or !std.math.isFinite(player_pos.z)) return;

        const pc = worldToChunkFromFloat(player_pos.x, player_pos.z);
        self.storePlayerChunkPos(pc.chunk_x, pc.chunk_z);

        // Keep LOD job priorities fresh as the player moves. doReprioritize is
        // LOD-aware (scales region coords to chunk space, preserves LOD-bias
        // bits), so this safely re-orders stale jobs after chunk crossings.
        // The actual rebuild is lazy (only on pop when the queue is large).
        self.gen_queues[LODLevel.count - 1].updatePlayerPos(pc.chunk_x, pc.chunk_z) catch {};

        // Throttle heavy LOD management logic (generation queuing, state processing, unloads).
        // LOD management involves iterating over thousands of potential regions and can
        // take several milliseconds. Throttling to every 4 frames (approx 15Hz at 60fps)
        // significantly reduces CPU overhead while remaining responsive to player movement.
        self.update_tick += 1;
        if (self.update_tick % LOD_UPDATE_DIVISOR != 0) {
            self.processUploads();
            self.decayTransitionFrames();
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

        const active_lod_count = lod_chunk.activeLODCount(self.config);

        // Queue a small horizon seed first so something appears quickly, then
        // let LOD0/LOD1/LOD2 refinements replace the coarse fallback.
        var order_idx: usize = 0;
        while (order_idx < active_lod_count) : (order_idx += 1) {
            const i = lod_scheduler.priorityLevelIndex(order_idx, active_lod_count);
            self.queueLODRegions(@enumFromInt(@as(u3, @intCast(i))), player_velocity, chunk_checker, checker_ctx) catch |err| {
                log.log.warn("LOD queue error for level {}: {} (non-fatal)", .{ i, err });
            };
        }

        // Process state transitions
        self.processStateTransitions(player_velocity) catch |err| {
            log.log.warn("LOD state transitions error: {} (non-fatal)", .{err});
        };

        // Process uploads (limited per frame)
        self.processUploads();

        // Update stats
        self.updateStats();
        self.enforceMemoryBudget() catch |err| {
            log.log.warn("LOD memory budget eviction error: {} (non-fatal)", .{err});
        };

        // Periodic WARN-level LOD stats so logs/zigcraft.log shows LOD fill
        // progress by default (no env vars needed). update_tick counts frames;
        // every ~180 frames (~3s @ 60fps) gives a trend over a 20s diagnostic run.
        if (self.update_tick % 180 == 0) {
            const s = self.stats;
            log.log.warn("LOD_STATS: loaded={any} generating={any} meshing={any} genQ={} uploadQ={any} meshes={any} cache_hit/miss={}/{} store_hit/miss={}/{} evictions={}", .{
                s.loaded,
                s.generating,
                s.meshing,
                s.gen_queue_depth[LODLevel.count - 1],
                s.upload_queue_depth,
                s.mesh_count,
                s.cache_hits,
                s.cache_misses,
                s.store_hits,
                s.store_misses,
                s.evictions,
            });
        }

        // Unload distant regions
        self.unloadDistantRegions() catch |err| {
            log.log.warn("LOD unload error: {} (non-fatal)", .{err});
        };

        // Chunk-derived ingestion: replay deferred ingestions, flush debounced
        // player edits, and persist any dirty source regions to the store.
        self.drainPendingIngestions();
        self.flushEditedChunks();
        self.flushDirtyStores();
        self.decayTransitionFrames();
    }

    /// Queue LOD regions that need generation
    fn queueLODRegions(self: *Self, lod: LODLevel, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
        const player = self.loadPlayerChunkPos();
        const Coverage = struct {
            fn areAllLoaded(ptr: *anyopaque, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool {
                const mgr: *Self = @ptrCast(@alignCast(ptr));
                return mgr.areAllChunksLoaded(bounds, checker, ctx);
            }
        };
        return lod_scheduler.queueLODRegions(.{
            .allocator = self.allocator,
            .config = self.config,
            .regions = &self.regions,
            .gen_queues = &self.gen_queues,
            .mutex = &self.mutex,
            .player_cx = player.cx,
            .player_cz = player.cz,
            .next_job_token = &self.next_job_token,
            .cleanup_covered_regions = self.cleanup_covered_regions,
            .coverage_ptr = self,
            .are_all_chunks_loaded = Coverage.areAllLoaded,
            .radius_reduction = &self.radius_shrink_chunks,
        }, lod, velocity, chunk_checker, checker_ctx);
    }

    /// Process state transitions (generated -> meshing -> ready)
    fn processStateTransitions(self: *Self, velocity: Vec3) !void {
        // Use exclusive lock since we modify chunk state
        self.mutex.lock();
        defer self.mutex.unlock();

        const player = self.loadPlayerChunkPos();
        const active_lod_count = lod_chunk.activeLODCount(self.config);

        // Collect generated/mesh-ready chunks, then sort by ascending distance
        // before enqueueing. The regions HashMap iterates in arbitrary
        // (hash-bucket) order, so without sorting the meshing/upload order is
        // effectively random — far chunks can be processed before near ones.
        const MeshCandidate = struct { chunk: *LODChunk, encoded_priority: i32, level: u3, coord_scale: i32 };
        var mesh_candidates = std.ArrayListUnmanaged(MeshCandidate).empty;
        defer mesh_candidates.deinit(self.allocator);

        const UploadCandidate = struct { chunk: *LODChunk, encoded_priority: i32, level: u3 };
        var upload_candidates = std.ArrayListUnmanaged(UploadCandidate).empty;
        defer upload_candidates.deinit(self.allocator);

        for (0..active_lod_count) |i| {
            const lod = @as(LODLevel, @enumFromInt(@as(u3, @intCast(i))));
            const scale = @as(i32, @intCast(lod.chunksPerSide()));
            const level: u3 = @intCast(i);
            var iter = self.regions[i].iterator();
            while (iter.next()) |entry| {
                const chunk = entry.value_ptr.*;
                if (chunk.state == .generated) {
                    const center_cx = chunk.region_x * scale + @divFloor(scale, 2);
                    const center_cz = chunk.region_z * scale + @divFloor(scale, 2);
                    const encoded_priority = lod_scheduler.encodePriority(lod, center_cx - player.cx, center_cz - player.cz, velocity, active_lod_count);
                    // Append before flipping state so an allocation failure
                    // leaves the chunk in .generated (re-tried next tick)
                    // instead of stuck in .meshing with no queued job.
                    try mesh_candidates.append(self.allocator, .{ .chunk = chunk, .encoded_priority = encoded_priority, .level = level, .coord_scale = scale });
                    chunk.state = .meshing;
                } else if (chunk.state == .mesh_ready) {
                    const center_cx = chunk.region_x * scale + @divFloor(scale, 2);
                    const center_cz = chunk.region_z * scale + @divFloor(scale, 2);
                    const encoded_priority = lod_scheduler.encodePriority(lod, center_cx - player.cx, center_cz - player.cz, velocity, active_lod_count);
                    try upload_candidates.append(self.allocator, .{ .chunk = chunk, .encoded_priority = encoded_priority, .level = level });
                    chunk.state = .uploading;
                }
            }
        }

        // Meshing jobs share one queue; sort by encoded priority so fine/near
        // sections are built before coarse fallback.
        std.mem.sort(MeshCandidate, mesh_candidates.items, {}, struct {
            fn lt(_: void, a: MeshCandidate, b: MeshCandidate) bool {
                return a.encoded_priority < b.encoded_priority;
            }
        }.lt);
        for (mesh_candidates.items) |mc| {
            try self.gen_queues[LODLevel.count - 1].push(.{
                .type = .chunk_meshing,
                .dist_sq = mc.encoded_priority,
                .data = .{
                    .chunk = .{
                        .x = mc.chunk.region_x,
                        .z = mc.chunk.region_z,
                        .job_token = mc.chunk.job_token,
                        .lod_level = mc.level,
                        .coord_scale = mc.coord_scale,
                    },
                },
            });
        }

        // Uploads go to per-level FIFO queues. Sort by the same encoded priority
        // used by generation/meshing: small horizon seed first, then detailed
        // bands so fallback terrain is visible but short-lived.
        std.mem.sort(UploadCandidate, upload_candidates.items, {}, struct {
            fn lt(_: void, a: UploadCandidate, b: UploadCandidate) bool {
                return a.encoded_priority < b.encoded_priority;
            }
        }.lt);
        for (upload_candidates.items) |uc| {
            try self.upload_queues[uc.level].push(uc.chunk);
        }
    }

    /// Process GPU uploads (limited per frame)
    fn processUploads(self: *Self) void {
        self.processUploadsWithBudget(lodUploadBudgetBytes());
    }

    fn processUploadsWithBudget(self: *Self, upload_budget_bytes: usize) void {
        const UploadTask = struct {
            key: LODRegionKey,
            chunk: *LODChunk,
            mesh: *LODMesh,
            lod_idx: usize,
            pending_bytes: usize,
        };

        self.mutex.lockShared();
        const max_uploads = self.config.getMaxUploadsPerFrame();
        self.mutex.unlockShared();

        var uploads: u32 = 0;
        var uploaded_bytes: usize = 0;

        while (uploads < max_uploads) {
            var task: ?UploadTask = null;
            var completed_without_upload = false;
            var made_progress = false;
            var stop_processing = false;

            self.mutex.lock();
            const active_lod_count = lod_chunk.activeLODCount(self.config);

            var order_idx: usize = 0;
            while (order_idx < active_lod_count and uploads < max_uploads and task == null and !completed_without_upload and !stop_processing) : (order_idx += 1) {
                const i = lod_scheduler.priorityLevelIndex(order_idx, active_lod_count);
                if (self.upload_queues[i].pop()) |chunk| {
                    made_progress = true;
                    const key = LODRegionKey{
                        .rx = chunk.region_x,
                        .rz = chunk.region_z,
                        .lod = chunk.lod_level,
                    };
                    if (self.meshes[i].get(key)) |mesh| {
                        const pending_bytes = mesh.pendingUploadBytes();
                        if (wouldExceedUploadBudget(uploaded_bytes, pending_bytes, upload_budget_bytes, uploads)) {
                            self.requeueUpload(i, chunk);
                            stop_processing = true;
                            break;
                        }

                        chunk.pin();
                        task = .{
                            .key = key,
                            .chunk = chunk,
                            .mesh = mesh,
                            .lod_idx = i,
                            .pending_bytes = pending_bytes,
                        };
                    } else {
                        self.markRegionRenderable(key, chunk);
                        uploads += 1;
                        completed_without_upload = true;
                    }
                }
            }
            self.mutex.unlock();

            if (stop_processing or !made_progress) break;
            if (completed_without_upload) continue;

            const upload_task = task orelse continue;
            self.gpu_bridge.upload(upload_task.mesh) catch |err| {
                log.log.warn("LOD{} mesh upload failed (will retry): {}", .{ upload_task.lod_idx, err });
                self.mutex.lock();
                self.stats.upload_failures += 1;
                uploads += 1;
                if (isUploadPressureError(err)) {
                    self.requeueUpload(upload_task.lod_idx, upload_task.chunk);
                    upload_task.chunk.unpin();
                    self.mutex.unlock();
                    return;
                }
                upload_task.chunk.state = .mesh_ready;
                upload_task.chunk.unpin();
                self.mutex.unlock();
                continue;
            };

            uploaded_bytes += upload_task.pending_bytes;
            self.mutex.lock();
            self.markRegionRenderable(upload_task.key, upload_task.chunk);
            uploads += 1;
            upload_task.chunk.unpin();
            self.mutex.unlock();
        }
    }

    fn requeueUpload(self: *Self, lod_idx: usize, chunk: *LODChunk) void {
        chunk.state = .uploading;
        self.upload_queues[lod_idx].push(chunk) catch |err| {
            log.log.warn("LOD{} upload requeue failed: {}", .{ lod_idx, err });
            self.stats.upload_failures += 1;
            chunk.state = .mesh_ready;
        };
    }

    fn countRenderableChildren(self: *Self, key: LODRegionKey) u8 {
        const children = key.childKeys() orelse return 0;
        const child_idx = @intFromEnum(children[0].lod);
        var count: u8 = 0;
        for (children) |child_key| {
            const child = self.regions[child_idx].get(child_key) orelse continue;
            if (self.regionContributesGeometry(child_key, child)) count += 1;
        }
        return count;
    }

    fn regionContributesGeometry(self: *Self, key: LODRegionKey, chunk: *const LODChunk) bool {
        if (chunk.state != .renderable) return false;
        const mesh = self.meshes[@intFromEnum(key.lod)].get(key) orelse return false;
        return mesh.ready and mesh.vertex_count > 0;
    }

    fn adjustParentReadyChildren(self: *Self, key: LODRegionKey, delta: i8) void {
        const parent = key.parentKey() orelse return;
        const parent_chunk = self.regions[@intFromEnum(parent.lod)].get(parent) orelse return;
        const before = parent_chunk.ready_children;
        if (delta > 0) {
            parent_chunk.ready_children = @min(parent_chunk.ready_children + @as(u8, @intCast(delta)), 4);
        } else if (delta < 0) {
            const amount: u8 = @intCast(-delta);
            parent_chunk.ready_children = if (amount >= parent_chunk.ready_children) 0 else parent_chunk.ready_children - amount;
        }
        if (before < 4 and parent_chunk.ready_children >= 4) {
            parent_chunk.transition_frames_remaining = lod_chunk.TRANSITION_FADE_FRAMES;
        } else if (parent_chunk.ready_children < 4) {
            parent_chunk.transition_frames_remaining = 0;
        }
    }

    fn markRegionRenderable(self: *Self, key: LODRegionKey, chunk: *LODChunk) void {
        if (chunk.state == .renderable) return;
        chunk.ready_children = self.countRenderableChildren(key);
        chunk.transition_frames_remaining = lod_chunk.TRANSITION_FADE_FRAMES;
        chunk.state = .renderable;
        if (self.regionContributesGeometry(key, chunk)) {
            self.adjustParentReadyChildren(key, 1);
        }
    }

    fn decayTransitionFrames(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const active = lod_chunk.activeLODCount(self.config);
        var i: usize = 1;
        while (i < active) : (i += 1) {
            var iter = self.regions[i].iterator();
            while (iter.next()) |entry| {
                const chunk = entry.value_ptr.*;
                if (chunk.transition_frames_remaining > 0) {
                    chunk.transition_frames_remaining -= 1;
                }
            }
        }
    }

    fn noteRegionRemoved(self: *Self, key: LODRegionKey, chunk: *const LODChunk) void {
        if (self.regionContributesGeometry(key, chunk)) {
            self.adjustParentReadyChildren(key, -1);
        }
    }

    fn demoteRegionForRemesh(self: *Self, key: LODRegionKey, chunk: *LODChunk) void {
        if (chunk.state == .renderable) {
            self.noteRegionRemoved(key, chunk);
            chunk.state = .generated;
        } else if (chunk.state == .mesh_ready) {
            chunk.state = .generated;
        }
    }

    /// Unload regions that are too far from player
    fn unloadDistantRegions(self: *Self) !void {
        const radii = self.config.getRadii();
        const active_lod_count = lod_chunk.activeLODCount(self.config);
        for (0..active_lod_count) |i| {
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

        const player = self.loadPlayerChunkPos();
        var iter = storage.iterator();
        while (iter.next()) |entry| {
            const key = entry.key_ptr.*;
            const chunk = entry.value_ptr.*;

            if (!key.chunkBounds().intersectsRadius(player.cx, player.cz, lod_radius)) {
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
                    self.noteRegionRemoved(key, chunk);
                    if (meshes.get(key)) |mesh| {
                        // Push to deferred deletion queue instead of deleting immediately
                        self.queueMeshDeletion(mesh);
                        _ = meshes.remove(key);
                    }

                    chunk.deinit(self.allocator);
                    self.allocator.destroy(chunk);
                    _ = storage.remove(key);
                }
            }
        }
    }

    fn queueMeshDeletion(self: *Self, mesh: *LODMesh) void {
        self.deletion_queue.append(self.allocator, mesh) catch {
            self.gpu_bridge.destroy(mesh);
            self.allocator.destroy(mesh);
        };
    }

    fn processMeshDeletions(self: *Self, max_count: usize) void {
        const count = @min(max_count, self.deletion_queue.items.len);
        if (count == 0) return;

        // LODMesh does not carry a per-frame fence today, so destruction still
        // requires GPU idle. Bound each sweep so a memory-pressure eviction burst
        // cannot turn into an unbounded main-thread stall.
        self.gpu_bridge.waitIdle();
        var processed: usize = 0;
        while (processed < count) : (processed += 1) {
            const idx = self.deletion_queue.items.len - 1;
            const mesh = self.deletion_queue.items[idx];
            self.gpu_bridge.destroy(mesh);
            self.allocator.destroy(mesh);
            self.deletion_queue.items.len = idx;
        }
    }

    fn regionMemoryBytes(chunk: *const LODChunk, mesh: ?*LODMesh) usize {
        var total: usize = 0;
        switch (chunk.data) {
            .simplified => |*s| total += s.totalMemoryBytes(),
            else => {},
        }
        if (mesh) |m| total += m.capacity * @sizeOf(Vertex);
        return total;
    }

    fn enforceMemoryBudget(self: *Self) !void {
        const budget_mb = self.config.getMemoryBudgetMB();
        if (budget_mb == 0) return;
        const budget_bytes = @as(usize, budget_mb) * 1024 * 1024;
        const hysteresis_low = (budget_bytes * 4) / 5; // 80% re-expand threshold

        // Decay path: comfortably under budget -> gradually re-expand radii.
        if (self.memory_used_bytes < hysteresis_low) {
            self.mutex.lock();
            var decayed = false;
            for (&self.radius_shrink_chunks) |*s| {
                if (s.* > 0) {
                    s.* -= 1;
                    decayed = true;
                }
            }
            self.mutex.unlock();
            if (decayed) {
                log.log.trace("LOD memory below 80% budget; re-expanding radii", .{});
            }
            return;
        }

        if (self.memory_used_bytes <= budget_bytes) return; // 80-100% band: hold

        const Candidate = struct { key: LODRegionKey, distance_sq: i64 };
        var candidates = std.ArrayListUnmanaged(Candidate).empty;
        defer candidates.deinit(self.allocator);

        self.mutex.lock();
        defer self.mutex.unlock();

        const player = self.loadPlayerChunkPos();
        const active_lod_count = lod_chunk.activeLODCount(self.config);
        for (0..active_lod_count) |i| {
            var iter = self.regions[i].iterator();
            while (iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const chunk = entry.value_ptr.*;
                if (chunk.state != .renderable or chunk.isPinned()) continue;
                // Coarsest active LOD regions have no renderable parent fallback and are
                // intentionally excluded so eviction never opens horizon holes.
                const parent = key.parentKey() orelse continue;
                const parent_idx = @intFromEnum(parent.lod);
                const parent_chunk = self.regions[parent_idx].get(parent) orelse continue;
                if (parent_chunk.state != .renderable) continue;
                const bounds = key.chunkBounds();
                try candidates.append(self.allocator, .{ .key = key, .distance_sq = bounds.distanceSquaredToPoint(player.cx, player.cz) });
            }
        }

        std.mem.sort(Candidate, candidates.items, {}, struct {
            fn lt(_: void, a: Candidate, b: Candidate) bool {
                return a.distance_sq > b.distance_sq;
            }
        }.lt);

        var used = self.memory_used_bytes;
        var evicted_count: usize = 0;
        for (candidates.items) |candidate| {
            if (used <= budget_bytes) break;
            if (evicted_count >= MAX_MEMORY_EVICTIONS_PER_UPDATE) break;
            const idx = @intFromEnum(candidate.key.lod);
            const chunk = self.regions[idx].get(candidate.key) orelse continue;
            if (chunk.state != .renderable or chunk.isPinned()) continue;
            const mesh = self.meshes[idx].get(candidate.key);
            const bytes = regionMemoryBytes(chunk, mesh);
            self.noteRegionRemoved(candidate.key, chunk);
            if (mesh) |m| {
                self.queueMeshDeletion(m);
                _ = self.meshes[idx].remove(candidate.key);
            }
            chunk.deinit(self.allocator);
            self.allocator.destroy(chunk);
            _ = self.regions[idx].remove(candidate.key);
            used = if (bytes >= used) 0 else used - bytes;
            self.memory_used_bytes = used;
            self.stats.evictions += 1;
            evicted_count += 1;
        }

        // Any eviction means the active radii are too ambitious for the current
        // budget. Shrink finer bands immediately so evicted regions do not get
        // queued again next update. The coarsest horizon band is exempt so the
        // vista never develops holes.
        if (evicted_count > 0 or self.memory_used_bytes > budget_bytes) {
            const active = lod_chunk.activeLODCount(self.config);
            var grew = false;
            var i: usize = 1;
            while (i + 1 < active) : (i += 1) {
                if (self.radius_shrink_chunks[i] < 64) {
                    self.radius_shrink_chunks[i] += 1;
                    grew = true;
                }
            }
            if (grew) {
                log.log.warn("LOD memory pressure; evicted {} regions this update and shrank finer radii (shrink={any})", .{ evicted_count, self.radius_shrink_chunks });
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
                const mesh = entry.value_ptr.*;
                self.stats.mesh_count[i] += 1;
                self.stats.mesh_vertices[i] += mesh.vertex_count;
                mem_usage += mesh.capacity * @sizeOf(Vertex);
            }

            self.stats.gen_queue_depth[i] = @intCast(self.gen_queues[i].count());
            self.stats.upload_queue_depth[i] = @intCast(self.upload_queues[i].count());
        }

        self.stats.addMemory(mem_usage);
        self.stats.store_hits = self.cache_hits;
        self.stats.store_misses = self.cache_misses;
        self.stats.cache_hits = self.cache_hits;
        self.stats.cache_misses = self.cache_misses;
        self.memory_used_bytes = mem_usage;

        if (engine_core.envFlag("ZIGCRAFT_LOD_DIAG", false)) {
            const S = struct {
                var counter: u64 = 0;
            };
            S.counter += 1;
            if (S.counter % 120 == 1) {
                log.log.info("LOD_STATS_DIAG gen_q={any} upload_q={any} meshes={any} verts={any} cache_hits={} cache_misses={} cache_hit_rate={d:.2} mem_mb={} upload_failures={} store_hits={} store_misses={} evictions={} ingestion_backlog={} drawn={any} instances={any}", .{
                    self.stats.gen_queue_depth,
                    self.stats.upload_queue_depth,
                    self.stats.mesh_count,
                    self.stats.mesh_vertices,
                    self.stats.cache_hits,
                    self.stats.cache_misses,
                    self.stats.cacheHitRate(),
                    self.stats.memory_used_mb,
                    self.stats.upload_failures,
                    self.stats.store_hits,
                    self.stats.store_misses,
                    self.stats.evictions,
                    self.stats.ingestion_backlog,
                    self.stats.drawn,
                    self.stats.instances,
                });
            }
        }
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
        const player = self.loadPlayerChunkPos();
        const dist_sq = pointDistanceSquared(chunk_x, chunk_z, player.cx, player.cz);
        const radii = self.config.getRadii();

        const active_lod_count = lod_chunk.activeLODCount(self.config);
        for (0..active_lod_count) |i| {
            const radius_sq = @as(i64, radii[i]) * @as(i64, radii[i]);
            if (dist_sq <= radius_sq) return @enumFromInt(@as(u3, @intCast(i)));
        }

        return @enumFromInt(@as(u3, @intCast(active_lod_count - 1)));
    }

    /// Check if a position is within LOD range
    pub fn isInRange(self: *const Self, chunk_x: i32, chunk_z: i32) bool {
        const radii = self.config.getRadii();
        const max_radius = radii[lod_chunk.activeLODCount(self.config) - 1];
        const player = self.loadPlayerChunkPos();
        const dist_sq = pointDistanceSquared(chunk_x, chunk_z, player.cx, player.cz);
        return dist_sq <= @as(i64, max_radius) * @as(i64, max_radius);
    }

    /// Render all LOD meshes
    /// chunk_checker: Optional callback to check if regular chunks cover this region.
    ///                If all chunks in region are loaded, the LOD region is skipped.
    ///
    /// NOTE: Acquires a shared lock on LODManager. LODRenderer must NOT attempt to acquire
    /// a write lock on LODManager during rendering to avoid deadlocks.
    pub fn render(self: *Self, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, use_frustum: bool, max_distance_chunks: ?i32, layer: LODRenderLayer) void {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        self.renderer.render(&self.meshes, &self.regions, self.config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, layer, &self.stats);
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

        const active_lod_count = lod_chunk.activeLODCount(self.config);
        for (0..active_lod_count) |i| {
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
                if (storage.get(rem_key)) |chunk| {
                    self.noteRegionRemoved(rem_key, chunk);
                }
                if (meshes.fetchRemove(rem_key)) |mesh_entry| {
                    // Queue for deferred deletion to avoid waitIdle stutter
                    self.queueMeshDeletion(mesh_entry.value);
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
        const chunk_radius: i64 = @as(i64, self.config.getChunkRenderRadius());
        const radius_sq = chunk_radius * chunk_radius;
        const player = self.loadPlayerChunkPos();

        const min_cx = @divFloor(bounds.min_x, CHUNK_SIZE_X) - CHUNK_COVERAGE_PADDING;
        const min_cz = @divFloor(bounds.min_z, CHUNK_SIZE_Z) - CHUNK_COVERAGE_PADDING;
        const max_cx = @divFloor(bounds.max_x, CHUNK_SIZE_X) - 1 + CHUNK_COVERAGE_PADDING;
        const max_cz = @divFloor(bounds.max_z, CHUNK_SIZE_Z) - 1 + CHUNK_COVERAGE_PADDING;

        var cz = min_cz;
        while (cz <= max_cz) : (cz += 1) {
            var cx = min_cx;
            while (cx <= max_cx) : (cx += 1) {
                const dx: i64 = @as(i64, cx) - @as(i64, player.cx);
                const dz: i64 = @as(i64, cz) - @as(i64, player.cz);
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
        if (lod_idx >= LODLevel.count) return error.InvalidLODLevel;

        const meshes = &self.meshes[lod_idx];

        if (meshes.get(key)) |mesh| {
            return mesh;
        }

        const mesh = try self.allocator.create(LODMesh);
        errdefer self.allocator.destroy(mesh);
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
                switch (self.effectiveMeshPath(chunk.lod_level)) {
                    .heightfield => try mesh.buildFromSimplifiedData(data, bounds.min_x, bounds.min_z, self.atlas),
                    .column_spans => try mesh.buildFromColumnSpans(data, bounds.min_x, bounds.min_z, self.atlas),
                    .qem => {
                        const lod = chunk.lod_level;
                        const horizontal_detail = self.config.getHorizontalDetail(lod);
                        const detail_target = horizontal_detail * horizontal_detail;
                        const target = @max(self.config.getQEMTarget(lod), detail_target);
                        if (target == 0) {
                            try mesh.buildFromSimplifiedData(data, bounds.min_x, bounds.min_z, self.atlas);
                        } else {
                            try mesh.buildFromSimplifiedDataWithQEM(data, bounds.min_x, bounds.min_z, target, self.config.getQEMMinInputTriangles(), self.atlas);
                        }
                    },
                }
            },
            .full => {
                // LOD0 meshes handled by World, not LODManager
            },
            .empty => {
                // No data to build mesh from
            },
        }
    }

    fn effectiveMeshPath(self: *Self, lod: LODLevel) lod_chunk.LODMeshPath {
        // Far bands stay as high-resolution stepped block columns. LOD2 keeps
        // the richer span path so mid-distance cliffs/trees remain voxel-like
        // without turning the terrain into a smooth polygon surface.
        if (@intFromEnum(lod) >= @intFromEnum(LODLevel.lod3)) return .heightfield;
        if (lod == LODConfig.coarsestLOD()) return .heightfield;
        if (engine_core.envFlag("ZIGCRAFT_LOD_MESH_PATH_QEM", false)) return .qem;
        if (engine_core.envFlag("ZIGCRAFT_LOD_MESH_PATH_SPANS", false)) return .column_spans;
        return self.config.getMeshPath();
    }

    fn cacheKey(self: *const Self, key: LODRegionKey) lod_cache.Key {
        return .{
            .seed = self.generator.seed,
            .generator_identity_hash = self.generator.identity_hash,
            .generator_version = self.generator.version,
            .rx = key.rx,
            .rz = key.rz,
            .lod = key.lod,
        };
    }

    fn legacyCacheFilePath(self: *Self, save_dir_path: []const u8, key: lod_cache.Key) ![]u8 {
        const filename = try std.fmt.allocPrint(
            self.allocator,
            "lod_{}_{}_{}_{}_{}_{}.dat",
            .{ key.seed, key.generator_identity_hash, key.generator_version, key.rx, key.rz, @intFromEnum(key.lod) },
        );
        defer self.allocator.free(filename);
        return std.fs.path.join(self.allocator, &.{ save_dir_path, "lod_cache", filename });
    }

    fn logLegacyCacheNotice(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.logged_legacy_cache_notice) return;
        self.logged_legacy_cache_notice = true;
        log.log.warn("Using read-only legacy LOD cache fallback; new writes go to lod/ region store", .{});
    }

    fn cacheDirPathSnapshot(self: *Self) ?[]u8 {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();

        const cache_dir_path = self.cache_dir_path orelse return null;
        return self.allocator.dupe(u8, cache_dir_path) catch |err| {
            log.log.warn("LOD cache path snapshot allocation failed: {}", .{err});
            return null;
        };
    }

    fn cacheEnabled(self: *Self) bool {
        self.mutex.lockShared();
        defer self.mutex.unlockShared();
        return self.cache_dir_path != null;
    }

    fn readStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key) !?[]u8 {
        self.store_mutex.lock();
        defer self.store_mutex.unlock();
        return lod_store.readPayload(self.allocator, save_dir_path, cache_key);
    }

    fn writeStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key, bytes: []const u8) !void {
        self.mutex.lockShared();
        const store_size_cap_mb = self.config.getLODStoreSizeCapMB();
        self.mutex.unlockShared();

        self.store_mutex.lock();
        defer self.store_mutex.unlock();
        try lod_store.writePayload(self.allocator, save_dir_path, cache_key, bytes, store_size_cap_mb);
    }

    fn deleteStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key) void {
        self.store_mutex.lock();
        defer self.store_mutex.unlock();
        lod_store.deletePayload(self.allocator, save_dir_path, cache_key);
    }

    fn deleteStoreContainer(self: *Self, path: []const u8) void {
        self.store_mutex.lock();
        defer self.store_mutex.unlock();
        fs.cwd().deleteFile(path) catch |delete_err| {
            if (delete_err != error.FileNotFound) {
                log.log.warn("Failed to delete corrupt LOD store container '{s}': {}", .{ path, delete_err });
            }
        };
    }

    fn loadCachedSourceData(self: *Self, key: LODRegionKey) ?LODSimplifiedData {
        const save_dir_path = self.cacheDirPathSnapshot() orelse return null;
        defer self.allocator.free(save_dir_path);

        const cache_key = self.cacheKey(key);

        if (self.readStorePayload(save_dir_path, cache_key) catch |err| switch (err) {
            lod_store.StoreError.CorruptContainer => {
                const path = lod_store.containerPath(self.allocator, save_dir_path, cache_key) catch null;
                if (path) |container_path| {
                    defer self.allocator.free(container_path);
                    log.log.warn("Discarding corrupt LOD store container '{s}'", .{container_path});
                    self.deleteStoreContainer(container_path);
                }
                return null;
            },
            else => {
                log.log.warn("Failed to read LOD store for LOD{} ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
                return null;
            },
        }) |bytes| {
            defer self.allocator.free(bytes);
            return lod_cache.deserialize(bytes, cache_key, self.allocator) catch |err| {
                log.log.warn("Discarding corrupt LOD store payload LOD{} ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
                self.deleteStorePayload(save_dir_path, cache_key);
                return null;
            };
        }

        const path = self.legacyCacheFilePath(save_dir_path, cache_key) catch |err| {
            log.log.warn("LOD legacy cache path allocation failed: {}", .{err});
            return null;
        };
        defer self.allocator.free(path);

        const bytes = fs.cwd().readFileAlloc(path, self.allocator, 16 * 1024 * 1024) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => {
                log.log.warn("Failed to read legacy LOD cache '{s}': {}", .{ path, err });
                return null;
            },
        };
        defer self.allocator.free(bytes);
        self.logLegacyCacheNotice();

        return lod_cache.deserialize(bytes, cache_key, self.allocator) catch |err| {
            log.log.warn("Discarding corrupt legacy LOD cache '{s}': {}", .{ path, err });
            fs.cwd().deleteFile(path) catch |delete_err| {
                if (delete_err != error.FileNotFound) {
                    log.log.warn("Failed to delete corrupt legacy LOD cache '{s}': {}", .{ path, delete_err });
                }
            };
            return null;
        };
    }

    fn recordCacheHit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cache_hits += 1;
    }

    fn recordCacheMiss(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.cache_misses += 1;
    }

    fn saveCachedSourceData(self: *Self, key: LODRegionKey, data: *const LODSimplifiedData) void {
        const save_dir_path = self.cacheDirPathSnapshot() orelse return;
        defer self.allocator.free(save_dir_path);

        const cache_key = self.cacheKey(key);

        const bytes = lod_cache.serialize(data, cache_key, self.allocator) catch |err| {
            log.log.warn("Failed to serialize LOD{} cache ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
            return;
        };
        defer self.allocator.free(bytes);

        self.writeStorePayload(save_dir_path, cache_key, bytes) catch |err| {
            log.log.warn("Failed to write LOD{} store ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
        };
    }

    fn initCacheTestManager(allocator: std.mem.Allocator, cache_dir_path: []const u8) Self {
        return .{
            .allocator = allocator,
            .config = undefined,
            .regions = undefined,
            .meshes = undefined,
            .gen_queues = undefined,
            .lod_gen_pool = null,
            .upload_queues = undefined,
            .transition_queue = .empty,
            .player_cx = std.atomic.Value(i32).init(0),
            .player_cz = std.atomic.Value(i32).init(0),
            .next_job_token = 1,
            .stats = .{},
            .cache_hits = 0,
            .cache_misses = 0,
            .mutex = .{},
            .gpu_bridge = undefined,
            .generator = .{
                .ptr = undefined,
                .generate_heightmap_only = undefined,
                .maybe_recenter_cache = undefined,
                .seed = 42,
                .identity_hash = 99,
                .version = 7,
            },
            .atlas = undefined,
            .paused = false,
            .stop_flag = std.atomic.Value(bool).init(false),
            .memory_used_bytes = 0,
            .update_tick = 0,
            .deletion_queue = .empty,
            .deletion_timer = 0,
            .renderer = undefined,
            .cache_dir_path = cache_dir_path,
            .logged_legacy_cache_notice = false,
            .store_mutex = .{},
            .cleanup_covered_regions = true,
            .pending_ingestions = .empty,
            .edit_dirty = ChunkCoordSet.init(allocator),
            .ingestion_mutex = .{},
            .chunk_resolver = null,
            .edit_cooldown = 0.0,
            .ingestion_drain_per_frame = 4,
            .radius_shrink_chunks = [_]i32{0} ** LODLevel.count,
        };
    }

    /// Worker pool callback for LOD tasks (generation and meshing)
    fn processLODJob(ctx: *anyopaque, job: Job) void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        const lod_level: LODLevel = @enumFromInt(job.data.chunk.lod_level);
        const key = LODRegionKey{
            .rx = job.data.chunk.x,
            .rz = job.data.chunk.z,
            .lod = lod_level,
        };

        const lod_idx = @intFromEnum(lod_level);

        // Phase 1: Acquire lock, validate job, pin chunk
        self.mutex.lock();
        const storage = &self.regions[lod_idx];

        const chunk = storage.get(key) orelse {
            self.mutex.unlock();
            return;
        };

        // Stale job check (too far from player)
        const player = self.loadPlayerChunkPos();
        const radii = self.config.getRadii();
        const radius = radii[lod_idx];
        const vertical_span_budget = self.config.getVerticalSpanBudget();
        const mesh_path = self.effectiveMeshPath(lod_level);
        const job_key = LODRegionKey{
            .rx = job.data.chunk.x,
            .rz = job.data.chunk.z,
            .lod = lod_level,
        };

        if (!job_key.chunkBounds().intersectsRadius(player.cx, player.cz, radius)) {
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
                    const cache_enabled = self.cacheEnabled();
                    const want_spans = vertical_span_budget > 0 and mesh_path == .column_spans;
                    var cached_data = if (cache_enabled) self.loadCachedSourceData(key) else null;
                    if (cached_data) |*cached| {
                        if (want_spans and !cached.hasVerticalSpans()) {
                            cached.deinit();
                            cached_data = null;
                        }
                    }
                    const data = if (cached_data) |cached| blk: {
                        self.recordCacheHit();
                        break :blk cached;
                    } else blk: {
                        if (cache_enabled) self.recordCacheMiss();
                        var generated = if (want_spans)
                            LODSimplifiedData.initWithVerticalSpans(self.allocator, lod_level) catch {
                                new_state = .missing;
                                self.mutex.lock();
                                if (chunk.job_token == job.data.chunk.job_token) chunk.state = new_state;
                                chunk.unpin();
                                self.mutex.unlock();
                                return;
                            }
                        else
                            LODSimplifiedData.init(self.allocator, lod_level) catch {
                                new_state = .missing;
                                self.mutex.lock();
                                if (chunk.job_token == job.data.chunk.job_token) chunk.state = new_state;
                                chunk.unpin();
                                self.mutex.unlock();
                                return;
                            };

                        // Generate heightmap data (expensive, done without lock).
                        // Pass the stop flag so teardown/pause can interrupt the
                        // multi-second coarse-LOD heightmap loop instead of
                        // forcing the worker-join to block until it finishes.
                        self.generator.generateHeightmapOnly(&generated, chunk.region_x, chunk.region_z, lod_level, &self.stop_flag);

                        // If generation was aborted, discard the partial data
                        // and leave the chunk in .missing so it re-generates later.
                        if (self.stop_flag.load(.acquire)) {
                            generated.deinit();
                            new_state = .missing;
                            self.mutex.lock();
                            if (chunk.job_token == job.data.chunk.job_token) chunk.state = new_state;
                            chunk.unpin();
                            self.mutex.unlock();
                            return;
                        }

                        self.saveCachedSourceData(key, &generated);
                        break :blk generated;
                    };

                    // Acquire lock to update chunk data
                    self.mutex.lock();
                    chunk.data = .{ .simplified = data };
                    chunk.updateHeightBoundsFromData();
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
                    self.mutex.lock();
                    if (chunk.job_token == job.data.chunk.job_token) chunk.state = new_state;
                    chunk.unpin();
                    self.mutex.unlock();
                    return;
                };
                success = true;
                new_state = .mesh_ready;
            },
            else => unreachable,
        }

        // Phase 3: Acquire lock briefly to update state
        self.mutex.lock();
        if (success and chunk.job_token == job.data.chunk.job_token) {
            chunk.state = new_state;
        }
        chunk.unpin();
        self.mutex.unlock();
    }
};

const testing = std.testing;

test "LODManager cache helpers save and reload source data" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var manager = LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    const key = LODRegionKey{ .rx = 2, .rz = -3, .lod = .lod1 };

    var data = try LODSimplifiedData.init(testing.allocator, .lod1);
    defer data.deinit();
    data.setColumn(1, 1, 72.0, .forest, .{
        .surface = .grass,
        .subsurface = .dirt,
        .foundation = .stone,
    }, 0xFF112233, .empty, .daylight, .empty);

    manager.saveCachedSourceData(key, &data);

    const store_path = try lod_store.containerPath(testing.allocator, save_dir_path, manager.cacheKey(key));
    defer testing.allocator.free(store_path);
    fs.cwd().access(store_path, .{}) catch return error.ExpectedStoreContainer;

    var loaded = manager.loadCachedSourceData(key) orelse return error.ExpectedCacheHit;
    defer loaded.deinit();

    const idx = 1 + data.width;
    try testing.expectEqual(data.heightmap[idx], loaded.heightmap[idx]);
    try testing.expectEqual(data.biomes[idx], loaded.biomes[idx]);
    try testing.expectEqual(data.material_layers[idx].foundation, loaded.material_layers[idx].foundation);
}

test "LODManager cache helpers delete corrupt cache files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var manager = LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod2 };
    const legacy_dir = try fs.path.join(testing.allocator, &.{ save_dir_path, "lod_cache" });
    defer testing.allocator.free(legacy_dir);
    try fs.cwd().makePath(legacy_dir);
    const path = try manager.legacyCacheFilePath(save_dir_path, manager.cacheKey(key));
    defer testing.allocator.free(path);

    const file = try fs.cwd().createFile(path, .{ .truncate = true });
    try file.writeAll(&.{ 0, 1, 2, 3 });
    file.close();

    try testing.expect(manager.loadCachedSourceData(key) == null);
    try testing.expectError(error.FileNotFound, fs.cwd().openFile(path, .{}));
}

test "LODManager enableCache deletes stale generator-keyed store and writes live header" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    try lod_store.writeHeader(testing.allocator, save_dir_path, .{
        .seed = 42,
        .generator_identity_hash = 1234,
        .generator_version = 1,
    });
    const stale_key = lod_cache.Key{ .seed = 42, .generator_identity_hash = 1234, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod1 };
    try lod_store.writePayload(testing.allocator, save_dir_path, stale_key, "stale", lod_store.DEFAULT_STORE_SIZE_CAP_MB);

    var manager = LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    manager.cache_dir_path = null;
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_dir_path) |path| testing.allocator.free(path);

    try testing.expect((try lod_store.readPayload(testing.allocator, save_dir_path, stale_key)) == null);
    const header = (try lod_store.readHeader(testing.allocator, save_dir_path)).?;
    try testing.expectEqual(@as(u64, 42), header.seed);
    try testing.expectEqual(@as(u64, 99), header.generator_identity_hash);
    try testing.expectEqual(@as(u32, 7), header.generator_version);
}

test "LODManager enableCache deletes stale data-version store" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    try lod_store.writeHeader(testing.allocator, save_dir_path, .{
        .seed = 42,
        .generator_identity_hash = 99,
        .generator_version = 7,
        .lod_data_version = lod_cache.CACHE_VERSION - 1,
    });
    const stale_key = lod_cache.Key{ .seed = 42, .generator_identity_hash = 99, .generator_version = 7, .rx = 0, .rz = 0, .lod = .lod1 };
    try lod_store.writePayload(testing.allocator, save_dir_path, stale_key, "stale", lod_store.DEFAULT_STORE_SIZE_CAP_MB);

    var manager = LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    manager.cache_dir_path = null;
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_dir_path) |path| testing.allocator.free(path);

    try testing.expect((try lod_store.readPayload(testing.allocator, save_dir_path, stale_key)) == null);
    const header = (try lod_store.readHeader(testing.allocator, save_dir_path)).?;
    try testing.expectEqual(lod_cache.CACHE_VERSION, header.lod_data_version);
}

fn initEvictionTestManager(allocator: std.mem.Allocator, config: *LODConfig) !LODManager {
    var manager = LODManager.initCacheTestManager(allocator, "");
    manager.config = config.interface();
    for (0..LODLevel.count) |i| {
        manager.regions[i] = RegionMap.init(allocator);
        manager.meshes[i] = MeshMap.init(allocator);
        manager.upload_queues[i] = try RingBuffer(*LODChunk).init(allocator, 4);
    }
    var bridge_ctx: u8 = 0;
    manager.gpu_bridge = .{
        .on_upload = struct {
            fn f(_: *LODMesh, _: *anyopaque) @import("engine-rhi").RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *LODMesh, _: *anyopaque) void {}
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(&bridge_ctx),
    };
    return manager;
}

fn deinitEvictionTestManager(manager: *LODManager) void {
    for (0..LODLevel.count) |i| {
        var region_iter = manager.regions[i].iterator();
        while (region_iter.next()) |entry| {
            entry.value_ptr.*.deinit(manager.allocator);
            manager.allocator.destroy(entry.value_ptr.*);
        }
        manager.regions[i].deinit();

        var mesh_iter = manager.meshes[i].iterator();
        while (mesh_iter.next()) |entry| {
            if (entry.value_ptr.*.pending_vertices) |pending| {
                manager.allocator.free(pending);
            }
            manager.allocator.destroy(entry.value_ptr.*);
        }
        manager.meshes[i].deinit();
        manager.upload_queues[i].deinit();
    }
    for (manager.deletion_queue.items) |mesh| {
        manager.allocator.destroy(mesh);
    }
    manager.deletion_queue.deinit(manager.allocator);
    manager.edit_dirty.deinit();
}

fn putTestRegion(manager: *LODManager, key: LODRegionKey, state: LODState) !*LODChunk {
    const chunk = try manager.allocator.create(LODChunk);
    chunk.* = LODChunk.init(key.rx, key.rz, key.lod);
    chunk.state = state;
    try manager.regions[@intFromEnum(key.lod)].put(key, chunk);
    return chunk;
}

fn putTestMesh(manager: *LODManager, key: LODRegionKey, capacity: u32) !*LODMesh {
    const mesh = try manager.allocator.create(LODMesh);
    mesh.* = LODMesh.init(manager.allocator, key.lod);
    mesh.ready = true;
    mesh.vertex_count = capacity;
    mesh.capacity = capacity;
    try manager.meshes[@intFromEnum(key.lod)].put(key, mesh);
    return mesh;
}

fn putTestPendingMesh(manager: *LODManager, key: LODRegionKey, vertex_count: usize) !*LODMesh {
    const mesh = try manager.allocator.create(LODMesh);
    mesh.* = LODMesh.init(manager.allocator, key.lod);
    mesh.pending_vertices = try manager.allocator.alloc(Vertex, vertex_count);
    try manager.meshes[@intFromEnum(key.lod)].put(key, mesh);
    return mesh;
}

const UploadMock = struct {
    allocator: std.mem.Allocator,
    calls: u32 = 0,
    fail_with_pressure: bool = false,

    fn bridge(self: *UploadMock) LODGPUBridge {
        return .{
            .on_upload = upload,
            .on_destroy = destroy,
            .on_wait_idle = waitIdle,
            .ctx = @ptrCast(self),
        };
    }

    fn upload(mesh: *LODMesh, ctx: *anyopaque) @import("engine-rhi").RhiError!void {
        const self: *UploadMock = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.fail_with_pressure) return error.OutOfMemory;
        if (mesh.pending_vertices) |pending| {
            mesh.vertex_count = @intCast(pending.len);
            mesh.opaque_vertex_count = @intCast(pending.len);
            mesh.ready = true;
            self.allocator.free(pending);
            mesh.pending_vertices = null;
        }
    }

    fn destroy(_: *LODMesh, _: *anyopaque) void {}
    fn waitIdle(_: *anyopaque) void {}
};

test "LODManager upload budget defers remaining queued meshes" {
    var config = LODConfig{ .max_uploads_per_frame = 8 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var mock = UploadMock{ .allocator = testing.allocator };
    manager.gpu_bridge = mock.bridge();

    const first_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const second_key = LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod1 };
    const first = try putTestRegion(&manager, first_key, .uploading);
    const second = try putTestRegion(&manager, second_key, .uploading);
    _ = try putTestPendingMesh(&manager, first_key, 1);
    _ = try putTestPendingMesh(&manager, second_key, 1);
    try manager.upload_queues[1].push(first);
    try manager.upload_queues[1].push(second);

    manager.processUploadsWithBudget(@sizeOf(Vertex));

    try testing.expectEqual(@as(u32, 1), mock.calls);
    try testing.expectEqual(LODState.renderable, first.state);
    try testing.expectEqual(LODState.uploading, second.state);
    try testing.expectEqual(@as(usize, 1), manager.upload_queues[1].count());
}

test "LODManager staging pressure failure stops upload sweep" {
    var config = LODConfig{ .max_uploads_per_frame = 8 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var mock = UploadMock{ .allocator = testing.allocator, .fail_with_pressure = true };
    manager.gpu_bridge = mock.bridge();

    const first_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const second_key = LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod1 };
    const first = try putTestRegion(&manager, first_key, .uploading);
    const second = try putTestRegion(&manager, second_key, .uploading);
    _ = try putTestPendingMesh(&manager, first_key, 1);
    _ = try putTestPendingMesh(&manager, second_key, 1);
    try manager.upload_queues[1].push(first);
    try manager.upload_queues[1].push(second);

    manager.processUploadsWithBudget(DEFAULT_LOD_UPLOAD_BUDGET_BYTES);

    try testing.expectEqual(@as(u32, 1), mock.calls);
    try testing.expectEqual(LODState.uploading, first.state);
    try testing.expectEqual(LODState.uploading, second.state);
    try testing.expectEqual(@as(usize, 2), manager.upload_queues[1].count());
    try testing.expectEqual(@as(u32, 1), manager.stats.upload_failures);
}

test "LODManager ready child counters update on renderable transitions and removal" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const child_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const child = try putTestRegion(&manager, child_key, .mesh_ready);
    _ = try putTestMesh(&manager, child_key, 1);
    manager.markRegionRenderable(child_key, child);

    const parent_key = child_key.parentKey().?;
    const parent = try putTestRegion(&manager, parent_key, .mesh_ready);
    manager.markRegionRenderable(parent_key, parent);
    try testing.expectEqual(@as(u8, 1), parent.ready_children);

    manager.noteRegionRemoved(child_key, child);
    try testing.expectEqual(@as(u8, 0), parent.ready_children);
}

test "LODManager demoting renderable child clears parent coverage" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const child_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const child = try putTestRegion(&manager, child_key, .mesh_ready);
    _ = try putTestMesh(&manager, child_key, 1);
    manager.markRegionRenderable(child_key, child);

    const parent_key = child_key.parentKey().?;
    const parent = try putTestRegion(&manager, parent_key, .mesh_ready);
    manager.markRegionRenderable(parent_key, parent);
    try testing.expectEqual(@as(u8, 1), parent.ready_children);

    manager.demoteRegionForRemesh(child_key, child);

    try testing.expectEqual(LODState.generated, child.state);
    try testing.expectEqual(@as(u8, 0), parent.ready_children);
}

test "LODManager ready child counters ignore renderable children without geometry" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const child_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const child = try putTestRegion(&manager, child_key, .mesh_ready);
    _ = try putTestMesh(&manager, child_key, 0);
    manager.markRegionRenderable(child_key, child);

    const parent_key = child_key.parentKey().?;
    const parent = try putTestRegion(&manager, parent_key, .mesh_ready);
    manager.markRegionRenderable(parent_key, parent);

    try testing.expectEqual(@as(u8, 0), parent.ready_children);
}

test "LODManager memory budget eviction skips unsafe regions and evicts farthest first" {
    var config = LODConfig{ .memory_budget_mb = 1 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const budget_bytes = @as(usize, config.memory_budget_mb) * 1024 * 1024;
    const eviction_bytes = 600 * 1024;
    const mesh_capacity: u32 = @intCast(@max(eviction_bytes / @sizeOf(Vertex), 1));
    const mesh_bytes = @as(usize, mesh_capacity) * @sizeOf(Vertex);

    const near_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const far_key = LODRegionKey{ .rx = 20, .rz = 0, .lod = .lod1 };
    const pinned_key = LODRegionKey{ .rx = 40, .rz = 0, .lod = .lod1 };
    const no_parent_key = LODRegionKey{ .rx = 60, .rz = 0, .lod = .lod1 };
    const in_flight_key = LODRegionKey{ .rx = 80, .rz = 0, .lod = .lod1 };

    _ = try putTestRegion(&manager, near_key.parentKey().?, .renderable);
    _ = try putTestRegion(&manager, far_key.parentKey().?, .renderable);
    _ = try putTestRegion(&manager, pinned_key.parentKey().?, .renderable);
    _ = try putTestRegion(&manager, in_flight_key.parentKey().?, .renderable);

    _ = try putTestRegion(&manager, near_key, .renderable);
    _ = try putTestRegion(&manager, far_key, .renderable);
    const pinned_chunk = try putTestRegion(&manager, pinned_key, .renderable);
    pinned_chunk.pin();
    _ = try putTestRegion(&manager, no_parent_key, .renderable);
    _ = try putTestRegion(&manager, in_flight_key, .generating);

    _ = try putTestMesh(&manager, near_key, mesh_capacity);
    _ = try putTestMesh(&manager, far_key, mesh_capacity);
    _ = try putTestMesh(&manager, pinned_key, mesh_capacity);
    _ = try putTestMesh(&manager, no_parent_key, mesh_capacity);
    _ = try putTestMesh(&manager, in_flight_key, mesh_capacity);

    manager.memory_used_bytes = budget_bytes + mesh_bytes;
    try manager.enforceMemoryBudget();

    try testing.expect(!manager.regions[1].contains(far_key));
    try testing.expect(!manager.meshes[1].contains(far_key));
    try testing.expect(manager.regions[1].contains(near_key));
    try testing.expect(manager.regions[1].contains(pinned_key));
    try testing.expect(manager.regions[1].contains(no_parent_key));
    try testing.expect(manager.regions[1].contains(in_flight_key));
    try testing.expect(manager.memory_used_bytes <= budget_bytes);
    try testing.expectEqual(@as(u32, 1), manager.stats.evictions);
    try testing.expectEqual(@as(u32, 1), manager.deletion_queue.items.len);
}
