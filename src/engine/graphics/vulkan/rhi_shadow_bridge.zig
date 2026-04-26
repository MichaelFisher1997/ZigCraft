const rhi = @import("../rhi.zig");
const Mat4 = @import("../../math/mat4.zig").Mat4;

const ShadowUniforms = extern struct {
    light_space_matrices: [rhi.SHADOW_CASCADE_COUNT]Mat4,
    cascade_splits: [4]f32,
    shadow_texel_sizes: [4]f32,
    shadow_params: [4]f32, // x = light_size (PCSS), y = 1 / shadow resolution
};

pub fn beginShadowPassInternal(ctx: anytype, cascade_index: u32, light_space_matrix: Mat4) void {
    if (!ctx.frames.frame_in_progress) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    ctx.shadow_system.beginPass(command_buffer, cascade_index, light_space_matrix);
}

pub fn endShadowPassInternal(ctx: anytype) void {
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    ctx.shadow_system.endPass(command_buffer);
}

pub fn getShadowMapHandle(ctx: anytype, cascade_index: u32) rhi.TextureHandle {
    if (cascade_index >= rhi.SHADOW_CASCADE_COUNT) return 0;
    return ctx.shadow_runtime.shadow_map_handles[cascade_index];
}

pub fn updateShadowUniforms(ctx: anytype, params: rhi.ShadowParams) !void {
    var splits = [_]f32{ 0, 0, 0, 0 };
    var sizes = [_]f32{ 0, 0, 0, 0 };
    @memcpy(splits[0..rhi.SHADOW_CASCADE_COUNT], &params.cascade_splits);
    @memcpy(sizes[0..rhi.SHADOW_CASCADE_COUNT], &params.shadow_texel_sizes);

    @memcpy(&ctx.shadow_runtime.shadow_texel_sizes, &params.shadow_texel_sizes);

    const inv_resolution: f32 = if (params.resolution > 0) 1.0 / @as(f32, @floatFromInt(params.resolution)) else 1.0 / 4096.0;
    const shadow_uniforms = ShadowUniforms{
        .light_space_matrices = params.light_space_matrices,
        .cascade_splits = splits,
        .shadow_texel_sizes = sizes,
        .shadow_params = .{ params.light_size, inv_resolution, 0.0, 0.0 },
    };

    try ctx.descriptors.updateShadowUniforms(ctx.frames.current_frame, &shadow_uniforms);
}

pub fn drawDebugShadowMap(_: anytype, _: usize, _: rhi.TextureHandle) void {}
