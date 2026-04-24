const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const Mat4 = @import("../../math/mat4.zig").Mat4;
const Vec3 = @import("../../math/vec3.zig").Vec3;
const bindings = @import("descriptor_bindings.zig");
const pass_orchestration = @import("rhi_pass_orchestration.zig");

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

const GlobalUniforms = extern struct {
    view_proj: Mat4,
    view_proj_prev: Mat4,
    cam_pos: [4]f32,
    sun_dir: [4]f32,
    sun_color: [4]f32,
    fog_color: [4]f32,
    cloud_wind_offset: [4]f32,
    params: [4]f32,
    lighting: [4]f32,
    cloud_params: [4]f32,
    shadow_params: [4]f32,
    pbr_params: [4]f32,
    volumetric_params: [4]f32,
    viewport_size: [4]f32,
    lpv_params: [4]f32,
    lpv_origin: [4]f32,
};

const CloudPushConstants = extern struct {
    view_proj: [4][4]f32,
    camera_pos: [4]f32,
    cloud_params: [4]f32,
    sun_params: [4]f32,
    fog_params: [4]f32,
};

pub fn updateGlobalUniforms(ctx: anytype, view_proj: Mat4, cam_pos: Vec3, sun_dir: Vec3, sun_color: Vec3, time_val: f32, fog_color: Vec3, fog_density: f32, fog_enabled: bool, sun_intensity: f32, ambient: f32, use_texture: bool, cloud_params: rhi.CloudParams) !void {
    const global_uniforms = GlobalUniforms{
        .view_proj = view_proj,
        .view_proj_prev = ctx.velocity.view_proj_prev,
        .cam_pos = .{ cam_pos.x, cam_pos.y, cam_pos.z, 1.0 },
        .sun_dir = .{ sun_dir.x, sun_dir.y, sun_dir.z, 0.0 },
        .sun_color = .{ sun_color.x, sun_color.y, sun_color.z, 1.0 },
        .fog_color = .{ fog_color.x, fog_color.y, fog_color.z, 1.0 },
        .cloud_wind_offset = .{ cloud_params.wind_offset_x, cloud_params.wind_offset_z, cloud_params.cloud_scale, cloud_params.cloud_coverage },
        .params = .{ time_val, fog_density, if (fog_enabled) 1.0 else 0.0, sun_intensity },
        .lighting = .{ ambient, if (use_texture) 1.0 else 0.0, if (cloud_params.pbr_enabled) 1.0 else 0.0, cloud_params.shadow.strength },
        .cloud_params = .{ cloud_params.cloud_height, if (cloud_params.cloud_shadows) 1.0 else 0.0, if (cloud_params.pbr_enabled) 1.0 else 0.0, if (cloud_params.simple_lighting_enabled) 1.0 else 0.0 },
        .shadow_params = .{ @floatFromInt(cloud_params.shadow.pcf_samples), if (cloud_params.shadow.cascade_blend) 1.0 else 0.0, cloud_params.shadow.strength, if (cloud_params.shadow_apply_to_beauty) 1.0 else 0.0 },
        .pbr_params = .{ @floatFromInt(cloud_params.pbr_quality), cloud_params.exposure, cloud_params.saturation, if (cloud_params.ssao_enabled) 1.0 else 0.0 },
        .volumetric_params = .{ if (cloud_params.volumetric_enabled) 1.0 else 0.0, cloud_params.volumetric_density, @floatFromInt(cloud_params.volumetric_steps), cloud_params.volumetric_scattering },
        .viewport_size = .{ @floatFromInt(ctx.swapchain.swapchain.extent.width), @floatFromInt(ctx.swapchain.swapchain.extent.height), if (ctx.options.debug_shadows_active) 1.0 else 0.0, @floatFromInt(ctx.options.shadow_debug_channel) },
        .lpv_params = .{ if (cloud_params.lpv_enabled) 1.0 else 0.0, cloud_params.lpv_intensity, cloud_params.lpv_cell_size, @floatFromInt(cloud_params.lpv_grid_size) },
        .lpv_origin = .{ cloud_params.lpv_origin.x, cloud_params.lpv_origin.y, cloud_params.lpv_origin.z, 0.0 },
    };

    // Env var override for debug channel (ZIGCRAFT_DEBUG_SHADER=5 for tile_id, 6 for tex_color)
    if (getenv("ZIGCRAFT_DEBUG_SHADER")) |ds| {
        const ch: u32 = std.fmt.parseInt(u32, ds, 10) catch 0;
        if (ch > 0) {
            var gu = global_uniforms;
            gu.viewport_size[2] = 1.0;
            gu.viewport_size[3] = @floatFromInt(ch);
            try ctx.descriptors.updateGlobalUniforms(ctx.frames.current_frame, &gu);
            return;
        }
    }

    try ctx.descriptors.updateGlobalUniforms(ctx.frames.current_frame, &global_uniforms);
    ctx.velocity.view_proj_prev = view_proj;
}

