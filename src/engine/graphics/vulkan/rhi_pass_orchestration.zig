const std = @import("std");
const c = @import("../../../c.zig").c;
const post_process_system_pkg = @import("post_process_system.zig");
const PostProcessPushConstants = post_process_system_pkg.PostProcessPushConstants;
const fxaa_system_pkg = @import("fxaa_system.zig");
const FXAAPushConstants = fxaa_system_pkg.FXAAPushConstants;
const setup = @import("rhi_resource_setup.zig");

pub fn beginGPassInternal(ctx: anytype) void {
    if (!ctx.frames.frame_in_progress or ctx.runtime.g_pass_active) return;

    if (ctx.render_pass_manager.g_render_pass == null or ctx.render_pass_manager.g_framebuffer == null or ctx.pipeline_manager.g_pipeline == null) {
        std.log.warn("beginGPass: skipping - resources null (rp={}, fb={}, pipeline={})", .{ ctx.render_pass_manager.g_render_pass != null, ctx.render_pass_manager.g_framebuffer != null, ctx.pipeline_manager.g_pipeline != null });
        return;
    }

    if (ctx.gpass.g_pass_extent.width != ctx.swapchain.getExtent().width or ctx.gpass.g_pass_extent.height != ctx.swapchain.getExtent().height) {
        std.log.warn("beginGPass: size mismatch! G-pass={}x{}, swapchain={}x{} - recreating", .{ ctx.gpass.g_pass_extent.width, ctx.gpass.g_pass_extent.height, ctx.swapchain.getExtent().width, ctx.swapchain.getExtent().height });
        _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);
        setup.createGPassResources(ctx) catch |err| {
            std.log.err("Failed to recreate G-pass resources: {}", .{err});
            return;
        };
        setup.createSSAOResources(ctx) catch |err| {
            std.log.err("Failed to recreate SSAO resources: {}", .{err});
            return;
        };
    }

    ensureNoRenderPassActiveInternal(ctx);

    ctx.runtime.g_pass_active = true;
    const current_frame = ctx.frames.current_frame;
    const command_buffer = ctx.frames.command_buffers[current_frame];

    if (command_buffer == null or ctx.pipeline_manager.pipeline_layout == null) {
        std.log.err("beginGPass: invalid command state (cb={}, layout={})", .{ command_buffer != null, ctx.pipeline_manager.pipeline_layout != null });
        return;
    }

    var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
    render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    render_pass_info.renderPass = ctx.render_pass_manager.g_render_pass;
    render_pass_info.framebuffer = ctx.render_pass_manager.g_framebuffer;
    render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
    render_pass_info.renderArea.extent = ctx.swapchain.getExtent();

    var clear_values: [3]c.VkClearValue = undefined;
    clear_values[0] = std.mem.zeroes(c.VkClearValue);
    clear_values[0].color = .{ .float32 = .{ 0, 0, 0, 1 } };
    clear_values[1] = std.mem.zeroes(c.VkClearValue);
    clear_values[1].color = .{ .float32 = .{ 0, 0, 0, 1 } };
    clear_values[2] = std.mem.zeroes(c.VkClearValue);
    clear_values[2].depthStencil = .{ .depth = 0.0, .stencil = 0 };
    render_pass_info.clearValueCount = 3;
    render_pass_info.pClearValues = &clear_values[0];

    c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.g_pipeline);

    const viewport = c.VkViewport{ .x = 0, .y = 0, .width = @floatFromInt(ctx.swapchain.getExtent().width), .height = @floatFromInt(ctx.swapchain.getExtent().height), .minDepth = 0, .maxDepth = 1 };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = ctx.swapchain.getExtent() };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    const ds = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
    if (ds == null) std.log.err("CRITICAL: descriptor_set is NULL for frame {}", .{ctx.frames.current_frame});

    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.pipeline_layout, 0, 1, &ds, 0, null);
}

pub fn endGPassInternal(ctx: anytype) void {
    if (!ctx.runtime.g_pass_active) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.runtime.g_pass_active = false;
}

