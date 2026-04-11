const std = @import("std");
const Settings = @import("data.zig").Settings;
const SHADOW_QUALITIES = @import("data.zig").SHADOW_QUALITIES;
const RESOLUTIONS = @import("data.zig").RESOLUTIONS;
const resolveShadowDebugChannel = @import("data.zig").resolveShadowDebugChannel;
const ShadowDebugChannel = @import("data.zig").ShadowDebugChannel;
const presets = @import("json_presets.zig");
const persistence = @import("persistence.zig");
const RenderDistancePreset = @import("../../engine/graphics/render_settings.zig").RenderDistancePreset;

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
    try std.testing.expectEqual(@as(i32, 8), settings.render_distance);
    try std.testing.expectEqual(RenderDistancePreset.low, settings.render_distance_preset);
    try std.testing.expectEqual(true, settings.lod_enabled);

    presets.apply(&settings, 3);
    try std.testing.expectEqual(@as(u32, 3), settings.shadow_quality);
    try std.testing.expectEqual(@as(i32, 16), settings.render_distance);
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
    try std.testing.expectEqual(presets.graphics_presets.items.len, presets.getIndex(&settings));
}

test "Settings.getShadowResolution returns correct resolution for quality levels" {
    var settings = Settings{};

    settings.shadow_quality = 0;
    try std.testing.expectEqual(@as(u32, 1024), settings.getShadowResolution());

    settings.shadow_quality = 1;
    try std.testing.expectEqual(@as(u32, 1536), settings.getShadowResolution());

    settings.shadow_quality = 2;
    try std.testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());

    settings.shadow_quality = 3;
    try std.testing.expectEqual(@as(u32, 4096), settings.getShadowResolution());
}

test "Settings.getShadowResolution defaults to high for invalid quality" {
    var settings = Settings{};
    settings.shadow_quality = 99;
    try std.testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());
}

test "Settings.getResolutionIndex finds standard resolutions" {
    var settings = Settings{};

    settings.window_width = 1920;
    settings.window_height = 1080;
    try std.testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());

    settings.window_width = 1280;
    settings.window_height = 720;
    try std.testing.expectEqual(@as(usize, 0), settings.getResolutionIndex());

    settings.window_width = 3840;
    settings.window_height = 2160;
    try std.testing.expectEqual(@as(usize, 6), settings.getResolutionIndex());
}

test "Settings.getResolutionIndex returns default for unknown resolution" {
    var settings = Settings{};
    settings.window_width = 9999;
    settings.window_height = 9999;
    try std.testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());
}

test "Settings.setResolutionByIndex sets correct resolution" {
    var settings = Settings{};

    settings.setResolutionByIndex(0);
    try std.testing.expectEqual(@as(u32, 1280), settings.window_width);
    try std.testing.expectEqual(@as(u32, 720), settings.window_height);

    settings.setResolutionByIndex(4);
    try std.testing.expectEqual(@as(u32, 2560), settings.window_width);
    try std.testing.expectEqual(@as(u32, 1440), settings.window_height);

    settings.setResolutionByIndex(6);
    try std.testing.expectEqual(@as(u32, 3840), settings.window_width);
    try std.testing.expectEqual(@as(u32, 2160), settings.window_height);
}

test "Settings.setResolutionByIndex ignores out of bounds index" {
    var settings = Settings{};
    const original_width = settings.window_width;
    const original_height = settings.window_height;

    settings.setResolutionByIndex(99);
    try std.testing.expectEqual(original_width, settings.window_width);
    try std.testing.expectEqual(original_height, settings.window_height);

    settings.setResolutionByIndex(1000);
    try std.testing.expectEqual(original_width, settings.window_width);
}

test "SHADOW_QUALITIES array has correct count and values" {
    try std.testing.expectEqual(@as(usize, 4), SHADOW_QUALITIES.len);
    try std.testing.expectEqual(@as(u32, 1024), SHADOW_QUALITIES[0].resolution);
    try std.testing.expectEqualStrings("LOW", SHADOW_QUALITIES[0].label);
    try std.testing.expectEqual(@as(u32, 4096), SHADOW_QUALITIES[3].resolution);
    try std.testing.expectEqualStrings("ULTRA", SHADOW_QUALITIES[3].label);
}

test "RESOLUTIONS array has correct count" {
    try std.testing.expectEqual(@as(usize, 7), RESOLUTIONS.len);
}

test "RESOLUTIONS array contains expected resolutions" {
    try std.testing.expectEqual(@as(u32, 1280), RESOLUTIONS[0].width);
    try std.testing.expectEqual(@as(u32, 720), RESOLUTIONS[0].height);
    try std.testing.expectEqualStrings("1280X720", RESOLUTIONS[0].label);

    try std.testing.expectEqual(@as(u32, 1920), RESOLUTIONS[2].width);
    try std.testing.expectEqual(@as(u32, 1080), RESOLUTIONS[2].height);
}

test "resolveShadowDebugChannel returns correct channel based on flags" {
    var settings = Settings{};

    settings.debug_shadows_active = false;
    settings.debug_shadow_cascade_index = false;
    settings.debug_shadow_caster_coverage = false;
    settings.debug_shadow_seam_diag = false;
    try std.testing.expectEqual(ShadowDebugChannel.off, resolveShadowDebugChannel(&settings));

    settings.debug_shadows_active = true;
    try std.testing.expectEqual(ShadowDebugChannel.shadow_factor, resolveShadowDebugChannel(&settings));

    settings.debug_shadows_active = false;
    settings.debug_shadow_cascade_index = true;
    try std.testing.expectEqual(ShadowDebugChannel.cascade_index, resolveShadowDebugChannel(&settings));

    settings.debug_shadow_cascade_index = false;
    settings.debug_shadow_caster_coverage = true;
    try std.testing.expectEqual(ShadowDebugChannel.caster_coverage, resolveShadowDebugChannel(&settings));

    settings.debug_shadow_caster_coverage = false;
    settings.debug_shadow_seam_diag = true;
    try std.testing.expectEqual(ShadowDebugChannel.seam_diagnostics, resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel seam_diag takes priority" {
    var settings = Settings{};
    settings.debug_shadows_active = true;
    settings.debug_shadow_cascade_index = true;
    settings.debug_shadow_caster_coverage = true;
    settings.debug_shadow_seam_diag = true;
    try std.testing.expectEqual(ShadowDebugChannel.seam_diagnostics, resolveShadowDebugChannel(&settings));
}

test "setTexturePack returns early if same name" {
    var settings = Settings{};
    settings.texture_pack = "MyPack";

    try persistence.setTexturePack(&settings, std.testing.allocator, "MyPack");
    try std.testing.expectEqualStrings("MyPack", settings.texture_pack);
}

test "setEnvironmentMap returns early if same name" {
    var settings = Settings{};
    settings.environment_map = "sunset.exr";

    try persistence.setEnvironmentMap(&settings, std.testing.allocator, "sunset.exr");
    try std.testing.expectEqualStrings("sunset.exr", settings.environment_map);
}
