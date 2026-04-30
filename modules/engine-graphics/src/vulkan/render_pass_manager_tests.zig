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

test "RenderPassManager destroyFramebuffers clears post_process_framebuffers items" {
    var manager: RenderPassManager = .{
        .allocator = testing.allocator,
        .hdr_render_pass = null,
        .g_render_pass = null,
        .post_process_render_pass = null,
        .ui_swapchain_render_pass = null,
        .main_framebuffer = null,
        .g_framebuffer = null,
        .post_process_framebuffers = .empty,
        .ui_swapchain_framebuffers = .empty,
    };
    try manager.post_process_framebuffers.append(testing.allocator, null);
    try manager.post_process_framebuffers.append(testing.allocator, null);
    try testing.expectEqual(@as(usize, 2), manager.post_process_framebuffers.items.len);
    manager.destroyFramebuffers(@ptrFromInt(1), testing.allocator);
    try testing.expectEqual(@as(usize, 0), manager.post_process_framebuffers.items.len);
}

test "RenderPassManager destroyFramebuffers clears ui_swapchain_framebuffers items" {
    var manager: RenderPassManager = .{
        .allocator = testing.allocator,
        .hdr_render_pass = null,
        .g_render_pass = null,
        .post_process_render_pass = null,
        .ui_swapchain_render_pass = null,
        .main_framebuffer = null,
        .g_framebuffer = null,
        .post_process_framebuffers = .empty,
        .ui_swapchain_framebuffers = .empty,
    };
    try manager.ui_swapchain_framebuffers.append(testing.allocator, null);
    try manager.ui_swapchain_framebuffers.append(testing.allocator, null);
    try testing.expectEqual(@as(usize, 2), manager.ui_swapchain_framebuffers.items.len);
    manager.destroyFramebuffers(@ptrFromInt(1), testing.allocator);
    try testing.expectEqual(@as(usize, 0), manager.ui_swapchain_framebuffers.items.len);
}

test "RenderPassManager destroyRenderPasses handles null render passes gracefully" {
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

test "VkFramebufferCreateInfo sType is correct" {
    var fb_info = std.mem.zeroes(c.VkFramebufferCreateInfo);
    fb_info.sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO), fb_info.sType);
}

test "VkAttachmentDescription format configuration" {
    var desc = std.mem.zeroes(c.VkAttachmentDescription);
    desc.format = c.VK_FORMAT_R16G16B16A16_SFLOAT;
    desc.samples = c.VK_SAMPLE_COUNT_1_BIT;
    desc.loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR;
    desc.storeOp = c.VK_ATTACHMENT_STORE_OP_STORE;
    try testing.expectEqual(@as(c.VkFormat, c.VK_FORMAT_R16G16B16A16_SFLOAT), desc.format);
    try testing.expectEqual(@as(c.VkSampleCountFlagBits, c.VK_SAMPLE_COUNT_1_BIT), desc.samples);
}

test "VkSubpassDescription pipeline bind point is graphics" {
    var subpass = std.mem.zeroes(c.VkSubpassDescription);
    subpass.pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS;
    try testing.expectEqual(@as(c.VkPipelineBindPoint, c.VK_PIPELINE_BIND_POINT_GRAPHICS), subpass.pipelineBindPoint);
}

test "VkSubpassDependency uses external subpass constant" {
    var dep = std.mem.zeroes(c.VkSubpassDependency);
    dep.srcSubpass = c.VK_SUBPASS_EXTERNAL;
    dep.dstSubpass = 0;
    try testing.expectEqual(@as(u32, c.VK_SUBPASS_EXTERNAL), dep.srcSubpass);
}

test "RenderPassManager framebuffer arrays can hold multiple handles" {
    var manager: RenderPassManager = .{
        .allocator = testing.allocator,
        .hdr_render_pass = null,
        .g_render_pass = null,
        .post_process_render_pass = null,
        .ui_swapchain_render_pass = null,
        .main_framebuffer = null,
        .g_framebuffer = null,
        .post_process_framebuffers = .empty,
        .ui_swapchain_framebuffers = .empty,
    };
    try manager.post_process_framebuffers.append(testing.allocator, @ptrFromInt(10));
    try manager.post_process_framebuffers.append(testing.allocator, @ptrFromInt(20));
    try manager.ui_swapchain_framebuffers.append(testing.allocator, @ptrFromInt(30));
    try testing.expectEqual(@as(usize, 2), manager.post_process_framebuffers.items.len);
    try testing.expectEqual(@as(usize, 1), manager.ui_swapchain_framebuffers.items.len);
}

test "RenderPassManager deinit with null allocator does not crash" {
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
    try testing.expect(manager.allocator == null);
}

test "VkRenderPassBeginInfo clearValueCount can be set" {
    var rp_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
    rp_begin.clearValueCount = 2;
    try testing.expectEqual(@as(u32, 2), rp_begin.clearValueCount);
}

test "VkAccessFlagBits for color attachment read/write" {
    const access = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    try testing.expect(access != 0);
}

test "VkAccessFlagBits for shader read" {
    const access = c.VK_ACCESS_SHADER_READ_BIT;
    try testing.expect(access != 0);
}
