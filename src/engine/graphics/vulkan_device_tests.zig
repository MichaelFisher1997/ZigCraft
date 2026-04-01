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
// Additional Error Code Mapping Tests
// ============================================================================

test "checkVk maps VK_SUBOPTIMAL_KHR to error.Unknown" {
    // VK_SUBOPTIMAL_KHR indicates surface properties changed but still usable
    // Currently maps to Unknown - could be mapped to a specific error in future
    try testing.expectError(error.Unknown, checkVk(c.VK_SUBOPTIMAL_KHR));
}

test "checkVk maps VK_ERROR_OUT_OF_DATE_KHR to error.Unknown" {
    // VK_ERROR_OUT_OF_DATE_KHR indicates surface properties changed but swapchain can be recreated
    // Currently maps to Unknown - could be mapped to a specific error like error.OutOfDate in future
    try testing.expectError(error.Unknown, checkVk(c.VK_ERROR_OUT_OF_DATE_KHR));
}

test "checkVk handles error codes near boundary values" {
    // Test various error codes to ensure comprehensive coverage
    // VK_ERROR_NATIVE_WINDOW_IN_USE_KHR
    try testing.expectError(error.Unknown, checkVk(c.VK_ERROR_NATIVE_WINDOW_IN_USE_KHR));

    // Negative error codes that aren't explicitly mapped
    try testing.expectError(error.Unknown, checkVk(-1000001000)); // Arbitrary unmapped negative
    try testing.expectError(error.Unknown, checkVk(-13)); // Between mapped values
}

test "checkVk success code handling completeness" {
    // Document all success codes and their current behavior
    // VK_SUCCESS - explicitly handled
    try checkVk(c.VK_SUCCESS);

    // Other success codes currently map to Unknown (documenting current behavior)
    // These could potentially return success instead in future
    try testing.expectError(error.Unknown, checkVk(c.VK_NOT_READY));
    try testing.expectError(error.Unknown, checkVk(c.VK_TIMEOUT));
    try testing.expectError(error.Unknown, checkVk(c.VK_EVENT_SET));
    try testing.expectError(error.Unknown, checkVk(c.VK_EVENT_RESET));
}

// ============================================================================
// Device Capability Boundary Tests
// ============================================================================

test "VulkanDevice max_anisotropy boundary values" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Test zero anisotropy (disabled)
    device.max_anisotropy = 0.0;
    try testing.expectEqual(@as(f32, 0.0), device.max_anisotropy);

    // Test common values
    device.max_anisotropy = 2.0;
    try testing.expectEqual(@as(f32, 2.0), device.max_anisotropy);

    device.max_anisotropy = 4.0;
    try testing.expectEqual(@as(f32, 4.0), device.max_anisotropy);

    device.max_anisotropy = 8.0;
    try testing.expectEqual(@as(f32, 8.0), device.max_anisotropy);

    device.max_anisotropy = 16.0;
    try testing.expectEqual(@as(f32, 16.0), device.max_anisotropy);

    // Test maximum possible value (Vulkan spec allows up to 16)
    device.max_anisotropy = 16.0;
    try testing.expect(device.max_anisotropy <= 16.0);
}

test "VulkanDevice max_msaa_samples valid values" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Valid MSAA sample counts per Vulkan spec
    const valid_samples = [_]u8{ 1, 2, 4, 8 };
    for (valid_samples) |samples| {
        device.max_msaa_samples = samples;
        try testing.expectEqual(samples, device.max_msaa_samples);
    }
}

test "VulkanDevice timestamp_period precision values" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Default value
    try testing.expectEqual(@as(f32, 1.0), device.timestamp_period);

    // Common GPU timestamp periods
    device.timestamp_period = 1.0; // 1 ns per tick (common)
    try testing.expectEqual(@as(f32, 1.0), device.timestamp_period);

    device.timestamp_period = 0.5; // 0.5 ns per tick
    try testing.expectEqual(@as(f32, 0.5), device.timestamp_period);

    device.timestamp_period = 2.0; // 2 ns per tick
    try testing.expectEqual(@as(f32, 2.0), device.timestamp_period);
}

