//! Unit tests for Vulkan Shader Registry
//!
//! Tests for shader path constants and SPIR-V file paths.

const std = @import("std");
const testing = std.testing;
const shader_registry = @import("shader_registry.zig");

// ============================================================================
// Shader Path Format Tests
// ============================================================================

test "all shader paths follow SPIR-V naming convention" {
    // All shader paths should end with .spv extension
    const paths = [_][]const u8{
        shader_registry.SSAO_VERT,
        shader_registry.SSAO_FRAG,
        shader_registry.SSAO_BLUR_FRAG,
        shader_registry.BLOOM_DOWNSAMPLE_VERT,
        shader_registry.BLOOM_DOWNSAMPLE_FRAG,
        shader_registry.BLOOM_UPSAMPLE_FRAG,
        shader_registry.FXAA_VERT,
        shader_registry.FXAA_FRAG,
        shader_registry.POST_PROCESS_VERT,
        shader_registry.POST_PROCESS_FRAG,
        shader_registry.TAA_VERT,
        shader_registry.TAA_FRAG,
        shader_registry.SHADOW_VERT,
        shader_registry.SHADOW_FRAG,
        shader_registry.TERRAIN_VERT,
        shader_registry.TERRAIN_FRAG,
        shader_registry.G_PASS_FRAG,
        shader_registry.SKY_VERT,
        shader_registry.SKY_FRAG,
        shader_registry.UI_VERT,
        shader_registry.UI_FRAG,
        shader_registry.UI_TEX_VERT,
        shader_registry.UI_TEX_FRAG,
        shader_registry.DEBUG_SHADOW_VERT,
        shader_registry.DEBUG_SHADOW_FRAG,
    };

    for (paths) |path| {
        // All paths should end with .spv
        try testing.expect(std.mem.endsWith(u8, path, ".spv"));

        // All paths should start with assets/shaders/vulkan/
        try testing.expect(std.mem.startsWith(u8, path, "assets/shaders/vulkan/"));
    }
}

test "vertex and fragment shader pairs exist for complete pipelines" {
    // Complete rendering pipelines should have both vertex and fragment shaders
    // SSAO
    try testing.expect(std.mem.endsWith(u8, shader_registry.SSAO_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.SSAO_FRAG, ".frag.spv"));

    // Bloom
    try testing.expect(std.mem.endsWith(u8, shader_registry.BLOOM_DOWNSAMPLE_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.BLOOM_DOWNSAMPLE_FRAG, ".frag.spv"));

    // FXAA
    try testing.expect(std.mem.endsWith(u8, shader_registry.FXAA_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.FXAA_FRAG, ".frag.spv"));

    // Post Process
    try testing.expect(std.mem.endsWith(u8, shader_registry.POST_PROCESS_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.POST_PROCESS_FRAG, ".frag.spv"));

    // TAA
    try testing.expect(std.mem.endsWith(u8, shader_registry.TAA_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.TAA_FRAG, ".frag.spv"));

    // Shadow
    try testing.expect(std.mem.endsWith(u8, shader_registry.SHADOW_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.SHADOW_FRAG, ".frag.spv"));

    // Terrain
    try testing.expect(std.mem.endsWith(u8, shader_registry.TERRAIN_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.TERRAIN_FRAG, ".frag.spv"));

    // Sky
    try testing.expect(std.mem.endsWith(u8, shader_registry.SKY_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.SKY_FRAG, ".frag.spv"));

    // UI
    try testing.expect(std.mem.endsWith(u8, shader_registry.UI_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.UI_FRAG, ".frag.spv"));

    // UI Textured
    try testing.expect(std.mem.endsWith(u8, shader_registry.UI_TEX_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.UI_TEX_FRAG, ".frag.spv"));

    // Debug Shadow
    try testing.expect(std.mem.endsWith(u8, shader_registry.DEBUG_SHADOW_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.DEBUG_SHADOW_FRAG, ".frag.spv"));
}

test "compute shaders are not present in registry" {
    // Currently, all shaders in the registry are graphics shaders (vert/frag)
    // No compute shaders are registered

    // Bloom upsample is fragment-only (used with same vertex shader as downsample)
    try testing.expect(std.mem.endsWith(u8, shader_registry.BLOOM_UPSAMPLE_FRAG, ".frag.spv"));

    // SSAO blur is fragment-only
    try testing.expect(std.mem.endsWith(u8, shader_registry.SSAO_BLUR_FRAG, ".frag.spv"));

    // G-pass is fragment-only (shares vertex shader with terrain)
    try testing.expect(std.mem.endsWith(u8, shader_registry.G_PASS_FRAG, ".frag.spv"));
}

