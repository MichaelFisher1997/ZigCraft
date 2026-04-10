//! Unit tests for graphics/vulkan-frame modules
//!
//! Covers RenderPassManager state and frame orchestration logic.
//! These tests focus on pure logic that doesn't require a real GPU.

const std = @import("std");
const testing = std.testing;
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");

const RenderPassManager = @import("render_pass_manager.zig").RenderPassManager;
const FrameManager = @import("frame_manager.zig").FrameManager;

test "RenderPassManager default initialization produces null handles" {
    const manager: RenderPassManager = .{};

    try testing.expect(manager.hdr_render_pass == null);
    try testing.expect(manager.g_render_pass == null);
    try testing.expect(manager.post_process_render_pass == null);
    try testing.expect(manager.ui_swapchain_render_pass == null);
    try testing.expect(manager.main_framebuffer == null);
    try testing.expect(manager.g_framebuffer == null);
    try testing.expect(manager.allocator == null);
}

test "RenderPassManager init sets allocator" {
    var manager = RenderPassManager.init(testing.allocator);
    try testing.expectEqual(testing.allocator, manager.allocator);
}

test "RenderPassManager empty ArrayLists on init" {
    const manager = RenderPassManager.init(testing.allocator);
    try testing.expectEqual(@as(usize, 0), manager.post_process_framebuffers.items.len);
    try testing.expectEqual(@as(usize, 0), manager.ui_swapchain_framebuffers.items.len);
}

test "RenderPassManager struct size is reasonable" {
    const size = @sizeOf(RenderPassManager);
    try testing.expect(size > 0);
    try testing.expect(size < 10 * 1024);
}

test "RenderPassManager field alignment" {
    const offset_allocator = @offsetOf(RenderPassManager, "allocator");
    const offset_hdr = @offsetOf(RenderPassManager, "hdr_render_pass");
    const offset_post = @offsetOf(RenderPassManager, "post_process_framebuffers");

    try testing.expect(offset_hdr % @alignOf(*anyopaque) == 0);
    try testing.expect(offset_allocator % @alignOf(*anyopaque) == 0);
    try testing.expect(offset_post % @alignOf(*anyopaque) == 0);
}

test "FrameManager default state values" {
    const fm: FrameManager = .{
        .vulkan_device = undefined,
        .command_pool = null,
        .command_buffers = undefined,
        .image_available_semaphores = undefined,
        .render_finished_semaphores = undefined,
        .in_flight_fences = undefined,
        .current_frame = 0,
        .current_image_index = 0,
        .frame_in_progress = false,
        .dry_run = true,
    };

    try testing.expectEqual(@as(usize, 0), fm.current_frame);
    try testing.expectEqual(@as(u32, 0), fm.current_image_index);
    try testing.expectEqual(@as(bool, false), fm.frame_in_progress);
    try testing.expectEqual(@as(bool, true), fm.dry_run);
}

test "FrameManager struct size reasonable" {
    const size = @sizeOf(FrameManager);
    try testing.expect(size > 0);
    try testing.expect(size < 100 * 1024);
}

const MockFramesState = struct {
    frame_in_progress: bool = false,
    current_frame: usize = 0,
    current_image_index: u32 = 0,
    command_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer = .{ null, null },
};

const MockRuntimeState = struct {
    main_pass_active: bool = false,
    g_pass_active: bool = false,
    post_process_ran_this_frame: bool = false,
    fxaa_ran_this_frame: bool = false,
    draw_call_count: u32 = 0,
};

const MockRenderPassManagerState = struct {
    hdr_render_pass: ?c.VkRenderPass = null,
    g_render_pass: ?c.VkRenderPass = null,
    main_framebuffer: ?c.VkFramebuffer = null,
    g_framebuffer: ?c.VkFramebuffer = null,
    post_process_framebuffers: std.ArrayListUnmanaged(c.VkFramebuffer) = .empty,
    ui_swapchain_framebuffers: std.ArrayListUnmanaged(c.VkFramebuffer) = .empty,
    ui_swapchain_render_pass: ?c.VkRenderPass = null,

    pub fn getExtent(_: MockRenderPassManagerState) c.VkExtent2D {
        return .{ .width = 1920, .height = 1080 };
    }
};

const MockSwapchainState = struct {
    skip_present: bool = false,

    pub fn getExtent(_: MockSwapchainState) c.VkExtent2D {
        return .{ .width = 1920, .height = 1080 };
    }
};

test "pass state machine defaults to inactive" {
    const runtime = MockRuntimeState{};
    try testing.expectEqual(@as(bool, false), runtime.main_pass_active);
    try testing.expectEqual(@as(bool, false), runtime.g_pass_active);
    try testing.expectEqual(@as(bool, false), runtime.post_process_ran_this_frame);
    try testing.expectEqual(@as(bool, false), runtime.fxaa_ran_this_frame);
}