pub fn beginFXAAPassInternal(ctx: anytype) void {
    if (!ctx.fxaa.enabled) return;
    if (ctx.fxaa.pass_active) return;
    if (ctx.fxaa.pipeline == null) return;
    if (ctx.fxaa.render_pass == null) return;

    const image_index = ctx.frames.current_image_index;
    if (image_index >= ctx.fxaa.framebuffers.items.len) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    const extent = ctx.swapchain.getExtent();

    var clear_value = std.mem.zeroes(c.VkClearValue);
    clear_value.color.float32 = .{ 0.0, 0.0, 0.0, 1.0 };

    var rp_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
    rp_begin.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rp_begin.renderPass = ctx.fxaa.render_pass;
    rp_begin.framebuffer = ctx.fxaa.framebuffers.items[image_index];
    rp_begin.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    rp_begin.clearValueCount = 1;
    rp_begin.pClearValues = &clear_value;

    c.vkCmdBeginRenderPass(command_buffer, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);

    const viewport = c.VkViewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.fxaa.pipeline);

    const frame = ctx.frames.current_frame;
    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.fxaa.pipeline_layout, 0, 1, &ctx.fxaa.descriptor_sets[frame], 0, null);

    const push = FXAAPushConstants{
        .texel_size = .{ 1.0 / @as(f32, @floatFromInt(extent.width)), 1.0 / @as(f32, @floatFromInt(extent.height)) },
        .fxaa_span_max = 8.0,
        .fxaa_reduce_mul = 1.0 / 8.0,
    };
    c.vkCmdPushConstants(command_buffer, ctx.fxaa.pipeline_layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(FXAAPushConstants), &push);

    c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
    ctx.runtime.draw_call_count += 1;

    ctx.runtime.fxaa_ran_this_frame = true;
    ctx.fxaa.pass_active = true;
}

pub fn beginFXAAPassForUI(ctx: anytype) void {
    if (!ctx.frames.frame_in_progress) return;
    if (ctx.fxaa.pass_active) return;
    if (ctx.render_pass_manager.ui_swapchain_render_pass == null) return;
    if (ctx.render_pass_manager.ui_swapchain_framebuffers.items.len == 0) return;

    const image_index = ctx.frames.current_image_index;
    if (image_index >= ctx.render_pass_manager.ui_swapchain_framebuffers.items.len) return;

    ensureNoRenderPassActiveInternal(ctx);

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    const extent = ctx.swapchain.getExtent();

    var clear_value = std.mem.zeroes(c.VkClearValue);
    clear_value.color.float32 = .{ 0.0, 0.0, 0.0, 1.0 };

    var rp_begin = std.mem.zeroes(c.VkRenderPassBeginInfo);
    rp_begin.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rp_begin.renderPass = ctx.render_pass_manager.ui_swapchain_render_pass.?;
    rp_begin.framebuffer = ctx.render_pass_manager.ui_swapchain_framebuffers.items[image_index];
    rp_begin.renderArea = .{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    rp_begin.clearValueCount = 1;
    rp_begin.pClearValues = &clear_value;

    c.vkCmdBeginRenderPass(command_buffer, &rp_begin, c.VK_SUBPASS_CONTENTS_INLINE);

    const viewport = c.VkViewport{
        .x = 0,
        .y = 0,
        .width = @floatFromInt(extent.width),
        .height = @floatFromInt(extent.height),
        .minDepth = 0.0,
        .maxDepth = 1.0,
    };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = extent };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);

    ctx.fxaa.pass_active = true;
}

pub fn endFXAAPassInternal(ctx: anytype) void {
    if (!ctx.fxaa.pass_active) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);

    ctx.fxaa.pass_active = false;
}

