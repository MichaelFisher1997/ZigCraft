const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const log = @import("../../core/log.zig");
const Mat4 = @import("../../math/mat4.zig").Mat4;
const build_options = @import("build_options");
const pass_orchestration = @import("rhi_pass_orchestration.zig");

fn getUIPipeline(ctx: anytype, textured: bool) c.VkPipeline {
    if (ctx.ui.ui_using_swapchain) {
        return if (textured) ctx.pipeline_manager.ui_swapchain_tex_pipeline else ctx.pipeline_manager.ui_swapchain_pipeline;
    }
    return if (textured) ctx.pipeline_manager.ui_tex_pipeline else ctx.pipeline_manager.ui_pipeline;
}

fn sampledImageLayout(format: rhi.TextureFormat) c.VkImageLayout {
    return if (format == .depth)
        c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL
    else
        c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
}

fn sameTint(a: [4]f32, b: [4]f32) bool {
    return a[0] == b[0] and a[1] == b[1] and a[2] == b[2] and a[3] == b[3];
}

pub fn flushUI(ctx: anytype) void {
    if (!ctx.runtime.main_pass_active and !ctx.fxaa.pass_active) {
        return;
    }
    if (ctx.ui.ui_vertex_offset / (6 * @sizeOf(f32)) > ctx.ui.ui_flushed_vertex_count) {
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

        const total_vertices: u32 = @intCast(ctx.ui.ui_vertex_offset / (6 * @sizeOf(f32)));
        const count = total_vertices - ctx.ui.ui_flushed_vertex_count;

        c.vkCmdDraw(command_buffer, count, 1, ctx.ui.ui_flushed_vertex_count, 0);
        ctx.ui.ui_flushed_vertex_count = total_vertices;
    }
}

pub fn begin2DPass(ctx: anytype, screen_width: f32, screen_height: f32) void {
    if (!ctx.frames.frame_in_progress) {
        return;
    }

    const direct_to_present = !ctx.runtime.post_process_ran_this_frame and !ctx.runtime.main_pass_active and ctx.runtime.draw_call_count == 0;
    const use_swapchain = ctx.runtime.post_process_ran_this_frame or direct_to_present;
    const ui_pipeline = if (use_swapchain) ctx.pipeline_manager.ui_swapchain_pipeline else ctx.pipeline_manager.ui_pipeline;
    if (ui_pipeline == null) {
        return;
    }

    if (use_swapchain) {
        if (!ctx.fxaa.pass_active) {
            pass_orchestration.beginFXAAPassForUI(ctx);
        }
        if (!ctx.fxaa.pass_active) {
            return;
        }
    } else {
        if (!ctx.runtime.main_pass_active and !ctx.water_system.pass_active) pass_orchestration.beginMainPassInternal(ctx);
        if (!ctx.runtime.main_pass_active) {
            return;
        }
    }

    ctx.ui.ui_using_swapchain = use_swapchain;

    if (direct_to_present) {
        ctx.runtime.post_process_ran_this_frame = true;
        ctx.runtime.fxaa_ran_this_frame = true;
    }

    ctx.ui.ui_screen_width = screen_width;
    ctx.ui.ui_screen_height = screen_height;
    ctx.ui.ui_in_progress = true;
    ctx.ui.ui_active_textured = false;
    ctx.ui.ui_active_texture = 0;
    ctx.ui.ui_active_tint = .{ 0.0, 0.0, 0.0, 0.0 };

    const ui_vbo = ctx.ui.ui_vbos[ctx.frames.current_frame];
    if (ui_vbo.mapped_ptr) |ptr| {
        ctx.ui.ui_mapped_ptr = ptr;
    } else {
        log.log.err("UI VBO memory not mapped!", .{});
    }

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ui_pipeline);
    ctx.draw.terrain_pipeline_bound = false;

    const offset_val: c.VkDeviceSize = 0;
    c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &ui_vbo.buffer, &offset_val);

    const proj = Mat4.orthographic(0, ctx.ui.ui_screen_width, ctx.ui.ui_screen_height, 0, -1, 1);
    c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.ui_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);

    const viewport = c.VkViewport{ .x = 0, .y = 0, .width = ctx.ui.ui_screen_width, .height = ctx.ui.ui_screen_height, .minDepth = 0, .maxDepth = 1 };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
    const scissor = c.VkRect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = @intFromFloat(ctx.ui.ui_screen_width), .height = @intFromFloat(ctx.ui.ui_screen_height) } };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
}

