const std = @import("std");
const testing = std.testing;
const data = @import("data.zig");
const Settings = data.Settings;

test "resolveShadowDebugChannel returns direct_key when active" {
    var settings = Settings{};
    settings.debug_direct_key_active = true;
    try testing.expectEqual(data.ShadowDebugChannel.direct_key, data.resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel returns sky_fill when active" {
    var settings = Settings{};
    settings.debug_sky_fill_active = true;
    try testing.expectEqual(data.ShadowDebugChannel.sky_fill, data.resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel returns entrance_bounce when active" {
    var settings = Settings{};
    settings.debug_entrance_bounce_active = true;
    try testing.expectEqual(data.ShadowDebugChannel.entrance_bounce, data.resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel returns block_light when active" {
    var settings = Settings{};
    settings.debug_block_light_active = true;
    try testing.expectEqual(data.ShadowDebugChannel.block_light, data.resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel returns outdoor_factor when active" {
    var settings = Settings{};
    settings.debug_outdoor_factor_active = true;
    try testing.expectEqual(data.ShadowDebugChannel.outdoor_factor, data.resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel priority order - direct_key wins" {
    var settings = Settings{};
    settings.debug_direct_key_active = true;
    settings.debug_sky_fill_active = true;
    settings.debug_entrance_bounce_active = true;
    settings.debug_block_light_active = true;
    settings.debug_outdoor_factor_active = true;
    settings.debug_shadow_seam_diag = true;
    settings.debug_shadow_cascade_index = true;
    settings.debug_shadows_active = true;
    try testing.expectEqual(data.ShadowDebugChannel.direct_key, data.resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel returns seam_diagnostics when active" {
    var settings = Settings{};
    settings.debug_shadow_seam_diag = true;
    try testing.expectEqual(data.ShadowDebugChannel.seam_diagnostics, data.resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel returns caster_coverage when active" {
    var settings = Settings{};
    settings.debug_shadow_caster_coverage = true;
    try testing.expectEqual(data.ShadowDebugChannel.caster_coverage, data.resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel returns cascade_index when active" {
    var settings = Settings{};
    settings.debug_shadow_cascade_index = true;
    try testing.expectEqual(data.ShadowDebugChannel.cascade_index, data.resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel returns shadow_factor when active" {
    var settings = Settings{};
    settings.debug_shadows_active = true;
    try testing.expectEqual(data.ShadowDebugChannel.shadow_factor, data.resolveShadowDebugChannel(&settings));
}

test "resolveShadowDebugChannel returns off when nothing active" {
    const settings = Settings{};
    try testing.expectEqual(data.ShadowDebugChannel.off, data.resolveShadowDebugChannel(&settings));
}

test "anyShadowMapDebugActive returns true when any flag set" {
    var settings = Settings{};
    settings.debug_shadows_active = true;
    try testing.expect(data.anyShadowMapDebugActive(&settings));
}

test "anyShadowMapDebugActive returns true for cascade_index" {
    var settings = Settings{};
    settings.debug_shadow_cascade_index = true;
    try testing.expect(data.anyShadowMapDebugActive(&settings));
}

test "anyShadowMapDebugActive returns true for caster_coverage" {
    var settings = Settings{};
    settings.debug_shadow_caster_coverage = true;
    try testing.expect(data.anyShadowMapDebugActive(&settings));
}

test "anyShadowMapDebugActive returns true for seam_diag" {
    var settings = Settings{};
    settings.debug_shadow_seam_diag = true;
    try testing.expect(data.anyShadowMapDebugActive(&settings));
}

test "anyShadowMapDebugActive returns false when all clear" {
    const settings = Settings{};
    try testing.expect(!data.anyShadowMapDebugActive(&settings));
}

test "anyTerrainDebugActive returns off when nothing active" {
    const settings = Settings{};
    try testing.expect(!data.anyTerrainDebugActive(&settings));
}

test "anyTerrainDebugActive returns true when any terrain debug active" {
    var settings = Settings{};
    settings.debug_shadows_active = true;
    try testing.expect(data.anyTerrainDebugActive(&settings));
}

test "clearTerrainDebugViews clears all debug flags" {
    var settings = Settings{};
    settings.debug_shadows_active = true;
    settings.debug_shadow_cascade_index = true;
    settings.debug_shadow_caster_coverage = true;
    settings.debug_shadow_seam_diag = true;
    settings.debug_direct_key_active = true;
    settings.debug_sky_fill_active = true;
    settings.debug_entrance_bounce_active = true;
    settings.debug_block_light_active = true;
    settings.debug_outdoor_factor_active = true;

    data.clearTerrainDebugViews(&settings);

    try testing.expect(!settings.debug_shadows_active);
    try testing.expect(!settings.debug_shadow_cascade_index);
    try testing.expect(!settings.debug_shadow_caster_coverage);
    try testing.expect(!settings.debug_shadow_seam_diag);
    try testing.expect(!settings.debug_direct_key_active);
    try testing.expect(!settings.debug_sky_fill_active);
    try testing.expect(!settings.debug_entrance_bounce_active);
    try testing.expect(!settings.debug_block_light_active);
    try testing.expect(!settings.debug_outdoor_factor_active);
}

test "sanitizeRuntimeConflicts returns false when no conflict" {
    var settings = Settings{};
    settings.lod_enabled = true;
    settings.taa_enabled = false;
    settings.fxaa_enabled = true;
    try testing.expect(!data.sanitizeRuntimeConflicts(&settings));
}

test "sanitizeRuntimeConflicts disables TAA when LOD+TAA both enabled" {
    var settings = Settings{};
    settings.lod_enabled = true;
    settings.taa_enabled = true;
    settings.fxaa_enabled = false;

    try testing.expect(data.sanitizeRuntimeConflicts(&settings));
    try testing.expect(!settings.taa_enabled);
    try testing.expect(settings.fxaa_enabled);
}

test "Settings.getShadowResolution returns correct resolution for each quality" {
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

test "Settings.getShadowResolution defaults to HIGH for out of range" {
    var settings = Settings{};
    settings.shadow_quality = 99;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());
}

test "Settings.getResolutionIndex finds matching resolution" {
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
    settings.window_width = 999;
    settings.window_height = 999;
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());
}

test "Settings.setResolutionByIndex sets correct resolution" {
    var settings = Settings{};
    settings.setResolutionByIndex(0);
    try testing.expectEqual(@as(u32, 1280), settings.window_width);
    try testing.expectEqual(@as(u32, 720), settings.window_height);

    settings.setResolutionByIndex(4);
    try testing.expectEqual(@as(u32, 2560), settings.window_width);
    try testing.expectEqual(@as(u32, 1440), settings.window_height);
}

test "Settings.setResolutionByIndex ignores out of range index" {
    var settings = Settings{};
    const original_width = settings.window_width;
    const original_height = settings.window_height;
    settings.setResolutionByIndex(999);
    try testing.expectEqual(original_width, settings.window_width);
    try testing.expectEqual(original_height, settings.window_height);
}