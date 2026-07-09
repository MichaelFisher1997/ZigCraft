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
        .defer_generation_dispatch = self.cacheEnabled(),
        .use_vertical_spans = use_vertical_spans,
    }, lod, velocity, chunk_checker, checker_ctx);
}

pub fn processQueuedGenerations(self: *Self, velocity: Vec3) !void {
    const Candidate = GenerationCandidate;
    var candidates = &self.generation_candidates_scratch;
    candidates.clearRetainingCapacity();

    const player = self.loadPlayerChunkPos();
    const cache_enabled = self.cacheEnabled();
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
        var cached_data: ?LODSimplifiedData = null;
        var attempted_cache = false;
        if (cache_enabled and cache_reads < MAX_CACHE_LOADS_PER_UPDATE) {
            cache_reads += 1;
            attempted_cache = true;
            cached_data = self.loadCachedSourceData(candidate.key);
            if (cached_data) |*cached| {
                if (candidate.want_spans and !cached.hasVerticalSpans()) {
                    cached.deinit();
                    cached_data = null;
                }
            }
        }

        if (cached_data) |data| {
            self.recordCacheHit();
            self.mutex.lock();
            if (candidate.chunk.getState() == .queued_for_generation and candidate.chunk.job_token == candidate.job_token) {
                candidate.chunk.data = .{ .simplified = data };
                candidate.chunk.updateHeightBoundsFromData();
                candidate.chunk.setState(.generated);
            } else {
                var stale_data = data;
                stale_data.deinit();
            }
            self.mutex.unlock();
            continue;
        }

        if (attempted_cache) self.recordCacheMiss();

        self.mutex.lock();
        if (candidate.chunk.getState() != .queued_for_generation or candidate.chunk.job_token != candidate.job_token) {
            self.mutex.unlock();
            continue;
        }
        candidate.chunk.setState(.generating);
        self.mutex.unlock();

        self.job_dispatcher.queues[LODLevel.count - 1].push(.{
            .type = .chunk_generation,
            .dist_sq = candidate.encoded_priority,
            .data = .{
                .chunk = .{
                    .x = candidate.chunk.region_x,
                    .z = candidate.chunk.region_z,
                    .job_token = candidate.job_token,
                    .lod_level = candidate.level,
                    .coord_scale = candidate.coord_scale,
                    .lod_radius = candidate.lod_radius,
                    .use_vertical_spans = candidate.want_spans,
                },
            },
        }) catch |err| {
            self.mutex.lock();
            if (candidate.chunk.getState() == .generating and candidate.chunk.job_token == candidate.job_token) {
                candidate.chunk.setState(.queued_for_generation);
            }
            self.mutex.unlock();
            return err;
        };
    }
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
            if (chunk.getState() == .generated) {
                const center_cx = chunk.region_x * scale + @divFloor(scale, 2);
                const center_cz = chunk.region_z * scale + @divFloor(scale, 2);
                const encoded_priority = lod_scheduler.encodePriority(lod, center_cx - player.cx, center_cz - player.cz, velocity, active_lod_count);
                // Append before flipping state so an allocation failure
                // leaves the chunk in .generated (re-tried next tick)
                // instead of stuck in .meshing with no queued job.
                mesh_candidates.append(self.allocator, .{ .chunk = chunk, .encoded_priority = encoded_priority, .level = level, .coord_scale = scale, .job_token = chunk.job_token, .lod_radius = radii[i] }) catch |err| {
                    self.mutex.unlock();
                    return err;
                };
                chunk.setState(.meshing);
            } else if (chunk.getState() == .mesh_ready) {
                const center_cx = chunk.region_x * scale + @divFloor(scale, 2);
                const center_cz = chunk.region_z * scale + @divFloor(scale, 2);
                const encoded_priority = lod_scheduler.encodePriority(lod, center_cx - player.cx, center_cz - player.cz, velocity, active_lod_count);
                upload_candidates.append(self.allocator, .{ .chunk = chunk, .encoded_priority = encoded_priority, .level = level }) catch |err| {
                    self.mutex.unlock();
                    return err;
                };
                chunk.setState(.uploading);
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
            self.mutex.lock();
            if (mc.chunk.getState() == .meshing and mc.chunk.job_token == mc.job_token) {
                mc.chunk.setState(.generated);
            }
            self.mutex.unlock();
            return err;
        };
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
        self.upload_queues[uc.level].push(uc.chunk) catch |err| {
            self.mutex.lock();
            if (uc.chunk.getState() == .uploading) {
                uc.chunk.setState(.mesh_ready);
            }
            self.mutex.unlock();
            return err;
        };
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
    const key = LODRegionKey{
        .rx = chunk.region_x,
        .rz = chunk.region_z,
        .lod = chunk.lodLevel(),
    };

    const mesh = try self.getOrCreateMesh(key);

    // Access chunk.data under shared lock - the data is read-only during meshing
    // and the chunk is pinned, so we just need to ensure visibility
    self.mutex.lockShared();
    defer self.mutex.unlockShared();

    switch (chunk.data) {
        .simplified => |*data| {
            const bounds = chunk.worldBounds();
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
            chunk.setState(.missing);
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
            // Initialize simplified data if needed
            if (needs_data_init) {
                var data = if (use_vertical_spans)
                    LODSimplifiedData.initWithVerticalSpans(self.allocator, lod_level) catch {
                        new_state = .missing;
                        self.mutex.lock();
                        if (chunk.job_token == job.data.chunk.job_token) chunk.setState(new_state);
                        chunk.unpin();
                        self.mutex.unlock();
                        return;
                    }
                else
                    LODSimplifiedData.init(self.allocator, lod_level) catch {
                        new_state = .missing;
                        self.mutex.lock();
                        if (chunk.job_token == job.data.chunk.job_token) chunk.setState(new_state);
                        chunk.unpin();
                        self.mutex.unlock();
                        return;
                    };

                // Generate heightmap data (expensive, done without lock).
                // Pass the stop flag so teardown/pause can interrupt the
                // multi-second coarse-LOD heightmap loop instead of
                // forcing the worker-join to block until it finishes.
                self.generator.generateHeightmapOnly(&data, chunk.region_x, chunk.region_z, lod_level, &self.job_dispatcher.stop_flag);

                // If generation was aborted, discard the partial data
                // and leave the chunk in .missing so it re-generates later.
                if (self.job_dispatcher.stop_flag.load(.acquire)) {
                    data.deinit();
                    new_state = .missing;
                    self.mutex.lock();
                    if (chunk.job_token == job.data.chunk.job_token) chunk.setState(new_state);
                    chunk.unpin();
                    self.mutex.unlock();
                    return;
                }

                // Acquire lock to update chunk data
                self.mutex.lock();
                chunk.data = .{ .simplified = data };
                chunk.updateHeightBoundsFromData();
                chunk.store_dirty = true;
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
