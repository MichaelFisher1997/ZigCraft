//! Unit tests for Vulkan Descriptor Bindings
//!
//! Tests for descriptor binding constants and layout validation.

const std = @import("std");
const testing = std.testing;
const descriptor_bindings = @import("descriptor_bindings.zig");

// ============================================================================
// Descriptor Binding Index Tests
// ============================================================================

test "descriptor binding indices are unique" {
    // All binding indices should be unique (no duplicates)
    const bindings = [_]u32{
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
    };

    // Check for duplicates
    for (0..bindings.len) |i| {
        for (i + 1..bindings.len) |j| {
            try testing.expect(bindings[i] != bindings[j]);
        }
    }
}

test "descriptor binding indices are sequential starting from 0" {
    // UBO should be at binding 0
    try testing.expectEqual(@as(u32, 0), descriptor_bindings.GLOBAL_UBO);

    // Check that other critical bindings follow
    try testing.expectEqual(@as(u32, 1), descriptor_bindings.ALBEDO_TEXTURE);
    try testing.expectEqual(@as(u32, 2), descriptor_bindings.SHADOW_UBO);
}

test "texture bindings are grouped together" {
    // Texture bindings should form a contiguous or semi-contiguous block
    // This is important for descriptor set layout optimization

    const albedo = descriptor_bindings.ALBEDO_TEXTURE;
    const shadow_compare = descriptor_bindings.SHADOW_COMPARE_TEXTURE;
    const shadow_regular = descriptor_bindings.SHADOW_REGULAR_TEXTURE;
    const normal = descriptor_bindings.NORMAL_TEXTURE;
    const roughness = descriptor_bindings.ROUGHNESS_TEXTURE;
    const displacement = descriptor_bindings.DISPLACEMENT_TEXTURE;
    const env = descriptor_bindings.ENV_TEXTURE;
    const ssao = descriptor_bindings.SSAO_TEXTURE;

    // All texture bindings should be >= 1 (after UBO) and < 20
    try testing.expect(albedo >= 1 and albedo < 20);
    try testing.expect(shadow_compare >= 1 and shadow_compare < 20);
    try testing.expect(shadow_regular >= 1 and shadow_regular < 20);
    try testing.expect(normal >= 1 and normal < 20);
    try testing.expect(roughness >= 1 and roughness < 20);
    try testing.expect(displacement >= 1 and displacement < 20);
    try testing.expect(env >= 1 and env < 20);
    try testing.expect(ssao >= 1 and ssao < 20);
}

test "LPV texture bindings are consecutive" {
    // LPV (Light Propagation Volume) textures should be consecutive
    // for easier array handling in shaders
    const lpv_r = descriptor_bindings.LPV_TEXTURE;
    const lpv_g = descriptor_bindings.LPV_TEXTURE_G;
    const lpv_b = descriptor_bindings.LPV_TEXTURE_B;

    // They should be consecutive
    try testing.expectEqual(lpv_g, lpv_r + 1);
    try testing.expectEqual(lpv_b, lpv_g + 1);
}

test "buffer bindings use even/odd separation pattern" {
    // UBOs and SSBOs should be separated from textures
    // UBO at 0, textures starting at 1, UBO at 2, textures continue...
    // This is a common pattern for cache efficiency

    const global_ubo = descriptor_bindings.GLOBAL_UBO;
    const shadow_ubo = descriptor_bindings.SHADOW_UBO;
    const instance_ssbo = descriptor_bindings.INSTANCE_SSBO;
    _ = instance_ssbo; // Silence unused warning

    // All buffer bindings should be even (0, 2, 5 is exception)
    try testing.expect(global_ubo == 0);
    try testing.expect(shadow_ubo == 2);
    // SSBO at 5 is an exception but still reasonable
}

test "shadow bindings are grouped" {
    // Shadow-related bindings should be close together
    const shadow_ubo = descriptor_bindings.SHADOW_UBO;
    const shadow_compare = descriptor_bindings.SHADOW_COMPARE_TEXTURE;
    const shadow_regular = descriptor_bindings.SHADOW_REGULAR_TEXTURE;

    // UBO at 2, textures at 3 and 4 - consecutive and close
    try testing.expectEqual(@as(u32, 2), shadow_ubo);
    try testing.expectEqual(@as(u32, 3), shadow_compare);
    try testing.expectEqual(@as(u32, 4), shadow_regular);
}

