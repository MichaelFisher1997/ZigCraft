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
const LODMesh = @import("lod_mesh.zig").LODMesh;
const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;
const rhi_types = @import("engine-rhi");
const RhiError = rhi_types.RhiError;

/// Callback interface for GPU data operations (upload, destroy, sync).
/// Created by the caller who owns the concrete RHI, passed to LODManager.
pub const LODGPUBridge = struct {
    /// Upload pending vertex data for a mesh to GPU buffers.
    on_upload: *const fn (mesh: *LODMesh, ctx: *anyopaque) RhiError!void,
    /// Destroy GPU resources owned by a mesh.
    on_destroy: *const fn (mesh: *LODMesh, ctx: *anyopaque) void,
    /// Wait for GPU to finish all pending work (needed before batch deletion).
    on_wait_idle: *const fn (ctx: *anyopaque) void,
    /// Opaque context pointer (typically the concrete RHI instance).
    ctx: *anyopaque,

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
};

/// Type aliases used by LODRenderInterface for mesh/region maps.
pub const MeshMap = std.HashMap(LODRegionKey, *LODMesh, LODRegionKeyContext, 80);
pub const RegionMap = std.HashMap(LODRegionKey, *LODChunk, LODRegionKeyContext, 80);

/// Callback type to check if a regular chunk is loaded and renderable.
pub const ChunkChecker = *const fn (chunk_x: i32, chunk_z: i32, ctx: *anyopaque) bool;

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
    ) void,
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
    ) void {
        self.render_fn(self.ptr, meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks);
    }

    pub fn deinit(self: LODRenderInterface) void {
        self.deinit_fn(self.ptr);
    }
};
