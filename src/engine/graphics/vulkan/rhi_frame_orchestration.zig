const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const log = @import("../../core/log.zig");
const build_options = @import("build_options");
const bindings = @import("descriptor_bindings.zig");
const lifecycle = @import("rhi_resource_lifecycle.zig");
const setup = @import("rhi_resource_setup.zig");

pub fn recreateSwapchainInternal(ctx: anytype) void {
    _ = c.vkDeviceWaitIdle(ctx.vulkan_device.vk_device);

    var w: c_int = 0;
    var h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(ctx.window, &w, &h);
    if (w == 0 or h == 0) return;

    setup.destroyMainRenderPassAndPipelines(ctx);
    lifecycle.destroyHDRResources(ctx);
    lifecycle.destroyFXAAResources(ctx);
    lifecycle.destroyTAAResources(ctx);
    lifecycle.destroyBloomResources(ctx);
    lifecycle.destroyPostProcessResources(ctx);
    lifecycle.destroyGPassResources(ctx);

    ctx.runtime.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.runtime.g_pass_active = false;
    ctx.runtime.ssao_pass_active = false;

    ctx.swapchain.recreate() catch |err| {
        log.log.errWithTrace("Failed to recreate swapchain: {}", .{err});
        return;
    };

    lifecycle.transitionImagesToPresent(ctx, ctx.swapchain.swapchain.images.items) catch |err| {
        log.log.warn("Failed to transition swapchain images to PRESENT: {}", .{err});
    };

    lifecycle.createHDRResources(ctx) catch |err| {
        log.log.errWithTrace("Failed to recreate HDR resources: {}", .{err});
        return;
    };
    setup.createGPassResources(ctx) catch |err| {
        log.log.errWithTrace("Failed to recreate G-Pass resources: {}", .{err});
        return;
    };
    setup.createSSAOResources(ctx) catch |err| {
        log.log.errWithTrace("Failed to recreate SSAO resources: {}", .{err});
        return;
    };
    setup.createTAAResources(ctx) catch |err| {
        log.log.errWithTrace("Failed to recreate TAA resources: {}", .{err});
        return;
    };
    ctx.render_pass_manager.createMainRenderPass(ctx.vulkan_device.vk_device, ctx.swapchain.getExtent(), ctx.options.msaa_samples) catch |err| {
        log.log.errWithTrace("Failed to recreate render pass: {}", .{err});
        return;
    };
    ctx.pipeline_manager.createMainPipelines(ctx.allocator, ctx.vulkan_device.vk_device, ctx.render_pass_manager.hdr_render_pass, ctx.render_pass_manager.g_render_pass, ctx.options.msaa_samples) catch |err| {
        log.log.errWithTrace("Failed to recreate pipelines: {}", .{err});
        return;
    };
    setup.createPostProcessResources(ctx) catch |err| {
        log.log.errWithTrace("Failed to recreate post-process resources: {}", .{err});
        return;
    };
    setup.createSwapchainUIResources(ctx) catch |err| {
        log.log.errWithTrace("Failed to recreate swapchain UI resources: {}", .{err});
        return;
    };
    ctx.fxaa.init(&ctx.vulkan_device, ctx.allocator, ctx.descriptors.descriptor_pool, ctx.swapchain.getExtent(), ctx.swapchain.getImageFormat(), ctx.post_process.sampler, ctx.swapchain.getImageViews()) catch |err| {
        log.log.errWithTrace("Failed to recreate FXAA resources: {}", .{err});
        return;
    };
    ctx.pipeline_manager.createSwapchainUIPipelines(ctx.allocator, ctx.vulkan_device.vk_device, ctx.render_pass_manager.ui_swapchain_render_pass) catch |err| {
        log.log.errWithTrace("Failed to recreate swapchain UI pipelines: {}", .{err});
        return;
    };
    ctx.bloom.init(&ctx.vulkan_device, ctx.allocator, ctx.descriptors.descriptor_pool, ctx.hdr.hdr_view, ctx.swapchain.getExtent().width, ctx.swapchain.getExtent().height, c.VK_FORMAT_R16G16B16A16_SFLOAT) catch |err| {
        log.log.errWithTrace("Failed to recreate Bloom resources: {}", .{err});
        return;
    };
    setup.updatePostProcessDescriptorsWithBloom(ctx);

    {
        var list: [32]c.VkImage = undefined;
        var count: usize = 0;
        const candidates = [_]c.VkImage{ ctx.hdr.hdr_image, ctx.gpass.g_normal_image, ctx.ssao_system.image, ctx.ssao_system.blur_image, ctx.ssao_system.noise_image, ctx.velocity.velocity_image };
        for (candidates) |img| {
            if (img != null) {
                list[count] = img;
                count += 1;
            }
        }
        for (ctx.bloom.mip_images) |img| {
            if (img != null) {
                list[count] = img;
                count += 1;
            }
        }

        if (count > 0) {
            lifecycle.transitionImagesToShaderRead(ctx, list[0..count], false) catch |err| log.log.warn("Failed to transition images: {}", .{err});
        }

        if (ctx.gpass.g_depth_image != null) {
            lifecycle.transitionImagesToShaderRead(ctx, &[_]c.VkImage{ctx.gpass.g_depth_image}, true) catch |err| log.log.warn("Failed to transition G-depth image: {}", .{err});
        }
        if (ctx.shadow_system.shadow_image != null) {
            lifecycle.transitionImagesToShaderRead(ctx, &[_]c.VkImage{ctx.shadow_system.shadow_image}, true) catch |err| log.log.warn("Failed to transition Shadow image: {}", .{err});
            for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
                ctx.shadow_system.shadow_image_layouts[i] = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            }
        }
    }

    ctx.runtime.framebuffer_resized = false;
    ctx.runtime.pipeline_rebuild_needed = false;
}

