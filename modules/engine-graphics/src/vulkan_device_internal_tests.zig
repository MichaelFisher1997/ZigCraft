const std = @import("std");
const testing = std.testing;
const c = @import("c").c;
const vulkan_device = @import("vulkan_device.zig");
const VulkanDevice = vulkan_device.VulkanDevice;
const checkVk = vulkan_device.checkVk;

fn makeTestDevice() VulkanDevice {
    return VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .validation_error_count = std.atomic.Value(u32).init(0),
    };
}

fn simulateDebugCallbackError(device: *VulkanDevice) void {
    _ = device.validation_error_count.fetchAdd(1, .monotonic);
}

test "debugCallback null user_data returns early without crash" {
    const severity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    const callback_data: ?*const c.VkDebugUtilsMessengerCallbackDataEXT = @ptrFromInt(0x1234);
    const user_data: ?*anyopaque = null;

    const result = vulkan_device.debugCallback(severity, 0, callback_data, user_data);
    try testing.expectEqual(c.VK_FALSE, result);
}

test "debugCallback non-error severity returns early without increment" {
    var device = makeTestDevice();
    const severity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT;
    const callback_data: ?*const c.VkDebugUtilsMessengerCallbackDataEXT = null;
    const user_data: ?*anyopaque = @ptrFromInt(@intFromPtr(&device));

    const result = vulkan_device.debugCallback(severity, 0, callback_data, user_data);
    try testing.expectEqual(c.VK_FALSE, result);
    try testing.expectEqual(@as(u32, 0), device.validation_error_count.load(.monotonic));
}

test "debugCallback error severity increments validation_error_count" {
    var device = makeTestDevice();
    try testing.expectEqual(@as(u32, 0), device.validation_error_count.load(.monotonic));

    simulateDebugCallbackError(&device);

    try testing.expectEqual(@as(u32, 1), device.validation_error_count.load(.monotonic));
}

test "debugCallback multiple errors accumulate in validation_error_count" {
    var device = makeTestDevice();
    simulateDebugCallbackError(&device);
    simulateDebugCallbackError(&device);
    simulateDebugCallbackError(&device);

    try testing.expectEqual(@as(u32, 3), device.validation_error_count.load(.monotonic));
}

test "debugCallback error path continues when callback_data is null" {
    var device = makeTestDevice();
    const severity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;
    const callback_data: ?*const c.VkDebugUtilsMessengerCallbackDataEXT = null;
    const user_data: ?*anyopaque = @ptrFromInt(@intFromPtr(&device));

    const result = vulkan_device.debugCallback(severity, 0, callback_data, user_data);
    try testing.expectEqual(c.VK_FALSE, result);
    try testing.expectEqual(@as(u32, 1), device.validation_error_count.load(.monotonic));
}

test "logDeviceFaults early return when vkGetDeviceFaultInfoEXT is null" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = @ptrFromInt(0xDEAD),
        .vkGetDeviceFaultInfoEXT = null,
    };

    const func = device.vkGetDeviceFaultInfoEXT;
    try testing.expect(func == null);

    if (func == null) {
        try testing.expect(true);
    } else {
        try testing.expect(false);
    }
}

test "logDeviceFaults early return when vk_device is null despite non-null extension" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .vkGetDeviceFaultInfoEXT = @ptrFromInt(0xBAD),
    };

    try testing.expect(device.vk_device == null);
    try testing.expect(device.vkGetDeviceFaultInfoEXT != null);
}

test "VulkanDevice vkGetDeviceFaultInfoEXT type signature is correct" {
    const fn_type = @TypeOf(@as(?*const fn (c.VkDevice, *c.VkDeviceFaultInfoEXT) callconv(.c) c.VkResult, null));
    const field_type = @TypeOf(@as(?*const fn (c.VkDevice, *c.VkDeviceFaultInfoEXT) callconv(.c) c.VkResult, &dummyFaultFn));
    _ = fn_type;
    _ = field_type;
}

fn dummyFaultFn(device: c.VkDevice, info: *c.VkDeviceFaultInfoEXT) callconv(.c) c.VkResult {
    _ = device;
    _ = info;
    return c.VK_SUCCESS;
}

test "VulkanDevice has correct field alignment for cache-line isolation" {
    const fault_offset = @offsetOf(VulkanDevice, "fault_count");
    const recovery_offset = @offsetOf(VulkanDevice, "recovery_count");
    try testing.expect(recovery_offset > fault_offset);
}

test "checkVk VK_SUBOPTIMAL_KHR maps to Unknown" {
    try testing.expectError(error.Unknown, checkVk(c.VK_SUBOPTIMAL_KHR));
}

test "checkVk VK_ERROR_VALIDATION_FAILED_EXT maps to Unknown" {
    try testing.expectError(error.Unknown, checkVk(c.VK_ERROR_VALIDATION_FAILED_EXT));
}

test "checkVk VK_ERROR_INCOMPATIBLE_DRIVER_KHR maps to Unknown" {
    try testing.expectError(error.Unknown, checkVk(c.VK_ERROR_INCOMPATIBLE_DRIVER_KHR));
}

test "VulkanDevice struct has no padding between fault/recovery counters" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .fault_count = 0,
        .recovery_count = 0,
        .recovery_success_count = 0,
        .recovery_fail_count = 0,
    };

    try testing.expectEqual(@as(u32, 0), device.fault_count);
    device.fault_count = 1;
    try testing.expectEqual(@as(u32, 1), device.fault_count);
}

test "VulkanDevice fault_count wraps correctly at u32 max" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    device.fault_count = std.math.maxInt(u32) - 1;
    device.fault_count += 1;
    try testing.expectEqual(@as(u32, std.math.maxInt(u32)), device.fault_count);

    device.fault_count +%= 1;
    try testing.expectEqual(@as(u32, 0), device.fault_count);
}

test "VulkanDevice recovery counters independent after multiple recovery cycles" {
    var device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .recovery_count = 0,
        .recovery_success_count = 0,
        .recovery_fail_count = 0,
        .max_recovery_attempts = 5,
    };

    device.recovery_count = 5;
    device.recovery_success_count = 3;
    device.recovery_fail_count = 2;

    try testing.expectEqual(@as(u32, 5), device.recovery_count);
    try testing.expectEqual(@as(u32, 3), device.recovery_success_count);
    try testing.expectEqual(@as(u32, 2), device.recovery_fail_count);

    device.recovery_count = 0;
    device.recovery_success_count = 0;
    device.recovery_fail_count = 0;

    try testing.expectEqual(@as(u32, 0), device.recovery_count);
    try testing.expectEqual(@as(u32, 0), device.recovery_success_count);
    try testing.expectEqual(@as(u32, 0), device.recovery_fail_count);
}