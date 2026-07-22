const std = @import("std");
const testing = std.testing;
const session_module = @import("game-core").session;
const BuildConfig = session_module.BuildConfig;
const Settings = @import("game-core").Settings;

test "distance metadata keeps render distance uncapped and bounds the user LOD horizon" {
    const range = Settings.metadata.render_distance.kind.int_range;
    try testing.expectEqual(@as(i32, 2), range.min);
    try testing.expectEqual(std.math.maxInt(i32), range.max);

    const horizon_range = Settings.metadata.horizon_distance.kind.int_range;
    try testing.expectEqual(@as(i32, 256), horizon_range.min);
    try testing.expectEqual(@as(i32, 512), horizon_range.max);
}

test "camera far plane covers the configured LOD horizon" {
    try testing.expectEqual(@as(f32, 10_000.0), session_module.cameraFarPlaneForHorizon(256));
    try testing.expectEqual(@as(f32, 17_408.0), session_module.cameraFarPlaneForHorizon(1024));
    try testing.expectEqual(@as(f32, 17_408.0), session_module.cameraFarPlaneForDistances(1024, 256));
    try testing.expect(session_module.cameraFarPlaneForHorizon(std.math.maxInt(i32)) > 34_000_000_000.0);
}

fn chunkDebugRestoreEnabled(build_config: BuildConfig, name: []const u8) bool {
    if (!build_config.chunk_debug_mode) return false;

    var it = std.mem.tokenizeScalar(u8, build_config.chunk_debug_enable, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }
    return false;
}

test "chunkDebugRestoreEnabled returns false when chunk_debug_mode is false" {
    const build_config = BuildConfig{ .chunk_debug_mode = false };
    try testing.expect(!chunkDebugRestoreEnabled(build_config, "lod"));
    try testing.expect(!chunkDebugRestoreEnabled(build_config, "water"));
}

test "chunkDebugRestoreEnabled finds single enabled feature" {
    const build_config = BuildConfig{
        .chunk_debug_mode = true,
        .chunk_debug_enable = "lod",
    };
    try testing.expect(chunkDebugRestoreEnabled(build_config, "lod"));
    try testing.expect(!chunkDebugRestoreEnabled(build_config, "water"));
}

test "chunkDebugRestoreEnabled finds feature among comma-separated list" {
    const build_config = BuildConfig{
        .chunk_debug_mode = true,
        .chunk_debug_enable = "lod,water,caves",
    };
    try testing.expect(chunkDebugRestoreEnabled(build_config, "lod"));
    try testing.expect(chunkDebugRestoreEnabled(build_config, "water"));
    try testing.expect(chunkDebugRestoreEnabled(build_config, "caves"));
    try testing.expect(!chunkDebugRestoreEnabled(build_config, "decorations"));
}

test "chunkDebugRestoreEnabled trims whitespace" {
    const build_config = BuildConfig{
        .chunk_debug_mode = true,
        .chunk_debug_enable = " lod , water , caves ",
    };
    try testing.expect(chunkDebugRestoreEnabled(build_config, "lod"));
    try testing.expect(chunkDebugRestoreEnabled(build_config, "water"));
    try testing.expect(chunkDebugRestoreEnabled(build_config, "caves"));
}

test "chunkDebugRestoreEnabled is case insensitive" {
    const build_config = BuildConfig{
        .chunk_debug_mode = true,
        .chunk_debug_enable = "LOD",
    };
    try testing.expect(chunkDebugRestoreEnabled(build_config, "lod"));
    try testing.expect(chunkDebugRestoreEnabled(build_config, "LOD"));
    try testing.expect(chunkDebugRestoreEnabled(build_config, "Lod"));
}

test "chunkDebugRestoreEnabled returns false for missing feature" {
    const build_config = BuildConfig{
        .chunk_debug_mode = true,
        .chunk_debug_enable = "lod,water",
    };
    try testing.expect(!chunkDebugRestoreEnabled(build_config, "caves"));
    try testing.expect(!chunkDebugRestoreEnabled(build_config, "decorations"));
}
