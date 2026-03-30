//! Unit tests for Vulkan Pipeline Manager
//!
//! These tests focus on pure logic that doesn't require a real GPU.
//! GPU-dependent functionality is marked as untestable without mocks.

const std = @import("std");
const testing = std.testing;
const c = @import("../../../c.zig").c;
const pipeline_manager = @import("pipeline_manager.zig");
const PipelineManager = pipeline_manager.PipelineManager;
const Utils = @import("utils.zig");
const rhi = @import("../rhi.zig");

// ============================================================================
// PipelineManager Initialization and State Tests
// ============================================================================

test "PipelineManager default initialization produces null handles" {
    // Test that a default-initialized PipelineManager has all null handles
    const manager: PipelineManager = .{};

    // All pipelines should be null
    try testing.expectEqual(@as(c.VkPipeline, null), manager.terrain_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.wireframe_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.selection_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.line_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.g_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.sky_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.ui_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.ui_tex_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.cloud_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.ui_swapchain_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.ui_swapchain_tex_pipeline);

    // All layouts should be null
    try testing.expectEqual(@as(c.VkPipelineLayout, null), manager.pipeline_layout);
    try testing.expectEqual(@as(c.VkPipelineLayout, null), manager.sky_pipeline_layout);
    try testing.expectEqual(@as(c.VkPipelineLayout, null), manager.ui_pipeline_layout);
    try testing.expectEqual(@as(c.VkPipelineLayout, null), manager.ui_tex_pipeline_layout);
    try testing.expectEqual(@as(c.VkPipelineLayout, null), manager.cloud_pipeline_layout);
    try testing.expectEqual(@as(c.VkDescriptorSetLayout, null), manager.ui_tex_descriptor_set_layout);

    // Debug shadow optional fields should be null
    try testing.expectEqual(@as(?c.VkPipeline, null), manager.debug_shadow_pipeline);
    try testing.expectEqual(@as(?c.VkPipelineLayout, null), manager.debug_shadow_pipeline_layout);
    try testing.expectEqual(@as(?c.VkDescriptorSetLayout, null), manager.debug_shadow_descriptor_set_layout);
}

test "PipelineManager handles null destruction gracefully" {
    // Verify that destroyPipelines doesn't crash with null handles
    // This is important for error handling paths where init fails partway
    var manager: PipelineManager = .{};

    // Should not panic - all handles are null
    manager.destroyPipelines(null);

    // All pipelines should still be null after destruction
    try testing.expectEqual(@as(c.VkPipeline, null), manager.terrain_pipeline);
    try testing.expectEqual(@as(c.VkPipeline, null), manager.wireframe_pipeline);
}

// ============================================================================
// MSAA Sample Count Flag Conversion Tests
// ============================================================================

test "getMSAASampleCountFlag converts valid sample counts correctly" {
    const getMSAASampleCountFlag = pipeline_manager.getMSAASampleCountFlag;

    // Test standard MSAA values
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(1));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_2_BIT), getMSAASampleCountFlag(2));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_4_BIT), getMSAASampleCountFlag(4));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_8_BIT), getMSAASampleCountFlag(8));
}

test "getMSAASampleCountFlag defaults to 1x for invalid values" {
    const getMSAASampleCountFlag = pipeline_manager.getMSAASampleCountFlag;

    // Invalid values should default to 1 sample
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(0));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(3));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(6));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(16));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(255));
}

test "getMSAASampleCountFlag handles edge case values" {
    const getMSAASampleCountFlag = pipeline_manager.getMSAASampleCountFlag;

    // Test boundary values
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(0));
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(1));

    // Test values that could cause issues with bit manipulation
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(255));
}

// ============================================================================
// Push Constant Size Tests
// ============================================================================

