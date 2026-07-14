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
const lod_tile = @import("lod_tile.zig");
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
const GenerationCandidate = manager_ctx.GenerationCandidate;
const MeshCandidate = manager_ctx.MeshCandidate;
const UploadCandidate = manager_ctx.UploadCandidate;
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

pub fn queueLODRegions(self: *Self, lod: LODLevel, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
    const player = self.loadPlayerChunkPos();
    self.mutex.lock();
    const radii = self.config.getRadii();
    const active_lod_count = lod_chunk.activeLODCount(self.config);
    const use_vertical_spans = self.config.getVerticalSpanBudget() > 0 and self.effectiveMeshPath(lod) == .column_spans;
    self.mutex.unlock();

    const Coverage = struct {
        fn areAllLoaded(ptr: *anyopaque, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool {
            const mgr: *Self = @ptrCast(@alignCast(ptr));
            return mgr.areAllChunksLoaded(bounds, checker, ctx);
        }
    };
    return lod_scheduler.queueLODRegions(.{
        .allocator = self.allocator,
        .config = self.config,
        .radii = radii,
        .active_lod_count = active_lod_count,
        .regions = &self.regions,
        .gen_queues = &self.job_dispatcher.queues,
        .mutex = &self.mutex,
        .player_cx = player.cx,
        .player_cz = player.cz,
        .next_job_token = &self.job_dispatcher.next_token,
        .cleanup_covered_regions = self.cleanup_covered_regions,
        .coverage_ptr = self,
        .are_all_chunks_loaded = Coverage.areAllLoaded,
        .radius_reduction = &self.memory_governor.radius_shrink_chunks,
        // Route every region through the bounded admission path, whether or
        // not persistent LOD caching is enabled.
        .defer_generation_dispatch = true,
        .pending_regions = &self.pending_region_count,
        .use_vertical_spans = use_vertical_spans,
    }, lod, velocity, chunk_checker, checker_ctx);
}

pub fn processQueuedGenerations(self: *Self, velocity: Vec3) !void {
    const Candidate = GenerationCandidate;
    var candidates = &self.generation_candidates_scratch;
    candidates.clearRetainingCapacity();

    const player = self.loadPlayerChunkPos();
    const cache_path = self.cacheDirPathSnapshot();
    defer if (cache_path) |path| self.allocator.free(path);
    var active_lod_count: usize = 0;

    self.mutex.lock();
    active_lod_count = lod_chunk.activeLODCount(self.config);
    const radii = self.config.getRadii();
    var i: usize = 0;
    while (i < active_lod_count) : (i += 1) {
        const lod: LODLevel = @enumFromInt(@as(u3, @intCast(i)));
        const scale: i32 = @intCast(lod.chunksPerSide());
        var iter = self.regions[i].iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.getState() != .queued_for_generation) continue;
            const center_cx = chunk.region_x * scale + @divFloor(scale, 2);
            const center_cz = chunk.region_z * scale + @divFloor(scale, 2);
            const encoded_priority = lod_scheduler.encodePriority(lod, center_cx - player.cx, center_cz - player.cz, velocity, active_lod_count);
            candidates.append(self.allocator, .{
                .key = entry.key_ptr.*,
                .chunk = chunk,
                .encoded_priority = encoded_priority,
                .level = @intCast(i),
                .coord_scale = scale,
                .job_token = chunk.job_token,
                .lod_radius = radii[i],
                .want_spans = self.config.getVerticalSpanBudget() > 0 and self.effectiveMeshPath(lod) == .column_spans,
            }) catch |err| {
                self.mutex.unlock();
                return err;
            };
        }
    }
    self.mutex.unlock();

    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lt(_: void, a: Candidate, b: Candidate) bool {
            return a.encoded_priority < b.encoded_priority;
        }
    }.lt);

    var cache_reads: usize = 0;
    for (candidates.items) |candidate| {
        if (cache_path) |path| {
            if (cache_reads < MAX_CACHE_LOADS_PER_UPDATE) {
                cache_reads += 1;
                self.mutex.lock();
                if (candidate.chunk.getState() == .queued_for_generation and candidate.chunk.job_token == candidate.job_token and !candidate.chunk.cache_read_queued) {
                    candidate.chunk.cache_read_queued = true;
                    const accepted = self.cache_io.enqueueRead(path, candidate.key, self.cacheKey(candidate.key), candidate.job_token) catch false;
                    if (accepted) {
                        self.mutex.unlock();
                        continue;
                    }
                    candidate.chunk.cache_read_queued = false;
                }
                self.mutex.unlock();
            }
        }

        dispatchGenerationCandidate(self, candidate) catch |err| return err;
    }
}

