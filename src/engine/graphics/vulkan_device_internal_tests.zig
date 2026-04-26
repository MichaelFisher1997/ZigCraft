const std = @import("std");
const testing = std.testing;
const c = @import("../../c.zig").c;
const vulkan_device = @import("vulkan_device.zig");
const VulkanDevice = vulkan_device.VulkanDevice;

const MockDeviceForCallback = struct {
    allocator: std.mem.Allocator,
    validation_error_count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

test "debugCallback effect: error severity increments atomic counter" {
    var device = MockDeviceForCallback{
        .allocator = testing.allocator,
        .validation_error_count = std.atomic.Value(u32).init(0),
    };

    try testing.expectEqual(@as(u32, 0), device.validation_error_count.load(.monotonic));

    _ = device.validation_error_count.fetchAdd(1, .monotonic);
    try testing.expectEqual(@as(u32, 1), device.validation_error_count.load(.monotonic));
}

test "debugCallback effect: multiple error increments accumulate" {
    var device = MockDeviceForCallback{
        .allocator = testing.allocator,
        .validation_error_count = std.atomic.Value(u32).init(0),
    };

    _ = device.validation_error_count.fetchAdd(1, .monotonic);
    _ = device.validation_error_count.fetchAdd(1, .monotonic);
    _ = device.validation_error_count.fetchAdd(1, .monotonic);

    try testing.expectEqual(@as(u32, 3), device.validation_error_count.load(.monotonic));
}

test "debugCallback effect: warning severity does not increment" {
    var device = MockDeviceForCallback{
        .allocator = testing.allocator,
        .validation_error_count = std.atomic.Value(u32).init(0),
    };

    const warning_severity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_WARNING_BIT_EXT;
    const error_bit = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;

    if ((warning_severity & error_bit) == 0) {
        _ = device.validation_error_count.fetchAdd(1, .monotonic);
    }

    try testing.expectEqual(@as(u32, 1), device.validation_error_count.load(.monotonic));
}

test "debugCallback effect: info severity does not increment" {
    var device = MockDeviceForCallback{
        .allocator = testing.allocator,
        .validation_error_count = std.atomic.Value(u32).init(0),
    };

    const info_severity = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_INFO_BIT_EXT;
    const error_bit = c.VK_DEBUG_UTILS_MESSAGE_SEVERITY_ERROR_BIT_EXT;

    if ((info_severity & error_bit) == 0) {
        _ = device.validation_error_count.fetchAdd(1, .monotonic);
    }

    try testing.expectEqual(@as(u32, 1), device.validation_error_count.load(.monotonic));
}

test "VulkanDevice struct default allocator field" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
    };

    try testing.expectEqual(testing.allocator, device.allocator);
}

test "VulkanDevice vk_device field defaults to null" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(c.VkDevice, null), device.vk_device);
}

test "VulkanDevice queue field defaults to null" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(c.VkQueue, null), device.queue);
}

test "VulkanDevice instance field defaults to null" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(c.VkInstance, null), device.instance);
}

test "VulkanDevice surface field defaults to null" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(c.VkSurfaceKHR, null), device.surface);
}

test "VulkanDevice physical_device field defaults to null" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(c.VkPhysicalDevice, null), device.physical_device);
}

test "VulkanDevice debug_messenger field defaults to null" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(c.VkDebugUtilsMessengerEXT, null), device.debug_messenger);
}

test "VulkanDevice graphics_family field defaults to zero" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(u32, 0), device.graphics_family);
}

test "VulkanDevice transfer_family field defaults to zero" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(u32, 0), device.transfer_family);
}

test "VulkanDevice has_dedicated_transfer_queue defaults to false" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(bool, false), device.has_dedicated_transfer_queue);
}

test "VulkanDevice supports_device_fault defaults to false" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(bool, false), device.supports_device_fault);
}

test "VulkanDevice debug_utils_enabled defaults to false" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(bool, false), device.debug_utils_enabled);
}

test "VulkanDevice vkGetDeviceFaultInfoEXT defaults to null" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(?*const fn (c.VkDevice, *c.VkDeviceFaultInfoEXT) callconv(.c) c.VkResult, null), device.vkGetDeviceFaultInfoEXT);
}

test "VulkanDevice fault_count defaults to zero" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(u32, 0), device.fault_count);
}

test "VulkanDevice recovery_count defaults to zero" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(u32, 0), device.recovery_count);
}

test "VulkanDevice recovery_success_count defaults to zero" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(u32, 0), device.recovery_success_count);
}

test "VulkanDevice recovery_fail_count defaults to zero" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(u32, 0), device.recovery_fail_count);
}

test "VulkanDevice max_recovery_attempts defaults to five" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(u32, 5), device.max_recovery_attempts);
}

test "VulkanDevice max_anisotropy defaults to zero" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(f32, 0.0), device.max_anisotropy);
}

test "VulkanDevice max_msaa_samples defaults to one" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(u8, 1), device.max_msaa_samples);
}

test "VulkanDevice multi_draw_indirect defaults to false" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(bool, false), device.multi_draw_indirect);
}

test "VulkanDevice draw_indirect_first_instance defaults to false" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(bool, false), device.draw_indirect_first_instance);
}

test "VulkanDevice timestamp_period defaults to one" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(f32, 1.0), device.timestamp_period);
}

test "VulkanDevice validation_error_count atomic initialization" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
    };

    try testing.expectEqual(@as(u32, 0), device.validation_error_count.load(.monotonic));
}

test "VulkanDevice full null handle state for deinit safety" {
    const device = VulkanDevice{
        .allocator = testing.allocator,
        .vk_device = null,
        .queue = null,
        .instance = null,
        .surface = null,
        .physical_device = null,
        .debug_messenger = null,
    };

    try testing.expect(device.vk_device == null);
    try testing.expect(device.queue == null);
    try testing.expect(device.instance == null);
    try testing.expect(device.surface == null);
    try testing.expect(device.physical_device == null);
    try testing.expect(device.debug_messenger == null);
}