pub fn setModelMatrix(ctx: anytype, model: Mat4, color: Vec3, mask_radius: f32) void {
    ctx.draw.current_model = model;
    ctx.draw.current_color = .{ color.x, color.y, color.z, 1.0 };
    ctx.draw.current_mask_radius = mask_radius;
}

pub fn setInstanceBuffer(ctx: anytype, handle: rhi.BufferHandle) void {
    if (!ctx.frames.frame_in_progress) return;
    ctx.draw.pending_instance_buffer = handle;
    ctx.draw.lod_mode = false;
    applyPendingDescriptorUpdates(ctx, ctx.frames.current_frame);
}

pub fn setLODInstanceBuffer(ctx: anytype, handle: rhi.BufferHandle) void {
    if (!ctx.frames.frame_in_progress) return;
    ctx.draw.pending_lod_instance_buffer = handle;
    ctx.draw.lod_mode = true;
    applyPendingDescriptorUpdates(ctx, ctx.frames.current_frame);
}

pub fn setTerrainPipelineBound(ctx: anytype, bound: bool) void {
    ctx.draw.terrain_pipeline_bound = bound;
}

pub fn setSelectionMode(ctx: anytype, enabled: bool) void {
    ctx.ui.selection_mode = enabled;
}

pub fn applyPendingDescriptorUpdates(ctx: anytype, frame_index: usize) void {
    if (ctx.draw.pending_instance_buffer != 0 and ctx.draw.bound_instance_buffer[frame_index] != ctx.draw.pending_instance_buffer) {
        const buf_opt = ctx.resources.buffers.get(ctx.draw.pending_instance_buffer);

        if (buf_opt) |buf| {
            var buffer_info = c.VkDescriptorBufferInfo{
                .buffer = buf.buffer,
                .offset = 0,
                .range = buf.size,
            };

            var write = std.mem.zeroes(c.VkWriteDescriptorSet);
            write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = ctx.descriptors.descriptor_sets[frame_index];
            write.dstBinding = bindings.INSTANCE_SSBO;
            write.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            write.descriptorCount = 1;
            write.pBufferInfo = &buffer_info;

            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write, 0, null);
            ctx.draw.bound_instance_buffer[frame_index] = ctx.draw.pending_instance_buffer;
        }
    }

    if (ctx.draw.pending_lod_instance_buffer != 0 and ctx.draw.bound_lod_instance_buffer[frame_index] != ctx.draw.pending_lod_instance_buffer) {
        const buf_opt = ctx.resources.buffers.get(ctx.draw.pending_lod_instance_buffer);

        if (buf_opt) |buf| {
            var buffer_info = c.VkDescriptorBufferInfo{
                .buffer = buf.buffer,
                .offset = 0,
                .range = buf.size,
            };

            var write = std.mem.zeroes(c.VkWriteDescriptorSet);
            write.sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            write.dstSet = ctx.descriptors.lod_descriptor_sets[frame_index];
            write.dstBinding = bindings.INSTANCE_SSBO;
            write.descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            write.descriptorCount = 1;
            write.pBufferInfo = &buffer_info;

            c.vkUpdateDescriptorSets(ctx.vulkan_device.vk_device, 1, &write, 0, null);
            ctx.draw.bound_lod_instance_buffer[frame_index] = ctx.draw.pending_lod_instance_buffer;
        }
    }
}

pub fn beginCloudPass(ctx: anytype, params: rhi.CloudParams) void {
    if (!ctx.frames.frame_in_progress) return;

    if (!ctx.runtime.main_pass_active and !ctx.water_system.pass_active) pass_orchestration.beginMainPassInternal(ctx);
    if (!ctx.runtime.main_pass_active) return;

    if (ctx.pipeline_manager.cloud_pipeline == null) return;

    const command_buffer = ctx.frames.command_buffers[ctx.frames.current_frame];

    c.vkCmdBindPipeline(command_buffer, c.VK_PIPELINE_BIND_POINT_GRAPHICS, ctx.pipeline_manager.cloud_pipeline);
    ctx.draw.terrain_pipeline_bound = false;

    const pc = CloudPushConstants{
        .view_proj = params.view_proj.data,
        .camera_pos = .{ params.cam_pos.x, params.cam_pos.y, params.cam_pos.z, params.cloud_height },
        .cloud_params = .{ params.cloud_coverage, params.cloud_scale, params.wind_offset_x, params.wind_offset_z },
        .sun_params = .{ params.sun_dir.x, params.sun_dir.y, params.sun_dir.z, params.sun_intensity },
        .fog_params = .{ params.fog_color.x, params.fog_color.y, params.fog_color.z, params.fog_density },
    };

    c.vkCmdPushConstants(command_buffer, ctx.pipeline_manager.cloud_pipeline_layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(CloudPushConstants), &pc);
}