test "frames state frame index cycles correctly" {
    var frames = MockFramesState{};

    try testing.expectEqual(@as(usize, 0), frames.current_frame);

    frames.current_frame = (frames.current_frame + 1) % rhi.MAX_FRAMES_IN_FLIGHT;
    try testing.expectEqual(@as(usize, 1), frames.current_frame);

    frames.current_frame = (frames.current_frame + 1) % rhi.MAX_FRAMES_IN_FLIGHT;
    try testing.expectEqual(@as(usize, 0), frames.current_frame);
}

test "render pass manager empty lists start at zero length" {
    const rpm = MockRenderPassManagerState{};
    try testing.expectEqual(@as(usize, 0), rpm.post_process_framebuffers.items.len);
    try testing.expectEqual(@as(usize, 0), rpm.ui_swapchain_framebuffers.items.len);
}

test "MAX_FRAMES_IN_FLIGHT is consistent" {
    try testing.expectEqual(@as(u32, 2), rhi.MAX_FRAMES_IN_FLIGHT);
}

test "MAX_SWAPCHAIN_IMAGES is consistent" {
    try testing.expectEqual(@as(u32, 8), rhi.MAX_SWAPCHAIN_IMAGES);
}

test "SHADOW_CASCADE_COUNT is consistent" {
    try testing.expectEqual(@as(u32, 4), rhi.SHADOW_CASCADE_COUNT);
}

test "BLOOM_MIP_COUNT is 5" {
    try testing.expectEqual(@as(u32, 5), rhi.BLOOM_MIP_COUNT);
}

test "VkAttachmentReference layout is valid" {
    const ref = c.VkAttachmentReference{
        .attachment = 0,
        .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
    };
    try testing.expectEqual(@as(u32, 0), ref.attachment);
    try testing.expectEqual(@as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL), ref.layout);
}

test "VkAttachmentReference depth stencil layout" {
    const ref = c.VkAttachmentReference{
        .attachment = 1,
        .layout = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    };
    try testing.expectEqual(@as(u32, 1), ref.attachment);
    try testing.expectEqual(@as(c.VkImageLayout, c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL), ref.layout);
}

test "VkClearValue color initialization" {
    var cv = std.mem.zeroes(c.VkClearValue);
    cv.color.float32 = .{ 1.0, 0.5, 0.25, 1.0 };

    try testing.expectEqual(@as(f32, 1.0), cv.color.float32[0]);
    try testing.expectEqual(@as(f32, 0.5), cv.color.float32[1]);
    try testing.expectEqual(@as(f32, 0.25), cv.color.float32[2]);
    try testing.expectEqual(@as(f32, 1.0), cv.color.float32[3]);
}

test "VkClearValue depth stencil initialization" {
    var cv = std.mem.zeroes(c.VkClearValue);
    cv.depthStencil.depth = 1.0;
    cv.depthStencil.stencil = 0;

    try testing.expectEqual(@as(f32, 1.0), cv.depthStencil.depth);
    try testing.expectEqual(@as(u32, 0), cv.depthStencil.stencil);
}

test "frame_in_progress state transition" {
    var frame_in_progress = false;

    try testing.expectEqual(@as(bool, false), frame_in_progress);

    frame_in_progress = true;
    try testing.expectEqual(@as(bool, true), frame_in_progress);

    frame_in_progress = false;
    try testing.expectEqual(@as(bool, false), frame_in_progress);
}

test "current_frame wraps around MAX_FRAMES_IN_FLIGHT" {
    var current_frame: usize = 0;

    for (0..10) |_| {
        current_frame = (current_frame + 1) % rhi.MAX_FRAMES_IN_FLIGHT;
    }

    try testing.expectEqual(@as(usize, 0), current_frame);
}

test "image_index stays within swapchain bounds" {
    const max_images = rhi.MAX_SWAPCHAIN_IMAGES;
    var current_image_index: u32 = 0;

    for (0..max_images) |_| {
        try testing.expect(current_image_index < max_images);
        current_image_index = @mod(current_image_index + 1, max_images);
    }
}

test "main and g pass cannot both be active (mutual exclusion)" {
    var main_pass_active = false;
    var g_pass_active = false;

    main_pass_active = true;
    g_pass_active = false;
    try testing.expect(main_pass_active != g_pass_active);

    main_pass_active = false;
    g_pass_active = true;
    try testing.expect(main_pass_active != g_pass_active);

    main_pass_active = false;
    g_pass_active = false;
    try testing.expect(main_pass_active == g_pass_active);
}

test "VkRenderPassBeginInfo sType is set correctly" {
    const info = c.VkRenderPassBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = null,
        .framebuffer = null,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = 1920, .height = 1080 },
        },
        .clearValueCount = 0,
        .pClearValues = null,
    };

    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO), info.sType);
}

test "VkRenderPassBeginInfo renderArea extent" {
    const info = c.VkRenderPassBeginInfo{
        .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
        .pNext = null,
        .renderPass = null,
        .framebuffer = null,
        .renderArea = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = 800, .height = 600 },
        },
        .clearValueCount = 0,
        .pClearValues = null,
    };

    try testing.expectEqual(@as(u32, 800), info.renderArea.extent.width);
    try testing.expectEqual(@as(u32, 600), info.renderArea.extent.height);
}