pub fn prepareFrameState(ctx: anytype) void {
    ctx.runtime.draw_call_count = 0;
    ctx.runtime.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.runtime.post_process_ran_this_frame = false;
    ctx.runtime.fxaa_ran_this_frame = false;
    ctx.taa.ran_this_frame = false;
    ctx.ui.ui_using_swapchain = false;

    ctx.draw.terrain_pipeline_bound = false;
    ctx.shadow_system.pipeline_bound = false;
    ctx.draw.descriptors_updated = false;
    ctx.draw.bound_texture = 0;

    const command_buffer = ctx.frames.getCurrentCommandBuffer();

    var mem_barrier = std.mem.zeroes(c.VkMemoryBarrier);
    mem_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
    mem_barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT | c.VK_ACCESS_TRANSFER_WRITE_BIT;
    mem_barrier.dstAccessMask = c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT | c.VK_ACCESS_INDEX_READ_BIT | c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_INDIRECT_COMMAND_READ_BIT;
    c.vkCmdPipelineBarrier(
        command_buffer,
        c.VK_PIPELINE_STAGE_HOST_BIT | c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_VERTEX_INPUT_BIT | c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT | c.VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT,
        0,
        1,
        &mem_barrier,
        0,
        null,
        0,
        null,
    );

    ctx.ui.ui_vertex_offset = 0;
    ctx.ui.ui_flushed_vertex_count = 0;
    ctx.ui.ui_tex_descriptor_next[ctx.frames.current_frame] = 0;
    if (comptime build_options.debug_shadows) {
        ctx.debug_shadow.descriptor_next[ctx.frames.current_frame] = 0;
    }

    const cur_tex = ctx.draw.current_texture;
    const cur_nor = ctx.draw.current_normal_texture;
    const cur_rou = ctx.draw.current_roughness_texture;
    const cur_dis = ctx.draw.current_displacement_texture;
    const cur_env = ctx.draw.current_env_texture;
    const cur_lpv = ctx.draw.current_lpv_texture;
    const cur_lpv_g = ctx.draw.current_lpv_texture_g;
    const cur_lpv_b = ctx.draw.current_lpv_texture_b;

    var needs_update = false;
    if (ctx.draw.bound_texture != cur_tex) needs_update = true;
    if (ctx.draw.bound_normal_texture != cur_nor) needs_update = true;
    if (ctx.draw.bound_roughness_texture != cur_rou) needs_update = true;
    if (ctx.draw.bound_displacement_texture != cur_dis) needs_update = true;
    if (ctx.draw.bound_env_texture != cur_env) needs_update = true;
    if (ctx.draw.bound_lpv_texture != cur_lpv) needs_update = true;
    if (ctx.draw.bound_lpv_texture_g != cur_lpv_g) needs_update = true;
    if (ctx.draw.bound_lpv_texture_b != cur_lpv_b) needs_update = true;

    for (0..rhi.SHADOW_CASCADE_COUNT) |si| {
        if (ctx.draw.bound_shadow_views[si] != ctx.shadow_system.shadow_image_views[si]) needs_update = true;
    }

    if (needs_update) {
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| ctx.draw.descriptors_dirty[i] = true;
        ctx.draw.bound_texture = cur_tex;
        ctx.draw.bound_normal_texture = cur_nor;
        ctx.draw.bound_roughness_texture = cur_rou;
        ctx.draw.bound_displacement_texture = cur_dis;
        ctx.draw.bound_env_texture = cur_env;
        ctx.draw.bound_lpv_texture = cur_lpv;
        ctx.draw.bound_lpv_texture_g = cur_lpv_g;
        ctx.draw.bound_lpv_texture_b = cur_lpv_b;
        for (0..rhi.SHADOW_CASCADE_COUNT) |si| ctx.draw.bound_shadow_views[si] = ctx.shadow_system.shadow_image_views[si];
    }

    if (ctx.draw.descriptors_dirty[ctx.frames.current_frame]) {
        if (ctx.descriptors.descriptor_sets[ctx.frames.current_frame] == null) {
            log.log.err("CRITICAL: Descriptor set for frame {} is NULL!", .{ctx.frames.current_frame});
            return;
        }
        var writes: [14]c.VkWriteDescriptorSet = undefined;
        var write_count: u32 = 0;
        var image_infos: [14]c.VkDescriptorImageInfo = undefined;
        var info_count: u32 = 0;

        const dummy_tex_entry = ctx.resources.textures.get(ctx.draw.dummy_texture);
        const dummy_tex_3d_entry = ctx.resources.textures.get(ctx.draw.dummy_texture_3d);

        const atlas_slots = [_]struct { handle: rhi.TextureHandle, binding: u32, is_3d: bool }{
            .{ .handle = cur_tex, .binding = bindings.ALBEDO_TEXTURE, .is_3d = false },
            .{ .handle = cur_nor, .binding = bindings.NORMAL_TEXTURE, .is_3d = false },
            .{ .handle = cur_rou, .binding = bindings.ROUGHNESS_TEXTURE, .is_3d = false },
            .{ .handle = cur_dis, .binding = bindings.DISPLACEMENT_TEXTURE, .is_3d = false },
            .{ .handle = cur_env, .binding = bindings.ENV_TEXTURE, .is_3d = false },
            .{ .handle = cur_lpv, .binding = bindings.LPV_TEXTURE, .is_3d = true },
            .{ .handle = cur_lpv_g, .binding = bindings.LPV_TEXTURE_G, .is_3d = true },
            .{ .handle = cur_lpv_b, .binding = bindings.LPV_TEXTURE_B, .is_3d = true },
        };

        for (atlas_slots) |slot| {
            const fallback = if (slot.is_3d) dummy_tex_3d_entry else dummy_tex_entry;
            const entry = ctx.resources.textures.get(slot.handle) orelse fallback;
            if (entry) |tex| {
                image_infos[info_count] = .{
                    .sampler = tex.sampler,
                    .imageView = tex.view,
                    .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
                };
                writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
                writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
                writes[write_count].dstSet = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
                writes[write_count].dstBinding = slot.binding;
                writes[write_count].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
                writes[write_count].descriptorCount = 1;
                writes[write_count].pImageInfo = &image_infos[info_count];
                write_count += 1;
                info_count += 1;
            }
        }

        if (ctx.shadow_system.shadow_sampler == null) {
            log.log.err("CRITICAL: Shadow sampler is NULL!", .{});
        }
        if (ctx.shadow_system.shadow_sampler_regular == null) {
            log.log.err("CRITICAL: Shadow regular sampler is NULL!", .{});
        }
        if (ctx.shadow_system.shadow_image_view == null) {
            log.log.err("CRITICAL: Shadow image view is NULL!", .{});
        }
        image_infos[info_count] = .{
            .sampler = ctx.shadow_system.shadow_sampler,
            .imageView = ctx.shadow_system.shadow_image_view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[write_count].dstSet = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
        writes[write_count].dstBinding = bindings.SHADOW_COMPARE_TEXTURE;
        writes[write_count].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[write_count].descriptorCount = 1;
        writes[write_count].pImageInfo = &image_infos[info_count];
        write_count += 1;
        info_count += 1;

        image_infos[info_count] = .{
            .sampler = if (ctx.shadow_system.shadow_sampler_regular != null) ctx.shadow_system.shadow_sampler_regular else ctx.shadow_system.shadow_sampler,
            .imageView = ctx.shadow_system.shadow_image_view,
            .imageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        };
        writes[write_count] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[write_count].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[write_count].dstSet = ctx.descriptors.descriptor_sets[ctx.frames.current_frame];
        writes[write_count].dstBinding = bindings.SHADOW_REGULAR_TEXTURE;
        writes[write_count].descriptorType = c.VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
        writes[write_count].descriptorCount = 1;
        writes[write_count].pImageInfo = &image_infos[info_count];
        write_count += 1;
        info_count += 1;

        if (write_count > 0) {
            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, write_count, &writes[0], 0, null);

            for (0..write_count) |i| {
                writes[i].dstSet = ctx.descriptors.lod_descriptor_sets[ctx.frames.current_frame];
            }
            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, write_count, &writes[0], 0, null);
        }

        ctx.draw.descriptors_dirty[ctx.frames.current_frame] = false;
    }

    ctx.draw.descriptors_updated = true;
}
