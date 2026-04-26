//! Render feature flags derived from build options, runtime environment, and safety mode.

const std = @import("std");
const build_options = @import("build_options");
const runtime_env = @import("../core/runtime_env.zig");

pub const RenderFeatureFlags = struct {
    safe_render_mode: bool,
    safe_mode_explicit: bool,
    safe_mode: bool,
    disable_shadow_draw: bool,
    disable_gpass_draw: bool,
    disable_ssao: bool,
    disable_water: bool,
    disable_taa: bool,
    disable_fxaa: bool,
    disable_bloom: bool,
    chunk_debug_mode: bool,
    chunk_debug_enable: []const u8,

    pub fn init() RenderFeatureFlags {
        const safe_render_mode = envEnabled("ZIGCRAFT_SAFE_RENDER");
        const safe_mode_explicit = getenv("ZIGCRAFT_SAFE_MODE") != null;
        const safe_mode = runtime_env.safeModeEnabled();

        const chunk_debug_restore_water = chunkDebugRestoreEnabled("water") or chunkDebugRestoreEnabled("waterrender");
        return .{
            .safe_render_mode = safe_render_mode,
            .safe_mode_explicit = safe_mode_explicit,
            .safe_mode = safe_mode,
            .disable_shadow_draw = envEnabled("ZIGCRAFT_DISABLE_SHADOWS"),
            .disable_gpass_draw = envEnabled("ZIGCRAFT_DISABLE_GPASS"),
            .disable_ssao = envEnabled("ZIGCRAFT_DISABLE_SSAO"),
            .disable_water = (build_options.chunk_debug_mode and !chunk_debug_restore_water) or envEnabled("ZIGCRAFT_DISABLE_WATER"),
            .disable_taa = envEnabled("ZIGCRAFT_DISABLE_TAA"),
            .disable_fxaa = envEnabled("ZIGCRAFT_DISABLE_FXAA"),
            .disable_bloom = envEnabled("ZIGCRAFT_DISABLE_BLOOM"),
            .chunk_debug_mode = build_options.chunk_debug_mode,
            .chunk_debug_enable = build_options.chunk_debug_enable,
        };
    }
};

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

fn envEnabled(name: [:0]const u8) bool {
    return if (getenv(name)) |val|
        !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
    else
        false;
}

fn chunkDebugRestoreEnabled(name: []const u8) bool {
    if (!build_options.chunk_debug_mode) return false;

    var it = std.mem.tokenizeScalar(u8, build_options.chunk_debug_enable, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }
    return false;
}
