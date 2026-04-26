const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");

const GpuPass = enum {
    shadow_0,
    shadow_1,
    shadow_2,
    g_pass,
    ssao,
    lpv_compute,
    sky,
    opaque_pass,
    bloom,
    fxaa,
    post_process,

    pub const COUNT = 11;
};

pub const QUERY_COUNT_PER_FRAME = GpuPass.COUNT * 2;

fn mapPassName(name: []const u8) ?GpuPass {
    if (std.mem.eql(u8, name, "ShadowPass0")) return .shadow_0;
    if (std.mem.eql(u8, name, "ShadowPass1")) return .shadow_1;
    if (std.mem.eql(u8, name, "ShadowPass2")) return .shadow_2;
    if (std.mem.eql(u8, name, "GPass")) return .g_pass;
    if (std.mem.eql(u8, name, "SSAOPass")) return .ssao;
    if (std.mem.eql(u8, name, "LPVPass")) return .lpv_compute;
    if (std.mem.eql(u8, name, "SkyPass")) return .sky;
    if (std.mem.eql(u8, name, "OpaquePass")) return .opaque_pass;
    if (std.mem.eql(u8, name, "BloomPass")) return .bloom;
    if (std.mem.eql(u8, name, "FXAAPass")) return .fxaa;
    if (std.mem.eql(u8, name, "PostProcessPass")) return .post_process;
    return null;
}

pub fn beginPassTiming(ctx: anytype, pass_name: []const u8) void {
    if (!ctx.timing.timing_enabled or ctx.timing.query_pool == null) return;

    const pass = mapPassName(pass_name) orelse return;
    const cmd = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (cmd == null) return;

    const query_index = @as(u32, @intCast(ctx.frames.current_frame * QUERY_COUNT_PER_FRAME)) + @as(u32, @intFromEnum(pass)) * 2;
    c.vkCmdWriteTimestamp(cmd, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, ctx.timing.query_pool, query_index);
}

pub fn endPassTiming(ctx: anytype, pass_name: []const u8) void {
    if (!ctx.timing.timing_enabled or ctx.timing.query_pool == null) return;

    const pass = mapPassName(pass_name) orelse return;
    const cmd = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (cmd == null) return;

    const query_index = @as(u32, @intCast(ctx.frames.current_frame * QUERY_COUNT_PER_FRAME)) + @as(u32, @intFromEnum(pass)) * 2 + 1;
    c.vkCmdWriteTimestamp(cmd, c.VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, ctx.timing.query_pool, query_index);
}

pub fn processTimingResults(ctx: anytype) void {
    if (!ctx.timing.timing_enabled or ctx.timing.query_pool == null) return;
    if (ctx.runtime.frame_index < rhi.MAX_FRAMES_IN_FLIGHT) return;

    const frame = ctx.frames.current_frame;
    const offset = frame * QUERY_COUNT_PER_FRAME;
    var results: [QUERY_COUNT_PER_FRAME]u64 = .{0} ** QUERY_COUNT_PER_FRAME;

    const res = c.vkGetQueryPoolResults(
        ctx.vulkan_device.vk_device,
        ctx.timing.query_pool,
        @intCast(offset),
        QUERY_COUNT_PER_FRAME,
        @sizeOf(@TypeOf(results)),
        &results,
        @sizeOf(u64),
        c.VK_QUERY_RESULT_64_BIT,
    );

    if (res == c.VK_SUCCESS) {
        const period = ctx.vulkan_device.timestamp_period;

        ctx.timing.timing_results.shadow_pass_ms[0] = @as(f32, @floatFromInt(results[1] -% results[0])) * period / 1e6;
        ctx.timing.timing_results.shadow_pass_ms[1] = @as(f32, @floatFromInt(results[3] -% results[2])) * period / 1e6;
        ctx.timing.timing_results.shadow_pass_ms[2] = @as(f32, @floatFromInt(results[5] -% results[4])) * period / 1e6;
        ctx.timing.timing_results.g_pass_ms = @as(f32, @floatFromInt(results[7] -% results[6])) * period / 1e6;
        ctx.timing.timing_results.ssao_pass_ms = @as(f32, @floatFromInt(results[9] -% results[8])) * period / 1e6;
        ctx.timing.timing_results.lpv_pass_ms = @as(f32, @floatFromInt(results[11] -% results[10])) * period / 1e6;
        ctx.timing.timing_results.sky_pass_ms = @as(f32, @floatFromInt(results[13] -% results[12])) * period / 1e6;
        ctx.timing.timing_results.opaque_pass_ms = @as(f32, @floatFromInt(results[15] -% results[14])) * period / 1e6;
        ctx.timing.timing_results.bloom_pass_ms = @as(f32, @floatFromInt(results[17] -% results[16])) * period / 1e6;
        ctx.timing.timing_results.fxaa_pass_ms = @as(f32, @floatFromInt(results[19] -% results[18])) * period / 1e6;
        ctx.timing.timing_results.post_process_pass_ms = @as(f32, @floatFromInt(results[21] -% results[20])) * period / 1e6;

        ctx.timing.timing_results.main_pass_ms = ctx.timing.timing_results.sky_pass_ms + ctx.timing.timing_results.opaque_pass_ms;
        ctx.timing.timing_results.validate();

        ctx.timing.timing_results.total_gpu_ms = 0;
        ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.shadow_pass_ms[0];
        ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.shadow_pass_ms[1];
        ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.shadow_pass_ms[2];
        ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.g_pass_ms;
        ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.ssao_pass_ms;
        ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.lpv_pass_ms;
        ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.main_pass_ms;
        ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.bloom_pass_ms;
        ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.fxaa_pass_ms;
        ctx.timing.timing_results.total_gpu_ms += ctx.timing.timing_results.post_process_pass_ms;

        if (ctx.timing.timing_enabled) {
            std.debug.print("GPU Frame Time: {d:.2}ms (Shadow: {d:.2}, G-Pass: {d:.2}, SSAO: {d:.2}, LPV: {d:.2}, Main: {d:.2}, Bloom: {d:.2}, FXAA: {d:.2}, Post: {d:.2})\n", .{
                ctx.timing.timing_results.total_gpu_ms,
                ctx.timing.timing_results.shadow_pass_ms[0] + ctx.timing.timing_results.shadow_pass_ms[1] + ctx.timing.timing_results.shadow_pass_ms[2],
                ctx.timing.timing_results.g_pass_ms,
                ctx.timing.timing_results.ssao_pass_ms,
                ctx.timing.timing_results.lpv_pass_ms,
                ctx.timing.timing_results.main_pass_ms,
                ctx.timing.timing_results.bloom_pass_ms,
                ctx.timing.timing_results.fxaa_pass_ms,
                ctx.timing.timing_results.post_process_pass_ms,
            });
        }
    }
}
