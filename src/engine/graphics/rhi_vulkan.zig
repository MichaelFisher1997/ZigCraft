const std = @import("std");
const c = @import("../../c.zig").c;
const rhi = @import("rhi.zig");
const log = @import("../core/log.zig");
const RenderDevice = @import("render_device.zig").RenderDevice;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const frame_orchestration = @import("vulkan/rhi_frame_orchestration.zig");
const pass_orchestration = @import("vulkan/rhi_pass_orchestration.zig");
const draw_submission = @import("vulkan/rhi_draw_submission.zig");
const ui_submission = @import("vulkan/rhi_ui_submission.zig");
const timing = @import("vulkan/rhi_timing.zig");
const context_factory = @import("vulkan/rhi_context_factory.zig");
const state_control = @import("vulkan/rhi_state_control.zig");
const shadow_bridge = @import("vulkan/rhi_shadow_bridge.zig");
const native_access = @import("vulkan/rhi_native_access.zig");
const render_state = @import("vulkan/rhi_render_state.zig");
const init_deinit = @import("vulkan/rhi_init_deinit.zig");
const rhi_timing = @import("vulkan/rhi_timing.zig");

const QUERY_COUNT_PER_FRAME = rhi_timing.QUERY_COUNT_PER_FRAME;

const VulkanContext = @import("vulkan/rhi_context_types.zig").VulkanContext;

fn initContext(ctx_ptr: *anyopaque, allocator: std.mem.Allocator, render_device: ?*RenderDevice) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    try init_deinit.initContext(ctx, allocator, render_device);
}

fn deinit(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    init_deinit.deinit(ctx);
}
fn createBuffer(ctx_ptr: *anyopaque, size: usize, usage: rhi.BufferUsage) rhi.RhiError!rhi.BufferHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.createBuffer(size, usage);
}

fn uploadBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, data: []const u8) rhi.RhiError!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.uploadBuffer(handle, data);
}

fn updateBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, dst_offset: usize, data: []const u8) rhi.RhiError!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.updateBuffer(handle, dst_offset, data);
}

fn destroyBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    ctx.resources.destroyBuffer(handle);
}

fn beginFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    if (ctx.runtime.gpu_fault_detected) return;
    if (ctx.frames.frame_in_progress) return;

    if (ctx.runtime.framebuffer_resized) {
        log.log.info("beginFrame: triggering recreateSwapchainInternal (resize)", .{});
        frame_orchestration.recreateSwapchainInternal(ctx);
    }

    if (ctx.resources.transfer_ready) {
        ctx.resources.flushTransfer() catch |err| {
            log.log.errWithTrace("Failed to flush inter-frame transfers: {}", .{err});
        };
    }

    // Begin frame (acquire image, reset fences/CBs)
    const frame_started = ctx.frames.beginFrame(&ctx.swapchain) catch |err| {
        if (err == error.GpuLost) {
            ctx.runtime.gpu_fault_detected = true;
        } else {
            log.log.errWithTrace("beginFrame failed: {}", .{err});
        }
        return;
    };

    if (frame_started) {
        processTimingResults(ctx);

        const current_frame = ctx.frames.current_frame;
        const command_buffer = ctx.frames.command_buffers[current_frame];
        if (ctx.timing.query_pool != null) {
            c.vkCmdResetQueryPool(command_buffer, ctx.timing.query_pool, @intCast(current_frame * QUERY_COUNT_PER_FRAME), QUERY_COUNT_PER_FRAME);
        }
    }

    ctx.resources.setCurrentFrame(ctx.frames.current_frame);

    if (!frame_started) {
        return;
    }

    render_state.applyPendingDescriptorUpdates(ctx, ctx.frames.current_frame);
    frame_orchestration.prepareFrameState(ctx);
}

