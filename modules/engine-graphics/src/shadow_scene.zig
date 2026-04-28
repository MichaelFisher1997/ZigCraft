const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const ShadowConfig = @import("engine-rhi").ShadowConfig;

pub const IShadowScene = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        renderShadowPass: *const fn (ptr: *anyopaque, light_space_matrix: Mat4, camera_pos: Vec3, shadow_config: ShadowConfig) void,
    };

    pub fn renderShadowPass(self: IShadowScene, light_space_matrix: Mat4, camera_pos: Vec3, shadow_config: ShadowConfig) void {
        self.vtable.renderShadowPass(self.ptr, light_space_matrix, camera_pos, shadow_config);
    }
};
