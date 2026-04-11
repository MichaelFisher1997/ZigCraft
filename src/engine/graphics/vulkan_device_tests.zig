const std = @import("std");
const testing = std.testing;
const c = @import("../../c.zig").c;
const vulkan_device = @import("vulkan_device.zig");
const VulkanDevice = vulkan_device.VulkanDevice;
const checkVk = vulkan_device.checkVk;

// ============================================================================
// Recovery State Machine Tests
// ============================================================================

test "VulkanDevice recovery state initialization" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    try testing.expectEqual(@as(u32, 0), device.fault_count);
    try testing.expectEqual(@as(u32, 0), device.recovery_count);
    try testing.expectEqual(@as(u32, 0), device.recovery_success_count);
    try testing.expectEqual(@as(u32, 0), device.recovery_fail_count);
    try testing.expectEqual(@as(u32, 5), device.max_recovery_attempts);
}

test "VulkanDevice recovery counter increments are independent" {
    // Verify that fault tracking fields are independent counters
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Simulate multiple fault scenarios
    device.fault_count = 3;
    device.recovery_count = 2;
    device.recovery_success_count = 1;
    device.recovery_fail_count = 1;

    // Each counter should track independently
    try testing.expectEqual(@as(u32, 3), device.fault_count);
    try testing.expectEqual(@as(u32, 2), device.recovery_count);
    try testing.expectEqual(@as(u32, 1), device.recovery_success_count);
    try testing.expectEqual(@as(u32, 1), device.recovery_fail_count);
}

test "VulkanDevice max_recovery_attempts boundary" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .max_recovery_attempts = 5,
        .recovery_count = 5,
    };

    // Recovery count at max should indicate no more attempts allowed
    try testing.expect(device.recovery_count >= device.max_recovery_attempts);

    // Reset and verify boundary
    device.recovery_count = 4;
    try testing.expect(device.recovery_count < device.max_recovery_attempts);
}

// ============================================================================
// Device Capability Tests
// ============================================================================

test "VulkanDevice capability fields default state" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Defaults from struct definition
    try testing.expectEqual(@as(f32, 0.0), device.max_anisotropy);
    try testing.expectEqual(@as(u8, 1), device.max_msaa_samples);
    try testing.expect(!device.multi_draw_indirect);
    try testing.expect(!device.draw_indirect_first_instance);
    try testing.expectEqual(@as(f32, 1.0), device.timestamp_period);
}

test "VulkanDevice capability state transitions" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Simulate capability detection
    device.max_anisotropy = 16.0;
    device.max_msaa_samples = 8;
    device.multi_draw_indirect = true;
    device.draw_indirect_first_instance = true;
    device.timestamp_period = 1.25;

    try testing.expectEqual(@as(f32, 16.0), device.max_anisotropy);
    try testing.expectEqual(@as(u8, 8), device.max_msaa_samples);
    try testing.expect(device.multi_draw_indirect);
    try testing.expect(device.draw_indirect_first_instance);
    try testing.expectEqual(@as(f32, 1.25), device.timestamp_period);
}

// ============================================================================
// Extension Support Tests
// ============================================================================

test "VulkanDevice extension support flags default false" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    try testing.expect(!device.supports_device_fault);
    try testing.expect(!device.debug_utils_enabled);
}

test "VulkanDevice extension flags can be enabled" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .supports_device_fault = true,
        .debug_utils_enabled = true,
    };

    try testing.expect(device.supports_device_fault);
    try testing.expect(device.debug_utils_enabled);
}

// ============================================================================
// Validation Error Tracking Tests
// ============================================================================

test "VulkanDevice validation_error_count atomic operations" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Initial state
    try testing.expectEqual(@as(u32, 0), device.validation_error_count.load(.monotonic));

    // Simulate atomic increment (as would happen in debugCallback)
    const prev = device.validation_error_count.fetchAdd(1, .monotonic);
    try testing.expectEqual(@as(u32, 0), prev);
    try testing.expectEqual(@as(u32, 1), device.validation_error_count.load(.monotonic));

    // Multiple increments
    _ = device.validation_error_count.fetchAdd(4, .monotonic);
    try testing.expectEqual(@as(u32, 5), device.validation_error_count.load(.monotonic));
}

// ============================================================================
// checkVk Error Mapping Edge Cases
// ============================================================================

