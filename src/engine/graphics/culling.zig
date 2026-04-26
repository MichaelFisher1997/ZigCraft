const Mat4 = @import("../math/mat4.zig").Mat4;

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

    pub fn deinit(self: ICullingSystem) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn updateAABBData(self: ICullingSystem, frame_index: usize, chunks: []const ChunkCullData) void {
        self.vtable.updateAABBData(self.ptr, frame_index, chunks);
    }

    pub fn readVisibleCount(self: ICullingSystem, frame_index: usize) u32 {
        return self.vtable.readVisibleCount(self.ptr, frame_index);
    }

    pub fn readVisibleIndices(self: ICullingSystem, frame_index: usize, count: u32, out: []u32) void {
        self.vtable.readVisibleIndices(self.ptr, frame_index, count, out);
    }

    pub fn dispatch(self: ICullingSystem, config: DispatchConfig) void {
        self.vtable.dispatch(self.ptr, config);
    }
};
