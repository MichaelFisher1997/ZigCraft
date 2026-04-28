const Mat4 = @import("engine-math").Mat4;

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
        update_aabb_data: *const fn (ptr: *anyopaque, frame_index: usize, chunks: []const ChunkCullData) void,
        read_visible_count: *const fn (ptr: *anyopaque, frame_index: usize) u32,
        read_visible_indices: *const fn (ptr: *anyopaque, frame_index: usize, count: u32, out: []u32) void,
        dispatch: *const fn (ptr: *anyopaque, config: DispatchConfig) void,
    };

    pub fn deinit(self: ICullingSystem) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn update_aabb_data(self: ICullingSystem, frame_index: usize, chunks: []const ChunkCullData) void {
        self.vtable.update_aabb_data(self.ptr, frame_index, chunks);
    }

    pub fn read_visible_count(self: ICullingSystem, frame_index: usize) u32 {
        return self.vtable.read_visible_count(self.ptr, frame_index);
    }

    pub fn read_visible_indices(self: ICullingSystem, frame_index: usize, count: u32, out: []u32) void {
        self.vtable.read_visible_indices(self.ptr, frame_index, count, out);
    }

    pub fn dispatch(self: ICullingSystem, config: DispatchConfig) void {
        self.vtable.dispatch(self.ptr, config);
    }
};