pub fn end2DPass(ctx: anytype) void {
    if (!ctx.ui.ui_in_progress) return;

    ctx.ui.ui_mapped_ptr = null;

    flushUI(ctx);
    if (ctx.ui.ui_using_swapchain) {
        pass_orchestration.endFXAAPassInternal(ctx);
        ctx.ui.ui_using_swapchain = false;
    }
    ctx.ui.ui_in_progress = false;
}

pub fn drawRect2D(ctx: anytype, rect: rhi.Rect, color: rhi.Color) void {
    if (ctx.ui.ui_active_textured) {
        flushUI(ctx);
        ctx.ui.ui_active_textured = false;
        ctx.ui.ui_active_texture = 0;
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
        const pipeline = getUIPipeline(ctx, false);
        if (pipeline != null) {
            c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
            const proj = Mat4.orthographic(0, ctx.ui.ui_screen_width, ctx.ui.ui_screen_height, 0, -1, 1);
            c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.ui_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);
        }
    }

    const x = rect.x;
    const y = rect.y;
    const w = rect.width;
    const h = rect.height;

    const vertices = [_]f32{
        x,     y,     color.r, color.g, color.b, color.a,
        x + w, y,     color.r, color.g, color.b, color.a,
        x + w, y + h, color.r, color.g, color.b, color.a,
        x,     y,     color.r, color.g, color.b, color.a,
        x + w, y + h, color.r, color.g, color.b, color.a,
        x,     y + h, color.r, color.g, color.b, color.a,
    };

    const size = @sizeOf(@TypeOf(vertices));

    const ui_vbo = ctx.ui.ui_vbos[ctx.frames.current_frame];
    if (ctx.ui.ui_vertex_offset + size > ui_vbo.size) {
        return;
    }

    if (ctx.ui.ui_mapped_ptr) |ptr| {
        const dest = @as([*]u8, @ptrCast(ptr)) + ctx.ui.ui_vertex_offset;
        @memcpy(dest[0..size], std.mem.asBytes(&vertices));
        ctx.ui.ui_vertex_offset += size;
    }
}

pub fn bindUIPipeline(ctx: anytype, textured: bool) void {
    if (!ctx.frames.frame_in_progress) return;

    flushUI(ctx);
    ctx.ui.ui_active_textured = textured;
    if (!textured) ctx.ui.ui_active_texture = 0;

    ctx.draw.terrain_pipeline_bound = false;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

    const pipeline = getUIPipeline(ctx, textured);
    if (pipeline == null) return;
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
}

pub fn drawTexture2D(ctx: anytype, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    drawTextureRegion2D(ctx, texture, rect, .{ .u0 = 0.0, .v0 = 0.0, .u1 = 1.0, .v1 = 1.0 }, rhi.Color.white);
}

pub fn drawTextureRegion2D(ctx: anytype, texture: rhi.TextureHandle, rect: rhi.Rect, uv: rhi.UVRect, color: rhi.Color) void {
    if (!ctx.frames.frame_in_progress or !ctx.ui.ui_in_progress) return;

    const tint = [_]f32{ color.r, color.g, color.b, color.a };
    const needs_bind = !ctx.ui.ui_active_textured or ctx.ui.ui_active_texture != texture or !sameTint(ctx.ui.ui_active_tint, tint);
    if (needs_bind) {
        flushUI(ctx);
    }

    const tex_opt = ctx.resources.textures.get(texture);
    if (tex_opt == null) {
        log.log.err("drawTexture2D: Texture handle {} not found in textures map!", .{texture});
        return;
    }
    const tex = tex_opt.?;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (needs_bind) {
        const textured_pipeline = getUIPipeline(ctx, true);
        if (textured_pipeline == null) return;
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, textured_pipeline);
        ctx.draw.terrain_pipeline_bound = false;

        var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        image_info.imageLayout = sampledImageLayout(tex.format);
        image_info.imageView = tex.view;
        image_info.sampler = tex.sampler;

        const frame = ctx.frames.current_frame;
        const idx = ctx.ui.ui_tex_descriptor_next[frame];
        const pool_len = ctx.ui.ui_tex_descriptor_pool[frame].len;
        ctx.ui.ui_tex_descriptor_next[frame] = @intCast((idx + 1) % pool_len);
        const ds = ctx.ui.ui_tex_descriptor_pool[frame][idx];

        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = ds;
        write.dstBinding = 0;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.descriptorCount = 1;
        write.pImageInfo = &image_info;

        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write, 0, null);
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.ui_tex_pipeline_layout, 0, 1, &ds, 0, null);

        const proj = Mat4.orthographic(0, ctx.ui.ui_screen_width, ctx.ui.ui_screen_height, 0, -1, 1);
        c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.ui_tex_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);
        c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.ui_tex_pipeline_layout, c.VK_SHADER_STAGE_FRAGMENT_BIT, @sizeOf(Mat4), @sizeOf(@TypeOf(tint)), &tint);

        ctx.ui.ui_active_textured = true;
        ctx.ui.ui_active_texture = texture;
        ctx.ui.ui_active_tint = tint;
    }

    const x = rect.x;
    const y = rect.y;
    const w = rect.width;
    const h = rect.height;

    const vertices = [_]f32{
        x,     y,     uv.u0, uv.v0, 0.0, 0.0,
        x + w, y,     uv.u1, uv.v0, 0.0, 0.0,
        x + w, y + h, uv.u1, uv.v1, 0.0, 0.0,
        x,     y,     uv.u0, uv.v0, 0.0, 0.0,
        x + w, y + h, uv.u1, uv.v1, 0.0, 0.0,
        x,     y + h, uv.u0, uv.v1, 0.0, 0.0,
    };

    const size = @sizeOf(@TypeOf(vertices));
    if (ctx.ui.ui_mapped_ptr) |ptr| {
        const ui_vbo = ctx.ui.ui_vbos[ctx.frames.current_frame];
        if (ctx.ui.ui_vertex_offset + size <= ui_vbo.size) {
            const dest = @as([*]u8, @ptrCast(ptr)) + ctx.ui.ui_vertex_offset;
            @memcpy(dest[0..size], std.mem.asBytes(&vertices));

            ctx.ui.ui_vertex_offset += size;
        }
    }
}