fn abortFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    if (!ctx.frames.frame_in_progress) return;

    if (ctx.runtime.main_pass_active) endMainPass(ctx_ptr);
    if (ctx.shadow_system.pass_active) endShadowPass(ctx_ptr);
    if (ctx.runtime.g_pass_active) endGPass(ctx_ptr);

    ctx.frames.abortFrame();

    // Recreate semaphores
    const device = ctx.vulkan_device.vk_device;
    const frame = ctx.frames.current_frame;

    c.vkDestroySemaphore(device, ctx.frames.image_available_semaphores[frame], null);
    var semaphore_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
    semaphore_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    _ = c.vkCreateSemaphore(device, &semaphore_info, null, &ctx.frames.image_available_semaphores[frame]);

    c.vkDestroySemaphore(device, ctx.frames.render_finished_semaphores[frame], null);
    _ = c.vkCreateSemaphore(device, &semaphore_info, null, &ctx.frames.render_finished_semaphores[frame]);

    ctx.runtime.draw_call_count = 0;
    ctx.runtime.main_pass_active = false;
    ctx.shadow_system.pass_active = false;
    ctx.runtime.g_pass_active = false;
    ctx.runtime.ssao_pass_active = false;
    ctx.draw.descriptors_updated = false;
    ctx.draw.bound_texture = 0;
}

fn beginGPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.beginGPassInternal(ctx);
}

fn endGPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.endGPassInternal(ctx);
}

fn beginFXAAPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.beginFXAAPassInternal(ctx);
}

fn endFXAAPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.endFXAAPassInternal(ctx);
}

fn computeBloom(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    if (!ctx.frames.frame_in_progress) return;
    pass_orchestration.ensureNoRenderPassActiveInternal(ctx);

    var bloom_source_image = ctx.hdr.hdr_image;
    if (ctx.taa.ran_this_frame and ctx.taa.output_texture != 0) {
        if (ctx.resources.textures.get(ctx.taa.output_texture)) |tex| {
            if (tex.image) |img| {
                bloom_source_image = img;
            }
        }
    }

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    ctx.bloom.compute(
        command_buffer,
        ctx.frames.current_frame,
        bloom_source_image,
        ctx.swapchain.getExtent(),
        &ctx.runtime.draw_call_count,
    );
}

fn computeTAA(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    if (!ctx.frames.frame_in_progress) return;
    if (!ctx.taa.enabled) return;
    pass_orchestration.ensureNoRenderPassActiveInternal(ctx);

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];
    ctx.taa.compute(
        ctx.vulkan_device.vk_device,
        command_buffer,
        ctx.frames.current_frame,
        &ctx.resources,
        ctx.hdr.hdr_view,
        ctx.velocity.velocity_view,
        ctx.swapchain.getExtent(),
        &ctx.runtime.draw_call_count,
    );
}

fn setFXAA(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.fxaa.enabled = enabled;
}

fn setBloom(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.bloom.enabled = enabled;
}

fn setBloomIntensity(ctx_ptr: *anyopaque, intensity: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.bloom.intensity = intensity;
}

fn setVignetteEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.vignette_enabled = enabled;
}

fn setVignetteIntensity(ctx_ptr: *anyopaque, intensity: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.vignette_intensity = intensity;
}

fn setFilmGrainEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.film_grain_enabled = enabled;
}

fn setFilmGrainIntensity(ctx_ptr: *anyopaque, intensity: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.film_grain_intensity = intensity;
}

fn setColorGradingEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.color_grading_enabled = enabled;
}

fn setColorGradingIntensity(ctx_ptr: *anyopaque, intensity: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.post_process_state.color_grading_intensity = intensity;
}

fn setTAABlendFactor(ctx_ptr: *anyopaque, value: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.taa.blend_factor = std.math.clamp(value, 0.0, 0.98);
}

fn setTAAVelocityRejection(ctx_ptr: *anyopaque, value: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.taa.velocity_rejection = std.math.clamp(value, 0.0, 0.25);
}

fn endFrame(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.endFrame(ctx);
}

fn setClearColor(ctx_ptr: *anyopaque, color: Vec3) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    const r = if (std.math.isFinite(color.x)) color.x else 0.0;
    const g = if (std.math.isFinite(color.y)) color.y else 0.0;
    const b = if (std.math.isFinite(color.z)) color.z else 0.0;
    ctx.runtime.clear_color = .{ r, g, b, 1.0 };
}

fn beginMainPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.beginMainPassInternal(ctx);
}

fn endMainPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.endMainPassInternal(ctx);
}

fn beginPostProcessPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.beginPostProcessPassInternal(ctx);
}

