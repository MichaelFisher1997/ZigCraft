const Mat4 = @import("engine-math").Mat4;
const rhi_types = @import("rhi_types.zig");

pub const ChunkCullData = extern struct {
    min_point: [4]f32,
    max_point: [4]f32,
};

pub const DispatchConfig = struct {
    view_proj: Mat4,
    chunk_count: u32,
    screen_width: f32,
    screen_height: f32,
    previous_frame_valid: bool,
};

pub const ICullingSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        updateAABBData: *const fn (ptr: *anyopaque, frame_index: usize, chunks: []const ChunkCullData) void,
        readVisibleCount: *const fn (ptr: *anyopaque, frame_index: usize) u32,
        readVisibleIndices: *const fn (ptr: *anyopaque, frame_index: usize, count: u32, out: []u32) void,
        dispatch: *const fn (ptr: *anyopaque, config: DispatchConfig) void,
    };

    /// Releases backend culling buffers, pipelines, and readback resources.
    /// No dispatch or readback methods may be used after this returns.
    pub fn deinit(self: ICullingSystem) void {
        self.vtable.deinit(self.ptr);
    }

    /// Uploads chunk AABB data for the selected frame-in-flight slot.
    /// `chunks` is copied or staged by the backend and must match the dispatch chunk count used for that frame.
    pub fn updateAABBData(self: ICullingSystem, frame_index: usize, chunks: []const ChunkCullData) void {
        self.vtable.updateAABBData(self.ptr, frame_index, chunks);
    }

    /// Reads the visible chunk count produced by a previous culling dispatch.
    /// The returned value is valid only after the backend has completed the corresponding frame's compute work.
    pub fn readVisibleCount(self: ICullingSystem, frame_index: usize) u32 {
        return self.vtable.readVisibleCount(self.ptr, frame_index);
    }

    /// Copies visible chunk indices from backend readback storage into `out`.
    /// `count` should come from `readVisibleCount`; the implementation clamps writes to `out.len`.
    pub fn readVisibleIndices(self: ICullingSystem, frame_index: usize, count: u32, out: []u32) void {
        self.vtable.readVisibleIndices(self.ptr, frame_index, count, out);
    }

    /// Dispatches GPU frustum/occlusion culling for the configured chunk set.
    /// Must run on the render thread with current-frame AABB data already uploaded.
    pub fn dispatch(self: ICullingSystem, config: DispatchConfig) void {
        self.vtable.dispatch(self.ptr, config);
    }
};

/// One CPU-approved LOD region.  The layout deliberately uses only vec4/mat4
/// aligned fields so it can be consumed directly by a std430 storage buffer.
pub const LODCullCandidate = extern struct {
    min_point: [4]f32,
    max_point: [4]f32,
    model: Mat4,
    instance_params: [4]f32,
    terrain_command: rhi_types.DrawIndirectCommand,
    water_command: rhi_types.DrawIndirectCommand,
    lod_and_padding: [4]u32,
};

pub const LODCullDispatch = extern struct {
    planes: [6][4]f32,
    candidate_count: u32,
    max_distance_blocks: f32,
    max_commands_per_lod: u32,
    _padding: u32 = 0,
};

pub const LODCullDiagnostics = extern struct {
    overflow_count: u32 = 0,
    validation_mismatch_count: u32 = 0,
};

pub const ILODCullingSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        dispatch: *const fn (ptr: *anyopaque, frame_index: usize, candidates: []const LODCullCandidate, config: LODCullDispatch) bool,
        instanceBuffer: *const fn (ptr: *anyopaque, frame_index: usize, fluid: bool) rhi_types.BufferHandle,
        indirectBuffer: *const fn (ptr: *anyopaque, frame_index: usize, fluid: bool) rhi_types.BufferHandle,
        countBuffer: *const fn (ptr: *anyopaque, frame_index: usize) rhi_types.BufferHandle,
        diagnostics: *const fn (ptr: *anyopaque) LODCullDiagnostics,
    };

    pub fn deinit(self: ILODCullingSystem) void {
        self.vtable.deinit(self.ptr);
    }

    /// Records same-frame compute culling before graphics render passes begin.
    /// Returns false when inputs exceed the fixed GPU capacity.
    pub fn dispatch(self: ILODCullingSystem, frame_index: usize, candidates: []const LODCullCandidate, config: LODCullDispatch) bool {
        return self.vtable.dispatch(self.ptr, frame_index, candidates, config);
    }

    pub fn instanceBuffer(self: ILODCullingSystem, frame_index: usize, fluid: bool) rhi_types.BufferHandle {
        return self.vtable.instanceBuffer(self.ptr, frame_index, fluid);
    }

    pub fn indirectBuffer(self: ILODCullingSystem, frame_index: usize, fluid: bool) rhi_types.BufferHandle {
        return self.vtable.indirectBuffer(self.ptr, frame_index, fluid);
    }
    pub fn countBuffer(self: ILODCullingSystem, frame_index: usize) rhi_types.BufferHandle {
        return self.vtable.countBuffer(self.ptr, frame_index);
    }
    pub fn diagnostics(self: ILODCullingSystem) LODCullDiagnostics {
        return self.vtable.diagnostics(self.ptr);
    }
};

test "LOD culling candidate ABI is std430 aligned" {
    try @import("std").testing.expectEqual(@as(usize, 160), @sizeOf(LODCullCandidate));
    try @import("std").testing.expectEqual(@as(usize, 32), @offsetOf(LODCullCandidate, "model"));
    try @import("std").testing.expectEqual(@as(usize, 96), @offsetOf(LODCullCandidate, "instance_params"));
}
