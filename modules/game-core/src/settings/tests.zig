const std = @import("std");
const data = @import("data.zig");
const Settings = data.Settings;
const presets = @import("json_presets.zig");
const persistence = @import("persistence.zig");
const RenderDistancePreset = @import("engine-rhi").RenderDistancePreset;

test "Persistence Roundtrip" {
    const allocator = std.testing.allocator;
    _ = allocator;
    var settings = Settings{};
    settings.shadow_quality = 3;
    settings.render_distance = 25;
    settings.lod_enabled = true;
}

test "Preset Application" {
    const allocator = std.testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    var settings = Settings{};
    presets.apply(&settings, 0);
    try std.testing.expectEqual(@as(u32, 0), settings.shadow_quality);
    try std.testing.expectEqual(@as(i32, 6), settings.render_distance);
    try std.testing.expectEqual(RenderDistancePreset.low, settings.render_distance_preset);
    try std.testing.expectEqual(true, settings.lod_enabled);

    presets.apply(&settings, 3);
    try std.testing.expectEqual(@as(u32, 3), settings.shadow_quality);
    try std.testing.expectEqual(@as(i32, 14), settings.render_distance);
    try std.testing.expectEqual(RenderDistancePreset.ultra, settings.render_distance_preset);
    try std.testing.expectEqual(true, settings.lod_enabled);

    presets.apply(&settings, 4);
    try std.testing.expectEqual(@as(u32, 3), settings.shadow_quality);
    try std.testing.expectEqual(@as(i32, 16), settings.render_distance);
    try std.testing.expectEqual(RenderDistancePreset.extreme, settings.render_distance_preset);
    try std.testing.expectEqual(true, settings.lod_enabled);
}

test "Preset Matching" {
    const allocator = std.testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    var settings = Settings{};
    presets.apply(&settings, 1); // Medium
    try std.testing.expectEqual(@as(usize, 1), presets.getIndex(&settings));

    // Modify a value to make it Custom
    settings.shadow_quality = 3;
    try std.testing.expectEqual(presets.count(), presets.getIndex(&settings));
}

test "TAA and LOD conflict sanitization" {
    var settings = Settings{};
    settings.lod_enabled = true;
    settings.taa_enabled = true;
    settings.fxaa_enabled = false;

    try std.testing.expectEqual(true, data.sanitizeRuntimeConflicts(&settings));
    try std.testing.expectEqual(false, settings.taa_enabled);
    try std.testing.expectEqual(true, settings.fxaa_enabled);
}
