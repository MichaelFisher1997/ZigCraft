const std = @import("std");
const Self = @import("lod_manager.zig").LODManager;
const fs = @import("fs");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODConfig = lod_chunk.LODConfig;
const LODState = lod_chunk.LODState;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const ILODConfig = lod_chunk.ILODConfig;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const LODColumnProvenance = world_core.LODColumnProvenance;
const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;
const Vertex = @import("engine-rhi").Vertex;
const engine_core = @import("engine-core");
const log = engine_core.log;
const JobSystem = engine_core.job_system;
const JobQueue = JobSystem.JobQueue;
const WorkerPool = JobSystem.WorkerPool;
const Job = JobSystem.Job;
const RingBuffer = engine_core.ring_buffer.RingBuffer;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const LODRenderLayer = lod_gpu.LODRenderLayer;
const ChunkChecker = lod_gpu.ChunkChecker;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const lod_scheduler = @import("lod_scheduler.zig");
const lod_cache = @import("lod_cache.zig");
const lod_store = @import("lod_store.zig");
const lod_ingest = @import("lod_ingest.zig");
const TextureAtlas = @import("engine-assets").TextureAtlas;
const LODGenerator = @import("lod_generator.zig").LODGenerator;
const LODStats = @import("lod_stats.zig").LODStats;
const manager_ctx = @import("lod_manager_context.zig");
const ChunkCoordKey = manager_ctx.ChunkCoordKey;
const ChunkCoordKeyContext = manager_ctx.ChunkCoordKeyContext;
const ChunkCoordSet = std.HashMap(ChunkCoordKey, void, ChunkCoordKeyContext, std.hash_map.default_max_load_percentage);
const ChunkResolver = manager_ctx.ChunkResolver;
const PendingIngestion = manager_ctx.PendingIngestion;
const PlayerChunkPos = manager_ctx.PlayerChunkPos;
const MAX_CACHE_LOADS_PER_UPDATE = manager_ctx.MAX_CACHE_LOADS_PER_UPDATE;
const MAX_MEMORY_EVICTIONS_PER_UPDATE = manager_ctx.MAX_MEMORY_EVICTIONS_PER_UPDATE;
const MAX_MESH_DELETIONS_PER_SWEEP = manager_ctx.MAX_MESH_DELETIONS_PER_SWEEP;
const DEFAULT_LOD_UPLOAD_BUDGET_BYTES = manager_ctx.DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
const LOD_UPLOAD_BUDGET_ENV = manager_ctx.LOD_UPLOAD_BUDGET_ENV;
const LOD_UPDATE_DIVISOR = manager_ctx.LOD_UPDATE_DIVISOR;
const DELETION_SWEEP_SECONDS = manager_ctx.DELETION_SWEEP_SECONDS;
const CHUNK_COVERAGE_PADDING = manager_ctx.CHUNK_COVERAGE_PADDING;
const MIN_LOD_WORKERS = manager_ctx.MIN_LOD_WORKERS;
const MAX_LOD_WORKERS = manager_ctx.MAX_LOD_WORKERS;
const MAX_PENDING_INGESTIONS = manager_ctx.MAX_PENDING_INGESTIONS;
const PENDING_INGESTION_TTL = manager_ctx.PENDING_INGESTION_TTL;
const EDIT_FLUSH_COOLDOWN = manager_ctx.EDIT_FLUSH_COOLDOWN;
const LOD_FRAME_DT_APPROX = manager_ctx.LOD_FRAME_DT_APPROX;
const lodUploadBudgetBytes = manager_ctx.lodUploadBudgetBytes;
const wouldExceedUploadBudget = manager_ctx.wouldExceedUploadBudget;
const isUploadPressureError = manager_ctx.isUploadPressureError;

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

pub fn flushDirtyStores(self: *Self) void {
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

pub fn cacheKey(self: *const Self, key: LODRegionKey) lod_cache.Key {
    return .{
        .seed = self.generator.seed,
        .generator_identity_hash = self.generator.identity_hash,
        .generator_version = self.generator.version,
        .rx = key.rx,
        .rz = key.rz,
        .lod = key.lod,
    };
}

pub fn legacyCacheFilePath(self: *Self, save_dir_path: []const u8, key: lod_cache.Key) ![]u8 {
    const filename = try std.fmt.allocPrint(
        self.allocator,
        "lod_{}_{}_{}_{}_{}_{}.dat",
        .{ key.seed, key.generator_identity_hash, key.generator_version, key.rx, key.rz, @intFromEnum(key.lod) },
    );
    defer self.allocator.free(filename);
    return std.fs.path.join(self.allocator, &.{ save_dir_path, "lod_cache", filename });
}

pub fn logLegacyCacheNotice(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.logged_legacy_cache_notice) return;
    self.logged_legacy_cache_notice = true;
    log.log.warn("Using read-only legacy LOD cache fallback; new writes go to lod/ region store", .{});
}

pub fn cacheDirPathSnapshot(self: *Self) ?[]u8 {
    self.mutex.lockShared();
    defer self.mutex.unlockShared();

    const cache_dir_path = self.cache_dir_path orelse return null;
    return self.allocator.dupe(u8, cache_dir_path) catch |err| {
        log.log.warn("LOD cache path snapshot allocation failed: {}", .{err});
        return null;
    };
}

pub fn cacheEnabled(self: *Self) bool {
    self.mutex.lockShared();
    defer self.mutex.unlockShared();
    return self.cache_dir_path != null;
}

pub fn readStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key) !?[]u8 {
    self.store_mutex.lock();
    defer self.store_mutex.unlock();
    return lod_store.readPayload(self.allocator, save_dir_path, cache_key);
}

pub fn writeStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key, bytes: []const u8) !void {
    self.mutex.lockShared();
    const store_size_cap_mb = self.config.getLODStoreSizeCapMB();
    self.mutex.unlockShared();

    self.store_mutex.lock();
    defer self.store_mutex.unlock();
    try lod_store.writePayload(self.allocator, save_dir_path, cache_key, bytes, store_size_cap_mb);
}

pub fn deleteStorePayload(self: *Self, save_dir_path: []const u8, cache_key: lod_cache.Key) void {
    self.store_mutex.lock();
    defer self.store_mutex.unlock();
    lod_store.deletePayload(self.allocator, save_dir_path, cache_key);
}

pub fn deleteStoreContainer(self: *Self, path: []const u8) void {
    self.store_mutex.lock();
    defer self.store_mutex.unlock();
    fs.cwd().deleteFile(path) catch |delete_err| {
        if (delete_err != error.FileNotFound) {
            log.log.warn("Failed to delete corrupt LOD store container '{s}': {}", .{ path, delete_err });
        }
    };
}

pub fn loadCachedSourceData(self: *Self, key: LODRegionKey) ?LODSimplifiedData {
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

pub fn recordCacheHit(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.cache_hits += 1;
}

pub fn recordCacheMiss(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.cache_misses += 1;
}

pub fn saveCachedSourceData(self: *Self, key: LODRegionKey, data: *const LODSimplifiedData) void {
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

pub fn initCacheTestManager(allocator: std.mem.Allocator, cache_dir_path: []const u8) Self {
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