fn endPostProcessPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    pass_orchestration.endPostProcessPassInternal(ctx);
}

fn waitIdle(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.waitIdle(ctx);
}

fn updateGlobalUniforms(ctx_ptr: *anyopaque, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, sun_color: Vec3, time_val: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: rhi.CloudParams) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    try render_state.updateGlobalUniforms(ctx, view_proj, cam_pos, sun_dir, sun_color, time_val, fog_color, fog_density, fog_enabled, sun_intensity, ambient, use_texture, cloud_params);
}

fn setModelMatrix(ctx_ptr: *anyopaque, model: Mat4, color: Vec3, mask_radius: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    render_state.setModelMatrix(ctx, model, color, mask_radius);
}

fn setInstanceBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    render_state.setInstanceBuffer(ctx, handle);
}

fn setLODInstanceBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    render_state.setLODInstanceBuffer(ctx, handle);
}

fn setSelectionMode(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    render_state.setSelectionMode(ctx, enabled);
}

fn setTextureUniforms(ctx_ptr: *anyopaque, texture_enabled: bool, shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    _ = shadow_map_handles;
    state_control.setTextureUniforms(ctx, texture_enabled);
}

fn beginCloudPass(ctx_ptr: *anyopaque, params: rhi.CloudParams) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    render_state.beginCloudPass(ctx, params);
}

fn drawDepthTexture(ctx_ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.drawDepthTexture(ctx, texture, rect);
}

fn createTexture(ctx_ptr: *anyopaque, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.createTexture(width, height, format, config, data_opt);
}

fn createTexture3D(ctx_ptr: *anyopaque, width: u32, height: u32, depth: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.createTexture3D(width, height, depth, format, config, data_opt);
}

fn destroyTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.resources.destroyTexture(handle);
}

fn bindTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle, slot: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    const resolved = if (handle == 0) switch (slot) {
        6 => ctx.draw.dummy_normal_texture,
        7, 8 => ctx.draw.dummy_roughness_texture,
        9 => ctx.draw.dummy_texture,
        0, 1 => ctx.draw.dummy_texture,
        else => ctx.draw.dummy_texture,
    } else handle;

    switch (slot) {
        0, 1 => ctx.draw.current_texture = resolved,
        6 => ctx.draw.current_normal_texture = resolved,
        7 => ctx.draw.current_roughness_texture = resolved,
        8 => ctx.draw.current_displacement_texture = resolved,
        9 => ctx.draw.current_env_texture = resolved,
        11 => ctx.draw.current_lpv_texture = resolved,
        12 => ctx.draw.current_lpv_texture_g = resolved,
        13 => ctx.draw.current_lpv_texture_b = resolved,
        else => ctx.draw.current_texture = resolved,
    }
}

fn updateTexture(ctx_ptr: *anyopaque, handle: rhi.TextureHandle, data: []const u8) rhi.RhiError!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.updateTexture(handle, data);
}

fn setViewport(ctx_ptr: *anyopaque, width: u32, height: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setViewport(ctx, width, height);
}

fn getAllocator(ctx_ptr: *anyopaque) std.mem.Allocator {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getAllocator(ctx);
}

fn getFrameIndex(ctx_ptr: *anyopaque) usize {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getFrameIndex(ctx);
}

fn supportsIndirectFirstInstance(ctx_ptr: *anyopaque) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.supportsIndirectFirstInstance(ctx);
}

fn recover(ctx_ptr: *anyopaque) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    try state_control.recover(ctx);
}

fn setWireframe(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setWireframe(ctx, enabled);
}

fn setTexturesEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setTexturesEnabled(ctx, enabled);
}

fn setDebugShadowView(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setDebugShadowView(ctx, enabled);
}

fn setVSync(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setVSync(ctx, enabled);
}

fn setAnisotropicFiltering(ctx_ptr: *anyopaque, level: u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setAnisotropicFiltering(ctx, level);
}

fn setVolumetricDensity(ctx_ptr: *anyopaque, density: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setVolumetricDensity(ctx, density);
}

fn setMSAA(ctx_ptr: *anyopaque, samples: u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    state_control.setMSAA(ctx, samples);
}