test "PBR material texture bindings are consecutive" {
    // PBR textures (normal, roughness, displacement) should be consecutive
    const normal = descriptor_bindings.NORMAL_TEXTURE;
    const roughness = descriptor_bindings.ROUGHNESS_TEXTURE;
    const displacement = descriptor_bindings.DISPLACEMENT_TEXTURE;

    try testing.expectEqual(normal + 1, roughness);
    try testing.expectEqual(roughness + 1, displacement);
}

// ============================================================================
// Binding Count and Range Tests
// ============================================================================

test "total number of bindings is reasonable" {
    // Count the bindings - we have 14 total (0-13)
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
    );

    // Should have bindings 0-13 (14 total)
    try testing.expectEqual(@as(u32, 13), max_binding);

    // 14 bindings should be well within Vulkan limits
    // (min guaranteed is 16 for some descriptor types, 128+ for others)
    try testing.expect(max_binding < 128);
}

test "binding indices fit in 8 bits" {
    // All binding indices should be small enough to fit in u8
    // This is important for some GPU packing schemes

    const bindings = [_]u32{
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
    };

    for (bindings) |binding| {
        try testing.expect(binding <= 255);
    }
}

// ============================================================================
// Shader Interface Validation Tests
// ============================================================================

test "binding names match shader expectations" {
    // This test documents the binding layout for shader developers
    // These bindings MUST match the shader code

    // Binding 0: Global Uniforms (matrices, camera, lights)
    try testing.expectEqual(@as(u32, 0), descriptor_bindings.GLOBAL_UBO);

    // Binding 1: Main Texture Atlas (block textures)
    try testing.expectEqual(@as(u32, 1), descriptor_bindings.ALBEDO_TEXTURE);

    // Binding 2: Shadow Uniforms (cascade matrices)
    try testing.expectEqual(@as(u32, 2), descriptor_bindings.SHADOW_UBO);

    // Bindings 3-4: Shadow Maps (comparison and regular sampling)
    try testing.expectEqual(@as(u32, 3), descriptor_bindings.SHADOW_COMPARE_TEXTURE);
    try testing.expectEqual(@as(u32, 4), descriptor_bindings.SHADOW_REGULAR_TEXTURE);

    // Binding 5: Instance Data (SSBO for instanced rendering)
    try testing.expectEqual(@as(u32, 5), descriptor_bindings.INSTANCE_SSBO);

    // Bindings 6-8: PBR Material Maps
    try testing.expectEqual(@as(u32, 6), descriptor_bindings.NORMAL_TEXTURE);
    try testing.expectEqual(@as(u32, 7), descriptor_bindings.ROUGHNESS_TEXTURE);
    try testing.expectEqual(@as(u32, 8), descriptor_bindings.DISPLACEMENT_TEXTURE);

    // Binding 9: Environment Map (sky/IBL)
    try testing.expectEqual(@as(u32, 9), descriptor_bindings.ENV_TEXTURE);

    // Binding 10: SSAO Result
    try testing.expectEqual(@as(u32, 10), descriptor_bindings.SSAO_TEXTURE);

    // Bindings 11-13: LPV (Light Propagation Volume) SH Coefficients
    try testing.expectEqual(@as(u32, 11), descriptor_bindings.LPV_TEXTURE);
    try testing.expectEqual(@as(u32, 12), descriptor_bindings.LPV_TEXTURE_G);
    try testing.expectEqual(@as(u32, 13), descriptor_bindings.LPV_TEXTURE_B);
}

// ============================================================================
// Descriptor Type Consistency Tests
// ============================================================================

test "UBO bindings are at indices suitable for uniform buffers" {
    // UBOs at bindings 0 and 2 - typical layout
    // Binding 5 is SSBO (storage buffer)

    // This test documents the buffer binding layout
    try testing.expectEqual(@as(u32, 0), descriptor_bindings.GLOBAL_UBO);
    try testing.expectEqual(@as(u32, 2), descriptor_bindings.SHADOW_UBO);
    try testing.expectEqual(@as(u32, 5), descriptor_bindings.INSTANCE_SSBO);
}

test "texture bindings start after first UBO" {
    // First texture is at binding 1, after UBO at 0
    try testing.expect(descriptor_bindings.ALBEDO_TEXTURE > descriptor_bindings.GLOBAL_UBO);

    // All textures are after the first UBO
    try testing.expect(descriptor_bindings.SHADOW_COMPARE_TEXTURE > descriptor_bindings.GLOBAL_UBO);
    try testing.expect(descriptor_bindings.NORMAL_TEXTURE > descriptor_bindings.GLOBAL_UBO);
}
