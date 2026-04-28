//! Unit tests for Vulkan utility functions (utils.zig)
//!
//! Tests for utility functions that are testable without GPU access.

const std = @import("std");
const testing = std.testing;
const c = @import("c").c;
const Utils = @import("utils.zig");
const VulkanBuffer = Utils.VulkanBuffer;
const rhi = @import("../rhi.zig");
const Mat4 = @import("../../math/mat4.zig").Mat4;

// ============================================================================
// VulkanBuffer Struct Layout Tests
// ============================================================================

test "VulkanBuffer default initialization produces null handles" {
    const buffer: VulkanBuffer = .{};

    try testing.expectEqual(@as(c.VkBuffer, null), buffer.buffer);
    try testing.expectEqual(@as(c.VkDeviceMemory, null), buffer.memory);
    try testing.expectEqual(@as(c.VkDeviceSize, 0), buffer.size);
    try testing.expectEqual(@as(bool, false), buffer.is_host_visible);
    try testing.expectEqual(@as(?*anyopaque, null), buffer.mapped_ptr);
}

test "VulkanBuffer struct size is reasonable" {
    const size = @sizeOf(VulkanBuffer);

    try testing.expect(size > 0);
    try testing.expect(size < 128); // Should be small (buffer, memory, size, flags, ptr)
}

test "VulkanBuffer field alignment is proper" {
    const offset_buffer = @offsetOf(VulkanBuffer, "buffer");
    const offset_memory = @offsetOf(VulkanBuffer, "memory");
    const offset_size = @offsetOf(VulkanBuffer, "size");
    const offset_mapped = @offsetOf(VulkanBuffer, "mapped_ptr");

    // Buffer and memory are pointers - should be pointer-aligned
    try testing.expect(offset_buffer % @alignOf(*anyopaque) == 0);
    try testing.expect(offset_memory % @alignOf(*anyopaque) == 0);
    try testing.expect(offset_mapped % @alignOf(*anyopaque) == 0);

    // Size should be 8-byte aligned (VkDeviceSize is uint64_t)
    try testing.expect(offset_size % 8 == 0);
}

// ============================================================================
// checkVk Error Code Mapping Tests
// ============================================================================

test "checkVk maps VK_SUCCESS correctly" {
    try Utils.checkVk(c.VK_SUCCESS);
}

test "checkVk maps VK_NOT_READY to Unknown" {
    const result = Utils.checkVk(c.VK_NOT_READY);
    try testing.expectError(error.Unknown, result);
}

test "checkVk maps VK_TIMEOUT to Unknown" {
    const result = Utils.checkVk(c.VK_TIMEOUT);
    try testing.expectError(error.Unknown, result);
}

test "checkVk maps VK_EVENT_SET to Unknown" {
    const result = Utils.checkVk(c.VK_EVENT_SET);
    try testing.expectError(error.Unknown, result);
}

test "checkVk maps VK_EVENT_RESET to Unknown" {
    const result = Utils.checkVk(c.VK_EVENT_RESET);
    try testing.expectError(error.Unknown, result);
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

test "checkVk maps VK_ERROR_UNKNOWN to Unknown" {
    const result = Utils.checkVk(c.VK_ERROR_UNKNOWN);
    try testing.expectError(error.Unknown, result);
}

test "checkVk maps VK_SUBOPTIMAL_KHR to Unknown" {
    const result = Utils.checkVk(c.VK_SUBOPTIMAL_KHR);
    try testing.expectError(error.Unknown, result);
}

test "checkVk maps negative result codes to Unknown" {
    // Test that negative VkResult values (which are errors) return Unknown
    const result = Utils.checkVk(@as(c.VkResult, -13));
    try testing.expectError(error.Unknown, result);
}

// ============================================================================
// Sampler Configuration Constants Tests
// ============================================================================

test "VK_BORDER_COLOR_INT_OPAQUE_BLACK is valid" {
    // This is used in createSampler
    try testing.expectEqual(@as(c.VkBorderColor, c.VK_BORDER_COLOR_INT_OPAQUE_BLACK), c.VK_BORDER_COLOR_INT_OPAQUE_BLACK);
}

test "VK_FILTER_NEAREST and VK_FILTER_LINEAR are distinct" {
    try testing.expect(c.VK_FILTER_NEAREST != c.VK_FILTER_LINEAR);
}

test "VK_SAMPLER_ADDRESS_MODE constants are valid" {
    try testing.expectEqual(@as(c.VkSamplerAddressMode, c.VK_SAMPLER_ADDRESS_MODE_REPEAT), c.VK_SAMPLER_ADDRESS_MODE_REPEAT);
    try testing.expectEqual(@as(c.VkSamplerAddressMode, c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT), c.VK_SAMPLER_ADDRESS_MODE_MIRRORED_REPEAT);
    try testing.expectEqual(@as(c.VkSamplerAddressMode, c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE), c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE);
    try testing.expectEqual(@as(c.VkSamplerAddressMode, c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER), c.VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_BORDER);
}

test "VK_SAMPLER_MIPMAP_MODE constants are valid" {
    try testing.expectEqual(@as(c.VkSamplerMipmapMode, c.VK_SAMPLER_MIPMAP_MODE_NEAREST), c.VK_SAMPLER_MIPMAP_MODE_NEAREST);
    try testing.expectEqual(@as(c.VkSamplerMipmapMode, c.VK_SAMPLER_MIPMAP_MODE_LINEAR), c.VK_SAMPLER_MIPMAP_MODE_LINEAR);
}

// ============================================================================
// Shader Module Creation Info Tests
// ============================================================================

test "VkShaderModuleCreateInfo sType is correct" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO), c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO);
}

