const rhi = @import("engine-rhi").rhi;
const Mat4 = @import("engine-math").Mat4;

pub const ShadowUniforms = extern struct {
    light_space_matrices: [rhi.SHADOW_CASCADE_COUNT]Mat4,
    cascade_splits: [4]f32,
    overlap_starts: [4]f32,
    shadow_texel_sizes: [4]f32,
    shadow_depth_spans: [4]f32,
    shadow_params: [4]f32,
    fade_params: [4]f32,
};

comptime {
    if (rhi.SHADOW_CASCADE_COUNT != 4) @compileError("shadow shader ABI requires four cascades");
    if (@sizeOf(ShadowUniforms) != 352) @compileError("unexpected ShadowUniforms size");
    if (@offsetOf(ShadowUniforms, "cascade_splits") != 256) @compileError("unexpected cascade_splits offset");
    if (@offsetOf(ShadowUniforms, "overlap_starts") != 272) @compileError("unexpected overlap_starts offset");
    if (@offsetOf(ShadowUniforms, "shadow_texel_sizes") != 288) @compileError("unexpected shadow_texel_sizes offset");
    if (@offsetOf(ShadowUniforms, "shadow_depth_spans") != 304) @compileError("unexpected shadow_depth_spans offset");
    if (@offsetOf(ShadowUniforms, "shadow_params") != 320) @compileError("unexpected shadow_params offset");
    if (@offsetOf(ShadowUniforms, "fade_params") != 336) @compileError("unexpected fade_params offset");
}
