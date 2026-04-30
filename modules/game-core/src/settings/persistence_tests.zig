const std = @import("std");
const testing = std.testing;
const persistence = @import("persistence.zig");
const data = @import("data.zig");
const Settings = data.Settings;

test "setTexturePack returns early when same value" {
    const allocator = testing.allocator;
    var settings = Settings{ .texture_pack = "default" };

    try persistence.setTexturePack(&settings, allocator, "default");
    try testing.expectEqualStrings("default", settings.texture_pack);
}

test "setTexturePack changes value" {
    const allocator = testing.allocator;
    var settings = Settings{ .texture_pack = "default" };

    try persistence.setTexturePack(&settings, allocator, "mypack");
    try testing.expectEqualStrings("mypack", settings.texture_pack);
    persistence.deinit(&settings, allocator);
}

test "setTexturePack handles multiple changes" {
    const allocator = testing.allocator;
    var settings = Settings{ .texture_pack = "default" };

    try persistence.setTexturePack(&settings, allocator, "pack1");
    try testing.expectEqualStrings("pack1", settings.texture_pack);

    try persistence.setTexturePack(&settings, allocator, "pack2");
    try testing.expectEqualStrings("pack2", settings.texture_pack);
    persistence.deinit(&settings, allocator);
}

test "setEnvironmentMap returns early when same value" {
    const allocator = testing.allocator;
    var settings = Settings{ .texture_pack = "default", .environment_map = "default" };

    try persistence.setEnvironmentMap(&settings, allocator, "default");
    try testing.expectEqualStrings("default", settings.environment_map);
}

test "setEnvironmentMap changes value" {
    const allocator = testing.allocator;
    var settings = Settings{ .texture_pack = "default", .environment_map = "default" };

    try persistence.setEnvironmentMap(&settings, allocator, "sunset.exr");
    try testing.expectEqualStrings("sunset.exr", settings.environment_map);
    persistence.deinit(&settings, allocator);
}

test "Settings.getShadowResolution returns correct resolution" {
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

test "Settings.getShadowResolution clamps out-of-bounds" {
    var settings = Settings{};
    settings.shadow_quality = 99;
    try testing.expectEqual(@as(u32, 2048), settings.getShadowResolution());
}

test "Settings.getResolutionIndex finds matching resolution" {
    var settings = Settings{ .window_width = 1920, .window_height = 1080 };
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());
}

test "Settings.getResolutionIndex returns default for unknown" {
    var settings = Settings{ .window_width = 9999, .window_height = 9999 };
    try testing.expectEqual(@as(usize, 2), settings.getResolutionIndex());
}

test "Settings.setResolutionByIndex updates dimensions" {
    var settings = Settings{};
    settings.setResolutionByIndex(0);
    try testing.expectEqual(@as(u32, 1280), settings.window_width);
    try testing.expectEqual(@as(u32, 720), settings.window_height);
}

test "Settings.setResolutionByIndex ignores invalid index" {
    var settings = Settings{ .window_width = 1920, .window_height = 1080 };
    settings.setResolutionByIndex(99);
    try testing.expectEqual(@as(u32, 1920), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);
}

test "Settings default values" {
    const settings = Settings{};
    try testing.expectEqual(@as(i32, 15), settings.render_distance);
    try testing.expectEqual(@as(f32, 50.0), settings.mouse_sensitivity);
    try testing.expectEqual(true, settings.vsync);
    try testing.expectEqual(@as(f32, 45.0), settings.fov);
    try testing.expectEqual(true, settings.textures_enabled);
    try testing.expectEqual(false, settings.wireframe_enabled);
}

test "SHADOW_QUALITIES array has correct values" {
    try testing.expectEqual(@as(u32, 1024), data.SHADOW_QUALITIES[0].resolution);
    try testing.expectEqualStrings("LOW", data.SHADOW_QUALITIES[0].label);

    try testing.expectEqual(@as(u32, 1536), data.SHADOW_QUALITIES[1].resolution);
    try testing.expectEqualStrings("MEDIUM", data.SHADOW_QUALITIES[1].label);

    try testing.expectEqual(@as(u32, 2048), data.SHADOW_QUALITIES[2].resolution);
    try testing.expectEqualStrings("HIGH", data.SHADOW_QUALITIES[2].label);

    try testing.expectEqual(@as(u32, 4096), data.SHADOW_QUALITIES[3].resolution);
    try testing.expectEqualStrings("ULTRA", data.SHADOW_QUALITIES[3].label);
}

test "RESOLUTIONS array has expected entries" {
    try testing.expectEqual(@as(u32, 1920), data.RESOLUTIONS[2].width);
    try testing.expectEqual(@as(u32, 1080), data.RESOLUTIONS[2].height);
    try testing.expectEqualStrings("1920X1080", data.RESOLUTIONS[2].label);
}

test "RESOLUTIONS covers standard resolutions" {
    try testing.expectEqual(@as(u32, 7), data.RESOLUTIONS.len);

    try testing.expectEqual(@as(u32, 1280), data.RESOLUTIONS[0].width);
    try testing.expectEqual(@as(u32, 720), data.RESOLUTIONS[0].height);

    try testing.expectEqual(@as(u32, 1600), data.RESOLUTIONS[1].width);
    try testing.expectEqual(@as(u32, 900), data.RESOLUTIONS[1].height);
}

test "Settings resolution roundtrip" {
    var settings = Settings{};

    for (0..data.RESOLUTIONS.len) |i| {
        settings.setResolutionByIndex(i);
        try testing.expectEqual(@as(usize, i), settings.getResolutionIndex());
    }
}
