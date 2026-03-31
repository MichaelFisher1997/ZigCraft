const std = @import("std");
const testing = std.testing;
const data = @import("data.zig");
const Settings = data.Settings;
const ShadowDebugChannel = data.ShadowDebugChannel;
const SHADOW_QUALITIES = data.SHADOW_QUALITIES;
const RESOLUTIONS = data.RESOLUTIONS;

// ============================================================================
// ShadowDebugChannel Tests
// ============================================================================

test "resolveShadowDebugChannel returns off when all flags false" {
    const settings = Settings{
        .debug_shadows_active = false,
        .debug_shadow_cascade_index = false,
        .debug_shadow_caster_coverage = false,
        .debug_shadow_seam_diag = false,
    };

    const channel = data.resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.off, channel);
}

test "resolveShadowDebugChannel returns shadow_factor when debug_shadows_active true" {
    const settings = Settings{
        .debug_shadows_active = true,
        .debug_shadow_cascade_index = false,
        .debug_shadow_caster_coverage = false,
        .debug_shadow_seam_diag = false,
    };

    const channel = data.resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.shadow_factor, channel);
}

test "resolveShadowDebugChannel returns cascade_index when debug_shadow_cascade_index true" {
    const settings = Settings{
        .debug_shadows_active = false,
        .debug_shadow_cascade_index = true,
        .debug_shadow_caster_coverage = false,
        .debug_shadow_seam_diag = false,
    };

    const channel = data.resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.cascade_index, channel);
}

test "resolveShadowDebugChannel returns caster_coverage when debug_shadow_caster_coverage true" {
    const settings = Settings{
        .debug_shadows_active = false,
        .debug_shadow_cascade_index = false,
        .debug_shadow_caster_coverage = true,
        .debug_shadow_seam_diag = false,
    };

    const channel = data.resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.caster_coverage, channel);
}

test "resolveShadowDebugChannel returns seam_diagnostics when debug_shadow_seam_diag true" {
    const settings = Settings{
        .debug_shadows_active = false,
        .debug_shadow_cascade_index = false,
        .debug_shadow_caster_coverage = false,
        .debug_shadow_seam_diag = true,
    };

    const channel = data.resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.seam_diagnostics, channel);
}

test "resolveShadowDebugChannel priority order respects seam_diagnostics highest" {
    // seam_diagnostics should take priority over all others
    const settings = Settings{
        .debug_shadows_active = true,
        .debug_shadow_cascade_index = true,
        .debug_shadow_caster_coverage = true,
        .debug_shadow_seam_diag = true,
    };

    const channel = data.resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.seam_diagnostics, channel);
}

test "resolveShadowDebugChannel priority order respects caster_coverage second" {
    const settings = Settings{
        .debug_shadows_active = true,
        .debug_shadow_cascade_index = true,
        .debug_shadow_caster_coverage = true,
        .debug_shadow_seam_diag = false,
    };

    const channel = data.resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.caster_coverage, channel);
}

test "resolveShadowDebugChannel priority order respects cascade_index third" {
    const settings = Settings{
        .debug_shadows_active = true,
        .debug_shadow_cascade_index = true,
        .debug_shadow_caster_coverage = false,
        .debug_shadow_seam_diag = false,
    };

    const channel = data.resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.cascade_index, channel);
}

// ============================================================================
// getShadowResolution Tests
// ============================================================================

test "getShadowResolution returns correct resolution for valid indices" {
    var settings = Settings{};

    // Test each valid quality index
    settings.shadow_quality = 0;
    try testing.expectEqual(@as(u32, 1024), settings.getShadowResolution());

    settings.shadow_quality = 1;
    try testing.expectEqual(@as(u32, 1536), settings.getShadowResolution());

    settings.shadow_quality = 2;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());

    settings.shadow_quality = 3;
    try testing.expectEqual(@as(u32, 4096), settings.getShadowResolution());
}

test "getShadowResolution returns default high resolution for out of bounds index" {
    var settings = Settings{};

    // Test out of bounds (should default to index 2 = HIGH = 2048)
    settings.shadow_quality = 99;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());

    settings.shadow_quality = 4;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());
}

// ============================================================================
// getResolutionIndex Tests
// ============================================================================

test "getResolutionIndex returns correct index for matching resolution" {
    var settings = Settings{};

    // Test 1920x1080 (index 2)
    settings.window_width = 1920;
    settings.window_height = 1080;
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());

    // Test 1280x720 (index 0)
    settings.window_width = 1280;
    settings.window_height = 720;
    try testing.expectEqual(@as(usize, 0), settings.getResolutionIndex());

    // Test 3840x2160 (index 6)
    settings.window_width = 3840;
    settings.window_height = 2160;
    try testing.expectEqual(@as(usize, 6), settings.getResolutionIndex());
}

