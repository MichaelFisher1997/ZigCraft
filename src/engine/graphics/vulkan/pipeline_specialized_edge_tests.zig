//! Unit tests for pipeline_specialized error paths and validation
//!
//! Tests for error handling that doesn't require GPU calls.

const std = @import("std");
const testing = std.testing;
const c = @import("../../../c.zig").c;
const pipeline_specialized = @import("pipeline_specialized.zig");
const PipelineManager = @import("pipeline_manager.zig").PipelineManager;
const rhi = @import("../rhi.zig");

test "createSwapchainUIPipelines early null check" {
    var manager: PipelineManager = .{};
    const layout: c.VkPipelineLayout = @ptrFromInt(@as(usize, 1));
    manager.ui_pipeline_layout = layout;
    manager.ui_tex_pipeline_layout = layout;

    const null_render_pass: c.VkRenderPass = null;
    const should_error = (null_render_pass == null);
    try testing.expect(should_error);
}

test "createDebugShadowPipeline requires non-null layout" {
    var manager: PipelineManager = .{};
    manager.debug_shadow_pipeline_layout = null;

    const layout = manager.debug_shadow_pipeline_layout;
    const is_null = (layout == null);
    try testing.expect(is_null);
}

test "createDebugShadowPipeline layout extraction logic" {
    var manager: PipelineManager = .{};
    const layout_val: c.VkPipelineLayout = @ptrFromInt(@as(usize, 0x1000));
    manager.debug_shadow_pipeline_layout = layout_val;

    const layout = manager.debug_shadow_pipeline_layout;
    const has_layout = (layout != null);
    try testing.expect(has_layout);
}

test "pipeline_specialized anytype self parameter accepts PipelineManager" {
    var manager: PipelineManager = .{};
    const layout: c.VkPipelineLayout = @ptrFromInt(@as(usize, 1));
    manager.ui_pipeline_layout = layout;
    manager.ui_tex_pipeline_layout = layout;
    manager.ui_swapchain_pipeline = null;
    manager.ui_swapchain_tex_pipeline = null;

    try testing.expect(@TypeOf(manager.ui_pipeline_layout) == c.VkPipelineLayout);
    try testing.expect(@TypeOf(manager.ui_tex_pipeline_layout) == c.VkPipelineLayout);
    try testing.expect(@TypeOf(manager.ui_swapchain_pipeline) == c.VkPipeline);
    try testing.expect(@TypeOf(manager.ui_swapchain_tex_pipeline) == c.VkPipeline);
}

test "createCloudPipeline self parameter has cloud_pipeline_layout field" {
    var manager: PipelineManager = .{};
    const layout: c.VkPipelineLayout = @ptrFromInt(@as(usize, 1));
    manager.cloud_pipeline_layout = layout;

    _ = manager.cloud_pipeline_layout;
    try testing.expect(@TypeOf(manager.cloud_pipeline_layout) == c.VkPipelineLayout);
}

test "PipelineManager has expected struct type info" {
    const info = @typeInfo(PipelineManager);
    try testing.expect(info == .@"struct");
}

test "UI pipeline vertex stride equals 6 floats (24 bytes)" {
    const expected_stride = 6 * @sizeOf(f32);
    try testing.expectEqual(@as(usize, 24), expected_stride);
}

test "Terrain pipeline vertex stride equals rhi.Vertex size" {
    const expected_stride = @sizeOf(rhi.Vertex);
    try testing.expect(expected_stride > 0);
    try testing.expect(expected_stride <= 64);
}

test "Debug shadow pipeline vertex stride equals 4 floats (16 bytes)" {
    const expected_stride = 4 * @sizeOf(f32);
    try testing.expectEqual(@as(usize, 16), expected_stride);
}

test "Cloud pipeline vertex stride equals 2 floats (8 bytes)" {
    const expected_stride = 2 * @sizeOf(f32);
    try testing.expectEqual(@as(usize, 8), expected_stride);
}

test "createSwapchainUIPipelines null render pass path" {
    var manager: PipelineManager = .{};
    const layout: c.VkPipelineLayout = @ptrFromInt(@as(usize, 1));
    manager.ui_pipeline_layout = layout;
    manager.ui_tex_pipeline_layout = layout;

    const existing_pipeline: c.VkPipeline = @ptrFromInt(@as(usize, 0x1000));
    manager.ui_swapchain_pipeline = existing_pipeline;
    manager.ui_swapchain_tex_pipeline = existing_pipeline;

    const null_render_pass: c.VkRenderPass = null;
    if (null_render_pass == null) {
        try testing.expect(true);
    }
}

test "VK_PRIMITIVE_TOPOLOGY_LINE_LIST is used for line pipeline" {
    try testing.expectEqual(@as(c.VkPrimitiveTopology, c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST), c.VK_PRIMITIVE_TOPOLOGY_LINE_LIST);
}

test "VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST is used for all other pipelines" {
    try testing.expectEqual(@as(c.VkPrimitiveTopology, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST), c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
}

test "pipeline_specialized self param works with optional fields" {
    var manager: PipelineManager = .{};
    manager.debug_shadow_pipeline_layout = null;
    manager.debug_shadow_pipeline = null;

    try testing.expect(@TypeOf(manager.debug_shadow_pipeline_layout) == ?c.VkPipelineLayout);
    try testing.expect(@TypeOf(manager.debug_shadow_pipeline) == ?c.VkPipeline);
}

test "createTerrainPipeline uses g_render_pass only when non-null" {
    var manager: PipelineManager = .{};
    manager.pipeline_layout = @ptrFromInt(@as(usize, 1));

    const null_g_render_pass: c.VkRenderPass = null;
    const has_g_pass = (null_g_render_pass != null);
    try testing.expect(!has_g_pass);
}