fn getMaxAnisotropy(ctx_ptr: *anyopaque) u8 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getMaxAnisotropy(ctx);
}

fn getMaxMSAASamples(ctx_ptr: *anyopaque) u8 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getMaxMSAASamples(ctx);
}

fn getFaultCount(ctx_ptr: *anyopaque) u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getFaultCount(ctx);
}

fn getValidationErrorCount(ctx_ptr: *anyopaque) u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return state_control.getValidationErrorCount(ctx);
}

fn drawIndexed(ctx_ptr: *anyopaque, vbo_handle: rhi.BufferHandle, ebo_handle: rhi.BufferHandle, count: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    draw_submission.drawIndexed(ctx, vbo_handle, ebo_handle, count);
}

fn drawIndirect(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, command_buffer: rhi.BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    draw_submission.drawIndirect(ctx, handle, command_buffer, offset, draw_count, stride);
}

fn drawInstance(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, instance_index: u32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    draw_submission.drawInstance(ctx, handle, count, instance_index);
}

fn draw(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode) void {
    drawOffset(ctx_ptr, handle, count, mode, 0);
}

fn drawOffset(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, count: u32, mode: rhi.DrawMode, offset: usize) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    draw_submission.drawOffset(ctx, handle, count, mode, offset);
}

fn bindBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle, usage: rhi.BufferUsage) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    draw_submission.bindBuffer(ctx, handle, usage);
}

fn pushConstants(ctx_ptr: *anyopaque, stages: rhi.ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    draw_submission.pushConstants(ctx, stages, offset, size, data);
}

// 2D Rendering functions
fn begin2DPass(ctx_ptr: *anyopaque, screen_width: f32, screen_height: f32) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    ui_submission.begin2DPass(ctx, screen_width, screen_height);
}

fn end2DPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.end2DPass(ctx);
}

fn drawRect2D(ctx_ptr: *anyopaque, rect: rhi.Rect, color: rhi.Color) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.drawRect2D(ctx, rect, color);
}

const VULKAN_SHADOW_CONTEXT_VTABLE = rhi.IShadowContext.VTable{
    .beginPass = beginShadowPass,
    .endPass = endShadowPass,
    .updateUniforms = updateShadowUniforms,
    .getShadowMapHandle = getShadowMapHandle,
};

fn bindUIPipeline(ctx_ptr: *anyopaque, textured: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.bindUIPipeline(ctx, textured);
}

fn drawTexture2D(ctx_ptr: *anyopaque, texture: rhi.TextureHandle, rect: rhi.Rect) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ui_submission.drawTexture2D(ctx, texture, rect);
}

fn createShader(ctx_ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) rhi.RhiError!rhi.ShaderHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.resources.createShader(vertex_src, fragment_src);
}

fn destroyShader(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.resources.destroyShader(handle);
}

fn mapBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) rhi.RhiError!?*anyopaque {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    return ctx.resources.mapBuffer(handle);
}

fn unmapBuffer(ctx_ptr: *anyopaque, handle: rhi.BufferHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.resources.unmapBuffer(handle);
}

fn bindShader(ctx_ptr: *anyopaque, handle: rhi.ShaderHandle) void {
    _ = ctx_ptr;
    _ = handle;
}

fn beginShadowPass(ctx_ptr: *anyopaque, cascade_index: u32, light_space_matrix: Mat4) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    shadow_bridge.beginShadowPassInternal(ctx, cascade_index, light_space_matrix);
}

fn endShadowPass(ctx_ptr: *anyopaque) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.mutex.lock();
    defer ctx.mutex.unlock();
    shadow_bridge.endShadowPassInternal(ctx);
}

fn getShadowMapHandle(ctx_ptr: *anyopaque, cascade_index: u32) rhi.TextureHandle {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return shadow_bridge.getShadowMapHandle(ctx, cascade_index);
}

fn updateShadowUniforms(ctx_ptr: *anyopaque, params: rhi.ShadowParams) anyerror!void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    try shadow_bridge.updateShadowUniforms(ctx, params);
}