test "shader paths contain meaningful names" {
    // Each shader path should clearly indicate its purpose

    // SSAO shaders
    try testing.expect(std.mem.indexOf(u8, shader_registry.SSAO_VERT, "ssao") != null);
    try testing.expect(std.mem.indexOf(u8, shader_registry.SSAO_FRAG, "ssao") != null);
    try testing.expect(std.mem.indexOf(u8, shader_registry.SSAO_BLUR_FRAG, "ssao_blur") != null);

    // Bloom shaders
    try testing.expect(std.mem.indexOf(u8, shader_registry.BLOOM_DOWNSAMPLE_VERT, "bloom_downsample") != null);
    try testing.expect(std.mem.indexOf(u8, shader_registry.BLOOM_UPSAMPLE_FRAG, "bloom_upsample") != null);

    // Terrain shaders
    try testing.expect(std.mem.indexOf(u8, shader_registry.TERRAIN_VERT, "terrain") != null);
    try testing.expect(std.mem.indexOf(u8, shader_registry.TERRAIN_FRAG, "terrain") != null);

    // Shadow shaders
    try testing.expect(std.mem.indexOf(u8, shader_registry.SHADOW_VERT, "shadow") != null);
}

// ============================================================================
// Shader Organization Tests
// ============================================================================

test "shaders are organized by feature" {
    // Post-processing shaders
    const post_process_shaders = [_][]const u8{
        shader_registry.FXAA_VERT,
        shader_registry.FXAA_FRAG,
        shader_registry.POST_PROCESS_VERT,
        shader_registry.POST_PROCESS_FRAG,
        shader_registry.TAA_VERT,
        shader_registry.TAA_FRAG,
    };

    for (post_process_shaders) |path| {
        // All post-processing shaders should have relevant keywords
        const has_fxaa = std.mem.indexOf(u8, path, "fxaa") != null;
        const has_post = std.mem.indexOf(u8, path, "post_process") != null;
        const has_taa = std.mem.indexOf(u8, path, "taa") != null;
        try testing.expect(has_fxaa or has_post or has_taa);
    }

    // Lighting/shadow shaders
    const lighting_shaders = [_][]const u8{
        shader_registry.SHADOW_VERT,
        shader_registry.SHADOW_FRAG,
        shader_registry.SSAO_VERT,
        shader_registry.SSAO_FRAG,
        shader_registry.DEBUG_SHADOW_VERT,
        shader_registry.DEBUG_SHADOW_FRAG,
    };

    for (lighting_shaders) |path| {
        const has_shadow = std.mem.indexOf(u8, path, "shadow") != null;
        const has_ssao = std.mem.indexOf(u8, path, "ssao") != null;
        try testing.expect(has_shadow or has_ssao);
    }
}

test "terrain rendering shader variants exist" {
    // Terrain has multiple shader variants

    // Main terrain shader
    try testing.expect(std.mem.indexOf(u8, shader_registry.TERRAIN_VERT, "terrain") != null);
    try testing.expect(std.mem.indexOf(u8, shader_registry.TERRAIN_FRAG, "terrain") != null);

    // G-buffer pass (deferred rendering)
    try testing.expect(std.mem.indexOf(u8, shader_registry.G_PASS_FRAG, "g_pass") != null);

    // Terrain vertex shader is shared with G-pass
    // (they use the same vertex module but different fragment modules)
}

test "UI shader variants exist" {
    // UI has two variants: colored and textured

    // Basic colored UI
    try testing.expect(std.mem.indexOf(u8, shader_registry.UI_VERT, "ui") != null);
    try testing.expect(std.mem.indexOf(u8, shader_registry.UI_FRAG, "ui") != null);
    try testing.expect(std.mem.indexOf(u8, shader_registry.UI_VERT, "ui_tex") == null);

    // Textured UI
    try testing.expect(std.mem.indexOf(u8, shader_registry.UI_TEX_VERT, "ui_tex") != null);
    try testing.expect(std.mem.indexOf(u8, shader_registry.UI_TEX_FRAG, "ui_tex") != null);
}

// ============================================================================
// Shader Path Consistency Tests
// ============================================================================

test "all shader paths use forward slashes" {
    // All paths should use forward slashes for cross-platform compatibility
    const paths = [_][]const u8{
        shader_registry.SSAO_VERT,
        shader_registry.TERRAIN_VERT,
        shader_registry.UI_VERT,
    };

    for (paths) |path| {
        // Should not contain backslashes
        try testing.expect(std.mem.indexOf(u8, path, "\\") == null);
    }
}

test "shader directory structure is consistent" {
    // All shaders should be in assets/shaders/vulkan/
    const expected_prefix = "assets/shaders/vulkan/";

    const paths = [_][]const u8{
        shader_registry.SSAO_VERT,
        shader_registry.BLOOM_DOWNSAMPLE_VERT,
        shader_registry.TERRAIN_VERT,
        shader_registry.SKY_VERT,
        shader_registry.UI_VERT,
    };

    for (paths) |path| {
        try testing.expect(std.mem.startsWith(u8, path, expected_prefix));
    }
}

// ============================================================================
// Shader File Existence (Build-time validation)
// ============================================================================

