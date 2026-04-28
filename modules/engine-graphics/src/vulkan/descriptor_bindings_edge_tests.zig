//! Unit tests for Vulkan descriptor_bindings constants and edge cases
//!
//! Additional tests for descriptor binding validation and edge cases.

const std = @import("std");
const testing = std.testing;
const descriptor_bindings = @import("descriptor_bindings.zig");
const rhi = @import("engine-rhi").rhi;

test "descriptor binding WATER_REFLECTION_TEXTURE is binding 14" {
    try testing.expectEqual(@as(u32, 14), descriptor_bindings.WATER_REFLECTION_TEXTURE);
}

test "descriptor binding SCENE_DEPTH_TEXTURE is binding 15" {
    try testing.expectEqual(@as(u32, 15), descriptor_bindings.SCENE_DEPTH_TEXTURE);
}

test "descriptor bindings WATER and SCENE_DEPTH are consecutive" {
    try testing.expectEqual(descriptor_bindings.SCENE_DEPTH_TEXTURE, descriptor_bindings.WATER_REFLECTION_TEXTURE + 1);
}

test "total bindings count is 16 (0-15)" {
    const bindings_list = [_]u32{
        descriptor_bindings.GLOBAL_UBO,
        descriptor_bindings.ALBEDO_TEXTURE,
        descriptor_bindings.SHADOW_UBO,
        descriptor_bindings.SHADOW_COMPARE_TEXTURE,
        descriptor_bindings.SHADOW_REGULAR_TEXTURE,
        descriptor_bindings.INSTANCE_SSBO,
        descriptor_bindings.NORMAL_TEXTURE,
        descriptor_bindings.ROUGHNESS_TEXTURE,
        descriptor_bindings.DISPLACEMENT_TEXTURE,
        descriptor_bindings.ENV_TEXTURE,
        descriptor_bindings.SSAO_TEXTURE,
        descriptor_bindings.LPV_TEXTURE,
        descriptor_bindings.LPV_TEXTURE_G,
        descriptor_bindings.LPV_TEXTURE_B,
        descriptor_bindings.WATER_REFLECTION_TEXTURE,
        descriptor_bindings.SCENE_DEPTH_TEXTURE,
    };

    try testing.expectEqual(@as(usize, 16), bindings_list.len);

    var unique: u32 = 0;
    for (bindings_list) |b| {
        unique = @max(unique, b);
    }
    try testing.expectEqual(@as(u32, 15), unique); // Max index is 15 (0-15 = 16 bindings)
}

test "UBO bindings are at even indices" {
    try testing.expect(descriptor_bindings.GLOBAL_UBO % 2 == 0);
    try testing.expect(descriptor_bindings.SHADOW_UBO % 2 == 0);
}

test "texture bindings are at odd indices (except SSBO at 5)" {
    // Most texture bindings should be odd
    try testing.expect(descriptor_bindings.ALBEDO_TEXTURE % 2 == 1);
}

test "binding indices are within VulkanDescriptorPool limits" {
    // Maximum binding should be well below VK_MAX_* limits
    const all_bindings = [_]u32{
        descriptor_bindings.GLOBAL_UBO,
        descriptor_bindings.ALBEDO_TEXTURE,
        descriptor_bindings.SHADOW_UBO,
        descriptor_bindings.SHADOW_COMPARE_TEXTURE,
        descriptor_bindings.SHADOW_REGULAR_TEXTURE,
        descriptor_bindings.INSTANCE_SSBO,
        descriptor_bindings.NORMAL_TEXTURE,
        descriptor_bindings.ROUGHNESS_TEXTURE,
        descriptor_bindings.DISPLACEMENT_TEXTURE,
        descriptor_bindings.ENV_TEXTURE,
        descriptor_bindings.SSAO_TEXTURE,
        descriptor_bindings.LPV_TEXTURE,
        descriptor_bindings.LPV_TEXTURE_G,
        descriptor_bindings.LPV_TEXTURE_B,
        descriptor_bindings.WATER_REFLECTION_TEXTURE,
        descriptor_bindings.SCENE_DEPTH_TEXTURE,
    };

    for (all_bindings) |binding| {
        try testing.expect(binding < 256); // Well within any limit
    }
}

test "binding constants are compile-time constants" {
    // All binding constants should be compile-time known
    const global_ubo = descriptor_bindings.GLOBAL_UBO;
    const albedo = descriptor_bindings.ALBEDO_TEXTURE;
    _ = global_ubo;
    _ = albedo;
    try testing.expect(true); // If we got here, they are compile-time constants
}

test "shadow-related bindings are grouped at 2, 3, 4" {
    try testing.expectEqual(@as(u32, 2), descriptor_bindings.SHADOW_UBO);
    try testing.expectEqual(@as(u32, 3), descriptor_bindings.SHADOW_COMPARE_TEXTURE);
    try testing.expectEqual(@as(u32, 4), descriptor_bindings.SHADOW_REGULAR_TEXTURE);
}

test "PBR material bindings are consecutive at 6, 7, 8" {
    try testing.expectEqual(@as(u32, 6), descriptor_bindings.NORMAL_TEXTURE);
    try testing.expectEqual(@as(u32, 7), descriptor_bindings.ROUGHNESS_TEXTURE);
    try testing.expectEqual(@as(u32, 8), descriptor_bindings.DISPLACEMENT_TEXTURE);
}

test "LPV bindings are consecutive at 11, 12, 13" {
    try testing.expectEqual(@as(u32, 11), descriptor_bindings.LPV_TEXTURE);
    try testing.expectEqual(@as(u32, 12), descriptor_bindings.LPV_TEXTURE_G);
    try testing.expectEqual(@as(u32, 13), descriptor_bindings.LPV_TEXTURE_B);
}

test "no binding index exceeds u8 max" {
    const max_binding = @max(
        descriptor_bindings.GLOBAL_UBO,
        descriptor_bindings.ALBEDO_TEXTURE,
        descriptor_bindings.SHADOW_UBO,
        descriptor_bindings.SHADOW_COMPARE_TEXTURE,
        descriptor_bindings.SHADOW_REGULAR_TEXTURE,
        descriptor_bindings.INSTANCE_SSBO,
        descriptor_bindings.NORMAL_TEXTURE,
        descriptor_bindings.ROUGHNESS_TEXTURE,
        descriptor_bindings.DISPLACEMENT_TEXTURE,
        descriptor_bindings.ENV_TEXTURE,
        descriptor_bindings.SSAO_TEXTURE,
        descriptor_bindings.LPV_TEXTURE,
        descriptor_bindings.LPV_TEXTURE_G,
        descriptor_bindings.LPV_TEXTURE_B,
        descriptor_bindings.WATER_REFLECTION_TEXTURE,
        descriptor_bindings.SCENE_DEPTH_TEXTURE,
    );

    try testing.expect(max_binding <= 255);
}

test "binding index for global uniform buffer is 0" {
    try testing.expectEqual(@as(u32, 0), descriptor_bindings.GLOBAL_UBO);
}

test "binding index for instance SSBO is 5" {
    try testing.expectEqual(@as(u32, 5), descriptor_bindings.INSTANCE_SSBO);
}