pub fn beginMainPassInternal(ctx: anytype) void {
    if (!ctx.frames.frame_in_progress) return;
    if (ctx.swapchain.getExtent().width == 0 or ctx.swapchain.getExtent().height == 0) return;

    if (ctx.render_pass_manager.hdr_render_pass == null) {
        ctx.render_pass_manager.createMainRenderPass(ctx.vulkan_device.vk_device, ctx.swapchain.getExtent(), 1) catch |err| {
            std.log.err("beginMainPass: failed to recreate render pass: {}", .{err});
            return;
        };
    }
    if (ctx.render_pass_manager.main_framebuffer == null) {
        setup.createMainFramebuffers(ctx) catch |err| {
            std.log.err("beginMainPass: failed to recreate framebuffer: {}", .{err});
            return;
        };
    }
    if (ctx.render_pass_manager.main_framebuffer == null) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (!ctx.runtime.main_pass_active) {
        ensureNoRenderPassActiveInternal(ctx);

        if (ctx.hdr.hdr_image != null) {
            var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
            barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
            barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
            barrier.image = ctx.hdr.hdr_image;
            barrier.subresourceRange = .{ .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT, .baseMipLevel = 0, .levelCount = 1, .baseArrayLayer = 0, .layerCount = 1 };
            barrier.srcAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

            c.vkCmdPipelineBarrier(command_buffer, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, null, 0, null, 1, &barrier);
        }

        ctx.draw.terrain_pipeline_bound = false;

        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
        render_pass_info.renderPass = ctx.render_pass_manager.hdr_render_pass;
        render_pass_info.framebuffer = ctx.render_pass_manager.main_framebuffer;
        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = ctx.swapchain.getExtent();

        var clear_values: [2]c.VkClearValue = undefined;
        clear_values[0] = std.mem.zeroes(c.VkClearValue);
        clear_values[0].color = .{ .float32 = ctx.runtime.clear_color };
        clear_values[1] = std.mem.zeroes(c.VkClearValue);
        clear_values[1].depthStencil = .{ .depth = 0.0, .stencil = 0 };
        render_pass_info.clearValueCount = 2;
        render_pass_info.pClearValues = &clear_values[0];

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        ctx.runtime.main_pass_active = true;
        ctx.draw.lod_mode = false;
    }

    var viewport = std.mem.zeroes(c.VkViewport);
    viewport.x = 0.0;
    viewport.y = 0.0;
    viewport.width = @floatFromInt(ctx.swapchain.getExtent().width);
    viewport.height = @floatFromInt(ctx.swapchain.getExtent().height);
    viewport.minDepth = 0.0;
    viewport.maxDepth = 1.0;
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

    var scissor = std.mem.zeroes(c.VkRect2D);
    scissor.offset = .{ .x = 0, .y = 0 };
    scissor.extent = ctx.swapchain.getExtent();
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
}

pub fn endMainPassInternal(ctx: anytype) void {
    if (!ctx.runtime.main_pass_active) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.runtime.main_pass_active = false;
}