pub fn drawDepthTexture(ctx: anytype, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    if (comptime !build_options.debug_shadows) return;
    if (!ctx.frames.frame_in_progress or !ctx.ui.ui_in_progress) return;

    if (ctx.debug_shadow.pipeline == null) return;

    flushUI(ctx);

    const tex_opt = ctx.resources.textures.get(texture);
    if (tex_opt == null) {
        log.log.err("drawDepthTexture: Texture handle {} not found in textures map!", .{texture});
        return;
    }
    const tex = tex_opt.?;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.debug_shadow.pipeline.?);
    ctx.draw.terrain_pipeline_bound = false;

    const width_f32 = ctx.ui.ui_screen_width;
    const height_f32 = ctx.ui.ui_screen_height;
    const proj = Mat4.orthographic(0, width_f32, height_f32, 0, -1, 1);
    c.vkCmdPushConstants(command_buffer, ctx.debug_shadow.pipeline_layout.?, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);

    var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
    image_info.imageLayout = sampledImageLayout(tex.format);
    image_info.imageView = tex.view;
    image_info.sampler = tex.sampler;

    const frame = ctx.frames.current_frame;
    const idx = ctx.debug_shadow.descriptor_next[frame];
    const pool_len = ctx.debug_shadow.descriptor_pool[frame].len;
    ctx.debug_shadow.descriptor_next[frame] = @intCast((idx + 1) % pool_len);
    const ds = ctx.debug_shadow.descriptor_pool[frame][idx] orelse return;

    var write_set = std.mem.zeroes(c.VkWriteDescriptorSet);
    write_set.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write_set.dstSet = ds;
    write_set.dstBinding = 0;
    write_set.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write_set.descriptorCount = 1;
    write_set.pImageInfo = &image_info;

    c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write_set, 0, null);
    c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.debug_shadow.pipeline_layout.?, 0, 1, &ds, 0, null);

    const debug_x = rect.x;
    const debug_y = rect.y;
    const debug_w = rect.width;
    const debug_h = rect.height;

    const debug_vertices = [_]f32{
        debug_x,           debug_y,           0.0, 0.0,
        debug_x + debug_w, debug_y,           1.0, 0.0,
        debug_x + debug_w, debug_y + debug_h, 1.0, 1.0,
        debug_x,           debug_y,           0.0, 0.0,
        debug_x + debug_w, debug_y + debug_h, 1.0, 1.0,
        debug_x,           debug_y + debug_h, 0.0, 1.0,
    };

    if (ctx.debug_shadow.vbo.mapped_ptr) |ptr| {
        @memcpy(@as([*]u8, @ptrCast(ptr))[0..@sizeOf(@TypeOf(debug_vertices))], std.mem.asBytes(&debug_vertices));

        const offset: c.VkDeviceSize = 0;
        c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &ctx.debug_shadow.vbo.buffer, &offset);
        c.vkCmdDraw(command_buffer, 6, 1, 0, 0);
    }

    const restore_pipeline = getUIPipeline(ctx, false);
    if (restore_pipeline != null) {
        c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, restore_pipeline);
        c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.ui_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT, 0, @sizeOf(Mat4), &proj.data);
    }
}