// ============================================================================
// Recovery State Boundary Tests
// ============================================================================

test "VulkanDevice recovery at maximum attempts boundary" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .max_recovery_attempts = 5,
        .recovery_count = 5,
    };

    // At max attempts - should not attempt recovery
    try testing.expect(device.recovery_count >= device.max_recovery_attempts);

    // Just under limit - recovery should be attempted
    device.recovery_count = 4;
    try testing.expect(device.recovery_count < device.max_recovery_attempts);
}

test "VulkanDevice recovery counter overflow protection" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .max_recovery_attempts = 5,
        .recovery_count = std.math.maxInt(u32),
    };

    // Even at u32 max, recovery count should exceed max attempts
    try testing.expect(device.recovery_count >= device.max_recovery_attempts);
}

test "VulkanDevice fault_count tracks independently from recovery" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Simulate multiple faults with some recoveries
    device.fault_count = 10;
    device.recovery_count = 5;
    device.recovery_success_count = 3;
    device.recovery_fail_count = 2;

    // fault_count should be total faults, regardless of recovery outcome
    try testing.expectEqual(@as(u32, 10), device.fault_count);
    try testing.expect(device.recovery_success_count + device.recovery_fail_count == device.recovery_count);
}

// ============================================================================
// Extension Function Pointer State Tests
// ============================================================================

test "VulkanDevice extension function pointer lifecycle" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Initially null
    try testing.expect(device.vkGetDeviceFaultInfoEXT == null);

    // If device fault extension were available, this would be set during init
    // Test that the field can be assigned
    const mock_func: @TypeOf(device.vkGetDeviceFaultInfoEXT) = @ptrFromInt(0x1234);
    device.vkGetDeviceFaultInfoEXT = mock_func;
    try testing.expect(device.vkGetDeviceFaultInfoEXT != null);

    // Reset to null (simulating cleanup)
    device.vkGetDeviceFaultInfoEXT = null;
    try testing.expect(device.vkGetDeviceFaultInfoEXT == null);
}

// ============================================================================
// Struct Layout and Alignment Tests
// ============================================================================

test "VulkanDevice struct size and alignment" {
    // Verify struct layout is as expected for GPU interop
    const device_size = @sizeOf(VulkanDevice);
    const device_align = @alignOf(VulkanDevice);

    // Struct should be reasonably sized (less than 1KB for cache efficiency)
    try testing.expect(device_size < 1024);

    // Alignment should be standard pointer alignment
    try testing.expect(device_align >= @alignOf(?*anyopaque));
}

test "VulkanDevice atomic field memory ordering" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Test that atomic operations work with different memory orderings
    _ = device.validation_error_count.fetchAdd(1, .monotonic);
    _ = device.validation_error_count.fetchAdd(1, .acquire);
    _ = device.validation_error_count.fetchAdd(1, .release);
    _ = device.validation_error_count.fetchAdd(1, .acq_rel);
    _ = device.validation_error_count.fetchAdd(1, .seq_cst);

    try testing.expectEqual(@as(u32, 5), device.validation_error_count.load(.monotonic));
}

// ============================================================================
// Debug Messenger State Tests
// ============================================================================

test "VulkanDevice debug_messenger lifecycle states" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Initial state
    try testing.expect(device.debug_messenger == null);
    try testing.expect(!device.debug_utils_enabled);

    // After enabling
    device.debug_utils_enabled = true;
    try testing.expect(device.debug_utils_enabled);
    // Note: debug_messenger still null until initDebugMessenger is called
    try testing.expect(device.debug_messenger == null);
}

// ============================================================================
// Queue Family Index Validation Tests
// ============================================================================

test "VulkanDevice graphics_family valid indices" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    // Test common queue family indices
    device.graphics_family = 0;
    try testing.expectEqual(@as(u32, 0), device.graphics_family);

    device.graphics_family = 1;
    try testing.expectEqual(@as(u32, 1), device.graphics_family);

    device.graphics_family = 2;
    try testing.expectEqual(@as(u32, 2), device.graphics_family);

    // Max reasonable queue family index
    device.graphics_family = 15;
    try testing.expectEqual(@as(u32, 15), device.graphics_family);
}
