const std = @import("std");
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const log = @import("engine-core").log;
const Mat4 = @import("engine-math").Mat4;
const build_options = @import("engine_graphics_options");
const pass_orchestration = @import("rhi_pass_orchestration.zig");

const UI_PUSH_STAGES = c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT;

fn getUIPipeline(ctx: anytype, textured: bool) c.VkPipeline {
    if (ctx.ui.ui_using_swapchain) {
        return if (textured) ctx.pipeline_manager.ui_swapchain_tex_pipeline else ctx.pipeline_manager.ui_swapchain_pipeline;
    }
    return if (textured) ctx.pipeline_manager.ui_tex_pipeline else ctx.pipeline_manager.ui_pipeline;
}

fn getRmlUIPipeline(ctx: anytype, textured: bool) c.VkPipeline {
    if (ctx.ui.ui_using_swapchain) {
        return if (textured) ctx.pipeline_manager.rml_ui_swapchain_tex_pipeline else ctx.pipeline_manager.rml_ui_swapchain_pipeline;
    }
    return if (textured) ctx.pipeline_manager.rml_ui_tex_pipeline else ctx.pipeline_manager.rml_ui_pipeline;
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

fn setFullUIScissor(ctx: anytype, command_buffer: c.VkCommandBuffer) void {
    const scissor = c.VkRect2D{
        .offset = .{ .x = 0, .y = 0 },
        .extent = .{
            .width = @intFromFloat(@max(ctx.ui.ui_screen_width, 0.0)),
            .height = @intFromFloat(@max(ctx.ui.ui_screen_height, 0.0)),
        },
    };
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
}

fn bindLegacyPipeline(ctx: anytype, textured: bool) bool {
    if (ctx.ui.legacy_pipeline_bound and ctx.ui.ui_active_textured == textured) return true;

    flushUI(ctx);
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    const pipeline = getUIPipeline(ctx, textured);
    if (pipeline == null) return false;

    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    const legacy_vbo = ctx.ui.ui_vbos[ctx.frames.current_frame];
    const legacy_offset: c.VkDeviceSize = 0;
    c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &legacy_vbo.buffer, &legacy_offset);
    const proj = Mat4.orthographic(0, ctx.ui.ui_screen_width, ctx.ui.ui_screen_height, 0, -1, 1);
    const layout = if (textured) ctx.pipeline_manager.ui_tex_pipeline_layout else ctx.pipeline_manager.ui_pipeline_layout;
    c.vkCmdPushConstants(command_buffer, layout, UI_PUSH_STAGES, 0, @sizeOf(Mat4), &proj.data);
    setFullUIScissor(ctx, command_buffer);
    ctx.ui.legacy_pipeline_bound = true;
    ctx.ui.ui_active_textured = textured;
    if (!textured) ctx.ui.ui_active_texture = 0;
    ctx.draw.terrain_pipeline_bound = false;
    return true;
}

pub fn flushUI(ctx: anytype) void {
    if (!ctx.runtime.main_pass_active and !ctx.ui.ui_swapchain_pass_active) {
        return;
    }
    if (ctx.ui.ui_vertex_offset / (6 * @sizeOf(f32)) > ctx.ui.ui_flushed_vertex_count) {
        const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

        const total_vertices: u32 = @intCast(ctx.ui.ui_vertex_offset / (6 * @sizeOf(f32)));
        const count = total_vertices - ctx.ui.ui_flushed_vertex_count;

        c.vkCmdDraw(command_buffer, count, 1, ctx.ui.ui_flushed_vertex_count, 0);
        ctx.ui.ui_flushed_vertex_count = total_vertices;
        // UI rendered into the HDR main pass still requires final composition.
        // Count this submission so endFrame runs post-processing even when the
        // world preview has not produced geometry yet.
        ctx.runtime.draw_call_count += 1;
    }
}

