const std = @import("std");
const testing = std.testing;
const persistence = @import("persistence.zig");
const Settings = @import("data.zig").Settings;

// ============================================================================
// setTexturePack Tests
// ============================================================================

test "setTexturePack updates texture pack name" {
    const allocator = testing.allocator;
    var settings = Settings{};

    try persistence.setTexturePack(&settings, allocator, "new_pack");

    try testing.expect(std.mem.eql(u8, "new_pack", settings.texture_pack));

    // Clean up
    persistence.deinit(&settings, allocator);
}

test "setTexturePack does nothing when setting same value" {
    const allocator = testing.allocator;
    var settings = Settings{};

    // Set initial value
    try persistence.setTexturePack(&settings, allocator, "original_pack");
    const original_ptr = settings.texture_pack.ptr;

    // Set same value - should be a no-op
    try persistence.setTexturePack(&settings, allocator, "original_pack");

    // Pointer should be unchanged (optimization)
    try testing.expectEqual(original_ptr, settings.texture_pack.ptr);
    try testing.expect(std.mem.eql(u8, "original_pack", settings.texture_pack));

    // Clean up
    persistence.deinit(&settings, allocator);
}

test "setTexturePack replaces existing value" {
    const allocator = testing.allocator;
    var settings = Settings{};

    try persistence.setTexturePack(&settings, allocator, "old_pack");
    try persistence.setTexturePack(&settings, allocator, "new_pack");

    try testing.expect(std.mem.eql(u8, "new_pack", settings.texture_pack));

    // Clean up
    persistence.deinit(&settings, allocator);
}

test "setTexturePack handles default sentinel" {
    const allocator = testing.allocator;
    var settings = Settings{};

    // Setting to "default" should not allocate
    try persistence.setTexturePack(&settings, allocator, "default");

    try testing.expect(std.mem.eql(u8, "default", settings.texture_pack));

    // Clean up (should be a no-op for default sentinel)
    persistence.deinit(&settings, allocator);
}

// ============================================================================
// setEnvironmentMap Tests
// ============================================================================

test "setEnvironmentMap updates environment map name" {
    const allocator = testing.allocator;
    var settings = Settings{};

    try persistence.setEnvironmentMap(&settings, allocator, "custom_env.hdr");

    try testing.expect(std.mem.eql(u8, "custom_env.hdr", settings.environment_map));

    // Clean up
    persistence.deinit(&settings, allocator);
}

test "setEnvironmentMap does nothing when setting same value" {
    const allocator = testing.allocator;
    var settings = Settings{};

    try persistence.setEnvironmentMap(&settings, allocator, "my_env.exr");
    const original_ptr = settings.environment_map.ptr;

    try persistence.setEnvironmentMap(&settings, allocator, "my_env.exr");

    try testing.expectEqual(original_ptr, settings.environment_map.ptr);

    // Clean up
    persistence.deinit(&settings, allocator);
}

// ============================================================================
// deinit Tests
// ============================================================================

test "deinit frees allocated string fields" {
    const allocator = testing.allocator;
    var settings = Settings{};

    // Set custom values that will be allocated
    try persistence.setTexturePack(&settings, allocator, "my_texture_pack");
    try persistence.setEnvironmentMap(&settings, allocator, "my_environment_map");

    // This should not leak memory (verified by testing.allocator leak detection)
    persistence.deinit(&settings, allocator);

    // After deinit, the strings are freed but the pointers remain as dangling references.
    // In real usage, the Settings struct would be discarded after deinit.
    // We verify the allocator didn't report any leaks above.
}

test "deinit with default sentinels is a no-op" {
    const allocator = testing.allocator;
    var settings = Settings{};

    // settings starts with "default" sentinels
    try testing.expect(std.mem.eql(u8, "default", settings.texture_pack));
    try testing.expect(std.mem.eql(u8, "default", settings.environment_map));

    // This should be safe (no-op for default sentinels)
    persistence.deinit(&settings, allocator);
}

// ============================================================================
// Multiple Set/Reset Cycle Tests
// ============================================================================

