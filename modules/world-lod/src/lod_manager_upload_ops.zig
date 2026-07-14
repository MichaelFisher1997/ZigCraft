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

/// Process GPU uploads (limited per frame)
pub fn processUploads(self: *Self) void {
    self.processUploadsWithBudget(lodUploadBudgetBytes());
}

pub fn processUploadsWithBudget(self: *Self, upload_budget_bytes: usize) void {
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
        const prep_timer = self.profiling.begin();
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
                const key = chunk.key();
                if (self.meshes[i].get(key)) |mesh| {
                    const pending_bytes = mesh.pendingUploadBytes();
                    if (wouldExceedUploadBudget(uploaded_bytes, pending_bytes, upload_budget_bytes)) {
                        self.profiling.addStagingPressure();
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

        if (stop_processing or !made_progress) {
            self.profiling.end(.upload_prep, prep_timer);
            break;
        }
        if (completed_without_upload) {
            self.profiling.end(.upload_prep, prep_timer);
            continue;
        }

        const upload_task = task orelse {
            self.profiling.end(.upload_prep, prep_timer);
            continue;
        };
        self.profiling.end(.upload_prep, prep_timer);
        const submission_timer = self.profiling.begin();
        self.gpu_bridge.upload(upload_task.mesh) catch |err| {
            self.profiling.end(.upload_submission, submission_timer);
            log.log.warn("LOD{} mesh upload failed (will retry): {}", .{ upload_task.lod_idx, err });
            // Compact allocation/update failures must not strand a far region
            // in .mesh_ready. Rebuild its stable CPU heightfield while the
            // upload task still pins the source, then put it straight back on
            // the upload queue. This also covers LOD4.
            if (upload_task.mesh.isCompact()) {
                self.fallbackCompactMeshToCpu(upload_task.mesh, upload_task.chunk) catch |fallback_err| {
                    log.log.warn("LOD{} compact fallback build failed; retaining retryable compact payload: {}", .{ upload_task.lod_idx, fallback_err });
                    self.mutex.lock();
                    self.stats.upload_failures += 1;
                    uploads += 1;
                    self.requeueUpload(upload_task.lod_idx, upload_task.chunk);
                    upload_task.chunk.unpin();
                    self.mutex.unlock();
                    return;
                };
                self.mutex.lock();
                self.stats.upload_failures += 1;
                uploads += 1;
                self.requeueUpload(upload_task.lod_idx, upload_task.chunk);
                upload_task.chunk.unpin();
                self.mutex.unlock();
                continue;
            }
            self.mutex.lock();
            self.stats.upload_failures += 1;
            uploads += 1;
            if (isUploadPressureError(err)) {
                self.profiling.addStagingPressure();
                self.requeueUpload(upload_task.lod_idx, upload_task.chunk);
                upload_task.chunk.unpin();
                self.mutex.unlock();
                return;
            }
            upload_task.chunk.setState(.mesh_ready);
            upload_task.chunk.unpin();
            self.mutex.unlock();
            continue;
        };
        self.profiling.end(.upload_submission, submission_timer);

        uploaded_bytes += upload_task.pending_bytes;
        self.profiling.addUploadBytes(upload_task.pending_bytes);
        self.mutex.lock();
        self.markRegionRenderable(upload_task.key, upload_task.chunk);
        uploads += 1;
        upload_task.chunk.unpin();
        self.mutex.unlock();
    }
}

pub fn requeueUpload(self: *Self, lod_idx: usize, chunk: *LODChunk) void {
    chunk.setState(.uploading);
    self.upload_queues[lod_idx].push(chunk) catch |err| {
        log.log.warn("LOD{} upload requeue failed: {}", .{ lod_idx, err });
        self.stats.upload_failures += 1;
        chunk.setState(.mesh_ready);
    };
}

pub fn countRenderableChildren(self: *Self, key: LODRegionKey) u8 {
    const children = key.childKeys() orelse return 0;
    const child_idx = @intFromEnum(children[0].lod);
    var count: u8 = 0;
    for (children) |child_key| {
        const child = self.regions[child_idx].get(child_key) orelse continue;
        if (self.regionContributesGeometry(child_key, child)) count += 1;
    }
    return count;
}

pub fn regionContributesGeometry(self: *Self, key: LODRegionKey, chunk: *const LODChunk) bool {
    if (chunk.getState() != .renderable) return false;
    const mesh = self.meshes[@intFromEnum(key.lod)].get(key) orelse return false;
    return mesh.isRenderable();
}

pub fn adjustParentReadyChildren(self: *Self, key: LODRegionKey, delta: i8) void {
    const parent = key.parentKey() orelse return;
    const parent_chunk = self.regions[@intFromEnum(parent.lod)].get(parent) orelse return;
    parent_chunk.adjustReadyChildren(delta);
}

pub fn markRegionRenderable(self: *Self, key: LODRegionKey, chunk: *LODChunk) void {
    if (chunk.isRenderable()) return;
    chunk.markRenderable(self.countRenderableChildren(key));
    if (self.pending_region_count > 0) self.pending_region_count -= 1;
    if (self.regionContributesGeometry(key, chunk)) {
        self.adjustParentReadyChildren(key, 1);
    }
}

pub fn decayTransitionFrames(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    const active = lod_chunk.activeLODCount(self.config);
    var i: usize = 1;
    while (i < active) : (i += 1) {
        var iter = self.regions[i].iterator();
        while (iter.next()) |entry| {
            const chunk = entry.value_ptr.*;
            chunk.tickTransition();
        }
    }
}

pub fn noteRegionRemoved(self: *Self, key: LODRegionKey, chunk: *const LODChunk) void {
    if (self.regionContributesGeometry(key, chunk)) {
        self.adjustParentReadyChildren(key, -1);
    }
}

pub fn demoteRegionForRemesh(self: *Self, key: LODRegionKey, chunk: *LODChunk) void {
    if (chunk.getState() == .renderable) {
        self.noteRegionRemoved(key, chunk);
        chunk.setState(.generated);
        self.pending_region_count += 1;
    } else if (chunk.getState() == .mesh_ready) {
        chunk.setState(.generated);
    }
}
