//! LOD GPU Bridge - callback interfaces that decouple LOD logic from GPU operations.
//!
//! Extracted from LODManager (Issue #246) to satisfy Single Responsibility Principle.
//! LODManager uses these interfaces instead of holding a direct RHI reference.

const std = @import("std");
const log = @import("engine-core").log;
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODRegionKeyContext = lod_chunk.LODRegionKeyContext;
const ILODConfig = lod_chunk.ILODConfig;
const LODStats = @import("lod_stats.zig").LODStats;
const LODProfilingCollector = @import("lod_stats.zig").LODProfilingCollector;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;
const rhi_types = @import("engine-rhi");
const RhiError = rhi_types.RhiError;
const LODStagingCost = @import("lod_mesh_resources.zig").LODStagingCost;
const LODWaitIdleReason = @import("lod_stats.zig").LODWaitIdleReason;

/// Callback interface for GPU data operations (upload, destroy, sync).
/// Created by the caller who owns the concrete RHI, passed to LODManager.
pub const LODGPUBridge = struct {
    /// Upload pending vertex data for a mesh to GPU buffers.
    on_upload: *const fn (mesh: *LODMesh, ctx: *anyopaque) RhiError!void,
    /// Destroy GPU resources owned by a mesh.
    on_destroy: *const fn (mesh: *LODMesh, ctx: *anyopaque) void,
    /// Wait for GPU to finish all pending work (needed before batch deletion).
    on_wait_idle: *const fn (ctx: *anyopaque) void,
    /// Preflight staging bytes. Non-pooled bridge implementations can omit
    /// this and are charged for the mesh payload alone.
    on_upload_cost: ?*const fn (mesh: *LODMesh, ctx: *anyopaque) LODStagingCost = null,
    /// Opaque context pointer (typically the concrete RHI instance).
    ctx: *anyopaque,
    /// Optional capability probe for compact storage-buffer vertex pulling.
    on_supports_compact: ?*const fn (ctx: *anyopaque) bool = null,
    /// Stronger production capability: compact streams may be GPU-culled with
    /// immutable terrain/water descriptor snapshots.
    on_supports_compact_gpu_culling: ?*const fn (ctx: *anyopaque) bool = null,

    fn hasInvalidCtx(self: LODGPUBridge) bool {
        const ctx_addr = @intFromPtr(self.ctx);
        return ctx_addr == 0 or ctx_addr == 0xaaaa_aaaa_aaaa_aaaa;
    }

    /// Validate that ctx is not undefined/null.
    fn assertValidCtx(self: LODGPUBridge) void {
        std.debug.assert(!self.hasInvalidCtx());
    }

    pub fn upload(self: LODGPUBridge, mesh: *LODMesh) RhiError!void {
        if (self.hasInvalidCtx()) return error.InvalidState;
        self.assertValidCtx();
        return self.on_upload(mesh, self.ctx);
    }

    pub fn destroy(self: LODGPUBridge, mesh: *LODMesh) void {
        if (self.hasInvalidCtx()) {
            log.log.err("LODGPUBridge.destroy called with invalid context pointer", .{});
            return;
        }
        self.assertValidCtx();
        self.on_destroy(mesh, self.ctx);
        mesh.clearPendingVertices();
    }

    pub fn waitIdle(self: LODGPUBridge) void {
        if (self.hasInvalidCtx()) {
            log.log.err("LODGPUBridge.waitIdle called with invalid context pointer", .{});
            return;
        }
        self.assertValidCtx();
        self.on_wait_idle(self.ctx);
    }

    /// Attribute an unavoidable device-wide wait to its caller. Streaming
    /// paths should never need this; renderer shutdown is recorded separately.
    pub fn waitIdleTracked(self: LODGPUBridge, profiling: *LODProfilingCollector, reason: LODWaitIdleReason) void {
        if (self.hasInvalidCtx()) return;
        const timer = profiling.begin();
        self.waitIdle();
        profiling.recordWaitIdle(reason, timer);
    }

    pub fn uploadCost(self: LODGPUBridge, mesh: *LODMesh) LODStagingCost {
        if (self.hasInvalidCtx()) return .{ .payload_bytes = mesh.pendingUploadBytes() };
        const estimate = self.on_upload_cost orelse return .{ .payload_bytes = mesh.pendingUploadBytes() };
        return estimate(mesh, self.ctx);
    }

    pub fn supportsCompact(self: LODGPUBridge) bool {
        if (self.hasInvalidCtx()) return false;
        const probe = self.on_supports_compact orelse return false;
        return probe(self.ctx);
    }

    pub fn supportsCompactGpuCulling(self: LODGPUBridge) bool {
        if (self.hasInvalidCtx()) return false;
        const probe = self.on_supports_compact_gpu_culling orelse return false;
        return probe(self.ctx);
    }
};

/// Type aliases used by LODRenderInterface for mesh/region maps.
pub const MeshMap = std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80);
pub const RegionMap = std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80);

/// Callback type to check if a regular chunk is loaded and renderable.
pub const ChunkChecker = *const fn (chunk_x: i32, chunk_z: i32, ctx: *anyopaque) bool;

pub const LODRenderLayer = enum {
    terrain,
    fluid,
};