pub fn begin2DPass(ctx: anytype, screen_width: f32, screen_height: f32) void {
    if (!ctx.frames.frame_in_progress) {
        return;
    }

    // UI overlays a completed scene. On a genuinely UI-only frame, it is also
    // allowed to establish the final target itself by explicitly clearing it.
    // Do not use FXAA pass state as a proxy: FXAA has already ended when UI is
    // layered over its output.
    const has_final_output = ctx.runtime.final_composed.isCurrentImage(ctx.frames.current_image_index);
    const ui_only_frame = !has_final_output and !ctx.runtime.main_pass_active and ctx.runtime.draw_call_count == 0;
    const use_swapchain = has_final_output or ui_only_frame;
    const ui_pipeline = if (use_swapchain) ctx.pipeline_manager.ui_swapchain_pipeline else ctx.pipeline_manager.ui_pipeline;
    if (ui_pipeline == null) {
        return;
    }

    if (use_swapchain) {
        pass_orchestration.beginUISwapchainPassInternal(ctx, ui_only_frame);
        if (!ctx.ui.ui_swapchain_pass_active) {
            return;
        }
    } else {
        if (!ctx.runtime.main_pass_active and !ctx.water_system.pass_active) pass_orchestration.beginMainPassInternal(ctx);
        if (!ctx.runtime.main_pass_active) {
            return;
        }
    }

    ctx.ui.ui_using_swapchain = use_swapchain;

    // Headless SDL paths can report a transient zero drawable size while the
    // offscreen swapchain already has a real extent. Never turn that into a
    // zero UI scissor/viewport.
    const swapchain_extent = ctx.swapchain.getExtent();
    ctx.ui.ui_screen_width = if (screen_width > 0.0) screen_width else @floatFromInt(swapchain_extent.width);
    ctx.ui.ui_screen_height = if (screen_height > 0.0) screen_height else @floatFromInt(swapchain_extent.height);
    ctx.ui.ui_in_progress = true;
    ctx.ui.ui_active_textured = false;
    ctx.ui.ui_active_texture = 0;
    ctx.ui.ui_active_tint = .{ 0.0, 0.0, 0.0, 0.0 };
    ctx.ui.legacy_pipeline_bound = true;

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
    c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.ui_pipeline_layout, UI_PUSH_STAGES, 0, @sizeOf(Mat4), &proj.data);

    const viewport = c.VkViewport{ .x = 0, .y = 0, .width = ctx.ui.ui_screen_width, .height = ctx.ui.ui_screen_height, .minDepth = 0, .maxDepth = 1 };
    c.vkCmdSetViewport(command_buffer, 0, 1, &viewport);
    setFullUIScissor(ctx, command_buffer);
}

pub fn end2DPass(ctx: anytype) void {
    if (!ctx.ui.ui_in_progress) return;

    ctx.ui.ui_mapped_ptr = null;

    flushUI(ctx);
    if (ctx.ui.ui_using_swapchain) {
        pass_orchestration.endUISwapchainPassInternal(ctx);
        ctx.ui.ui_using_swapchain = false;
    }
    ctx.ui.ui_in_progress = false;
}

pub fn drawRect2D(ctx: anytype, rect: rhi.Rect, color: rhi.Color) void {
    if (!ctx.ui.ui_in_progress or !bindLegacyPipeline(ctx, false)) return;

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
    _ = bindLegacyPipeline(ctx, textured);
}

pub fn drawTexture2D(ctx: anytype, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    drawTextureRegion2D(ctx, texture, rect, .{ .u0 = 0.0, .v0 = 0.0, .u1 = 1.0, .v1 = 1.0 }, rhi.Color.white);
}