pub fn dispatchCacheMiss(self: *Self, key: LODRegionKey, token: u32) void {
    const lod_idx = @intFromEnum(key.lod);
    const player = self.loadPlayerChunkPos();
    self.mutex.lock();
    const chunk = self.regions[lod_idx].get(key) orelse {
        self.mutex.unlock();
        return;
    };
    if (chunk.getState() != .queued_for_generation or chunk.job_token != token) {
        self.mutex.unlock();
        return;
    }
    const active_lod_count = lod_chunk.activeLODCount(self.config);
    const scale: i32 = @intCast(key.lod.chunksPerSide());
    const candidate = GenerationCandidate{
        .key = key,
        .chunk = chunk,
        .encoded_priority = lod_scheduler.encodePriority(key.lod, key.rx * scale + @divFloor(scale, 2) - player.cx, key.rz * scale + @divFloor(scale, 2) - player.cz, Vec3.zero, active_lod_count),
        .level = @intCast(lod_idx),
        .coord_scale = scale,
        .job_token = token,
        .lod_radius = self.config.getRadii()[lod_idx],
        .want_spans = self.config.getVerticalSpanBudget() > 0 and self.effectiveMeshPath(key.lod) == .column_spans,
    };
    self.mutex.unlock();
    dispatchGenerationCandidate(self, candidate) catch |err| {
        log.log.warn("Failed to dispatch cache-miss LOD{} generation ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
    };
}

fn dispatchGenerationCandidate(self: *Self, candidate: GenerationCandidate) !void {
    self.mutex.lock();
    if (candidate.chunk.getState() != .queued_for_generation or candidate.chunk.job_token != candidate.job_token or candidate.chunk.cache_read_queued) {
        self.mutex.unlock();
        return;
    }
    candidate.chunk.resetCancellation();
    candidate.chunk.setState(.generating);
    self.mutex.unlock();

    const dispatch_timer = self.profiling.begin();
    self.job_dispatcher.queues[LODLevel.count - 1].push(.{
        .type = .chunk_generation,
        .dist_sq = candidate.encoded_priority,
        .data = .{ .chunk = .{
            .x = candidate.chunk.region_x,
            .z = candidate.chunk.region_z,
            .job_token = candidate.job_token,
            .lod_level = candidate.level,
            .coord_scale = candidate.coord_scale,
            .lod_radius = candidate.lod_radius,
            .use_vertical_spans = candidate.want_spans,
        } },
    }) catch |err| {
        self.profiling.end(.generation_dispatch, dispatch_timer);
        self.mutex.lock();
        if (candidate.chunk.getState() == .generating and candidate.chunk.job_token == candidate.job_token) candidate.chunk.setState(.queued_for_generation);
        self.mutex.unlock();
        return err;
    };
    self.profiling.end(.generation_dispatch, dispatch_timer);
}

/// Process state transitions (generated -> meshing -> ready)
pub fn processStateTransitions(self: *Self, velocity: Vec3) !void {
    // Collect generated/mesh-ready chunks, then sort by ascending distance
    // before enqueueing. The regions HashMap iterates in arbitrary
    // (hash-bucket) order, so without sorting the meshing/upload order is
    // effectively random — far chunks can be processed before near ones.
    var mesh_candidates = &self.mesh_candidates_scratch;
    mesh_candidates.clearRetainingCapacity();

    var upload_candidates = &self.upload_candidates_scratch;
    upload_candidates.clearRetainingCapacity();

    const player = self.loadPlayerChunkPos();
    var active_lod_count: usize = 0;

    self.mutex.lock();
    active_lod_count = lod_chunk.activeLODCount(self.config);
    const radii = self.config.getRadii();
    for (0..active_lod_count) |i| {
        const lod = @as(LODLevel, @enumFromInt(@as(u3, @intCast(i))));
        const scale = @as(i32, @intCast(lod.chunksPerSide()));
        const level: u3 = @intCast(i);
        var iter = self.regions[i].iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            if (chunk.isPinned()) continue;
            if (chunk.getState() == .renderable) {
                if (self.meshes[i].get(entry.key_ptr.*)) |mesh| {
                    if (mesh.isCompact() and mesh.compactDrawFailed()) {
                        chunk.compact_disabled = true;
                        chunk.setState(.generated);
                    }
                }
            }
            if (chunk.getState() == .generated) {
                const center_cx = chunk.region_x * scale + @divFloor(scale, 2);
                const center_cz = chunk.region_z * scale + @divFloor(scale, 2);
                const encoded_priority = lod_scheduler.encodePriority(lod, center_cx - player.cx, center_cz - player.cz, velocity, active_lod_count);
                mesh_candidates.append(self.allocator, .{ .chunk = chunk, .encoded_priority = encoded_priority, .level = level, .coord_scale = scale, .job_token = chunk.job_token, .lod_radius = radii[i] }) catch |err| {
                    self.mutex.unlock();
                    return err;
                };
            } else if (chunk.getState() == .mesh_ready) {
                if (self.meshes[i].get(entry.key_ptr.*)) |mesh| patchCompactAprons(self, i, entry.key_ptr.*, mesh);
                const center_cx = chunk.region_x * scale + @divFloor(scale, 2);
                const center_cz = chunk.region_z * scale + @divFloor(scale, 2);
                const encoded_priority = lod_scheduler.encodePriority(lod, center_cx - player.cx, center_cz - player.cz, velocity, active_lod_count);
                upload_candidates.append(self.allocator, .{ .chunk = chunk, .encoded_priority = encoded_priority, .level = level }) catch |err| {
                    self.mutex.unlock();
                    return err;
                };
            }
        }
    }
    self.mutex.unlock();

    // Meshing jobs share one queue; sort by encoded priority so fine/near
    // sections are built before coarse fallback.
    std.mem.sort(MeshCandidate, mesh_candidates.items, {}, struct {
        fn lt(_: void, a: MeshCandidate, b: MeshCandidate) bool {
            return a.encoded_priority < b.encoded_priority;
        }
    }.lt);
    for (mesh_candidates.items) |mc| {
        // Transition and enqueue atomically with respect to workers. A worker
        // may pop immediately, but cannot inspect the chunk until this short
        // manager critical section publishes the matching state.
        self.mutex.lock();
        if (mc.chunk.getState() != .generated or mc.chunk.job_token != mc.job_token) {
            self.mutex.unlock();
            continue;
        }
        mc.chunk.setState(.meshing);
        mc.chunk.resetCancellation();
        self.job_dispatcher.queues[LODLevel.count - 1].push(.{
            .type = .chunk_meshing,
            .dist_sq = mc.encoded_priority,
            .data = .{
                .chunk = .{
                    .x = mc.chunk.region_x,
                    .z = mc.chunk.region_z,
                    .job_token = mc.job_token,
                    .lod_level = mc.level,
                    .coord_scale = mc.coord_scale,
                    .lod_radius = mc.lod_radius,
                },
            },
        }) catch |err| {
            if (mc.chunk.getState() == .meshing and mc.chunk.job_token == mc.job_token) {
                mc.chunk.setState(.generated);
            }
            self.mutex.unlock();
            return err;
        };
        // Never let a worker invoke RHI or release a live pooled range. Once
        // the replacement job is guaranteed to be queued, detach the previous
        // representation and retire it through the normal frame-delayed
        // disposal queue. The worker will create a fresh mesh object.
        const mesh_key = LODRegionKey{ .rx = mc.chunk.region_x, .rz = mc.chunk.region_z, .lod = @enumFromInt(mc.level) };
        if (self.meshes[mc.level].fetchRemove(mesh_key)) |old_mesh| {
            self.queueMeshDeletion(old_mesh.value);
        }
        self.mutex.unlock();
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
        self.mutex.lock();
        if (uc.chunk.getState() != .mesh_ready) {
            self.mutex.unlock();
            continue;
        }
        uc.chunk.setState(.uploading);
        self.upload_queues[uc.level].push(uc.chunk) catch |err| {
            if (uc.chunk.getState() == .uploading) {
                uc.chunk.setState(.mesh_ready);
            }
            self.mutex.unlock();
            return err;
        };
        self.mutex.unlock();
    }
}

