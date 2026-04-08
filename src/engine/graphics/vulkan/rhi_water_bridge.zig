const rhi = @import("../rhi.zig");
const Mat4 = @import("../../math/mat4.zig").Mat4;
const Vec3 = @import("../../math/vec3.zig").Vec3;
const water_system = @import("water_system.zig");

pub fn beginWaterReflectionPassInternal(ctx: anytype) void {
    if (!ctx.frames.frame_in_progress) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    ctx.water_system.beginReflectionPass(command_buffer);
}

pub fn endWaterReflectionPassInternal(ctx: anytype) void {
    if (!ctx.frames.frame_in_progress) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    ctx.water_system.endReflectionPass(command_buffer);
}

pub fn getWaterReflectionTextureHandle(ctx: anytype) rhi.TextureHandle {
    _ = ctx;
    return 0;
}

pub fn computeWaterReflectedViewProj(ctx: anytype, view: Mat4, proj: Mat4, camera_pos: Vec3) Mat4 {
    return ctx.water_system.computeReflectedViewProj(view, proj, camera_pos);
}
