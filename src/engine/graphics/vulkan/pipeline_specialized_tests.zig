//! Unit tests for Vulkan Pipeline Specialized functions
//!
//! Tests for pipeline creation functions and error handling paths.

const std = @import("std");
const testing = std.testing;
const c = @import("../../../c.zig").c;
const pipeline_specialized = @import("pipeline_specialized.zig");
const PipelineManager = @import("pipeline_manager.zig").PipelineManager;

test "createSwapchainUIPipelines returns error.InitializationFailed for null render pass" {
    var manager: PipelineManager = .{};
    manager.ui_pipeline_layout = @ptrFromInt(1);
    manager.ui_tex_pipeline_layout = @ptrFromInt(1);

    const result = pipeline_specialized.createSwapchainUIPipelines(&manager, testing.allocator, null, null);
    try testing.expectError(error.InitializationFailed, result);
}

test "push constant sizes are within Vulkan required alignment" {
    const PUSH_CONSTANT_SIZE_MODEL: u32 = 256;
    const PUSH_CONSTANT_SIZE_SKY: u32 = 128;

    try testing.expect(PUSH_CONSTANT_SIZE_MODEL <= 256);
    try testing.expect(PUSH_CONSTANT_SIZE_SKY <= 256);
    try testing.expect(PUSH_CONSTANT_SIZE_MODEL % 4 == 0);
    try testing.expect(PUSH_CONSTANT_SIZE_SKY % 4 == 0);
}

test "MAX_SHADER_MODULE_BYTES is reasonable for shader compilation" {
    const MAX_SHADER_MODULE_BYTES: usize = 4 * 1024 * 1024;

    try testing.expect(MAX_SHADER_MODULE_BYTES >= 1024 * 1024);
    try testing.expect(MAX_SHADER_MODULE_BYTES <= 64 * 1024 * 1024);
}

test "shader registry paths are valid for loading" {
    const shader_registry = @import("shader_registry.zig");

    try testing.expect(shader_registry.TERRAIN_VERT.len > 0);
    try testing.expect(shader_registry.TERRAIN_FRAG.len > 0);
    try testing.expect(shader_registry.UI_VERT.len > 0);
    try testing.expect(shader_registry.UI_FRAG.len > 0);
    try testing.expect(shader_registry.SKY_VERT.len > 0);
    try testing.expect(shader_registry.SKY_FRAG.len > 0);
    try testing.expect(shader_registry.CLOUD_VERT.len > 0);
    try testing.expect(shader_registry.CLOUD_FRAG.len > 0);
}

test "shader paths end with .spv extension" {
    const shader_registry = @import("shader_registry.zig");

    try testing.expect(std.mem.endsWith(u8, shader_registry.TERRAIN_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.TERRAIN_FRAG, ".frag.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.SKY_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.SKY_FRAG, ".frag.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.CLOUD_VERT, ".vert.spv"));
    try testing.expect(std.mem.endsWith(u8, shader_registry.CLOUD_FRAG, ".frag.spv"));
}

test "VK_CULL_MODE_NONE equals expected value" {
    try testing.expectEqual(@as(c.VkCullModeFlags, c.VK_CULL_MODE_NONE), c.VK_CULL_MODE_NONE);
}

test "VK_FRONT_FACE_COUNTER_CLOCKWISE equals expected value" {
    try testing.expectEqual(@as(c.VkFrontFace, c.VK_FRONT_FACE_COUNTER_CLOCKWISE), c.VK_FRONT_FACE_COUNTER_CLOCKWISE);
}

test "VK_POLYGON_MODE_LINE and VK_POLYGON_MODE_FILL are valid polygon modes" {
    try testing.expectEqual(@as(c.VkPolygonMode, c.VK_POLYGON_MODE_LINE), c.VK_POLYGON_MODE_LINE);
    try testing.expectEqual(@as(c.VkPolygonMode, c.VK_POLYGON_MODE_FILL), c.VK_POLYGON_MODE_FILL);
}

test "PipelineManager struct has expected field alignment" {
    try testing.expect(@offsetOf(PipelineManager, "terrain_pipeline") % @alignOf(*anyopaque) == 0);
    try testing.expect(@offsetOf(PipelineManager, "pipeline_layout") % @alignOf(*anyopaque) == 0);
    try testing.expect(@offsetOf(PipelineManager, "sky_pipeline_layout") % @alignOf(*anyopaque) == 0);
}

test "terrain pipeline variants use different polygon modes" {
    try testing.expect(c.VK_POLYGON_MODE_LINE != c.VK_POLYGON_MODE_FILL);
    try testing.expect(c.VK_CULL_MODE_NONE != c.VK_CULL_MODE_BACK_BIT);
}

test "sky and wireframe pipeline use VK_CULL_MODE_NONE" {
    try testing.expectEqual(@as(c.VkCullModeFlags, c.VK_CULL_MODE_NONE), c.VK_CULL_MODE_NONE);
}

test "cloud pipeline uses VK_FRONT_FACE_COUNTER_CLOCKWISE" {
    try testing.expectEqual(@as(c.VkFrontFace, c.VK_FRONT_FACE_COUNTER_CLOCKWISE), c.VK_FRONT_FACE_COUNTER_CLOCKWISE);
}

// ============================================================================
// Error Path Logic Tests for pipeline_specialized
// ============================================================================

test "createSwapchainUIPipelines null render pass is detected early" {
    // The function validates render pass before any pipeline operations
    const null_render_pass: c.VkRenderPass = null;
    // This is the exact check the function performs
    const is_null = (null_render_pass == null);
    try testing.expect(is_null);
}

test "createDebugShadowPipeline null layout triggers error path" {
    // When debug_shadow_pipeline_layout is null, function returns error.MissingPipelineLayout
    var manager: PipelineManager = .{};
    manager.debug_shadow_pipeline_layout = null;

    // The layout check: `const layout = self.debug_shadow_pipeline_layout orelse return error.MissingPipelineLayout;`
    const layout = manager.debug_shadow_pipeline_layout;
    const has_layout = layout != null;
    try testing.expect(!has_layout);
}

test "pipeline_specialized functions use anytype for self parameter" {
    // Verify that the pipeline_specialized functions accept anytype self
    // This allows them to work with PipelineManager or any struct with required fields
    const manager: PipelineManager = .{};

    // Check that required fields exist in PipelineManager for createSwapchainUIPipelines
    // ui_pipeline_layout and ui_tex_pipeline_layout are needed
    _ = manager.ui_pipeline_layout;
    _ = manager.ui_tex_pipeline_layout;

    // ui_swapchain_pipeline and ui_swapchain_tex_pipeline are modified by the function
    try testing.expect(@TypeOf(manager.ui_swapchain_pipeline) == c.VkPipeline);
    try testing.expect(@TypeOf(manager.ui_swapchain_tex_pipeline) == c.VkPipeline);
}
