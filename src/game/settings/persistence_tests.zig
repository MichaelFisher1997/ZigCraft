const std = @import("std");
const testing = std.testing;
const persistence = @import("persistence.zig");
const Settings = @import("data.zig").Settings;

test "setTexturePack returns early when setting same value" {
    const allocator = testing.allocator;
    var settings = Settings{
        .texture_pack = "default",
        .environment_map = "default",
    };
    defer persistence.deinit(&settings, allocator);

    try testing.expectEqualStrings("default", settings.texture_pack);

    try persistence.setTexturePack(&settings, allocator, "default");

    try testing.expectEqualStrings("default", settings.texture_pack);
}

test "setTexturePack changes value when different" {
    const allocator = testing.allocator;
    var settings = Settings{
        .texture_pack = "default",
        .environment_map = "default",
    };
    defer persistence.deinit(&settings, allocator);

    try persistence.setTexturePack(&settings, allocator, "mypack");

    try testing.expectEqualStrings("mypack", settings.texture_pack);
}

test "setTexturePack can change multiple times" {
    const allocator = testing.allocator;
    var settings = Settings{
        .texture_pack = "default",
        .environment_map = "default",
    };
    defer persistence.deinit(&settings, allocator);

    try persistence.setTexturePack(&settings, allocator, "pack1");
    try testing.expectEqualStrings("pack1", settings.texture_pack);

    try persistence.setTexturePack(&settings, allocator, "pack2");
    try testing.expectEqualStrings("pack2", settings.texture_pack);

    try persistence.setTexturePack(&settings, allocator, "default");
    try testing.expectEqualStrings("default", settings.texture_pack);
}

test "setEnvironmentMap returns early when setting same value" {
    const allocator = testing.allocator;
    var settings = Settings{
        .texture_pack = "default",
        .environment_map = "default",
    };
    defer persistence.deinit(&settings, allocator);

    try persistence.setEnvironmentMap(&settings, allocator, "default");

    try testing.expectEqualStrings("default", settings.environment_map);
}

test "setEnvironmentMap changes value when different" {
    const allocator = testing.allocator;
    var settings = Settings{
        .texture_pack = "default",
        .environment_map = "default",
    };
    defer persistence.deinit(&settings, allocator);

    try persistence.setEnvironmentMap(&settings, allocator, "mymap.exr");

    try testing.expectEqualStrings("mymap.exr", settings.environment_map);
}

test "setEnvironmentMap can change multiple times" {
    const allocator = testing.allocator;
    var settings = Settings{
        .texture_pack = "default",
        .environment_map = "default",
    };
    defer persistence.deinit(&settings, allocator);

    try persistence.setEnvironmentMap(&settings, allocator, "map1.exr");
    try testing.expectEqualStrings("map1.exr", settings.environment_map);

    try persistence.setEnvironmentMap(&settings, allocator, "map2.hdr");
    try testing.expectEqualStrings("map2.hdr", settings.environment_map);

    try persistence.setEnvironmentMap(&settings, allocator, "default");
    try testing.expectEqualStrings("default", settings.environment_map);
}

test "deinit handles default (static) strings without crash" {
    const allocator = testing.allocator;
    var settings = Settings{
        .texture_pack = "default",
        .environment_map = "default",
    };

    persistence.deinit(&settings, allocator);
}

test "deinit handles allocated strings without crash" {
    const allocator = testing.allocator;
    var settings = Settings{
        .texture_pack = "default",
        .environment_map = "default",
    };

    try persistence.setTexturePack(&settings, allocator, "mypack");
    try persistence.setEnvironmentMap(&settings, allocator, "mymap.exr");

    try testing.expectEqualStrings("mypack", settings.texture_pack);
    try testing.expectEqualStrings("mymap.exr", settings.environment_map);

    persistence.deinit(&settings, allocator);
}

test "texture_pack and environment_map are independent" {
    const allocator = testing.allocator;
    var settings = Settings{
        .texture_pack = "default",
        .environment_map = "default",
    };
    defer persistence.deinit(&settings, allocator);

    try persistence.setTexturePack(&settings, allocator, "mypack");
    try testing.expectEqualStrings("mypack", settings.texture_pack);
    try testing.expectEqualStrings("default", settings.environment_map);

    try persistence.setEnvironmentMap(&settings, allocator, "mymap.exr");
    try testing.expectEqualStrings("mypack", settings.texture_pack);
    try testing.expectEqualStrings("mymap.exr", settings.environment_map);
}