/// Renderer-owned LOD pool accounting. Pool allocation and slack are reported
/// separately because every pool buffer also has a same-sized CPU shadow.
pub const LODRendererMemoryStats = struct {
    pool_gpu_capacity_bytes: usize = 0,
    pool_gpu_allocated_bytes: usize = 0,
    pool_gpu_slack_bytes: usize = 0,
    pool_cpu_shadow_bytes: usize = 0,
    compact_pool_capacity_bytes: usize = 0,
    compact_pool_allocated_bytes: usize = 0,
    compact_pool_free_bytes: usize = 0,
    compact_pool_retired_bytes: usize = 0,
};

/// Type-erased interface for LOD rendering.
/// Allows LODManager to delegate rendering without knowing the concrete RHI type.
pub const LODRenderInterface = struct {
    /// Render LOD meshes using the provided data.
    render_fn: *const fn (
        self_ptr: *anyopaque,
        meshes: *const [LODLevel.count]MeshMap,
        regions: *const [LODLevel.count]RegionMap,
        config: ILODConfig,
        view_proj: Mat4,
        camera_pos: Vec3,
        chunk_checker: ?ChunkChecker,
        checker_ctx: ?*anyopaque,
        use_frustum: bool,
        max_distance_chunks: ?i32,
        layer: LODRenderLayer,
        stats: ?*LODStats,
        profiling: ?*LODProfilingCollector,
    ) void,
    /// Frame-aware render entry point. Optional to preserve small test and
    /// alternate renderer implementations; production renderers use it to
    /// share a value-only visibility projection across terrain and water.
    render_frame_fn: ?*const fn (
        self_ptr: *anyopaque,
        frame_serial: u64,
        meshes: *const [LODLevel.count]MeshMap,
        regions: *const [LODLevel.count]RegionMap,
        config: ILODConfig,
        view_proj: Mat4,
        camera_pos: Vec3,
        chunk_checker: ?ChunkChecker,
        checker_ctx: ?*anyopaque,
        use_frustum: bool,
        max_distance_chunks: ?i32,
        layer: LODRenderLayer,
        stats: ?*LODStats,
        profiling: ?*LODProfilingCollector,
    ) void = null,
    prepare_frame_fn: ?*const fn (
        self_ptr: *anyopaque,
        frame_serial: u64,
        meshes: *const [LODLevel.count]MeshMap,
        regions: *const [LODLevel.count]RegionMap,
        config: ILODConfig,
        view_proj: Mat4,
        camera_pos: Vec3,
        chunk_checker: ?ChunkChecker,
        checker_ctx: ?*anyopaque,
        max_distance_chunks: ?i32,
        stats: ?*LODStats,
        profiling: ?*LODProfilingCollector,
    ) void = null,
    memory_stats_fn: ?*const fn (self_ptr: *anyopaque) LODRendererMemoryStats = null,
    /// Destroy renderer resources.
    deinit_fn: *const fn (self_ptr: *anyopaque) void,
    /// Opaque pointer to the concrete renderer.
    ptr: *anyopaque,

    pub fn render(
        self: LODRenderInterface,
        meshes: *const [LODLevel.count]MeshMap,
        regions: *const [LODLevel.count]RegionMap,
        config: ILODConfig,
        view_proj: Mat4,
        camera_pos: Vec3,
        chunk_checker: ?ChunkChecker,
        checker_ctx: ?*anyopaque,
        use_frustum: bool,
        max_distance_chunks: ?i32,
        layer: LODRenderLayer,
        stats: ?*LODStats,
        profiling: ?*LODProfilingCollector,
    ) void {
        self.render_fn(self.ptr, meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, layer, stats, profiling);
    }

    pub fn renderFrame(
        self: LODRenderInterface,
        frame_serial: u64,
        meshes: *const [LODLevel.count]MeshMap,
        regions: *const [LODLevel.count]RegionMap,
        config: ILODConfig,
        view_proj: Mat4,
        camera_pos: Vec3,
        chunk_checker: ?ChunkChecker,
        checker_ctx: ?*anyopaque,
        use_frustum: bool,
        max_distance_chunks: ?i32,
        layer: LODRenderLayer,
        stats: ?*LODStats,
        profiling: ?*LODProfilingCollector,
    ) void {
        if (self.render_frame_fn) |render_frame| {
            render_frame(self.ptr, frame_serial, meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, layer, stats, profiling);
        } else {
            self.render(meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, layer, stats, profiling);
        }
    }

    pub fn deinit(self: LODRenderInterface) void {
        self.deinit_fn(self.ptr);
    }

    pub fn prepareFrame(self: LODRenderInterface, frame_serial: u64, meshes: *const [LODLevel.count]MeshMap, regions: *const [LODLevel.count]RegionMap, config: ILODConfig, view_proj: Mat4, camera_pos: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque, max_distance_chunks: ?i32, stats: ?*LODStats, profiling: ?*LODProfilingCollector) void {
        if (self.prepare_frame_fn) |prepare| prepare(self.ptr, frame_serial, meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, max_distance_chunks, stats, profiling);
    }

    pub fn memoryStats(self: LODRenderInterface) LODRendererMemoryStats {
        if (self.memory_stats_fn) |memory_stats| return memory_stats(self.ptr);
        return .{};
    }
};
