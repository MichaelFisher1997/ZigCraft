const std = @import("std");
const testing = std.testing;
const session_module = @import("game-core").session;
const BuildConfig = session_module.BuildConfig;

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