fn patchCompactAprons(self: *Self, lod_index: usize, key: LODRegionKey, mesh: *LODMesh) void {
    const neighbors = [_]struct { dx: i32, dz: i32, edge: lod_tile.TileEdge }{
        .{ .dx = -1, .dz = 0, .edge = .west },
        .{ .dx = 1, .dz = 0, .edge = .east },
        .{ .dx = 0, .dz = -1, .edge = .north },
        .{ .dx = 0, .dz = 1, .edge = .south },
    };
    for (neighbors) |neighbor| {
        const neighbor_key = LODRegionKey{ .rx = key.rx + neighbor.dx, .rz = key.rz + neighbor.dz, .lod = key.lod };
        const neighbor_mesh = self.meshes[lod_index].get(neighbor_key) orelse continue;
        _ = mesh.patchCompactNeighbor(neighbor.edge, neighbor_mesh);
    }
}

pub fn getOrCreateMesh(self: *Self, key: LODRegionKey) !*LODMesh {
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
pub fn buildMeshForChunk(self: *Self, chunk: *LODChunk) !void {
    // A meshing worker pins its chunk while it owns the immutable source data.
    // Ingestion defers writes to .meshing chunks and eviction skips pinned
    // chunks, so retaining the manager lock through mesh construction is both
    // unnecessary and a substantial source of contention.
    std.debug.assert(chunk.isPinned());
    std.debug.assert(chunk.getState() == .meshing);

    const key = LODRegionKey{
        .rx = chunk.region_x,
        .rz = chunk.region_z,
        .lod = chunk.lodLevel(),
    };

    const mesh = try self.getOrCreateMesh(key);

    switch (chunk.data) {
        .simplified => |*data| {
            const bounds = chunk.worldBounds();
            // LOD3/4 can use the diagnostic compact heightfield path while the
            // expanded CPU-built GPU mesh remains the production fallback.
            // Compact water is temporarily quarantined on RADV: the direct
            // compact water vertex path can cause a rejected command stream on
            // real saved worlds even with validation clean. Preserve water by
            // routing wet regions through the maintained expanded CPU mesh.
            if (shouldUseCompactTiles(self, chunk) and !hasRenderableWater(data)) {
                mesh.buildCompactTile(data) catch |err| switch (err) {
                    error.UnsupportedSourceFeatures => {},
                    else => return err,
                };
                if (mesh.isCompact()) return;
            }
            switch (self.effectiveMeshPath(chunk.lodLevel())) {
                .heightfield => try mesh.buildFromSimplifiedData(data, bounds.min_x, bounds.min_z, self.atlas),
                .column_spans => try mesh.buildFromColumnSpans(data, bounds.min_x, bounds.min_z, self.atlas),
                .qem => {
                    const lod = chunk.lodLevel();
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

fn hasRenderableWater(data: *const LODSimplifiedData) bool {
    for (data.water) |water| {
        if (water.is_surface and water.coverage > 0.001) return true;
    }
    return false;
}

/// Converts an unrenderable compact upload to the established CPU heightfield
/// route. The upload task pins `chunk`, so its simplified source is stable for
/// this synchronous recovery and can immediately be requeued without a hole.
pub fn fallbackCompactMeshToCpu(self: *Self, mesh: *LODMesh, chunk: *LODChunk) !void {
    std.debug.assert(mesh.isCompact());
    self.gpu_bridge.destroy(mesh);
    mesh.clearRetiredState();
    switch (chunk.data) {
        .simplified => |*data| {
            const bounds = chunk.worldBounds();
            try mesh.buildFromSimplifiedData(data, bounds.min_x, bounds.min_z, self.atlas);
        },
        else => return error.InvalidState,
    }
}

fn shouldUseCompactTiles(self: *Self, chunk: *const LODChunk) bool {
    if (chunk.compact_disabled) return false;
    const lod = chunk.lodLevel();
    if (lod != .lod3 and lod != .lod4) return false;
    const mode = engine_core.getenv("ZIGCRAFT_LOD_COMPACT") orelse "auto";
    if (std.ascii.eqlIgnoreCase(mode, "off")) return false;
    // Capability checks prove that the required Vulkan entry points and
    // resources exist, but the compact path still causes command-stream
    // rejection on RADV in mixed wet/dry saved worlds. Auto therefore fails
    // closed until driver qualification is represented by a real capability
    // probe. `force` remains available for bounded diagnostics.
    if (std.ascii.eqlIgnoreCase(mode, "auto")) return false;
    if (std.ascii.eqlIgnoreCase(mode, "force")) return self.gpu_bridge.supportsCompact();
    return false;
}

pub fn effectiveMeshPath(self: *Self, lod: LODLevel) lod_chunk.LODMeshPath {
    // Far bands stay as high-resolution stepped block columns. LOD2 keeps
    // the richer span path so mid-distance cliffs/trees remain voxel-like
    // without turning the terrain into a smooth polygon surface.
    if (@intFromEnum(lod) >= @intFromEnum(LODLevel.lod3)) return .heightfield;
    if (lod == LODConfig.coarsestLOD()) return .heightfield;
    if (engine_core.envFlag("ZIGCRAFT_LOD_MESH_PATH_QEM", false)) return .qem;
    if (engine_core.envFlag("ZIGCRAFT_LOD_MESH_PATH_SPANS", false)) return .column_spans;
    return self.config.getMeshPath();
}

/// Worker pool callback for LOD tasks (generation and meshing)
pub fn processLODJob(ctx: *anyopaque, job: Job) void {
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

    // Reject invalidated work before any state reconciliation. A stale queued
    // job must never demote a newer job for the same region.
    if (chunk.job_token != job.data.chunk.job_token) {
        self.mutex.unlock();
        return;
    }

    // Stale job check (too far from player)
    const player = self.loadPlayerChunkPos();
    const radius = job.data.chunk.lod_radius;
    const use_vertical_spans = job.data.chunk.use_vertical_spans;
    const job_key = LODRegionKey{
        .rx = job.data.chunk.x,
        .rz = job.data.chunk.z,
        .lod = lod_level,
    };

    if (!job_key.chunkBounds().intersectsRadius(player.cx, player.cz, radius)) {
        if (chunk.getState() == .generating or chunk.getState() == .meshing) {
            if (self.pending_region_count > 0) self.pending_region_count -= 1;
            chunk.setState(.missing);
        }
        self.mutex.unlock();
        return;
    }

    // Check state and capture job type before releasing lock
    const current_state = chunk.getState();
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
            const generation_timer = self.profiling.begin();
            defer self.profiling.end(.worker_generation, generation_timer);
            // Initialize simplified data if needed
            if (needs_data_init) {
                var data = if (use_vertical_spans)
                    LODSimplifiedData.initWithVerticalSpans(self.allocator, lod_level) catch {
                        new_state = .missing;
                        self.mutex.lock();
                        if (chunk.job_token == job.data.chunk.job_token) {
                            if (self.pending_region_count > 0) self.pending_region_count -= 1;
                            chunk.setState(new_state);
                        }
                        chunk.unpin();
                        self.mutex.unlock();
                        return;
                    }
                else
                    LODSimplifiedData.init(self.allocator, lod_level) catch {
                        new_state = .missing;
                        self.mutex.lock();
                        if (chunk.job_token == job.data.chunk.job_token) {
                            if (self.pending_region_count > 0) self.pending_region_count -= 1;
                            chunk.setState(new_state);
                        }
                        chunk.unpin();
                        self.mutex.unlock();
                        return;
                    };

                // Generate heightmap data (expensive, done without lock).
                // Pass the region cancellation signal so pause and teleport
                // can interrupt a multi-second coarse-LOD generation loop.
                // Teardown sets both the manager flag and every region signal.
                self.generator.generateHeightmapOnly(&data, chunk.region_x, chunk.region_z, lod_level, &chunk.cancel_requested);

                // If generation was aborted, discard the partial data
                // and leave the chunk in .missing so it re-generates later.
                if (self.job_dispatcher.stop_flag.load(.acquire) or chunk.cancellationRequested()) {
                    data.deinit();
                    new_state = .missing;
                    self.mutex.lock();
                    if (chunk.job_token == job.data.chunk.job_token) {
                        if (self.pending_region_count > 0) self.pending_region_count -= 1;
                        chunk.setState(new_state);
                    }
                    chunk.unpin();
                    self.mutex.unlock();
                    return;
                }

                // Acquire lock to update chunk data
                self.mutex.lock();
                chunk.data = .{ .simplified = data };
                chunk.updateHeightBoundsFromData();
                chunk.markSourceDirty();
                self.mutex.unlock();
            }
            success = true;
            new_state = .generated;
        },
        .chunk_meshing => {
            const mesh_timer = self.profiling.begin();
            defer self.profiling.end(.worker_mesh_construction, mesh_timer);
            // Build mesh (expensive, done without lock)
            // Note: buildMeshForChunk -> getOrCreateMesh acquires its own lock
            self.buildMeshForChunk(chunk) catch |err| {
                log.log.errWithTrace("Failed to build LOD{} async mesh: {}", .{ @intFromEnum(lod_level), err });
                new_state = .generated; // Retry later
                self.mutex.lock();
                if (chunk.job_token == job.data.chunk.job_token) chunk.setState(new_state);
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
        chunk.setState(new_state);
    }
    chunk.unpin();
    self.mutex.unlock();
}
