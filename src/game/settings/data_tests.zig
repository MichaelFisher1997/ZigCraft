const std = @import("std");
const testing = std.testing;
const data = @import("data.zig");
const Settings = data.Settings;
const ShadowDebugChannel = data.ShadowDebugChannel;
const resolveShadowDebugChannel = data.resolveShadowDebugChannel;
const SHADOW_QUALITIES = data.SHADOW_QUALITIES;
const RESOLUTIONS = data.RESOLUTIONS;

// ============================================================================
// resolveShadowDebugChannel Tests
// ============================================================================

test "resolveShadowDebugChannel returns off when all debug flags are false" {
    const settings = Settings{
        .debug_shadows_active = false,
        .debug_shadow_cascade_index = false,
        .debug_shadow_caster_coverage = false,
        .debug_shadow_seam_diag = false,
    };

    const result = resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.off, result);
}

test "resolveShadowDebugChannel returns shadow_factor when only debug_shadows_active is true" {
    const settings = Settings{
        .debug_shadows_active = true,
        .debug_shadow_cascade_index = false,
        .debug_shadow_caster_coverage = false,
        .debug_shadow_seam_diag = false,
    };

    const result = resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.shadow_factor, result);
}

test "resolveShadowDebugChannel returns cascade_index when debug_shadow_cascade_index is true" {
    const settings = Settings{
        .debug_shadows_active = false,
        .debug_shadow_cascade_index = true,
        .debug_shadow_caster_coverage = false,
        .debug_shadow_seam_diag = false,
    };

    const result = resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.cascade_index, result);
}

test "resolveShadowDebugChannel returns caster_coverage when debug_shadow_caster_coverage is true" {
    const settings = Settings{
        .debug_shadows_active = false,
        .debug_shadow_cascade_index = false,
        .debug_shadow_caster_coverage = true,
        .debug_shadow_seam_diag = false,
    };

    const result = resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.caster_coverage, result);
}

test "resolveShadowDebugChannel returns seam_diagnostics when debug_shadow_seam_diag is true" {
    const settings = Settings{
        .debug_shadows_active = false,
        .debug_shadow_cascade_index = false,
        .debug_shadow_caster_coverage = false,
        .debug_shadow_seam_diag = true,
    };

    const result = resolveShadowDebugChannel(&settings);
    try testing.expectEqual(ShadowDebugChannel.seam_diagnostics, result);
}

test "resolveShadowDebugChannel priority order: seam_diagnostics > caster_coverage > cascade_index > shadow_factor" {
    // Test that seam_diagnostics takes priority over others
    const settings1 = Settings{
        .debug_shadows_active = true,
        .debug_shadow_cascade_index = true,
        .debug_shadow_caster_coverage = true,
        .debug_shadow_seam_diag = true,
    };
    try testing.expectEqual(ShadowDebugChannel.seam_diagnostics, resolveShadowDebugChannel(&settings1));

    // Test that caster_coverage takes priority over cascade_index and shadow_factor
    const settings2 = Settings{
        .debug_shadows_active = true,
        .debug_shadow_cascade_index = true,
        .debug_shadow_caster_coverage = true,
        .debug_shadow_seam_diag = false,
    };
    try testing.expectEqual(ShadowDebugChannel.caster_coverage, resolveShadowDebugChannel(&settings2));

    // Test that cascade_index takes priority over shadow_factor
    const settings3 = Settings{
        .debug_shadows_active = true,
        .debug_shadow_cascade_index = true,
        .debug_shadow_caster_coverage = false,
        .debug_shadow_seam_diag = false,
    };
    try testing.expectEqual(ShadowDebugChannel.cascade_index, resolveShadowDebugChannel(&settings3));
}

// ============================================================================
// Settings.getShadowResolution Tests
// ============================================================================

test "Settings.getShadowResolution returns correct resolution for each quality level" {
    var settings = Settings{};

    // Test each valid quality level
    settings.shadow_quality = 0;
    try testing.expectEqual(@as(u32, 1024), settings.getShadowResolution());

    settings.shadow_quality = 1;
    try testing.expectEqual(@as(u32, 1536), settings.getShadowResolution());

    settings.shadow_quality = 2;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());

    settings.shadow_quality = 3;
    try testing.expectEqual(@as(u32, 4096), settings.getShadowResolution());
}

test "Settings.getShadowResolution defaults to high when quality index is out of bounds" {
    var settings = Settings{};

    // Test out of bounds (above)
    settings.shadow_quality = 100;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());

    // Test out of bounds (below)
    settings.shadow_quality = 0;
    // This should still work as it's a valid index
}

// ============================================================================
// Settings.getResolutionIndex Tests
// ============================================================================