pub fn drawTextureRegion2D(ctx: anytype, texture: rhi.TextureHandle, rect: rhi.Rect, uv: rhi.UVRect, color: rhi.Color) void {
    if (!ctx.frames.frame_in_progress or !ctx.ui.ui_in_progress) return;

    const tex_opt = ctx.resources.textures.get(texture);
    if (tex_opt == null) {
        log.log.err("drawTexture2D: Texture handle {} not found in textures map!", .{texture});
        return;
    }
    const tex = tex_opt.?;

    // Red-channel UI textures are font/coverage atlases. RGBA textures must
    // preserve their sampled color, otherwise map/image widgets render grayscale.
    const alpha = if (tex.format == .red) -color.a else color.a;
    const tint = [_]f32{ color.r, color.g, color.b, alpha };
    const needs_bind = !ctx.ui.legacy_pipeline_bound or !ctx.ui.ui_active_textured or ctx.ui.ui_active_texture != texture or !sameTint(ctx.ui.ui_active_tint, tint);

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    if (needs_bind) {
        if (!bindLegacyPipeline(ctx, true)) return;

        var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        image_info.imageLayout = sampledImageLayout(tex.format);
        image_info.imageView = tex.view;
        image_info.sampler = tex.sampler;

        const frame = ctx.frames.current_frame;
        const idx = ctx.ui.ui_tex_descriptor_next[frame];
        const pool_len = ctx.ui.ui_tex_descriptor_pool[frame].len;
        if (idx >= pool_len) {
            log.log.err("UI texture descriptor storage exhausted for frame {}", .{frame});
            return;
        }
        ctx.ui.ui_tex_descriptor_next[frame] = idx + 1;
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

        c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.ui_tex_pipeline_layout, UI_PUSH_STAGES, @sizeOf(Mat4), @sizeOf(@TypeOf(tint)), &tint);

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

/// Copies one retained UI mesh into the bounded per-frame geometry buffers and
/// emits an indexed draw immediately. This lets RmlUi change texture/scissor
/// state per element without disturbing queued legacy UI vertices.
pub fn drawIndexedGeometry(ctx: anytype, vertices: []const rhi.UiVertex, indices: []const u32, texture: rhi.TextureHandle, translation: [2]f32) void {
    if (!ctx.frames.frame_in_progress or !ctx.ui.ui_in_progress or vertices.len == 0 or indices.len == 0) return;
    if (vertices.len > std.math.maxInt(u32) or indices.len > std.math.maxInt(u32)) {
        log.log.err("RmlUi geometry exceeds Vulkan draw count limits (vertices={}, indices={})", .{ vertices.len, indices.len });
        return;
    }
    for (indices) |index| {
        if (index >= @as(u32, @intCast(vertices.len))) {
            log.log.err("RmlUi geometry index {} exceeds vertex count {}", .{ index, vertices.len });
            return;
        }
    }

    const vertex_bytes = std.math.mul(usize, vertices.len, @sizeOf(rhi.UiVertex)) catch {
        log.log.err("RmlUi vertex byte size overflow", .{});
        return;
    };
    const index_bytes = std.math.mul(usize, indices.len, @sizeOf(u32)) catch {
        log.log.err("RmlUi index byte size overflow", .{});
        return;
    };
    const frame = ctx.frames.current_frame;
    const textured = texture != rhi.InvalidTextureHandle;
    const tex = if (textured) ctx.resources.textures.get(texture) orelse {
        log.log.err("RmlUi texture handle {} was not found", .{texture});
        return;
    } else null;
    const descriptor_index = ctx.ui.ui_tex_descriptor_next[frame];
    if (textured and descriptor_index >= ctx.ui.ui_tex_descriptor_pool[frame].len) {
        log.log.err("RmlUi texture descriptor storage exhausted for frame {}", .{frame});
        return;
    }
    const vbo = ctx.ui.rml_vbos[frame];
    const ibo = ctx.ui.rml_ibos[frame];
    const vertex_bytes_u64: u64 = @intCast(vertex_bytes);
    const index_bytes_u64: u64 = @intCast(index_bytes);
    const vertex_end = std.math.add(u64, ctx.ui.rml_vertex_offset, vertex_bytes_u64) catch {
        log.log.err("RmlUi vertex storage offset overflow", .{});
        return;
    };
    const index_end = std.math.add(u64, ctx.ui.rml_index_offset, index_bytes_u64) catch {
        log.log.err("RmlUi index storage offset overflow", .{});
        return;
    };
    if (vertex_end > vbo.size or index_end > ibo.size) {
        log.log.err("RmlUi per-frame geometry storage overflow: vertices {}/{} bytes, indices {}/{} bytes", .{ vertex_end, vbo.size, index_end, ibo.size });
        return;
    }

    const vertex_ptr = vbo.mapped_ptr orelse {
        log.log.err("RmlUi vertex storage is not mapped", .{});
        return;
    };
    const index_ptr = ibo.mapped_ptr orelse {
        log.log.err("RmlUi index storage is not mapped", .{});
        return;
    };
    const vertex_offset_usize: usize = @intCast(ctx.ui.rml_vertex_offset);
    const index_offset_usize: usize = @intCast(ctx.ui.rml_index_offset);
    @memcpy((@as([*]u8, @ptrCast(vertex_ptr)) + vertex_offset_usize)[0..vertex_bytes], std.mem.sliceAsBytes(vertices));
    @memcpy((@as([*]u8, @ptrCast(index_ptr)) + index_offset_usize)[0..index_bytes], std.mem.sliceAsBytes(indices));

    flushUI(ctx);
    const command_buffer = ctx.frames.command_buffers[frame];
    const pipeline = getRmlUIPipeline(ctx, textured);
    if (pipeline == null) {
        log.log.err("RmlUi pipeline is unavailable", .{});
        return;
    }
    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    const layout = if (textured) ctx.pipeline_manager.ui_tex_pipeline_layout else ctx.pipeline_manager.ui_pipeline_layout;
    const projection = Mat4.orthographic(0, ctx.ui.ui_screen_width, ctx.ui.ui_screen_height, 0, -1, 1);
    c.vkCmdPushConstants(command_buffer, layout, UI_PUSH_STAGES, 0, @sizeOf(Mat4), &projection.data);
    c.vkCmdPushConstants(command_buffer, layout, c.VK_SHADER_STAGE_VERTEX_BIT, @sizeOf(Mat4), @sizeOf([2]f32), &translation);

    if (tex) |texture_resource| {
        ctx.ui.ui_tex_descriptor_next[frame] = descriptor_index + 1;
        const descriptor_set = ctx.ui.ui_tex_descriptor_pool[frame][descriptor_index];
        if (descriptor_set == null) {
            log.log.err("RmlUi texture descriptor {} is unavailable for frame {}", .{ descriptor_index, frame });
            return;
        }
        var image_info = std.mem.zeroes(c.VkDescriptorImageInfo);
        image_info.imageLayout = sampledImageLayout(texture_resource.format);
        image_info.imageView = texture_resource.view;
        image_info.sampler = texture_resource.sampler;
        var write = std.mem.zeroes(c.VkWriteDescriptorSet);
        write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        write.dstSet = descriptor_set;
        write.dstBinding = 0;
        write.descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        write.descriptorCount = 1;
        write.pImageInfo = &image_info;
        c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write, 0, null);
        c.vkCmdBindDescriptorSets(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &descriptor_set, 0, null);
    }

    const vertex_offset: c.VkDeviceSize = ctx.ui.rml_vertex_offset;
    c.vkCmdBindVertexBuffers(command_buffer, 0, 1, &vbo.buffer, &vertex_offset);
    c.vkCmdBindIndexBuffer(command_buffer, ibo.buffer, ctx.ui.rml_index_offset, c.VK_INDEX_TYPE_UINT32);
    c.vkCmdDrawIndexed(command_buffer, @intCast(indices.len), 1, 0, 0, 0);
    ctx.ui.rml_vertex_offset = vertex_end;
    ctx.ui.rml_index_offset = index_end;
    ctx.ui.legacy_pipeline_bound = false;
    ctx.ui.ui_active_textured = false;
    ctx.ui.ui_active_texture = 0;
    ctx.draw.terrain_pipeline_bound = false;
    ctx.runtime.draw_call_count += 1;
}

