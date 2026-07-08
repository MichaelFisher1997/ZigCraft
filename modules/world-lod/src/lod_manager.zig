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
const lod_manager_context = @import("lod_manager_context.zig");
const lod_manager_core = @import("lod_manager_core_ops.zig");
const lod_manager_cache_ops = @import("lod_manager_cache_ops.zig");
const lod_manager_ingestion_ops = @import("lod_manager_ingestion_ops.zig");
const lod_manager_generation_ops = @import("lod_manager_generation_ops.zig");
const lod_manager_upload_ops = @import("lod_manager_upload_ops.zig");
const lod_manager_eviction_ops = @import("lod_manager_eviction_ops.zig");
const LODColumnProvenance = world_core.LODColumnProvenance;
const ChunkCoordKey = lod_manager_context.ChunkCoordKey;
const ChunkCoordKeyContext = lod_manager_context.ChunkCoordKeyContext;
const ChunkCoordSet = std.HashMap(ChunkCoordKey, void, ChunkCoordKeyContext, std.hash_map.default_max_load_percentage);
const PendingIngestion = lod_manager_context.PendingIngestion;
const PlayerChunkPos = lod_manager_context.PlayerChunkPos;
pub const ChunkResolver = lod_manager_context.ChunkResolver;
const MAX_LOD_REGIONS = lod_manager_context.MAX_LOD_REGIONS;

/// LOD transition request
const LODTransition = struct {
    region_key: LODRegionKey,
    target_lod: LODLevel,
    priority: i32,
};

pub const LODCacheStore = struct {
    cache_dir_path: ?[]const u8 = null,
    logged_legacy_cache_notice: bool = false,
    store_mutex: sync.Mutex = .{},
};

pub const LODIngestionQueue = struct {
    pending_ingestions: std.ArrayListUnmanaged(PendingIngestion) = .empty,
    edit_dirty: ChunkCoordSet,
    mutex: sync.Mutex = .{},
    chunk_resolver: ?ChunkResolver = null,
    edit_cooldown: f32 = 0.0,
    drain_per_frame: u32 = 4,

    /// Constructs an LOD manager through `init`.
    /// The manager owns scheduling, cache, mesh, and upload state until `deinit`.
    pub fn init(allocator: std.mem.Allocator) LODIngestionQueue {
        return .{ .edit_dirty = ChunkCoordSet.init(allocator) };
    }

    /// Releases LOD manager queues, caches, meshes, and worker-owned resources.
    /// Call after pending LOD work has been quiesced or made safe to discard.
    pub fn deinit(self: *LODIngestionQueue, allocator: std.mem.Allocator) void {
        self.pending_ingestions.deinit(allocator);
        self.edit_dirty.deinit();
    }
};

pub const LODMeshDisposalQueue = struct {
    queue: std.ArrayListUnmanaged(*LODMesh) = .empty,
    timer: f32 = 0,
};

pub const LODMemoryGovernor = struct {
    used_bytes: usize = 0,
    radius_shrink_chunks: [LODLevel.count]i32 = [_]i32{0} ** LODLevel.count,
};

