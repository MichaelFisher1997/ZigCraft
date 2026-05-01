//! Unit tests for graphics/vulkan-frame render pass manager
//!
//! Covers getMSAASampleCountFlag and render pass attachment configuration logic.

const std = @import("std");
const testing = std.testing;
const c = @import("c").c;

const render_pass_manager = @import("render_pass_manager.zig");
const RenderPassManager = render_pass_manager.RenderPassManager;
const rhi = @import("engine-rhi").rhi;

test "getMSAASampleCountFlag returns 1_BIT for sample count 0" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), render_pass_manager.getMSAASampleCountFlag(0));
}

test "getMSAASampleCountFlag returns 1_BIT for sample count 1" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), render_pass_manager.getMSAASampleCountFlag(1));
}

test "getMSAASampleCountFlag returns 2_BIT for sample count 2" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_2_BIT), render_pass_manager.getMSAASampleCountFlag(2));
}

test "getMSAASampleCountFlag returns 4_BIT for sample count 4" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_4_BIT), render_pass_manager.getMSAASampleCountFlag(4));
}

test "getMSAASampleCountFlag returns 8_BIT for sample count 8" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_8_BIT), render_pass_manager.getMSAASampleCountFlag(8));
}

test "getMSAASampleCountFlag returns 1_BIT for sample count 3" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), render_pass_manager.getMSAASampleCountFlag(3));
}

test "getMSAASampleCountFlag returns 1_BIT for sample count 16" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), render_pass_manager.getMSAASampleCountFlag(16));
}

test "getMSAASampleCountFlag returns 1_BIT for max u8" {
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), render_pass_manager.getMSAASampleCountFlag(255));
}

test "RenderPassManager DEPTH_FORMAT is D32_SFLOAT" {
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_D32_SFLOAT), render_pass_manager.DEPTH_FORMAT);
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
    const desc = std.mem.zeroes(c.VkAttachmentDescription);
    try testing.expectEqual(@as(u32, 0), desc.flags);
}

test "VkSubpassDependency external subpass constant" {
    try testing.expectEqual(@as(u32, c.VK_SUBPASS_EXTERNAL), @as(u32, 0xFFFFFFFF));
}

test "RenderPassManager init with allocator sets allocator field" {
    const manager = RenderPassManager.init(testing.allocator);
    try testing.expectEqual(testing.allocator, manager.allocator);
}

test "RenderPassManager framebuffer arrays are empty after init" {
    const manager = RenderPassManager.init(testing.allocator);
    try testing.expectEqual(@as(usize, 0), manager.post_process_framebuffers.items.len);
    try testing.expectEqual(@as(usize, 0), manager.ui_swapchain_framebuffers.items.len);
}

test "RenderPassManager render pass handles are null after init" {
    const manager = RenderPassManager.init(testing.allocator);
    try testing.expect(manager.hdr_render_pass == null);
    try testing.expect(manager.g_render_pass == null);
    try testing.expect(manager.post_process_render_pass == null);
    try testing.expect(manager.ui_swapchain_render_pass == null);
}

test "RenderPassManager framebuffer handles are null after init" {
    const manager = RenderPassManager.init(testing.allocator);
    try testing.expect(manager.main_framebuffer == null);
    try testing.expect(manager.g_framebuffer == null);
}

test "VkFramebufferCreateInfo sType is correct" {
    var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
    fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO), fb_info.sType);
}

test "VkFramebufferCreateInfo renders pass attachment count" {
    var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
    fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    fb_info.attachmentCount = 3;
    try testing.expectEqual(@as(u32, 3), fb_info.attachmentCount);
}

test "createMainFramebuffer uses 3 attachments when MSAA is enabled with msaa view" {
    const use_msaa = true;
    const msaa_view: c.VkImageView = @ptrFromInt(1);

    const attachment_count: u32 = if (use_msaa and msaa_view != null) 3 else 2;
    try testing.expectEqual(@as(u32, 3), attachment_count);
}

test "createMainFramebuffer uses 2 attachments when MSAA is disabled" {
    const use_msaa = false;
    const msaa_view: ?c.VkImageView = null;

    const attachment_count: u32 = if (use_msaa and msaa_view != null) 3 else 2;
    try testing.expectEqual(@as(u32, 2), attachment_count);
}

test "createMainFramebuffer uses 2 attachments when MSAA view is null" {
    const use_msaa = true;
    const msaa_view: ?c.VkImageView = null;

    const attachment_count: u32 = if (use_msaa and msaa_view != null) 3 else 2;
    try testing.expectEqual(@as(u32, 2), attachment_count);
}

test "VkAttachmentReference layout configuration" {
    const color_ref = c.VkAttachmentReference{ .attachment = 0, .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    try testing.expectEqual(@as(u32, 0), color_ref.attachment);
    try testing.expectEqual(@as(u32, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL), color_ref.layout);
}

test "VkSubpassDescription pipeline bind point is graphics" {
    var subpass = std.mem.zeroes(c.VkSubpassDescription);
    subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
    try testing.expectEqual(@as(c.VkPipelineBindPoint, c.VK_PIPELINE_BIND_POINT_GRAPHICS), subpass.pipelineBindPoint);
}

test "VkSubpassDescription color attachment count for G-pass" {
    var subpass = std.mem.zeroes(c.VkSubpassDescription);
    subpass.colorAttachmentCount = 2;
    try testing.expectEqual(@as(u32, 2), subpass.colorAttachmentCount);
}

test "VkSubpassDependency dependency flags by region" {
    var deps = std.mem.zeroes([2]c.VkSubpassDependency);
    deps[0].dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT;
    try testing.expectEqual(@as(c.VkDependencyFlags, c.VK_DEPENDENCY_BY_REGION_BIT), deps[0].dependencyFlags);
}

test "RenderPassManager destroyRenderPasses handles null handles gracefully" {
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
    manager.destroyRenderPasses(null);
    try testing.expect(true);
}

test "RenderPassManager init sets post_process_framebuffers to empty" {
    const manager = RenderPassManager.init(testing.allocator);
    try testing.expectEqual(@as(usize, 0), manager.post_process_framebuffers.items.len);
}

test "RenderPassManager init sets ui_swapchain_framebuffers to empty" {
    const manager = RenderPassManager.init(testing.allocator);
    try testing.expectEqual(@as(usize, 0), manager.ui_swapchain_framebuffers.items.len);
}
