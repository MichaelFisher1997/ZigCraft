const rhi = @import("engine-rhi");
const Vec3 = @import("engine-math").Vec3;

pub const CloudConfig = struct {
    enabled: bool = true,
    enable_3d: bool = true,
    radius: u16 = 25,
    density: f32 = 0.42,
    height: f32 = 192.0,
    thickness: f32 = 16.0,
    speed_x: f32 = 0.0,
    speed_z: f32 = -2.0,
    seed: u32 = 1337,
};

pub const ICloudSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        setConfig: *const fn (ptr: *anyopaque, config: CloudConfig) void,
        step: *const fn (ptr: *anyopaque, dt: f32) void,
        render: *const fn (ptr: *anyopaque, ctx: rhi.RenderContext, camera_pos: Vec3) anyerror!void,
    };

    pub fn deinit(self: ICloudSystem) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn setConfig(self: ICloudSystem, config: CloudConfig) void {
        self.vtable.setConfig(self.ptr, config);
    }

    pub fn step(self: ICloudSystem, dt: f32) void {
        self.vtable.step(self.ptr, dt);
    }

    pub fn render(self: ICloudSystem, ctx: rhi.RenderContext, camera_pos: Vec3) !void {
        try self.vtable.render(self.ptr, ctx, camera_pos);
    }
};
