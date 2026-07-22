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
const MAX_LIFECYCLE_TRANSITIONS_PER_UPDATE = manager_ctx.MAX_LIFECYCLE_TRANSITIONS_PER_UPDATE;

/// Rendering can discover a compact submission failure, but may not retire GPU
/// state while it holds the manager's render lock. Bound update-side recovery
/// so a pathological driver cannot monopolize one frame.
const MAX_COMPACT_DRAW_RECOVERIES_PER_UPDATE: usize = 4;

/// Consumes compact draw failures recorded by the renderer. This runs only on
/// the manager update thread: it pins immutable source data, retires compact
/// GPU storage through the bridge, builds the expanded CPU mesh, then requeues
/// the normal bounded upload path. Workers never call the bridge.
pub fn recoverCompactDrawFailures(self: *Self) void {
    const RecoveryTask = struct {
        key: LODRegionKey,
        chunk: *LODChunk,
        mesh: *LODMesh,
        lod_idx: usize,
        job_token: u32,
        source_revision: u32,
    };

    var recovered: usize = 0;
    while (recovered < MAX_COMPACT_DRAW_RECOVERIES_PER_UPDATE) : (recovered += 1) {
        var task: ?RecoveryTask = null;
        self.mutex.lock();
        find_failure: for (0..LODLevel.count) |lod_idx| {
            var mesh_iter = self.meshes[lod_idx].iterator();
            while (mesh_iter.next()) |entry| {
                const key = entry.key_ptr.*;
                const chunk = self.regions[lod_idx].get(key) orelse continue;
                const mesh = entry.value_ptr.*;
                // The source identity guards against a render failure from a
                // representation superseded by ingestion, cache reload, or a
                // cancelled lifecycle token.
                if (!mesh.compactDrawFailureMatches(chunk.job_token, chunk.source_revision)) continue;
                if (chunk.getState() != .renderable) continue;

                chunk.pin();
                chunk.compact_disabled = true;
                self.profiling.addCompactDisabled();
                // `markCompactDrawFailed` already made the mesh non-renderable,
                // so `noteRegionRemoved` cannot infer its former contribution.
                // Account for it explicitly to keep the parent visible between
                // the failed frame and successful expanded upload.
                self.adjustParentReadyChildren(key, -1);
                self.pending_region_count += 1;
                chunk.setState(.meshing);
                task = .{
                    .key = key,
                    .chunk = chunk,
                    .mesh = mesh,
                    .lod_idx = lod_idx,
                    .job_token = chunk.job_token,
                    .source_revision = chunk.source_revision,
                };
                break :find_failure;
            }
        }
        self.mutex.unlock();

        const recovery = task orelse break;
        self.profiling.addCompactRecovery();
        self.fallbackCompactMeshToCpu(recovery.mesh, recovery.chunk) catch |err| {
            log.log.warn("LOD{} compact draw recovery CPU build failed: {}", .{ recovery.lod_idx, err });
            self.mutex.lock();
            if (self.regions[recovery.lod_idx].get(recovery.key) == recovery.chunk and
                recovery.chunk.job_token == recovery.job_token and
                recovery.chunk.source_revision == recovery.source_revision and
                recovery.chunk.getState() == .meshing)
            {
                // The compact range is already safely retired. Retry the
                // regular CPU meshing path later; compact remains disabled for
                // this source revision.
                recovery.chunk.setState(.generated);
                self.enqueueTransition(recovery.key, recovery.chunk, .mesh);
            }
            recovery.chunk.unpin();
            self.mutex.unlock();
            continue;
        };

        self.mutex.lock();
        if (self.regions[recovery.lod_idx].get(recovery.key) == recovery.chunk and
            recovery.chunk.job_token == recovery.job_token and
            recovery.chunk.source_revision == recovery.source_revision and
            recovery.chunk.getState() == .meshing)
        {
            self.requeueUpload(recovery.lod_idx, recovery.chunk);
        }
        recovery.chunk.unpin();
        self.mutex.unlock();
    }
}

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
        staging_bytes: usize,
    };

    self.mutex.lockShared();
    const max_uploads = self.config.getMaxUploadsPerFrame();
    self.mutex.unlockShared();

    var uploads: u32 = 0;
    var uploaded_bytes: usize = 0;

    while (uploads < max_uploads) {
        const prep_timer = self.profiling.begin();
        var task: ?UploadTask = null;
        var oversized_fallback: ?UploadTask = null;
        var completed_without_upload = false;
        var made_progress = false;
        var deferred_for_budget = false;

        self.mutex.lock();
        const active_lod_count = lod_chunk.activeLODCount(self.config);

        // Inspect at most the queue depth observed for each level. An
        // oversized far migration goes back at the tail, allowing a later
        // near upload to use the remaining frame budget without looping on
        // that deferred entry forever.
        var order_idx: usize = 0;
        while (order_idx < active_lod_count and task == null and !completed_without_upload) : (order_idx += 1) {
            const i = lod_scheduler.priorityLevelIndex(order_idx, active_lod_count);
            const attempts = self.upload_queues[i].count();
            var attempt: usize = 0;
            while (attempt < attempts and task == null and !completed_without_upload) : (attempt += 1) if (self.upload_queues[i].pop()) |chunk| {
                made_progress = true;
                const key = chunk.key();
                if (self.meshes[i].get(key)) |mesh| {
                    const staging_bytes = self.gpu_bridge.uploadCost(mesh).total();
                    if (wouldExceedUploadBudget(uploaded_bytes, staging_bytes, upload_budget_bytes)) {
                        self.profiling.addStagingPressure();
                        deferred_for_budget = true;
                        // Preserve room for any smaller task later in the
                        // priority scan. If every queued task is oversized,
                        // admit one at the start of the frame so a pool
                        // migration cannot be deferred forever.
                        if (uploaded_bytes == 0 and oversized_fallback == null) {
                            oversized_fallback = .{
                                .key = key,
                                .chunk = chunk,
                                .mesh = mesh,
                                .lod_idx = i,
                                .staging_bytes = staging_bytes,
                            };
                        } else {
                            self.requeueUpload(i, chunk);
                        }
                        continue;
                    }

                    chunk.pin();
                    task = .{
                        .key = key,
                        .chunk = chunk,
                        .mesh = mesh,
                        .lod_idx = i,
                        .staging_bytes = staging_bytes,
                    };
                } else {
                    self.markRegionRenderable(key, chunk);
                    uploads += 1;
                    completed_without_upload = true;
                }
            };
        }
        if (oversized_fallback) |fallback| {
            if (task == null and !completed_without_upload and uploaded_bytes == 0) {
                fallback.chunk.pin();
                task = fallback;
            } else {
                self.requeueUpload(fallback.lod_idx, fallback.chunk);
            }
        }
        self.mutex.unlock();

        if (!made_progress) {
            self.profiling.end(.upload_prep, prep_timer);
            break;
        }
        if (completed_without_upload) {
            self.profiling.end(.upload_prep, prep_timer);
            continue;
        }

        const upload_task = task orelse {
            self.profiling.end(.upload_prep, prep_timer);
            if (deferred_for_budget) break;
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
                self.profiling.addCompactUploadFailure();
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

        uploaded_bytes = std.math.add(usize, uploaded_bytes, upload_task.staging_bytes) catch std.math.maxInt(usize);
        self.profiling.addUploadBytes(upload_task.staging_bytes);
        // Count only ownership that reached the GPU bridge successfully. A
        // requeued failure arrives here once on its eventual successful upload,
        // never once per retry. LOD3/LOD4 are the compact far-path boundary;
        // near pooled uploads remain intentionally outside this comparison.
        if (upload_task.lod_idx >= @intFromEnum(LODLevel.lod3)) {
            if (upload_task.mesh.isCompact()) {
                self.profiling.addCompactUploadBytes(upload_task.staging_bytes);
            } else {
                self.profiling.addFarExpandedUploadBytes(upload_task.staging_bytes);
            }
        }
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
    self.enqueueFade(parent, parent_chunk);
}

pub fn markRegionRenderable(self: *Self, key: LODRegionKey, chunk: *LODChunk) void {
    if (chunk.isRenderable()) return;
    chunk.markRenderable(self.countRenderableChildren(key));
    if (engine_core.envFlag("ZIGCRAFT_LOD_DIAG", false)) {
        log.log.warn("LOD_REGION_RENDERABLE: lod={} region=({}, {})", .{ @intFromEnum(key.lod), key.rx, key.rz });
    }
    self.enqueueFade(key, chunk);
    if (self.pending_region_count > 0) self.pending_region_count -= 1;
    if (self.regionContributesGeometry(key, chunk)) {
        self.adjustParentReadyChildren(key, 1);
    }
}

pub fn decayTransitionFrames(self: *Self) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    var processed: usize = 0;
    while (processed < MAX_LIFECYCLE_TRANSITIONS_PER_UPDATE) : (processed += 1) {
        const token = self.fade_tokens.pop() orelse break;
        if (token.stage != .fade) continue;
        const chunk = self.regions[@intFromEnum(token.key.lod)].get(token.key) orelse continue;
        if (!token.matches(chunk)) continue;
        chunk.tickTransition();
        if (chunk.transition_frames_remaining > 0) {
            _ = self.fade_tokens.push(self.allocator, token) catch false;
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
        // Source revisions invalidate any queued worker/transition token before
        // the edited data is allowed to publish a replacement mesh.
        chunk.job_token +%= 1;
        chunk.setState(.generated);
        self.pending_region_count += 1;
        self.enqueueTransition(key, chunk, .mesh);
    } else if (chunk.getState() == .mesh_ready or chunk.getState() == .generated) {
        // A queued transition captured the pre-edit source revision. Invalidate
        // it and publish a mesh transition for the authoritative edited data.
        chunk.job_token +%= 1;
        chunk.setState(.generated);
        self.enqueueTransition(key, chunk, .mesh);
    }
}