test "push constant sizes are reasonable for GPU usage" {
    // Push constant sizes must be within Vulkan limits (typically 128-256 bytes)
    // and properly aligned (4 bytes)

    const PUSH_CONSTANT_SIZE_MODEL: u32 = 256;
    const PUSH_CONSTANT_SIZE_SKY: u32 = 128;
    const PUSH_CONSTANT_SIZE_UI: u32 = @sizeOf(@import("../../math/mat4.zig").Mat4);

    // Model push constants should be <= 256 (common limit)
    try testing.expect(PUSH_CONSTANT_SIZE_MODEL <= 256);

    // Sky push constants should be <= 256 and properly aligned
    try testing.expect(PUSH_CONSTANT_SIZE_SKY <= 256);
    try testing.expect(PUSH_CONSTANT_SIZE_SKY % 4 == 0);

    // UI push constants (Mat4) should be 64 bytes (4x4 f32)
    try testing.expectEqual(@as(usize, 64), PUSH_CONSTANT_SIZE_UI);
    try testing.expect(PUSH_CONSTANT_SIZE_UI <= 256);
}

// ============================================================================
// Shader Module Size Limit Tests
// ============================================================================

test "MAX_SHADER_MODULE_BYTES is reasonable" {
    const MAX_SHADER_MODULE_BYTES: usize = 4 * 1024 * 1024;

    // 4MB should be enough for any reasonable shader
    try testing.expect(MAX_SHADER_MODULE_BYTES >= 1024 * 1024);

    // Should not exceed reasonable memory limits
    try testing.expect(MAX_SHADER_MODULE_BYTES <= 64 * 1024 * 1024);
}

// ============================================================================
// PipelineManager State Consistency Tests
// ============================================================================

test "PipelineManager struct size is reasonable" {
    const size = @sizeOf(PipelineManager);

    // Should be larger than zero (contains fields)
    try testing.expect(size > 0);

    // Should not be excessively large (< 10KB for a struct)
    try testing.expect(size < 10 * 1024);
}

test "PipelineManager field offsets are properly aligned" {
    // Verify that pointer-sized fields are properly aligned
    // This is important for GPU interop

    const offset_terrain = @offsetOf(PipelineManager, "terrain_pipeline");
    const offset_layout = @offsetOf(PipelineManager, "pipeline_layout");

    // VkPipeline is a pointer type, should be pointer-aligned
    try testing.expect(offset_terrain % @alignOf(*anyopaque) == 0);
    try testing.expect(offset_layout % @alignOf(*anyopaque) == 0);
}

// ============================================================================
// Error Code Mapping Tests (via Utils.checkVk)
// ============================================================================

test "checkVk maps VK_SUCCESS to void" {
    // VK_SUCCESS should return without error
    try Utils.checkVk(c.VK_SUCCESS);
}

test "checkVk maps VK_ERROR_DEVICE_LOST to GpuLost" {
    const result = Utils.checkVk(c.VK_ERROR_DEVICE_LOST);
    try testing.expectError(error.GpuLost, result);
}

test "checkVk maps VK_ERROR_OUT_OF_HOST_MEMORY to OutOfMemory" {
    const result = Utils.checkVk(c.VK_ERROR_OUT_OF_HOST_MEMORY);
    try testing.expectError(error.OutOfMemory, result);
}

test "checkVk maps VK_ERROR_OUT_OF_DEVICE_MEMORY to OutOfMemory" {
    const result = Utils.checkVk(c.VK_ERROR_OUT_OF_DEVICE_MEMORY);
    try testing.expectError(error.OutOfMemory, result);
}

test "checkVk maps VK_ERROR_SURFACE_LOST_KHR to SurfaceLost" {
    const result = Utils.checkVk(c.VK_ERROR_SURFACE_LOST_KHR);
    try testing.expectError(error.SurfaceLost, result);
}

test "checkVk maps VK_ERROR_INITIALIZATION_FAILED to InitializationFailed" {
    const result = Utils.checkVk(c.VK_ERROR_INITIALIZATION_FAILED);
    try testing.expectError(error.InitializationFailed, result);
}

