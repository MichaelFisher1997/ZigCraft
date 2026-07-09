const rhi = @import("engine-rhi").rhi;
const Mat4 = @import("engine-math").Mat4;

pub const ShadowUniforms = extern struct {
    light_space_matrices: [rhi.SHADOW_CASCADE_COUNT]Mat4,
    cascade_splits: [4]f32,
    shadow_texel_sizes: [4]f32,
    shadow_params: [4]f32,
};

comptime {
    if (rhi.SHADOW_CASCADE_COUNT != 4) @compileError("shadow shader ABI requires four cascades");
    if (@sizeOf(ShadowUniforms) != 304) @compileError("unexpected ShadowUniforms size");
    if (@offsetOf(ShadowUniforms, "cascade_splits") != 256) @compileError("unexpected cascade_splits offset");
    if (@offsetOf(ShadowUniforms, "shadow_texel_sizes") != 272) @compileError("unexpected shadow_texel_sizes offset");
    if (@offsetOf(ShadowUniforms, "shadow_params") != 288) @compileError("unexpected shadow_params offset");
}