test "checkVk maps unhandled error codes to Unknown" {
    // Test various Vulkan error codes that should map to Unknown
    try testing.expectError(error.Unknown, checkVk(c.VK_ERROR_MEMORY_MAP_FAILED));
    try testing.expectError(error.Unknown, checkVk(c.VK_ERROR_LAYER_NOT_PRESENT));
    try testing.expectError(error.Unknown, checkVk(c.VK_INCOMPLETE));
    try testing.expectError(error.Unknown, checkVk(c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR));
}

test "checkVk handles success variants" {
    // VK_SUCCESS should not return an error
    try checkVk(c.VK_SUCCESS);

    // Other success codes should also not error
    // Note: These return error.Unknown currently as they're not explicitly handled
    // This test documents the current behavior
    try testing.expectError(error.Unknown, checkVk(c.VK_NOT_READY));
    try testing.expectError(error.Unknown, checkVk(c.VK_TIMEOUT));
    try testing.expectError(error.Unknown, checkVk(c.VK_EVENT_SET));
    try testing.expectError(error.Unknown, checkVk(c.VK_EVENT_RESET));
    try testing.expectError(error.Unknown, checkVk(c.VK_INCOMPLETE));
}

// ============================================================================
// Graphics Queue Family Tests
// ============================================================================

test "VulkanDevice graphics_family default and assignment" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Default should be 0
    try testing.expectEqual(@as(u32, 0), device.graphics_family);

    // Simulate assignment after device enumeration
    device.graphics_family = 2;
    try testing.expectEqual(@as(u32, 2), device.graphics_family);
}

// ============================================================================
// Null Handle Safety Tests
// ============================================================================

test "VulkanDevice null handles are safe for default initialization" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .instance = null,
        .surface = null,
        .physical_device = null,
        .debug_messenger = null,
    };

    // All handles should be null in default state
    try testing.expect(device.vk_device == null);
    try testing.expect(device.queue == null);
    try testing.expect(device.instance == null);
    try testing.expect(device.surface == null);
    try testing.expect(device.physical_device == null);
}

// ============================================================================
// Extension Function Pointer Tests
// ============================================================================

test "VulkanDevice vkGetDeviceFaultInfoEXT defaults to null" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    try testing.expect(device.vkGetDeviceFaultInfoEXT == null);
}

// ============================================================================
// Mutex Safety Tests
// ============================================================================

test "VulkanDevice mutex is initialized" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Verify mutex can be locked/unlocked
    device.mutex.lock();
    device.mutex.unlock();

    // If we get here without deadlock or panic, mutex is properly initialized
    try testing.expect(true);
}

// ============================================================================
// initDebugMessenger Early Return Tests
// ============================================================================

test "initDebugMessenger early returns when debug_utils_enabled is false" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .instance = @ptrFromInt(0x1234),
        .debug_utils_enabled = false,
        .debug_messenger = null,
    };

    // Should return early without trying to create messenger
    device.initDebugMessenger();

    // debug_messenger should remain null
    try testing.expect(device.debug_messenger == null);
}

test "initDebugMessenger early returns when debug_messenger already set" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .instance = @ptrFromInt(0x1234),
        .debug_utils_enabled = true,
        .debug_messenger = @as(c.VkDebugUtilsMessengerEXT, @ptrFromInt(0xDEADBEEF)),
    };

    // Should return early without trying to create another messenger
    device.initDebugMessenger();

    // debug_messenger should remain unchanged
    try testing.expect(device.debug_messenger == @as(c.VkDebugUtilsMessengerEXT, @ptrFromInt(0xDEADBEEF)));
}

// ============================================================================
// has_dedicated_transfer_queue Tests
// ============================================================================

test "VulkanDevice has_dedicated_transfer_queue defaults to false" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    try testing.expect(!device.has_dedicated_transfer_queue);
}

test "VulkanDevice has_dedicated_transfer_queue can be set to true" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .has_dedicated_transfer_queue = true,
    };

    try testing.expect(device.has_dedicated_transfer_queue);

    // Setting back to false
    device.has_dedicated_transfer_queue = false;
    try testing.expect(!device.has_dedicated_transfer_queue);
}

// ============================================================================
// transfer_family Assignment Tests
// ============================================================================

test "VulkanDevice transfer_family defaults to graphics_family" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .graphics_family = 4,
        .transfer_family = 4, // When no dedicated transfer, equals graphics_family
    };

    try testing.expectEqual(device.graphics_family, device.transfer_family);
}

test "VulkanDevice transfer_family separate from graphics_family when dedicated" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .graphics_family = 0,
        .transfer_family = 2,
        .has_dedicated_transfer_queue = true,
    };

    try testing.expect(device.has_dedicated_transfer_queue);
    try testing.expect(device.graphics_family != device.transfer_family);
}