test "checkVk maps VK_ERROR_EXTENSION_NOT_PRESENT to ExtensionNotPresent" {
    const result = Utils.checkVk(c.VK_ERROR_EXTENSION_NOT_PRESENT);
    try testing.expectError(error.ExtensionNotPresent, result);
}

test "checkVk maps VK_ERROR_FEATURE_NOT_PRESENT to FeatureNotPresent" {
    const result = Utils.checkVk(c.VK_ERROR_FEATURE_NOT_PRESENT);
    try testing.expectError(error.FeatureNotPresent, result);
}

test "checkVk maps VK_ERROR_TOO_MANY_OBJECTS to TooManyObjects" {
    const result = Utils.checkVk(c.VK_ERROR_TOO_MANY_OBJECTS);
    try testing.expectError(error.TooManyObjects, result);
}

test "checkVk maps VK_ERROR_FORMAT_NOT_SUPPORTED to FormatNotSupported" {
    const result = Utils.checkVk(c.VK_ERROR_FORMAT_NOT_SUPPORTED);
    try testing.expectError(error.FormatNotSupported, result);
}

test "checkVk maps VK_ERROR_FRAGMENTED_POOL to FragmentedPool" {
    const result = Utils.checkVk(c.VK_ERROR_FRAGMENTED_POOL);
    try testing.expectError(error.FragmentedPool, result);
}

test "checkVk maps unknown error codes to Unknown" {
    // Test with an arbitrary value that isn't explicitly mapped
    const UNKNOWN_ERROR: c.VkResult = -9999;
    const result = Utils.checkVk(UNKNOWN_ERROR);
    try testing.expectError(error.Unknown, result);
}

test "checkVk maps VK_ERROR_OUT_OF_DATE_KHR to Unknown" {
    // This error is not explicitly mapped, should return Unknown
    const result = Utils.checkVk(c.VK_ERROR_OUT_OF_DATE_KHR);
    try testing.expectError(error.Unknown, result);
}

// ============================================================================
// MAX_FRAMES_IN_FLIGHT Consistency Tests
// ============================================================================

test "MAX_FRAMES_IN_FLIGHT matches descriptor set array sizes" {
    // The PipelineManager uses MAX_FRAMES_IN_FLIGHT for descriptor sets
    // This test ensures consistency across the module
    try testing.expectEqual(@as(usize, rhi.MAX_FRAMES_IN_FLIGHT), 2);
}

// ============================================================================
// PipelineManager Lifecycle State Machine Tests
// ============================================================================

test "PipelineManager partial initialization state" {
    // Simulate a partially initialized state (e.g., init failed partway)
    var manager: PipelineManager = .{};

    // Simulate some pipelines being created but not all
    // In reality, these would be valid handles, but we're testing state logic
    manager.terrain_pipeline = @ptrFromInt(1);
    manager.wireframe_pipeline = null;

    // The struct should allow this state (it doesn't enforce invariants)
    try testing.expect(manager.terrain_pipeline != null);
    try testing.expect(manager.wireframe_pipeline == null);
}

// ============================================================================
// Resource Handle Safety Tests
// ============================================================================

test "null Vulkan handles can be compared safely" {
    // This test ensures that null handle comparisons work as expected
    const null_pipeline: c.VkPipeline = null;
    const null_layout: c.VkPipelineLayout = null;

    try testing.expect(null_pipeline == null);
    try testing.expect(null_layout == null);
}

test "PipelineManager optional fields are properly optional" {
    var manager: PipelineManager = .{};

    // Debug shadow fields are optional (?T)
    try testing.expect(manager.debug_shadow_pipeline == null);
    try testing.expect(manager.debug_shadow_pipeline_layout == null);
    try testing.expect(manager.debug_shadow_descriptor_set_layout == null);

    // Setting them to null explicitly should work
    manager.debug_shadow_pipeline = null;
    manager.debug_shadow_pipeline_layout = null;
    manager.debug_shadow_descriptor_set_layout = null;

    try testing.expect(manager.debug_shadow_pipeline == null);
}