pub fn setScissorRegion(ctx: anytype, region: rhi.UiScissor) void {
    if (!ctx.frames.frame_in_progress or !ctx.ui.ui_in_progress) return;
    const max_width: i64 = @intFromFloat(@max(ctx.ui.ui_screen_width, 0.0));
    const max_height: i64 = @intFromFloat(@max(ctx.ui.ui_screen_height, 0.0));
    const x0 = std.math.clamp(@as(i64, region.x), @as(i64, 0), max_width);
    const y0 = std.math.clamp(@as(i64, region.y), @as(i64, 0), max_height);
    const x1 = std.math.clamp(@as(i64, region.x) + @as(i64, @intCast(region.width)), @as(i64, 0), max_width);
    const y1 = std.math.clamp(@as(i64, region.y) + @as(i64, @intCast(region.height)), @as(i64, 0), max_height);
    const scissor = c.VkRect2D{
        .offset = .{ .x = @intCast(x0), .y = @intCast(y0) },
        .extent = .{ .width = @intCast(@max(x1 - x0, 0)), .height = @intCast(@max(y1 - y0, 0)) },
    };
    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    c.vkCmdSetScissor(command_buffer, 0, 1, &scissor);
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
    c.vkCmdPushConstants(command_buffer, ctx.debug_shadow.pipeline_layout.?, UI_PUSH_STAGES, 0, @sizeOf(Mat4), &proj.data);

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
        c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.ui_pipeline_layout, UI_PUSH_STAGES, 0, @sizeOf(Mat4), &proj.data);
        setFullUIScissor(ctx, command_buffer);
        ctx.ui.legacy_pipeline_bound = true;
        ctx.ui.ui_active_textured = false;
        ctx.ui.ui_active_texture = 0;
    }
}