fn getNativeSkyPipeline(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeSkyPipeline(ctx);
}
fn getNativeSkyPipelineLayout(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeSkyPipelineLayout(ctx);
}
fn getNativeCloudPipeline(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeCloudPipeline(ctx);
}
fn getNativeCloudPipelineLayout(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeCloudPipelineLayout(ctx);
}
fn getNativeMainDescriptorSet(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeMainDescriptorSet(ctx);
}
fn getNativeCommandBuffer(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeCommandBuffer(ctx);
}
fn getNativeSwapchainExtent(ctx_ptr: *anyopaque) [2]u32 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeSwapchainExtent(ctx);
}
fn getNativeDevice(ctx_ptr: *anyopaque) u64 {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return native_access.getNativeDevice(ctx);
}

fn computeSSAO(ctx_ptr: *anyopaque, proj: Mat4, inv_proj: Mat4) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.ssao_system.compute(
        ctx.vulkan_device.vk_device,
        ctx.frames.command_buffers[ctx.frames.current_frame],
        ctx.frames.current_frame,
        ctx.swapchain.getExtent(),
        proj,
        inv_proj,
    );
}

fn drawDebugShadowMap(ctx_ptr: *anyopaque, cascade_index: usize, depth_map_handle: rhi.TextureHandle) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    shadow_bridge.drawDebugShadowMap(ctx, cascade_index, depth_map_handle);
}

const VULKAN_SSAO_VTABLE = rhi.ISSAOContext.VTable{
    .compute = computeSSAO,
};

const VULKAN_UI_CONTEXT_VTABLE = rhi.IUIContext.VTable{
    .beginPass = begin2DPass,
    .endPass = end2DPass,
    .drawRect = drawRect2D,
    .drawTexture = drawTexture2D,
    .drawDepthTexture = drawDepthTexture,
    .bindPipeline = bindUIPipeline,
};

fn getStateContext(ctx_ptr: *anyopaque) rhi.IRenderStateContext {
    return .{ .ptr = ctx_ptr, .vtable = &VULKAN_STATE_CONTEXT_VTABLE };
}

const VULKAN_STATE_CONTEXT_VTABLE = rhi.IRenderStateContext.VTable{
    .setModelMatrix = setModelMatrix,
    .setInstanceBuffer = setInstanceBuffer,
    .setLODInstanceBuffer = setLODInstanceBuffer,
    .setSelectionMode = setSelectionMode,
    .updateGlobalUniforms = updateGlobalUniforms,
    .setTextureUniforms = setTextureUniforms,
};

fn getEncoder(ctx_ptr: *anyopaque) rhi.IGraphicsCommandEncoder {
    return .{ .ptr = ctx_ptr, .vtable = &VULKAN_COMMAND_ENCODER_VTABLE };
}

const VULKAN_COMMAND_ENCODER_VTABLE = rhi.IGraphicsCommandEncoder.VTable{
    .bindShader = bindShader,
    .bindTexture = bindTexture,
    .bindBuffer = bindBuffer,
    .pushConstants = pushConstants,
    .draw = draw,
    .drawOffset = drawOffset,
    .drawIndexed = drawIndexed,
    .drawIndirect = drawIndirect,
    .drawInstance = drawInstance,
    .setViewport = setViewport,
};