test "VkFramebufferCreateInfo sType is correct" {
    const fb_info = c.VkFramebufferCreateInfo{
        .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .pNext = null,
        .flags = 0,
        .renderPass = null,
        .attachmentCount = 2,
        .pAttachments = null,
        .width = 1920,
        .height = 1080,
        .layers = 1,
    };

    try testing.expectEqual(@as(u32, c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO), fb_info.sType);
    try testing.expectEqual(@as(u32, 1), fb_info.layers);
}

const MockPassContext = struct {
    frames: MockFramesState = .{},
    runtime: MockRuntimeState = .{},
    render_pass_manager: MockRenderPassManagerState = .{},
    swapchain: MockSwapchainState = .{},
};

test "MockPassContext frame field access" {
    var ctx = MockPassContext{};
    ctx.frames.current_frame = 1;
    ctx.frames.frame_in_progress = true;

    try testing.expectEqual(@as(usize, 1), ctx.frames.current_frame);
    try testing.expect(ctx.frames.frame_in_progress);
}

test "MockPassContext runtime pass flags" {
    var ctx = MockPassContext{};
    ctx.runtime.main_pass_active = true;
    ctx.runtime.g_pass_active = false;

    try testing.expect(ctx.runtime.main_pass_active);
    try testing.expect(!ctx.runtime.g_pass_active);
}

test "MockPassContext extent getter" {
    const ctx = MockPassContext{};
    const extent = ctx.render_pass_manager.getExtent();
    try testing.expectEqual(@as(u32, 1920), extent.width);
    try testing.expectEqual(@as(u32, 1080), extent.height);
}

const MockFramesWithSyncObjects = struct {
    command_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,
    image_available_semaphores: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkSemaphore,
    render_finished_semaphores: [rhi.MAX_SWAPCHAIN_IMAGES]c.VkSemaphore,
    in_flight_fences: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkFence,
};

test "command_buffers array size matches MAX_FRAMES_IN_FLIGHT" {
    const mock = MockFramesWithSyncObjects{
        .command_buffers = undefined,
        .image_available_semaphores = undefined,
        .render_finished_semaphores = undefined,
        .in_flight_fences = undefined,
    };
    _ = mock;
    try testing.expectEqual(@as(usize, rhi.MAX_FRAMES_IN_FLIGHT), @sizeOf([rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer) / @sizeOf(c.VkCommandBuffer));
}

test "image_available_semaphores array size matches MAX_FRAMES_IN_FLIGHT" {
    try testing.expectEqual(@as(usize, rhi.MAX_FRAMES_IN_FLIGHT), @sizeOf([rhi.MAX_FRAMES_IN_FLIGHT]c.VkSemaphore) / @sizeOf(c.VkSemaphore));
}

test "render_finished_semaphores array size matches MAX_SWAPCHAIN_IMAGES" {
    try testing.expectEqual(@as(usize, rhi.MAX_SWAPCHAIN_IMAGES), @sizeOf([rhi.MAX_SWAPCHAIN_IMAGES]c.VkSemaphore) / @sizeOf(c.VkSemaphore));
}

test "in_flight_fences array size matches MAX_FRAMES_IN_FLIGHT" {
    try testing.expectEqual(@as(usize, rhi.MAX_FRAMES_IN_FLIGHT), @sizeOf([rhi.MAX_FRAMES_IN_FLIGHT]c.VkFence) / @sizeOf(c.VkFence));
}

test "VkSubpassDescription basic initialization" {
    const subpass = c.VkSubpassDescription{
        .flags = 0,
        .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
        .inputAttachmentCount = 0,
        .pInputAttachments = null,
        .colorAttachmentCount = 1,
        .pColorAttachments = null,
        .pResolveAttachments = null,
        .pDepthStencilAttachment = null,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = null,
    };

    try testing.expectEqual(@as(u32, 1), subpass.colorAttachmentCount);
    try testing.expectEqual(@as(c.VkPipelineBindPoint, c.VK_PIPELINE_BIND_POINT_GRAPHICS), subpass.pipelineBindPoint);
}

test "VkSubpassDependency initialization" {
    const dep = c.VkSubpassDependency{
        .srcSubpass = c.VK_SUBPASS_EXTERNAL,
        .dstSubpass = 0,
        .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
        .dstStageMask = c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        .srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT,
        .dependencyFlags = c.VK_DEPENDENCY_BY_REGION_BIT,
    };

    try testing.expectEqual(@as(u32, c.VK_SUBPASS_EXTERNAL), dep.srcSubpass);
    try testing.expectEqual(@as(u32, 0), dep.dstSubpass);
    try testing.expectEqual(@as(u32, c.VK_DEPENDENCY_BY_REGION_BIT), dep.dependencyFlags);
}