pub const LODJobDispatcher = struct {
    queues: [LODLevel.count]*JobQueue,
    worker_pool: ?*WorkerPool = null,
    next_token: u32 = 1,
    stop_flag: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
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

    // LOD job queues, worker pool, tokens, and teardown signaling.
    job_dispatcher: LODJobDispatcher,

    // Upload queues per LOD level
    upload_queues: [LODLevel.count]RingBuffer(*LODChunk),

    // Transition queue for LOD upgrades/downgrades
    transition_queue: std.ArrayListUnmanaged(LODTransition),

    // Current player position (chunk coords), read by worker threads for stale-job checks.
    player_cx: std.atomic.Value(i32),
    player_cz: std.atomic.Value(i32),

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

    // Memory tracking and pressure hysteresis.
    memory_governor: LODMemoryGovernor,

    // Performance tracking for throttling
    update_tick: u32 = 0,

    // Deferred mesh deletion queue (Vulkan optimization)
    mesh_disposal: LODMeshDisposalQueue,

    // Type-erased renderer interface (replaces direct LODRenderer(RHI) field)
    renderer: LODRenderInterface,

    // Optional source-data persistence store.
    cache_store: LODCacheStore,

    // Keep cleanup behavior testable, but allow the live world to opt out.
    cleanup_covered_regions: bool = true,

    // -- Chunk-derived LOD ingestion (issue #752 Phase 2) --
    // Pending chunk ingestions whose containing LOD region did not yet have
    // source data when the chunk finished generating/loading. Drained from
    // update() once the regions appear.
    ingestion_queue: LODIngestionQueue,

    // Callback type to check if a regular chunk is loaded and renderable
    pub const ChunkChecker = lod_gpu.ChunkChecker;

    // ----------------------------------------------------------------------
    // Chunk-derived LOD ingestion (issue #752 Phase 2)
    // ----------------------------------------------------------------------

    /// Initialize the LOD manager facade and its extracted operation state.
    pub fn init(allocator: std.mem.Allocator, config: ILODConfig, gpu_bridge: LODGPUBridge, render_iface: LODRenderInterface, generator: LODGenerator, atlas: *const TextureAtlas) !*Self {
        return lod_manager_core.init(allocator, config, gpu_bridge, render_iface, generator, atlas);
    }

    /// Test-only lightweight manager state. Cache ownership starts disabled;
    /// tests that need persistence should call enableCache() and free it after.
    pub fn initCacheTestManager(allocator: std.mem.Allocator, cache_dir_path: []const u8) Self {
        return lod_manager_cache_ops.initCacheTestManager(allocator, cache_dir_path);
    }

    /// Updates LOD manager lifecycle or scheduling state through `storePlayerChunkPos`.
    /// Call from the world/update thread that owns the manager.
    pub fn storePlayerChunkPos(self: *Self, cx: i32, cz: i32) void {
        return lod_manager_core.storePlayerChunkPos(self, cx, cz);
    }

    /// Updates LOD manager lifecycle or scheduling state through `loadPlayerChunkPos`.
    /// Call from the world/update thread that owns the manager.
    pub fn loadPlayerChunkPos(self: *const Self) PlayerChunkPos {
        return lod_manager_core.loadPlayerChunkPos(self);
    }

    /// Releases LOD manager queues, caches, meshes, and worker-owned resources.
    /// Call after pending LOD work has been quiesced or made safe to discard.
    pub fn deinit(self: *Self) void {
        return lod_manager_core.deinit(self);
    }

    /// Updates LOD manager lifecycle or scheduling state through `update`.
    /// Call from the world/update thread that owns the manager.
    pub fn update(self: *Self, player_pos: Vec3, player_velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
        return lod_manager_core.update(self, player_pos, player_velocity, chunk_checker, checker_ctx);
    }

    /// Queries LOD manager state via `getStats`.
    /// This does not mutate scheduling state except for diagnostics explicitly documented by the implementation.
    pub fn getStats(self: *Self) LODStats {
        return lod_manager_core.getStats(self);
    }

    /// Updates LOD manager lifecycle or scheduling state through `pause`.
    /// Call from the world/update thread that owns the manager.
    pub fn pause(self: *Self) void {
        return lod_manager_core.pause(self);
    }

    /// Updates LOD manager lifecycle or scheduling state through `unpause`.
    /// Call from the world/update thread that owns the manager.
    pub fn unpause(self: *Self) void {
        return lod_manager_core.unpause(self);
    }

    /// Queries LOD manager state via `getLODForDistance`.
    /// This does not mutate scheduling state except for diagnostics explicitly documented by the implementation.
    pub fn getLODForDistance(self: *const Self, chunk_x: i32, chunk_z: i32) LODLevel {
        return lod_manager_core.getLODForDistance(self, chunk_x, chunk_z);
    }

    /// Queries LOD manager state via `isInRange`.
    /// This does not mutate scheduling state except for diagnostics explicitly documented by the implementation.
    pub fn isInRange(self: *const Self, chunk_x: i32, chunk_z: i32) bool {
        return lod_manager_core.isInRange(self, chunk_x, chunk_z);
    }

    /// Renders currently renderable LOD regions through the configured renderer.
    /// Generation and upload queues are not drained by this call.
    pub fn render(self: *Self, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, use_frustum: bool, max_distance_chunks: ?i32, layer: LODRenderLayer) void {
        return lod_manager_core.render(self, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, layer);
    }

    /// Manages persistent LOD cache data through `enableCache`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn enableCache(self: *Self, save_dir_path: []const u8) !void {
        return lod_manager_cache_ops.enableCache(self, save_dir_path);
    }

    /// Manages persistent LOD cache data through `flushDirtyStores`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn flushDirtyStores(self: *Self) void {
        return lod_manager_cache_ops.flushDirtyStores(self);
    }

    /// Manages persistent LOD cache data through `cacheKey`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn cacheKey(self: *const Self, key: LODRegionKey) lod_cache.Key {
        return lod_manager_cache_ops.cacheKey(self, key);
    }

    /// Manages persistent LOD cache data through `legacyCacheFilePath`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn legacyCacheFilePath(self: *Self, save_dir_path: []const u8, key: lod_cache.Key) ![]u8 {
        return lod_manager_cache_ops.legacyCacheFilePath(self, save_dir_path, key);
    }

    /// Manages persistent LOD cache data through `logLegacyCacheNotice`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn logLegacyCacheNotice(self: *Self) void {
        return lod_manager_cache_ops.logLegacyCacheNotice(self);
    }

    /// Manages persistent LOD cache data through `cacheDirPathSnapshot`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn cacheDirPathSnapshot(self: *Self) ?[]u8 {
        return lod_manager_cache_ops.cacheDirPathSnapshot(self);
    }

    /// Manages persistent LOD cache data through `cacheEnabled`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn cacheEnabled(self: *Self) bool {
        return lod_manager_cache_ops.cacheEnabled(self);
    }

    /// Manages persistent LOD cache data through `readStorePayload`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn readStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key) !?[]u8 {
        return lod_manager_cache_ops.readStorePayload(self, save_dir_path, cache_key);
    }

    /// Manages persistent LOD cache data through `writeStorePayload`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn writeStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key, bytes: []const u8) !void {
        return lod_manager_cache_ops.writeStorePayload(self, save_dir_path, cache_key, bytes);
    }

    /// Manages persistent LOD cache data through `deleteStorePayload`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn deleteStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key) void {
        return lod_manager_cache_ops.deleteStorePayload(self, save_dir_path, cache_key);
    }

    /// Manages persistent LOD cache data through `deleteStoreContainer`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn deleteStoreContainer(self: *Self, path: []const u8) void {
        return lod_manager_cache_ops.deleteStoreContainer(self, path);
    }

    /// Manages persistent LOD cache data through `loadCachedSourceData`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn loadCachedSourceData(self: *Self, key: LODRegionKey) ?LODSimplifiedData {
        return lod_manager_cache_ops.loadCachedSourceData(self, key);
    }

    /// Manages persistent LOD cache data through `recordCacheHit`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn recordCacheHit(self: *Self) void {
        return lod_manager_cache_ops.recordCacheHit(self);
    }

    /// Manages persistent LOD cache data through `recordCacheMiss`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn recordCacheMiss(self: *Self) void {
        return lod_manager_cache_ops.recordCacheMiss(self);
    }

    /// Manages persistent LOD cache data through `saveCachedSourceData`.
    /// Cache paths and payloads are owned by the manager; IO failures are reported or recorded by the caller path.
    pub fn saveCachedSourceData(self: *Self, key: LODRegionKey, data: *const LODSimplifiedData) void {
        return lod_manager_cache_ops.saveCachedSourceData(self, key, data);
    }

    /// Updates LOD manager lifecycle or scheduling state through `setChunkResolver`.
    /// Call from the world/update thread that owns the manager.
    pub fn setChunkResolver(self: *Self, resolver: ChunkResolver) void {
        return lod_manager_ingestion_ops.setChunkResolver(self, resolver);
    }

    /// Updates LOD manager lifecycle or scheduling state through `ingestChunk`.
    /// Call from the world/update thread that owns the manager.
    pub fn ingestChunk(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance) void {
        return lod_manager_ingestion_ops.ingestChunk(self, cx, cz, chunk, provenance);
    }

    /// Updates LOD manager lifecycle or scheduling state through `requestIngestion`.
    /// Call from the world/update thread that owns the manager.
    pub fn requestIngestion(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance) void {
        return lod_manager_ingestion_ops.requestIngestion(self, cx, cz, provenance);
    }

    /// Records LOD manager bookkeeping via `markChunkEdited`.
    /// Used to keep cache, transition, and readiness state consistent with world edits.
    pub fn markChunkEdited(self: *Self, cx: i32, cz: i32) void {
        return lod_manager_ingestion_ops.markChunkEdited(self, cx, cz);
    }

    /// Updates LOD manager lifecycle or scheduling state through `applyIngestionToRegions`.
    /// Call from the world/update thread that owns the manager.
    pub fn applyIngestionToRegions(self: *Self, cx: i32, cz: i32, chunk: *const Chunk, provenance: LODColumnProvenance) u8 {
        return lod_manager_ingestion_ops.applyIngestionToRegions(self, cx, cz, chunk, provenance);
    }

    /// Records LOD manager bookkeeping via `recordPendingLocked`.
    /// Used to keep cache, transition, and readiness state consistent with world edits.
    pub fn recordPendingLocked(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance, mask: u8) void {
        return lod_manager_ingestion_ops.recordPendingLocked(self, cx, cz, provenance, mask);
    }

    /// Updates LOD manager lifecycle or scheduling state through `rerecordPending`.
    /// Call from the world/update thread that owns the manager.
    pub fn rerecordPending(self: *Self, cx: i32, cz: i32, provenance: LODColumnProvenance, mask: u8, ttl: u16) void {
        return lod_manager_ingestion_ops.rerecordPending(self, cx, cz, provenance, mask, ttl);
    }

    /// Updates LOD manager lifecycle or scheduling state through `decayPendingLocked`.
    /// Call from the world/update thread that owns the manager.
    pub fn decayPendingLocked(self: *Self) void {
        return lod_manager_ingestion_ops.decayPendingLocked(self);
    }

    /// Advances LOD work scheduling through `drainPendingIngestions`.
    /// May enqueue generation, upload, deletion, or state-transition work for later frames.
    pub fn drainPendingIngestions(self: *Self) void {
        return lod_manager_ingestion_ops.drainPendingIngestions(self);
    }

    /// Updates LOD manager lifecycle or scheduling state through `flushEditedChunks`.
    /// Call from the world/update thread that owns the manager.
    pub fn flushEditedChunks(self: *Self) void {
        return lod_manager_ingestion_ops.flushEditedChunks(self);
    }

    /// Advances LOD work scheduling through `queueLODRegions`.
    /// May enqueue generation, upload, deletion, or state-transition work for later frames.
    pub fn queueLODRegions(self: *Self, lod: LODLevel, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
        return lod_manager_generation_ops.queueLODRegions(self, lod, velocity, chunk_checker, checker_ctx);
    }

    /// Advances LOD work scheduling through `processQueuedGenerations`.
    /// May enqueue generation, upload, deletion, or state-transition work for later frames.
    pub fn processQueuedGenerations(self: *Self, velocity: Vec3) !void {
        return lod_manager_generation_ops.processQueuedGenerations(self, velocity);
    }

    /// Advances LOD work scheduling through `processStateTransitions`.
    /// May enqueue generation, upload, deletion, or state-transition work for later frames.
    pub fn processStateTransitions(self: *Self, velocity: Vec3) !void {
        return lod_manager_generation_ops.processStateTransitions(self, velocity);
    }

    /// Queries LOD manager state via `getOrCreateMesh`.
    /// This does not mutate scheduling state except for diagnostics explicitly documented by the implementation.
    pub fn getOrCreateMesh(self: *Self, key: LODRegionKey) !*LODMesh {
        return lod_manager_generation_ops.getOrCreateMesh(self, key);
    }

    /// Updates LOD manager lifecycle or scheduling state through `buildMeshForChunk`.
    /// Call from the world/update thread that owns the manager.
    pub fn buildMeshForChunk(self: *Self, chunk: *LODChunk) !void {
        return lod_manager_generation_ops.buildMeshForChunk(self, chunk);
    }

    /// Updates LOD manager lifecycle or scheduling state through `effectiveMeshPath`.
    /// Call from the world/update thread that owns the manager.
    pub fn effectiveMeshPath(self: *Self, lod: LODLevel) lod_chunk.LODMeshPath {
        return lod_manager_generation_ops.effectiveMeshPath(self, lod);
    }

    /// Advances LOD work scheduling through `processUploads`.
    /// May enqueue generation, upload, deletion, or state-transition work for later frames.
    pub fn processUploads(self: *Self) void {
        return lod_manager_upload_ops.processUploads(self);
    }

    /// Advances LOD work scheduling through `processUploadsWithBudget`.
    /// May enqueue generation, upload, deletion, or state-transition work for later frames.
    pub fn processUploadsWithBudget(self: *Self, upload_budget_bytes: usize) void {
        return lod_manager_upload_ops.processUploadsWithBudget(self, upload_budget_bytes);
    }

    /// Updates LOD manager lifecycle or scheduling state through `requeueUpload`.
    /// Call from the world/update thread that owns the manager.
    pub fn requeueUpload(self: *Self, lod_idx: usize, chunk: *LODChunk) void {
        return lod_manager_upload_ops.requeueUpload(self, lod_idx, chunk);
    }

    /// Updates LOD manager lifecycle or scheduling state through `countRenderableChildren`.
    /// Call from the world/update thread that owns the manager.
    pub fn countRenderableChildren(self: *Self, key: LODRegionKey) u8 {
        return lod_manager_upload_ops.countRenderableChildren(self, key);
    }

    /// Updates LOD manager lifecycle or scheduling state through `regionContributesGeometry`.
    /// Call from the world/update thread that owns the manager.
    pub fn regionContributesGeometry(self: *Self, key: LODRegionKey, chunk: *const LODChunk) bool {
        return lod_manager_upload_ops.regionContributesGeometry(self, key, chunk);
    }

    /// Updates LOD manager lifecycle or scheduling state through `adjustParentReadyChildren`.
    /// Call from the world/update thread that owns the manager.
    pub fn adjustParentReadyChildren(self: *Self, key: LODRegionKey, delta: i8) void {
        return lod_manager_upload_ops.adjustParentReadyChildren(self, key, delta);
    }

    /// Records LOD manager bookkeeping via `markRegionRenderable`.
    /// Used to keep cache, transition, and readiness state consistent with world edits.
    pub fn markRegionRenderable(self: *Self, key: LODRegionKey, chunk: *LODChunk) void {
        return lod_manager_upload_ops.markRegionRenderable(self, key, chunk);
    }

    /// Updates LOD manager lifecycle or scheduling state through `decayTransitionFrames`.
    /// Call from the world/update thread that owns the manager.
    pub fn decayTransitionFrames(self: *Self) void {
        return lod_manager_upload_ops.decayTransitionFrames(self);
    }

    /// Records LOD manager bookkeeping via `noteRegionRemoved`.
    /// Used to keep cache, transition, and readiness state consistent with world edits.
    pub fn noteRegionRemoved(self: *Self, key: LODRegionKey, chunk: *const LODChunk) void {
        return lod_manager_upload_ops.noteRegionRemoved(self, key, chunk);
    }

    /// Updates LOD manager lifecycle or scheduling state through `demoteRegionForRemesh`.
    /// Call from the world/update thread that owns the manager.
    pub fn demoteRegionForRemesh(self: *Self, key: LODRegionKey, chunk: *LODChunk) void {
        return lod_manager_upload_ops.demoteRegionForRemesh(self, key, chunk);
    }

    /// Updates LOD manager lifecycle or scheduling state through `unloadDistantRegions`.
    /// Call from the world/update thread that owns the manager.
    pub fn unloadDistantRegions(self: *Self) !void {
        return lod_manager_eviction_ops.unloadDistantRegions(self);
    }

    /// Updates LOD manager lifecycle or scheduling state through `unloadDistantForLevel`.
    /// Call from the world/update thread that owns the manager.
    pub fn unloadDistantForLevel(self: *Self, lod: LODLevel, max_radius: i32) !void {
        return lod_manager_eviction_ops.unloadDistantForLevel(self, lod, max_radius);
    }

    /// Advances LOD work scheduling through `queueMeshDeletion`.
    /// May enqueue generation, upload, deletion, or state-transition work for later frames.
    pub fn queueMeshDeletion(self: *Self, mesh: *LODMesh) void {
        return lod_manager_eviction_ops.queueMeshDeletion(self, mesh);
    }

    /// Advances LOD work scheduling through `processMeshDeletions`.
    /// May enqueue generation, upload, deletion, or state-transition work for later frames.
    pub fn processMeshDeletions(self: *Self, max_count: usize) void {
        return lod_manager_eviction_ops.processMeshDeletions(self, max_count);
    }

    /// Updates LOD manager lifecycle or scheduling state through `enforceMemoryBudget`.
    /// Call from the world/update thread that owns the manager.
    pub fn enforceMemoryBudget(self: *Self) !void {
        return lod_manager_eviction_ops.enforceMemoryBudget(self);
    }

    /// Updates LOD manager lifecycle or scheduling state through `updateStats`.
    /// Call from the world/update thread that owns the manager.
    pub fn updateStats(self: *Self) void {
        return lod_manager_eviction_ops.updateStats(self);
    }

    /// Updates LOD manager lifecycle or scheduling state through `unloadLODWhereChunksLoaded`.
    /// Call from the world/update thread that owns the manager.
    pub fn unloadLODWhereChunksLoaded(self: *Self, checker: ChunkChecker, ctx: *anyopaque) void {
        return lod_manager_eviction_ops.unloadLODWhereChunksLoaded(self, checker, ctx);
    }

    /// Updates LOD manager lifecycle or scheduling state through `areAllChunksLoaded`.
    /// Call from the world/update thread that owns the manager.
    pub fn areAllChunksLoaded(self: *Self, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool {
        return lod_manager_eviction_ops.areAllChunksLoaded(self, bounds, checker, ctx);
    }
};
