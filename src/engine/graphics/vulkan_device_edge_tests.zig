const std = @import("std");
const testing = std.testing;
const c = @import("../../c.zig").c;
const vulkan_device = @import("vulkan_device.zig");
const VulkanDevice = vulkan_device.VulkanDevice;
const checkVk = vulkan_device.checkVk;

// ============================================================================
// initDebugMessenger Early Return Tests
// ============================================================================

test "VulkanDevice.initDebugMessenger early returns when debug_utils disabled" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .debug_utils_enabled = false,
        .debug_messenger = null,
        .instance = @ptrFromInt(0x1234),
    };

    // Should return early without calling any Vulkan debug functions
    device.initDebugMessenger();

    // debug_messenger should remain null since early return happened
    try testing.expect(device.debug_messenger == null);
}

test "VulkanDevice.initDebugMessenger early returns when messenger already created" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .debug_utils_enabled = true,
        .debug_messenger = @ptrFromInt(0x5678), // Already set
        .instance = @ptrFromInt(0x1234),
    };

    // Should return early because debug_messenger != null
    device.initDebugMessenger();

    // debug_messenger should remain unchanged
    try testing.expect(device.debug_messenger != null);
}

// ============================================================================
// MSAA Sample Count Edge Cases
// ============================================================================

test "VulkanDevice MSAA defaults to 1 when no sample flags set" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Default max_msaa_samples is 1
    try testing.expectEqual(@as(u8, 1), device.max_msaa_samples);
}

test "VulkanDevice MSAA can be set to boundary values" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Test min boundary (1)
    device.max_msaa_samples = 1;
    try testing.expectEqual(@as(u8, 1), device.max_msaa_samples);

    // Test mid boundary (4)
    device.max_msaa_samples = 4;
    try testing.expectEqual(@as(u8, 4), device.max_msaa_samples);

    // Test max boundary (8)
    device.max_msaa_samples = 8;
    try testing.expectEqual(@as(u8, 8), device.max_msaa_samples);
}

// ============================================================================
// Recovery State Machine Tests
// ============================================================================

test "VulkanDevice recovery_fail_count increments independently" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .recovery_fail_count = 0,
    };

    device.recovery_fail_count = 3;
    try testing.expectEqual(@as(u32, 3), device.recovery_fail_count);

    device.recovery_fail_count += 1;
    try testing.expectEqual(@as(u32, 4), device.recovery_fail_count);
}

test "VulkanDevice recovery_success_count increments independently" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .recovery_success_count = 0,
    };

    device.recovery_success_count = 2;
    try testing.expectEqual(@as(u32, 2), device.recovery_success_count);

    device.recovery_success_count += 1;
    try testing.expectEqual(@as(u32, 3), device.recovery_success_count);
}

// ============================================================================
// checkVk Extended Error Code Coverage
// ============================================================================

test "checkVk maps VK_ERROR_VALIDATION_FAILED_EXT to Unknown" {
    // This error code is less common but should still map to Unknown
    try testing.expectError(error.Unknown, checkVk(c.VK_ERROR_VALIDATION_FAILED_EXT));
}

test "checkVk maps VK_SUBOPTIMAL_KHR to Unknown" {
    // SUBOPTIMAL is a success variant, but current implementation maps it to Unknown
    // This documents current behavior
    try testing.expectError(error.Unknown, checkVk(c.VK_SUBOPTIMAL_KHR));
}
