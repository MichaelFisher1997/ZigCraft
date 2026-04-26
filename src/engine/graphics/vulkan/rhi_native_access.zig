pub fn getNativeSkyPipeline(ctx: anytype) u64 {
    return @intFromPtr(ctx.pipeline_manager.sky_pipeline);
}

pub fn getNativeSkyPipelineLayout(ctx: anytype) u64 {
    return @intFromPtr(ctx.pipeline_manager.sky_pipeline_layout);
}

pub fn getNativeWaterPipeline(ctx: anytype) u64 {
    return @intFromPtr(ctx.water_system.water_pipeline);
}

pub fn getNativeWaterPipelineLayout(ctx: anytype) u64 {
    return @intFromPtr(ctx.water_system.water_pipeline_layout);
}

pub fn getNativeMainDescriptorSet(ctx: anytype) u64 {
    return @intFromPtr(ctx.descriptors.descriptor_sets[ctx.frames.current_frame]);
}

pub fn getNativeCommandBuffer(ctx: anytype) u64 {
    return @intFromPtr(ctx.frames.command_buffers[ctx.frames.current_frame]);
}

pub fn getNativeSwapchainExtent(ctx: anytype) [2]u32 {
    const extent = ctx.swapchain.getExtent();
    return .{ extent.width, extent.height };
}

pub fn getNativeDevice(ctx: anytype) u64 {
    return @intFromPtr(ctx.vulkan_device.vk_device);
}