const VULKAN_RHI_VTABLE = rhi.RHI.VTable{
    .init = initContext,
    .deinit = deinit,
    .resources = .{
        .createBuffer = createBuffer,
        .uploadBuffer = uploadBuffer,
        .updateBuffer = updateBuffer,
        .destroyBuffer = destroyBuffer,
        .createTexture = createTexture,
        .createTexture3D = createTexture3D,
        .destroyTexture = destroyTexture,
        .updateTexture = updateTexture,
        .createShader = createShader,
        .destroyShader = destroyShader,
        .mapBuffer = mapBuffer,
        .unmapBuffer = unmapBuffer,
    },
    .render = .{
        .beginFrame = beginFrame,
        .endFrame = endFrame,
        .abortFrame = abortFrame,
        .beginMainPass = beginMainPass,
        .endMainPass = endMainPass,
        .beginPostProcessPass = beginPostProcessPass,
        .endPostProcessPass = endPostProcessPass,
        .beginGPass = beginGPass,
        .endGPass = endGPass,
        .beginFXAAPass = beginFXAAPass,
        .endFXAAPass = endFXAAPass,
        .computeBloom = computeBloom,
        .computeTAA = computeTAA,
        .getEncoder = getEncoder,
        .getStateContext = getStateContext,
        .getNativeSkyPipeline = getNativeSkyPipeline,
        .getNativeSkyPipelineLayout = getNativeSkyPipelineLayout,
        .getNativeCloudPipeline = getNativeCloudPipeline,
        .getNativeCloudPipelineLayout = getNativeCloudPipelineLayout,
        .getNativeMainDescriptorSet = getNativeMainDescriptorSet,
        .getNativeCommandBuffer = getNativeCommandBuffer,
        .getNativeSwapchainExtent = getNativeSwapchainExtent,
        .getNativeDevice = getNativeDevice,
        .setClearColor = setClearColor,
        .computeSSAO = computeSSAO,
        .drawDebugShadowMap = drawDebugShadowMap,
    },
    .ssao = VULKAN_SSAO_VTABLE,
    .shadow = VULKAN_SHADOW_CONTEXT_VTABLE,
    .ui = VULKAN_UI_CONTEXT_VTABLE,
    .query = .{
        .getFrameIndex = getFrameIndex,
        .supportsIndirectFirstInstance = supportsIndirectFirstInstance,
        .getMaxAnisotropy = getMaxAnisotropy,
        .getMaxMSAASamples = getMaxMSAASamples,
        .getFaultCount = getFaultCount,
        .getValidationErrorCount = getValidationErrorCount,
        .waitIdle = waitIdle,
    },
    .timing = .{
        .beginPassTiming = beginPassTiming,
        .endPassTiming = endPassTiming,
        .getTimingResults = getTimingResults,
        .isTimingEnabled = isTimingEnabled,
        .setTimingEnabled = setTimingEnabled,
    },
    .setWireframe = setWireframe,
    .setTexturesEnabled = setTexturesEnabled,
    .setDebugShadowView = setDebugShadowView,
    .setVSync = setVSync,
    .setAnisotropicFiltering = setAnisotropicFiltering,
    .setVolumetricDensity = setVolumetricDensity,
    .setMSAA = setMSAA,
    .recover = recover,
    .setFXAA = setFXAA,
    .setBloom = setBloom,
    .setBloomIntensity = setBloomIntensity,
    .setVignetteEnabled = setVignetteEnabled,
    .setVignetteIntensity = setVignetteIntensity,
    .setFilmGrainEnabled = setFilmGrainEnabled,
    .setFilmGrainIntensity = setFilmGrainIntensity,
    .setColorGradingEnabled = setColorGradingEnabled,
    .setColorGradingIntensity = setColorGradingIntensity,
    .setTAABlendFactor = setTAABlendFactor,
    .setTAAVelocityRejection = setTAAVelocityRejection,
};

fn beginPassTiming(ctx_ptr: *anyopaque, pass_name: []const u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    timing.beginPassTiming(ctx, pass_name);
}

fn endPassTiming(ctx_ptr: *anyopaque, pass_name: []const u8) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    timing.endPassTiming(ctx, pass_name);
}

fn getTimingResults(ctx_ptr: *anyopaque) rhi.GpuTimingResults {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.timing.timing_results;
}

fn isTimingEnabled(ctx_ptr: *anyopaque) bool {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    return ctx.timing.timing_enabled;
}

fn setTimingEnabled(ctx_ptr: *anyopaque, enabled: bool) void {
    const ctx: *VulkanContext = @ptrCast(@alignCast(ctx_ptr));
    ctx.timing.timing_enabled = enabled;
}

fn processTimingResults(ctx: *VulkanContext) void {
    timing.processTimingResults(ctx);
}

pub fn createRHI(allocator: std.mem.Allocator, window: *c.SDL_Window, render_device: ?*RenderDevice, shadow_resolution: u32, msaa_samples: u8, anisotropic_filtering: u8) !rhi.RHI {
    return context_factory.createRHI(
        VulkanContext,
        allocator,
        window,
        render_device,
        shadow_resolution,
        msaa_samples,
        anisotropic_filtering,
        &VULKAN_RHI_VTABLE,
    );
}