pub fn beginPostProcessPassInternal(ctx: anytype) void {
    if (!ctx.frames.frame_in_progress) return;
    if (ctx.render_pass_manager.post_process_framebuffers.items.len == 0) return;
    if (ctx.frames.current_image_index >= ctx.render_pass_manager.post_process_framebuffers.items.len) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (!ctx.post_process.pass_active) {
        ensureNoRenderPassActiveInternal(ctx);

        const use_fxaa_output = ctx.fxaa.enabled and ctx.fxaa.post_process_to_fxaa_render_pass != null and ctx.fxaa.post_process_to_fxaa_framebuffer != null;

        var render_pass_info = std.mem.zeroes(c.VkRenderPassBeginInfo);
        render_pass_info.sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;

        if (use_fxaa_output) {
            render_pass_info.renderPass = ctx.fxaa.post_process_to_fxaa_render_pass;
            render_pass_info.framebuffer = ctx.fxaa.post_process_to_fxaa_framebuffer;
        } else {
            render_pass_info.renderPass = ctx.render_pass_manager.post_process_render_pass;
            render_pass_info.framebuffer = ctx.render_pass_manager.post_process_framebuffers.items[ctx.frames.current_image_index];
        }

        render_pass_info.renderArea.offset = .{ .x = 0, .y = 0 };
        render_pass_info.renderArea.extent = ctx.swapchain.getExtent();

        var clear_value = std.mem.zeroes(c.VkClearValue);
        clear_value.color = .{ .float32 = .{ 0, 0, 0, 1 } };
        render_pass_info.clearValueCount = 1;
        render_pass_info.pClearValues = &clear_value;

        c.vkCmdBeginRenderPass(command_buffer, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);
        ctx.post_process.pass_active = true;
        ctx.runtime.post_process_ran_this_frame = true;

        if (ctx.post_process.pipeline == null) {
            std.log.err("Post-process pipeline is null, skipping draw", .{});
            return;
        }

        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.post_process.pipeline);

        var source_view = ctx.hdr.hdr_view;
        var source_sampler = ctx.post_process.sampler;
        if (ctx.taa.ran_this_frame and ctx.taa.output_texture != 0) {
            if (ctx.resources.textures.get(ctx.taa.output_texture)) |tex| {
                source_view = tex.view;
                source_sampler = tex.sampler;
            }
        }
        ctx.post_process.updateSourceDescriptors(ctx.vulkan_device.vk_device, source_view, source_sampler);

        const pp_ds = ctx.post_process.descriptor_sets[ctx.frames.current_frame];
        if (pp_ds == null) {
            std.log.err("Post-process descriptor set is null for frame {}", .{ctx.frames.current_frame});
            return;
        }
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.post_process.pipeline_layout, 0, 1, &pp_ds, 0, null);

        const push = PostProcessPushConstants{
            .bloom_enabled = if (ctx.bloom.enabled) 1.0 else 0.0,
            .bloom_intensity = ctx.bloom.intensity,
            .vignette_intensity = if (ctx.post_process_state.vignette_enabled) ctx.post_process_state.vignette_intensity else 0.0,
            .film_grain_intensity = if (ctx.post_process_state.film_grain_enabled) ctx.post_process_state.film_grain_intensity else 0.0,
            .color_grading_enabled = if (ctx.post_process_state.color_grading_enabled) 1.0 else 0.0,
            .color_grading_intensity = ctx.post_process_state.color_grading_intensity,
        };
        c.vkCmdPushConstants(command_buffer, ctx.post_process.pipeline_layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(PostProcessPushConstants), &push);

        var viewport = std.mem.zeroes(c.VkViewport);
        viewport.x = 0.0;
        viewport.y = 0.0;
        viewport.width = @floatFromInt(ctx.swapchain.getExtent().width);
        viewport.height = @floatFromInt(ctx.swapchain.getExtent().height);
        viewport.minDepth = 0.0;
        viewport.maxDepth = 1.0;
        c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);

        var scissor = std.mem.zeroes(c.VkRect2D);
        scissor.offset = .{ .x = 0, .y = 0 };
        scissor.extent = ctx.swapchain.getExtent();
        c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
    }
}

pub fn endPostProcessPassInternal(ctx: anytype) void {
    if (!ctx.post_process.pass_active) return;
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdEndRenderPass(command_buffer);
    ctx.post_process.pass_active = false;
}

pub fn ensureNoRenderPassActiveInternal(ctx: anytype) void {
    if (ctx.runtime.main_pass_active) endMainPassInternal(ctx);
    if (ctx.shadow_system.pass_active) {
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
        ctx.shadow_system.endPass(command_buffer);
    }
    if (ctx.runtime.g_pass_active) endGPassInternal(ctx);
    if (ctx.post_process.pass_active) endPostProcessPassInternal(ctx);
}

pub fn endFrame(ctx: anytype) void {
    if (!ctx.frames.frame_in_progress) return;

    if (ctx.runtime.main_pass_active) endMainPassInternal(ctx);
    if (ctx.shadow_system.pass_active) {
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
        ctx.shadow_system.endPass(command_buffer);
    }

    if (!ctx.runtime.post_process_ran_this_frame and ctx.render_pass_manager.post_process_framebuffers.items.len > 0 and ctx.frames.current_image_index < ctx.render_pass_manager.post_process_framebuffers.items.len) {
        beginPostProcessPassInternal(ctx);
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
        c.vkCmdDraw(command_buffer, 3, 1, 0, 0);
        ctx.runtime.draw_call_count += 1;
    }
    if (ctx.post_process.pass_active) endPostProcessPassInternal(ctx);

    if (ctx.fxaa.enabled and ctx.runtime.post_process_ran_this_frame and !ctx.runtime.fxaa_ran_this_frame) {
        beginFXAAPassInternal(ctx);
    }
    if (ctx.fxaa.pass_active) endFXAAPassInternal(ctx);

    const transfer_cb = ctx.resources.getTransferCommandBuffer();

    ctx.frames.endFrame(&ctx.swapchain, transfer_cb) catch |err| {
        std.log.err("endFrame failed: {}", .{err});
    };

    if (transfer_cb != null) {
        ctx.resources.resetTransferState();
    }

    ctx.runtime.frame_index += 1;
}
