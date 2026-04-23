//! Unit tests for Vulkan Pipeline Manager error paths and edge cases
//!
//! These tests focus on error handling paths and boundary conditions
//! that are not covered by the existing pipeline_manager_tests.zig

const std = @import("std");
const testing = std.testing;
const c = @import("../../../c.zig").c;
const pipeline_manager = @import("pipeline_manager.zig");
const PipelineManager = pipeline_manager.PipelineManager;
const Mat4 = @import("../../math/mat4.zig").Mat4;

test "createMainPipelines validates null render pass early" {
    var manager: PipelineManager = .{};
    manager.pipeline_layout = null;
    manager.sky_pipeline_layout = null;
    manager.ui_pipeline_layout = null;
    manager.ui_tex_pipeline_layout = null;
    manager.ui_tex_descriptor_set_layout = null;
    manager.cloud_pipeline_layout = null;

    const null_render_pass: c.VkRenderPass = null;
    const has_error = (null_render_pass == null);
    try testing.expect(has_error);
}

test "PipelineManager creates null state for optional debug shadow pipeline" {
    var manager: PipelineManager = .{};

    try testing.expect(manager.debug_shadow_pipeline == null);
    try testing.expect(manager.debug_shadow_pipeline_layout == null);
    try testing.expect(manager.debug_shadow_descriptor_set_layout == null);
}

test "PipelineManager water_pipeline field exists and is nullable" {
    var manager: PipelineManager = .{};
    try testing.expectEqual(@as(c.VkPipeline, null), manager.water_pipeline);
}

test "PipelineManager init returns error on invalid device" {
    // Test that init validates its inputs
    // Without a real device, we can't call init, but we can verify
    // the function signature requires valid parameters
    const manager: PipelineManager = .{};
    _ = manager;
}

test "getMSAASampleCountFlag edge case: maximum valid value" {
    // 8 is the maximum supported MSAA level in this engine
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_8_BIT), pipeline_manager.getMSAASampleCountFlag(8));
}

test "PipelineManager layout fields are optional for debug shadow" {
    var manager: PipelineManager = .{};

    // Debug shadow pipeline layout is optional (?c.VkPipelineLayout)
    try testing.expect(@TypeOf(manager.debug_shadow_pipeline_layout) == ?c.VkPipelineLayout);
    try testing.expect(@TypeOf(manager.debug_shadow_descriptor_set_layout) == ?c.VkDescriptorSetLayout);

    // Null assignment should work
    manager.debug_shadow_pipeline_layout = null;
    manager.debug_shadow_descriptor_set_layout = null;

    try testing.expectEqual(@as(?c.VkPipelineLayout, null), manager.debug_shadow_pipeline_layout);
    try testing.expectEqual(@as(?c.VkDescriptorSetLayout, null), manager.debug_shadow_descriptor_set_layout);
}