test "texture pack can be changed multiple times" {
    const allocator = testing.allocator;
    var settings = Settings{};

    try persistence.setTexturePack(&settings, allocator, "pack1");
    try testing.expect(std.mem.eql(u8, "pack1", settings.texture_pack));

    try persistence.setTexturePack(&settings, allocator, "pack2");
    try testing.expect(std.mem.eql(u8, "pack2", settings.texture_pack));

    try persistence.setTexturePack(&settings, allocator, "pack3");
    try testing.expect(std.mem.eql(u8, "pack3", settings.texture_pack));

    // Back to default
    try persistence.setTexturePack(&settings, allocator, "default");
    try testing.expect(std.mem.eql(u8, "default", settings.texture_pack));

    persistence.deinit(&settings, allocator);
}

test "environment map can be changed multiple times" {
    const allocator = testing.allocator;
    var settings = Settings{};

    try persistence.setEnvironmentMap(&settings, allocator, "env1.hdr");
    try persistence.setEnvironmentMap(&settings, allocator, "env2.hdr");
    try persistence.setEnvironmentMap(&settings, allocator, "env3.hdr");

    try testing.expect(std.mem.eql(u8, "env3.hdr", settings.environment_map));

    persistence.deinit(&settings, allocator);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "setTexturePack handles empty string" {
    const allocator = testing.allocator;
    var settings = Settings{};

    try persistence.setTexturePack(&settings, allocator, "");
    try testing.expect(std.mem.eql(u8, "", settings.texture_pack));

    persistence.deinit(&settings, allocator);
}

test "setEnvironmentMap handles empty string" {
    const allocator = testing.allocator;
    var settings = Settings{};

    try persistence.setEnvironmentMap(&settings, allocator, "");
    try testing.expect(std.mem.eql(u8, "", settings.environment_map));

    persistence.deinit(&settings, allocator);
}

test "setTexturePack handles long string" {
    const allocator = testing.allocator;
    var settings = Settings{};

    const long_name = "a" ** 1000;
    try persistence.setTexturePack(&settings, allocator, long_name);
    try testing.expect(std.mem.eql(u8, long_name, settings.texture_pack));

    persistence.deinit(&settings, allocator);
}

test "setEnvironmentMap handles long string" {
    const allocator = testing.allocator;
    var settings = Settings{};

    const long_name = "b" ** 1000;
    try persistence.setEnvironmentMap(&settings, allocator, long_name);
    try testing.expect(std.mem.eql(u8, long_name, settings.environment_map));

    persistence.deinit(&settings, allocator);
}

// ============================================================================
// Settings Struct Default Values Tests
// ============================================================================

test "Settings defaults have correct string values" {
    const settings = Settings{};

    try testing.expect(std.mem.eql(u8, "default", settings.texture_pack));
    try testing.expect(std.mem.eql(u8, "default", settings.environment_map));
}

test "Settings defaults have correct numeric values" {
    const settings = Settings{};

    try testing.expectEqual(@as(i32, 15), settings.render_distance);
    try testing.expectEqual(@as(f32, 50.0), settings.mouse_sensitivity);
    try testing.expectEqual(@as(f32, 45.0), settings.fov);
    try testing.expectEqual(@as(u32, 2), settings.shadow_quality);
    try testing.expectEqual(@as(u32, 1920), settings.window_width);
    try testing.expectEqual(@as(u32, 1080), settings.window_height);
}

test "Settings defaults have correct boolean values" {
    const settings = Settings{};

    try testing.expect(settings.vsync);
    try testing.expect(settings.textures_enabled);
    try testing.expect(!settings.wireframe_enabled);
    try testing.expect(!settings.debug_shadows_active);
    try testing.expect(!settings.lod_enabled);
    try testing.expect(settings.pbr_enabled);
    try testing.expect(settings.cloud_shadows_enabled);
    try testing.expect(settings.volumetric_lighting_enabled);
    try testing.expect(settings.ssao_enabled);
    try testing.expect(settings.lpv_enabled);
    try testing.expect(settings.fxaa_enabled);
    try testing.expect(settings.bloom_enabled);
    try testing.expect(!settings.vignette_enabled);
    try testing.expect(!settings.film_grain_enabled);
}