test "getResolutionIndex returns default index for non-matching resolution" {
    var settings = Settings{};

    // Non-standard resolution should return default (2 = 1920x1080)
    settings.window_width = 1234;
    settings.window_height = 567;
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());
}

test "getResolutionIndex handles all predefined resolutions" {
    var settings = Settings{};

    // Test all resolutions in the RESOLUTIONS array
    for (RESOLUTIONS, 0..) |res, i| {
        settings.window_width = res.width;
        settings.window_height = res.height;
        try testing.expectEqual(i, settings.getResolutionIndex());
    }
}

// ============================================================================
// setResolutionByIndex Tests
// ============================================================================

test "setResolutionByIndex sets correct resolution for valid indices" {
    var settings = Settings{};

    // Test setting each valid index
    settings.setResolutionByIndex(0);
    try testing.expectEqual(@as(u32, 1280), settings.window_width);
    try testing.expectEqual(@as(u32, 720), settings.window_height);

    settings.setResolutionByIndex(2);
    try testing.expectEqual(@as(u32, 1920), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);

    settings.setResolutionByIndex(6);
    try testing.expectEqual(@as(u32, 3840), settings.window_width);
    try testing.expectEqual(@as(u32, 2160), settings.window_height);
}

test "setResolutionByIndex ignores out of bounds index" {
    var settings = Settings{};

    // Set a known resolution first
    settings.setResolutionByIndex(2);
    try testing.expectEqual(@as(u32, 1920), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);

    // Out of bounds should not modify settings
    settings.setResolutionByIndex(99);
    try testing.expectEqual(@as(u32, 1920), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);

    settings.setResolutionByIndex(RESOLUTIONS.len);
    try testing.expectEqual(@as(u32, 1920), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);
}

test "setResolutionByIndex and getResolutionIndex are inverse operations" {
    var settings = Settings{};

    // For all valid indices, setting then getting should return the same index
    for (0..RESOLUTIONS.len) |i| {
        settings.setResolutionByIndex(i);
        const retrieved_index = settings.getResolutionIndex();
        try testing.expectEqual(i, retrieved_index);
    }
}

// ============================================================================
// Settings Default Values Tests
// ============================================================================

test "Settings default values are reasonable" {
    const settings = Settings{};

    // Check critical defaults
    try testing.expect(settings.render_distance >= 2);
    try testing.expect(settings.render_distance <= 32);

    try testing.expect(settings.mouse_sensitivity > 0);
    try testing.expect(settings.fov >= 30.0);
    try testing.expect(settings.fov <= 120.0);

    try testing.expect(settings.shadow_quality < SHADOW_QUALITIES.len);

    try testing.expect(settings.anisotropic_filtering == 1 or
        settings.anisotropic_filtering == 2 or
        settings.anisotropic_filtering == 4 or
        settings.anisotropic_filtering == 8 or
        settings.anisotropic_filtering == 16);

    try testing.expect(settings.msaa_samples == 1 or
        settings.msaa_samples == 2 or
        settings.msaa_samples == 4 or
        settings.msaa_samples == 8);

    try testing.expect(settings.ui_scale >= 0.5);
    try testing.expect(settings.ui_scale <= 2.0);

    try testing.expect(settings.max_texture_resolution == 16 or
        settings.max_texture_resolution == 32 or
        settings.max_texture_resolution == 64 or
        settings.max_texture_resolution == 128 or
        settings.max_texture_resolution == 256 or
        settings.max_texture_resolution == 512);
}

// ============================================================================
// ShadowQuality Constants Tests
// ============================================================================

test "SHADOW_QUALITIES array has expected values" {
    try testing.expectEqual(@as(usize, 4), SHADOW_QUALITIES.len);

    try testing.expectEqual(@as(u32, 1024), SHADOW_QUALITIES[0].resolution);
    try testing.expectEqual(@as(u32, 1536), SHADOW_QUALITIES[1].resolution);
    try testing.expectEqual(@as(u32, 2048), SHADOW_QUALITIES[2].resolution);
    try testing.expectEqual(@as(u32, 4096), SHADOW_QUALITIES[3].resolution);
}

// ============================================================================
// RESOLUTIONS Constants Tests
// ============================================================================

test "RESOLUTIONS array has expected values" {
    try testing.expectEqual(@as(usize, 7), RESOLUTIONS.len);

    // Spot check a few
    try testing.expectEqual(@as(u32, 1280), RESOLUTIONS[0].width);
    try testing.expectEqual(@as(u32, 720), RESOLUTIONS[0].height);

    try testing.expectEqual(@as(u32, 1920), RESOLUTIONS[2].width);
    try testing.expectEqual(@as(u32, 1080), RESOLUTIONS[2].height);

    try testing.expectEqual(@as(u32, 3840), RESOLUTIONS[6].width);
    try testing.expectEqual(@as(u32, 2160), RESOLUTIONS[6].height);
}