// ============================================================================
// Pipeline State Constants Tests
// ============================================================================

test "VK_DYNAMIC_STATE_VIEWPORT and VK_DYNAMIC_STATE_SCISSOR are valid" {
    try testing.expectEqual(@as(cVkDynamicState, c.VK_DYNAMIC_STATE_VIEWPORT), c.VK_DYNAMIC_STATE_VIEWPORT);
    try testing.expectEqual(@as(cVkDynamicState, c.VK_DYNAMIC_STATE_SCISSOR), c.VK_DYNAMIC_STATE_SCISSOR);
}

test "VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST is valid" {
    try testing.expectEqual(@as(cVkPrimitiveTopology, c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST), c.VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST);
}

test "VK_CULL_MODE_NONE and VK_CULL_MODE_BACK_BIT are distinct flags" {
    try testing.expect(c.VK_CULL_MODE_NONE != c.VK_CULL_MODE_BACK_BIT);
}

test "VK_FRONT_FACE_CLOCKWISE and VK_FRONT_FACE_COUNTER_CLOCKWISE are distinct" {
    try testing.expect(c.VK_FRONT_FACE_CLOCKWISE != c.VK_FRONT_FACE_COUNTER_CLOCKWISE);
}

test "VK_POLYGON_MODE_FILL and VK_POLYGON_MODE_LINE are distinct" {
    try testing.expect(c.VK_POLYGON_MODE_FILL != c.VK_POLYGON_MODE_LINE);
}

// ============================================================================
// Color Blend State Constants Tests
// ============================================================================

test "VK_BLEND_FACTOR constants are valid and distinct" {
    try testing.expect(c.VK_BLEND_FACTOR_SRC_ALPHA != c.VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA);
    try testing.expect(c.VK_BLEND_FACTOR_ONE != c.VK_BLEND_FACTOR_ZERO);
}

test "VK_BLEND_OP_ADD is valid" {
    try testing.expectEqual(@as(cVkBlendOp, c.VK_BLEND_OP_ADD), c.VK_BLEND_OP_ADD);
}

test "VK_COLOR_COMPONENT_R_G_B_A flags are valid" {
    const flags = c.VK_COLOR_COMPONENT_R_BIT | c.VK_COLOR_COMPONENT_G_BIT | c.VK_COLOR_COMPONENT_B_BIT | c.VK_COLOR_COMPONENT_A_BIT;
    try testing.expect(flags > 0);
}

// ============================================================================
// Depth Stencil State Constants Tests
// ============================================================================

test "VK_COMPARE_OP_GREATER_OR_EQUAL is valid" {
    try testing.expectEqual(@as(cVkCompareOp, c.VK_COMPARE_OP_GREATER_OR_EQUAL), c.VK_COMPARE_OP_GREATER_OR_EQUAL);
}

// ============================================================================
// Vertex Input Constants Tests
// ============================================================================

test "VK_VERTEX_INPUT_RATE_VERTEX is valid" {
    try testing.expectEqual(@as(cVkVertexInputRate, c.VK_VERTEX_INPUT_RATE_VERTEX), c.VK_VERTEX_INPUT_RATE_VERTEX);
}

test "VK_FORMAT_R32G32B32_SFLOAT format is valid for position" {
    try testing.expectEqual(@as(cVkFormat, c.VK_FORMAT_R32G32B32_SFLOAT), c.VK_FORMAT_R32G32B32_SFLOAT);
}

test "VK_FORMAT_R32_UINT format is valid for uint attributes" {
    try testing.expectEqual(@as(cVkFormat, c.VK_FORMAT_R32_UINT), c.VK_FORMAT_R32_UINT);
}