test "Settings.getResolutionIndex returns correct index for exact resolution matches" {
    var settings = Settings{};

    // Test 1280x720 (index 0)
    settings.window_width = 1280;
    settings.window_height = 720;
    try testing.expectEqual(@as(usize, 0), settings.getResolutionIndex());

    // Test 1920x1080 (index 2)
    settings.window_width = 1920;
    settings.window_height = 1080;
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());

    // Test 3840x2160 (index 6)
    settings.window_width = 3840;
    settings.window_height = 2160;
    try testing.expectEqual(@as(usize, 6), settings.getResolutionIndex());
}

test "Settings.getResolutionIndex returns default index for non-standard resolutions" {
    var settings = Settings{};

    // Test a non-standard resolution
    settings.window_width = 1234;
    settings.window_height = 567;
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex()); // Defaults to 1920x1080
}

// ============================================================================
// Settings.setResolutionByIndex Tests
// ============================================================================

test "Settings.setResolutionByIndex sets correct resolution for valid indices" {
    var settings = Settings{};

    // Test setting to 1280x720 (index 0)
    settings.setResolutionByIndex(0);
    try testing.expectEqual(@as(u32, 1280), settings.window_width);
    try testing.expectEqual(@as(u32, 720), settings.window_height);

    // Test setting to 1920x1080 (index 2)
    settings.setResolutionByIndex(2);
    try testing.expectEqual(@as(u32, 1920), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);

    // Test setting to 3840x2160 (index 6)
    settings.setResolutionByIndex(6);
    try testing.expectEqual(@as(u32, 3840), settings.window_width);
    try testing.expectEqual(@as(u32, 2160), settings.window_height);
}

test "Settings.setResolutionByIndex ignores out of bounds indices" {
    var settings = Settings{};

    // Set to a known value first
    settings.window_width = 1920;
    settings.window_height = 1080;

    // Try to set with out of bounds index
    settings.setResolutionByIndex(100);

    // Should remain unchanged
    try testing.expectEqual(@as(u32, 1920), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);
}

// ============================================================================
// Constants Validation Tests
// ============================================================================

test "SHADOW_QUALITIES has expected values" {
    try testing.expectEqual(@as(usize, 4), SHADOW_QUALITIES.len);

    try testing.expectEqual(@as(u32, 1024), SHADOW_QUALITIES[0].resolution);
    try testing.expect(std.mem.eql(u8, "LOW", SHADOW_QUALITIES[0].label));

    try testing.expectEqual(@as(u32, 1536), SHADOW_QUALITIES[1].resolution);
    try testing.expect(std.mem.eql(u8, "MEDIUM", SHADOW_QUALITIES[1].label));

    try testing.expectEqual(@as(u32, 2048), SHADOW_QUALITIES[2].resolution);
    try testing.expect(std.mem.eql(u8, "HIGH", SHADOW_QUALITIES[2].label));

    try testing.expectEqual(@as(u32, 4096), SHADOW_QUALITIES[3].resolution);
    try testing.expect(std.mem.eql(u8, "ULTRA", SHADOW_QUALITIES[3].label));
}

test "RESOLUTIONS has expected values" {
    try testing.expectEqual(@as(usize, 7), RESOLUTIONS.len);

    // Test first resolution
    try testing.expectEqual(@as(u32, 1280), RESOLUTIONS[0].width);
    try testing.expectEqual(@as(u32, 720), RESOLUTIONS[0].height);
    try testing.expect(std.mem.eql(u8, "1280X720", RESOLUTIONS[0].label));

    // Test last resolution
    try testing.expectEqual(@as(u32, 3840), RESOLUTIONS[6].width);
    try testing.expectEqual(@as(u32, 2160), RESOLUTIONS[6].height);
    try testing.expect(std.mem.eql(u8, "3840X2160", RESOLUTIONS[6].label));
}

test "Shadow resolutions increase with quality level" {
    // Verify that shadow resolutions are in ascending order
    for (1..SHADOW_QUALITIES.len) |i| {
        try testing.expect(SHADOW_QUALITIES[i].resolution > SHADOW_QUALITIES[i - 1].resolution);
    }
}

// ============================================================================
// Round-trip Resolution Tests
// ============================================================================

test "Resolution round-trip: set then get returns same index" {
    var settings = Settings{};

    for (0..RESOLUTIONS.len) |idx| {
        settings.setResolutionByIndex(idx);
        const retrieved_idx = settings.getResolutionIndex();
        try testing.expectEqual(@as(usize, idx), retrieved_idx);
    }
}

// ============================================================================
// ShadowDebugChannel Enum Tests
// ============================================================================

test "ShadowDebugChannel enum values are as expected" {
    try testing.expectEqual(@as(u32, 0), @intFromEnum(ShadowDebugChannel.off));
    try testing.expectEqual(@as(u32, 1), @intFromEnum(ShadowDebugChannel.shadow_factor));
    try testing.expectEqual(@as(u32, 2), @intFromEnum(ShadowDebugChannel.cascade_index));
    try testing.expectEqual(@as(u32, 3), @intFromEnum(ShadowDebugChannel.caster_coverage));
    try testing.expectEqual(@as(u32, 4), @intFromEnum(ShadowDebugChannel.seam_diagnostics));
}