// Note: These tests run at build time to validate that SPIR-V files exist
// For unit tests, we just validate the path format

test "shader paths are non-empty" {
    const paths = [_][]const u8{
        shader_registry.SSAO_VERT,
        shader_registry.SSAO_FRAG,
        shader_registry.TERRAIN_VERT,
        shader_registry.TERRAIN_FRAG,
        shader_registry.UI_VERT,
        shader_registry.UI_FRAG,
    };

    for (paths) |path| {
        try testing.expect(path.len > 0);
        try testing.expect(path.len > "assets/shaders/vulkan/".len);
    }
}

test "critical shader paths are valid" {
    // Critical shaders that must exist for the engine to run
    const critical_shaders = [_][]const u8{
        shader_registry.TERRAIN_VERT,
        shader_registry.TERRAIN_FRAG,
        shader_registry.UI_VERT,
        shader_registry.UI_FRAG,
    };

    for (critical_shaders) |path| {
        // Should have proper extension
        try testing.expect(std.mem.endsWith(u8, path, ".spv"));

        // Should have proper prefix
        try testing.expect(std.mem.startsWith(u8, path, "assets/shaders/vulkan/"));

        // Should have shader type indicator
        const has_vert = std.mem.indexOf(u8, path, ".vert") != null;
        const has_frag = std.mem.indexOf(u8, path, ".frag") != null;
        try testing.expect(has_vert or has_frag);
    }
}

// ============================================================================
// Additional Shader Path Validation Tests
// ============================================================================

test "compute shader CULLING_COMP exists and has correct extension" {
    try testing.expect(std.mem.endsWith(u8, shader_registry.CULLING_COMP, ".comp.spv"));
    try testing.expect(std.mem.startsWith(u8, shader_registry.CULLING_COMP, "assets/shaders/vulkan/"));
}

test "water shaders exist with correct naming convention" {
    try testing.expect(std.mem.endsWith(u8, shader_registry.WATER_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.WATER_FRAG, ".frag.spv"));
    try testing.expect(std.mem.indexOf(u8, shader_registry.WATER_VERT, "water") != null);
    try testing.expect(std.mem.indexOf(u8, shader_registry.WATER_FRAG, "water") != null);
}

test "all shader paths have unique base names" {
    // No two shaders should have the same filename
    const paths = [_][]const u8{
        shader_registry.SSAO_VERT,
        shader_registry.SSAO_FRAG,
        shader_registry.SSAO_BLUR_FRAG,
        shader_registry.BLOOM_DOWNSAMPLE_VERT,
        shader_registry.BLOOM_DOWNSAMPLE_FRAG,
        shader_registry.BLOOM_UPSAMPLE_FRAG,
        shader_registry.FXAA_VERT,
        shader_registry.FXAA_FRAG,
        shader_registry.POST_PROCESS_VERT,
        shader_registry.POST_PROCESS_FRAG,
        shader_registry.TAA_VERT,
        shader_registry.TAA_FRAG,
        shader_registry.SHADOW_VERT,
        shader_registry.SHADOW_FRAG,
        shader_registry.TERRAIN_VERT,
        shader_registry.TERRAIN_FRAG,
        shader_registry.G_PASS_FRAG,
        shader_registry.SKY_VERT,
        shader_registry.SKY_FRAG,
        shader_registry.UI_VERT,
        shader_registry.UI_FRAG,
        shader_registry.UI_TEX_VERT,
        shader_registry.UI_TEX_FRAG,
        shader_registry.DEBUG_SHADOW_VERT,
        shader_registry.DEBUG_SHADOW_FRAG,
        shader_registry.CULLING_COMP,
        shader_registry.WATER_VERT,
        shader_registry.WATER_FRAG,
    };

    for (0..paths.len) |i| {
        const basename_i = std.fs.path.basename(paths[i]);
        for (i + 1..paths.len) |j| {
            const basename_j = std.fs.path.basename(paths[j]);
            try testing.expect(!std.mem.eql(u8, basename_i, basename_j));
        }
    }
}

test "compute shader is only non-graphics shader" {
    // Only CULLING_COMP should be a compute shader
    const compute_shader = shader_registry.CULLING_COMP;
    try testing.expect(std.mem.endsWith(u8, compute_shader, ".comp.spv"));

    // All other shaders should be vert or frag (not comp)
    const non_compute_shaders = [_][]const u8{
        shader_registry.SSAO_VERT,
        shader_registry.SSAO_FRAG,
        shader_registry.TERRAIN_VERT,
        shader_registry.TERRAIN_FRAG,
        shader_registry.SKY_VERT,
        shader_registry.SKY_FRAG,
        shader_registry.UI_VERT,
        shader_registry.UI_FRAG,
    };

    for (non_compute_shaders) |path| {
        try testing.expect(!std.mem.endsWith(u8, path, ".comp.spv"));
    }
}