test "VK_FORMAT_R16G16_SFLOAT format is valid for UV coordinates" {
    try testing.expectEqual(@as(cVkFormat, c.VK_FORMAT_R16G16_SFLOAT), c.VK_FORMAT_R16G16_SFLOAT);
}

// ============================================================================
// Memory Properties Tests
// ============================================================================

test "VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT and VK_MEMORY_PROPERTY_HOST_COHERENT_BIT are valid flags" {
    try testing.expect(c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT > 0);
    try testing.expect(c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT > 0);
}

test "VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT and VK_BUFFER_USAGE_STORAGE_BUFFER_BIT are valid flags" {
    try testing.expect(c.VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT > 0);
    try testing.expect(c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT > 0);
}

// ============================================================================
// Pipeline Layout Constants Tests
// ============================================================================

test "VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO), c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO);
}

test "VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO), c.VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO);
}

// ============================================================================
// Sample Count Flag Tests
// ============================================================================

test "VK_SAMPLE_COUNT_1_BIT is the minimum sample count" {
    try testing.expect(c.VK_SAMPLE_COUNT_1_BIT > 0);
}

test "VK_SAMPLE_COUNT_FLAG_BITS are power-of-two values" {
    try testing.expectEqual(@as(u32, 0), @ctz(c.VK_SAMPLE_COUNT_1_BIT));
    try testing.expectEqual(@as(u32, 1), @ctz(c.VK_SAMPLE_COUNT_2_BIT));
    try testing.expectEqual(@as(u32, 2), @ctz(c.VK_SAMPLE_COUNT_4_BIT));
    try testing.expectEqual(@as(u32, 3), @ctz(c.VK_SAMPLE_COUNT_8_BIT));
}

// ============================================================================
// Shader Stage Constants Tests
// ============================================================================

test "VK_SHADER_STAGE_VERTEX_BIT and VK_SHADER_STAGE_FRAGMENT_BIT are valid" {
    try testing.expect(c.VK_SHADER_STAGE_VERTEX_BIT > 0);
    try testing.expect(c.VK_SHADER_STAGE_FRAGMENT_BIT > 0);
}

test "VK_SHADER_STAGE_COMPUTE_BIT is distinct from graphics stages" {
    try testing.expect(c.VK_SHADER_STAGE_COMPUTE_BIT != c.VK_SHADER_STAGE_VERTEX_BIT);
    try testing.expect(c.VK_SHADER_STAGE_COMPUTE_BIT != c.VK_SHADER_STAGE_FRAGMENT_BIT);
}

// ============================================================================
// Descriptor Type Constants Tests
// ============================================================================

test "VK_DESCRIPTOR_TYPE constants are valid and distinct" {
    try testing.expect(c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER != c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER);
    try testing.expect(c.VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER != c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER);
    try testing.expect(c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER != c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER);
}

// ============================================================================
// Pipeline Cache Tests
// ============================================================================

test "VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO), c.VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO);
}

// ============================================================================
// Specialization Constants Tests
// ============================================================================

test "VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO), c.VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO);
}

test "VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO), c.VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO);
}

test "VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO), c.VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO);
}

test "VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO), c.VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO);
}

test "VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO), c.VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO);
}

test "VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO), c.VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO);
}

test "VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO), c.VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO);
}

test "VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO is valid" {
    try testing.expectEqual(@as(cVkStructureType, c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO), c.VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO);
}

// Workaround for missing type alias
const cVkStructureType = c.VkStructureType;
const cVkDynamicState = c.VkDynamicState;
const cVkPrimitiveTopology = c.VkPrimitiveTopology;
const cVkCullModeFlags = c.VkCullModeFlags;
const cVkFrontFace = c.VkFrontFace;
const cVkPolygonMode = c.VkPolygonMode;
const cVkBlendOp = c.VkBlendOp;
const cVkCompareOp = c.VkCompareOp;
const cVkVertexInputRate = c.VkVertexInputRate;
const cVkFormat = c.VkFormat;
const cVkBufferUsageFlags = c.VkBufferUsageFlags;
const cVkMemoryPropertyFlags = c.VkMemoryPropertyFlags;
const cVkShaderStageFlags = c.VkShaderStageFlags;
const cVkDescriptorType = c.VkDescriptorType;
const cVkBorderColor = c.VkBorderColor;
const cVkSamplerAddressMode = c.VkSamplerAddressMode;
const cVkSamplerMipmapMode = c.VkSamplerMipmapMode;
const cVkFilter = c.VkFilter;
const cVkColorComponentFlags = c.VkColorComponentFlags;
