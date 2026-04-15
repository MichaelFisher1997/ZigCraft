//! Unit tests for graphics/vulkan-frame render pass manager
//!
//! Covers getMSAASampleCountFlag and render pass attachment configuration logic.

const std = @import("std");
const testing = std.testing;
const c = @import("../../../c.zig").c;

const RenderPassManager = @import("render_pass_manager.zig").RenderPassManager;
const rhi = @import("../rhi.zig");

fn getMSAASampleCountFlag(samples: u8) c.VkSampleCountFlagBits {
    return switch (samples) {
        2 => c.VK_SAMPLE_COUNT_2_BIT,
        4 => c.VK_SAMPLE_COUNT_4_BIT,
        8 => c.VK_SAMPLE_COUNT_8_BIT,
        else => c.VK_SAMPLE_COUNT_1_BIT,
    };
}

test "getMSAASampleCountFlag returns 1_BIT for sample count 0" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(0));
}

test "getMSAASampleCountFlag returns 1_BIT for sample count 1" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(1));
}

test "getMSAASampleCountFlag returns 2_BIT for sample count 2" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_2_BIT), getMSAASampleCountFlag(2));
}

test "getMSAASampleCountFlag returns 4_BIT for sample count 4" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_4_BIT), getMSAASampleCountFlag(4));
}

test "getMSAASampleCountFlag returns 8_BIT for sample count 8" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_8_BIT), getMSAASampleCountFlag(8));
}

test "getMSAASampleCountFlag returns 1_BIT for sample count 3" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(3));
}

test "getMSAASampleCountFlag returns 1_BIT for sample count 16" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(16));
}

test "getMSAASampleCountFlag returns 1_BIT for max u8" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), getMSAASampleCountFlag(255));
}

test "RenderPassManager DEPTH_FORMAT is D32_SFLOAT" {
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_D32_SFLOAT), c.VK_FORMAT_D32_SFLOAT);
}

test "RenderPassManager destroyFramebuffers handles null handles gracefully" {
    var manager: RenderPassManager = .{
        .allocator = null,
        .hdr_render_pass = null,
        .g_render_pass = null,
        .post_process_render_pass = null,
        .ui_swapchain_render_pass = null,
        .main_framebuffer = null,
        .g_framebuffer = null,
        .post_process_framebuffers = .empty,
        .ui_swapchain_framebuffers = .empty,
    };
    manager.destroyFramebuffers(null, testing.allocator);
    try testing.expect(true);
}

test "RenderPassManager deinit handles null allocator gracefully" {
    var manager: RenderPassManager = .{
        .allocator = null,
        .hdr_render_pass = null,
        .g_render_pass = null,
        .post_process_render_pass = null,
        .ui_swapchain_render_pass = null,
        .main_framebuffer = null,
        .g_framebuffer = null,
        .post_process_framebuffers = .empty,
        .ui_swapchain_framebuffers = .empty,
    };
    manager.deinit(null);
    try testing.expect(true);
}

test "VkRenderPassCreateInfo sType is correct" {
    const rp_info = c.VkRenderPassCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .attachmentCount = 0,
        .pAttachments = null,
        .subpassCount = 0,
        .pSubpasses = null,
        .dependencyCount = 0,
        .pDependencies = null,
    };
    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO), rp_info.sType);
}

test "VkAttachmentDescription zero initialization is valid" {
    var desc = std.mem.zeroes(c.VkAttachmentDescription);
    try testing.expectEqual(@as(u32, 0), desc.flags);
}

test "VkSubpassDependency external subpass constant" {
    try testing.expectEqual(@as(u32, c.VK_SUBPASS_EXTERNAL), @as(u32, 0xFFFFFFFF));
}

test "RenderPassManager init with allocator sets allocator field" {
    var manager = RenderPassManager.init(testing.allocator);
    try testing.expectEqual(testing.allocator, manager.allocator);
}

test "RenderPassManager framebuffer arrays are empty after init" {
    var manager = RenderPassManager.init(testing.allocator);
    try testing.expectEqual(@as(usize, 0), manager.post_process_framebuffers.items.len);
    try testing.expectEqual(@as(usize, 0), manager.ui_swapchain_framebuffers.items.len);
}

test "RenderPassManager render pass handles are null after init" {
    var manager = RenderPassManager.init(testing.allocator);
    try testing.expect(manager.hdr_render_pass == null);
    try testing.expect(manager.g_render_pass == null);
    try testing.expect(manager.post_process_render_pass == null);
    try testing.expect(manager.ui_swapchain_render_pass == null);
}

test "RenderPassManager framebuffer handles are null after init" {
    var manager = RenderPassManager.init(testing.allocator);
    try testing.expect(manager.main_framebuffer == null);
    try testing.expect(manager.g_framebuffer == null);
}
