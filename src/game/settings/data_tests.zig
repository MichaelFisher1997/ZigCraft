const std = @import("std");
const testing = std.testing;
const data = @import("data.zig");
const Settings = data.Settings;
const resolveShadowDebugChannel = data.resolveShadowDebugChannel;
const ShadowDebugChannel = data.ShadowDebugChannel;
const SHADOW_QUALITIES = data.SHADOW_QUALITIES;
const RESOLUTIONS = data.RESOLUTIONS;
const RenderDistancePreset = @import("../../engine/graphics/render_settings.zig").RenderDistancePreset;

test "Settings has correct default values" {
    const settings = Settings{};

    try testing.expectEqual(@as(i32, 15), settings.render_distance);
    try testing.expectEqual(@as(f32, 50.0), settings.mouse_sensitivity);
    try testing.expect(settings.vsync);
    try testing.expectEqual(@as(f32, 45.0), settings.fov);
    try testing.expect(settings.textures_enabled);
    try testing.expect(!settings.wireframe_enabled);
    try testing.expectEqual(@as(u32, 2), settings.shadow_quality);
    try testing.expectEqual(@as(u8, 16), settings.anisotropic_filtering);
    try testing.expectEqual(@as(u8, 4), settings.msaa_samples);
    try testing.expect(!settings.taa_enabled);
    try testing.expectEqual(@as(f32, 1.0), settings.ui_scale);
    try testing.expectEqual(@as(u32, 1920), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);
    try testing.expect(!settings.lod_enabled);
    try testing.expectEqual(RenderDistancePreset.high, settings.render_distance_preset);
}

test "Settings.getShadowResolution returns correct resolution for quality levels" {
    var settings = Settings{};

    settings.shadow_quality = 0;
    try testing.expectEqual(@as(u32, 1024), settings.getShadowResolution());

    settings.shadow_quality = 1;
    try testing.expectEqual(@as(u32, 1536), settings.getShadowResolution());

    settings.shadow_quality = 2;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());

    settings.shadow_quality = 3;
    try testing.expectEqual(@as(u32, 4096), settings.getShadowResolution());
}

test "Settings.getShadowResolution falls back to HIGH for invalid quality" {
    var settings = Settings{};

    settings.shadow_quality = 99;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());

    settings.shadow_quality = 100;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());
}

test "Settings.getResolutionIndex returns correct index for known resolutions" {
    var settings = Settings{};

    settings.window_width = 1280;
    settings.window_height = 720;
    try testing.expectEqual(@as(usize, 0), settings.getResolutionIndex());

    settings.window_width = 1920;
    settings.window_height = 1080;
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());

    settings.window_width = 3840;
    settings.window_height = 2160;
    try testing.expectEqual(@as(usize, 6), settings.getResolutionIndex());
}

test "Settings.getResolutionIndex returns default for unknown resolution" {
    var settings = Settings{};

    settings.window_width = 9999;
    settings.window_height = 9999;
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());
}

test "Settings.setResolutionByIndex sets correct resolution" {
    var settings = Settings{};

    settings.setResolutionByIndex(0);
    try testing.expectEqual(@as(u32, 1280), settings.window_width);
    try testing.expectEqual(@as(u32, 720), settings.window_height);

    settings.setResolutionByIndex(3);
    try testing.expectEqual(@as(u32, 2560), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);

    settings.setResolutionByIndex(4);
    try testing.expectEqual(@as(u32, 2560), settings.window_width);
    try testing.expectEqual(@as(u32, 1440), settings.window_height);

    settings.setResolutionByIndex(6);
    try testing.expectEqual(@as(u32, 3840), settings.window_width);
    try testing.expectEqual(@as(u32, 2160), settings.window_height);
}

test "Settings.setResolutionByIndex ignores out of bounds index" {
    var settings = Settings{};

    const original_width = settings.window_width;
    const original_height = settings.window_height;

    settings.setResolutionByIndex(999);
    try testing.expectEqual(original_width, settings.window_width);
    try testing.expectEqual(original_height, settings.window_height);
}

test "SHADOW_QUALITIES has 4 entries" {
    try testing.expectEqual(@as(usize, 4), SHADOW_QUALITIES.len);
}

test "SHADOW_QUALITIES entries have valid labels and resolutions" {
    try testing.expectEqualStrings("LOW", SHADOW_QUALITIES[0].label);
    try testing.expectEqual(@as(u32, 1024), SHADOW_QUALITIES[0].resolution);

    try testing.expectEqualStrings("MEDIUM", SHADOW_QUALITIES[1].label);
    try testing.expectEqual(@as(u32, 1536), SHADOW_QUALITIES[1].resolution);

    try testing.expectEqualStrings("HIGH", SHADOW_QUALITIES[2].label);
    try testing.expectEqual(@as(u32, 2048), SHADOW_QUALITIES[2].resolution);

    try testing.expectEqualStrings("ULTRA", SHADOW_QUALITIES[3].label);
    try testing.expectEqual(@as(u32, 4096), SHADOW_QUALITIES[3].resolution);
}

test "RESOLUTIONS has 7 entries" {
    try testing.expectEqual(@as(usize, 7), RESOLUTIONS.len);
}

test "RESOLUTIONS entries are in ascending order" {
    var prev_width: u32 = 0;
    for (RESOLUTIONS) |res| {
        try testing.expect(res.width >= prev_width);
        prev_width = res.width;
    }
}

test "RESOLUTIONS includes common display resolutions" {
    var found_1920x1080 = false;
    var found_2560x1440 = false;
    var found_3840x2160 = false;

    for (RESOLUTIONS) |res| {
        if (res.width == 1920 and res.height == 1080) found_1920x1080 = true;
        if (res.width == 2560 and res.height == 1440) found_2560x1440 = true;
        if (res.width == 3840 and res.height == 2160) found_3840x2160 = true;
    }

    try testing.expect(found_1920x1080);
    try testing.expect(found_2560x1440);
    try testing.expect(found_3840x2160);
}

test "ShadowDebugChannel enum has expected values" {
    try testing.expectEqual(@as(u32, 0), @intFromEnum(ShadowDebugChannel.off));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(ShadowDebugChannel.shadow_factor));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(ShadowDebugChannel.cascade_index));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(ShadowDebugChannel.caster_coverage));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(ShadowDebugChannel.seam_diagnostics));
}

test "resolveShadowDebugChannel returns off when all debug flags are false" {
    const settings = Settings{};
    try testing.expectEqual(ShadowDebugChannel.off, resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel prioritizes seam_diagnostics" {
    var settings = Settings{};
    settings.debug_shadow_seam_diag = true;
    settings.debug_shadow_cascade_index = true;
    settings.debug_shadows_active = true;
    try testing.expectEqual(ShadowDebugChannel.seam_diagnostics, resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel prioritizes caster_coverage over cascade_index" {
    var settings = Settings{};
    settings.debug_shadow_caster_coverage = true;
    settings.debug_shadow_cascade_index = true;
    settings.debug_shadows_active = true;
    try testing.expectEqual(ShadowDebugChannel.caster_coverage, resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel prioritizes cascade_index over shadow_factor" {
    var settings = Settings{};
    settings.debug_shadow_cascade_index = true;
    settings.debug_shadows_active = true;
    try testing.expectEqual(ShadowDebugChannel.cascade_index, resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel returns shadow_factor when only debug_shadows_active is true" {
    var settings = Settings{};
    settings.debug_shadows_active = true;
    try testing.expectEqual(ShadowDebugChannel.shadow_factor, resolveShadowDebugChannel(&settings));
}
