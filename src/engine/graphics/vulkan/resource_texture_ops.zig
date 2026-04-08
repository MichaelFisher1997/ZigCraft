const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const log = @import("../../core/log.zig");
const Utils = @import("utils.zig");
const transfer_queue = @import("transfer_queue.zig");

pub fn createTexture(self: anytype, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
    const vk_format: c.VkFormat = switch (format) {
        .rgba => c.VK_FORMAT_R8G8B8A8_UNORM,
        .rgba_srgb => c.VK_FORMAT_R8G8B8A8_SRGB,
        .rgb => c.VK_FORMAT_R8G8B8_UNORM,
        .red => c.VK_FORMAT_R8_UNORM,
        .depth => c.VK_FORMAT_D32_SFLOAT,
        .rgba32f => c.VK_FORMAT_R32G32B32A32_SFLOAT,
    };

    const mip_levels: u32 = if (config.generate_mipmaps and format != .depth)
        @as(u32, @intFromFloat(@floor(std.math.log2(@as(f32, @floatFromInt(@max(width, height))))))) + 1
    else
        1;

    const aspect_mask: c.VkImageAspectFlags = if (format == .depth)
        c.VK_IMAGE_ASPECT_DEPTH_BIT
    else
        c.VK_IMAGE_ASPECT_COLOR_BIT;

    var usage_flags: c.VkImageUsageFlags = if (format == .depth)
        c.VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT
    else
        c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;

    if (mip_levels > 1) usage_flags |= c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT;
    if (config.is_render_target) usage_flags |= c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    if (format == .rgba32f) usage_flags |= c.VK_IMAGE_USAGE_STORAGE_BIT;

    var staging_offset: u64 = 0;
    var staging_slice: ?transfer_queue.StagingSlice = null;
    if (data_opt) |data| {
        staging_slice = self.staging_ring.allocate(data.len, self.current_frame_index) orelse return error.OutOfMemory;
        staging_offset = staging_slice.?.buffer_offset;
    }

    const device = self.vulkan_device.vk_device;

    var image: c.VkImage = null;
    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_2D;
    image_info.extent.width = width;
    image_info.extent.height = height;
    image_info.extent.depth = 1;
    image_info.mipLevels = mip_levels;
    image_info.arrayLayers = 1;
    image_info.format = vk_format;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    image_info.usage = usage_flags;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    try Utils.checkVk(c.vkCreateImage(device, &image_info, null, &image));
    errdefer c.vkDestroyImage(device, image, null);

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(device, image, &mem_reqs);

    var memory: c.VkDeviceMemory = null;
    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = try Utils.findMemoryType(self.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

    try Utils.checkVk(c.vkAllocateMemory(device, &alloc_info, null, &memory));
    errdefer c.vkFreeMemory(device, memory, null);

    try Utils.checkVk(c.vkBindImageMemory(device, image, memory, 0));

    if (data_opt) |data| {
        if (staging_slice == null) return error.OutOfMemory;
        const slice = staging_slice.?;
        @memcpy(slice.ptr[0..data.len], data);

        const transfer_cb = try self.prepareTransfer();

        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = aspect_mask;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = mip_levels;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;

        c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.bufferOffset = staging_offset;
        region.imageSubresource.aspectMask = aspect_mask;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = .{ .width = width, .height = height, .depth = 1 };

        c.vkCmdCopyBufferToImage(transfer_cb, self.staging_ring.buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        if (mip_levels > 1) {
            var mip_width: i32 = @intCast(width);
            var mip_height: i32 = @intCast(height);

            for (1..mip_levels) |i| {
                barrier.subresourceRange.baseMipLevel = @intCast(i - 1);
                barrier.subresourceRange.levelCount = 1;
                barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
                barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;

                c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, null, 0, null, 1, &barrier);

                var blit = std.mem.zeroes(c.VkImageBlit);
                blit.srcOffsets[0] = .{ .x = 0, .y = 0, .z = 0 };
                blit.srcOffsets[1] = .{ .x = mip_width, .y = mip_height, .z = 1 };
                blit.srcSubresource.aspectMask = aspect_mask;
                blit.srcSubresource.mipLevel = @intCast(i - 1);
                blit.srcSubresource.baseArrayLayer = 0;
                blit.srcSubresource.layerCount = 1;

                const next_width = if (mip_width > 1) @divFloor(mip_width, 2) else 1;
                const next_height = if (mip_height > 1) @divFloor(mip_height, 2) else 1;

                blit.dstOffsets[0] = .{ .x = 0, .y = 0, .z = 0 };
                blit.dstOffsets[1] = .{ .x = next_width, .y = next_height, .z = 1 };
                blit.dstSubresource.aspectMask = aspect_mask;
                blit.dstSubresource.mipLevel = @intCast(i);
                blit.dstSubresource.baseArrayLayer = 0;
                blit.dstSubresource.layerCount = 1;

                c.vkCmdBlitImage(transfer_cb, image, c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &blit, c.VK_FILTER_LINEAR);

                barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
                barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
                barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
                barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
                c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);

                if (mip_width > 1) mip_width = @divFloor(mip_width, 2);
                if (mip_height > 1) mip_height = @divFloor(mip_height, 2);
            }

            barrier.subresourceRange.baseMipLevel = @intCast(mip_levels - 1);
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
        } else {
            barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
            barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
            barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
            c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
        }
    } else {
        const transfer_cb = try self.prepareTransfer();

        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = aspect_mask;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = mip_levels;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;
        barrier.srcAccessMask = 0;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;

        c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
    }

    var view: c.VkImageView = null;
    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = vk_format;
    view_info.subresourceRange.aspectMask = aspect_mask;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = mip_levels;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;

    const sampler = try Utils.createSampler(self.vulkan_device, config, mip_levels, self.vulkan_device.max_anisotropy);
    errdefer c.vkDestroySampler(device, sampler, null);

    try Utils.checkVk(c.vkCreateImageView(device, &view_info, null, &view));
    errdefer c.vkDestroyImageView(device, view, null);

    const handle = self.next_texture_handle;
    self.next_texture_handle += 1;
    try self.textures.put(handle, .{
        .image = image,
        .memory = memory,
        .view = view,
        .sampler = sampler,
        .width = width,
        .height = height,
        .depth = 1,
        .format = format,
        .config = config,
        .is_3d = false,
        .is_owned = true,
    });

    return handle;
}

/// Creates a 3D texture resource.
/// Note: `config.generate_mipmaps` is currently forced off for 3D textures.
/// Other config parameters (filtering, wrapping, render-target flag) are respected.
pub fn createTexture3D(self: anytype, width: u32, height: u32, depth: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data_opt: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
    var texture_config = config;
    if (texture_config.generate_mipmaps) {
        log.log.warn("3D texture mipmaps are not supported yet; disabling generate_mipmaps", .{});
        texture_config.generate_mipmaps = false;
    }

    const vk_format: c.VkFormat = switch (format) {
        .rgba => c.VK_FORMAT_R8G8B8A8_UNORM,
        .rgba_srgb => c.VK_FORMAT_R8G8B8A8_SRGB,
        .rgb => c.VK_FORMAT_R8G8B8_UNORM,
        .red => c.VK_FORMAT_R8_UNORM,
        .depth => c.VK_FORMAT_D32_SFLOAT,
        .rgba32f => c.VK_FORMAT_R32G32B32A32_SFLOAT,
    };

    if (format == .depth) return error.FormatNotSupported;
    if (depth == 0) return error.InvalidState;

    var usage_flags: c.VkImageUsageFlags = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT;
    if (format == .rgba32f) usage_flags |= c.VK_IMAGE_USAGE_STORAGE_BIT;
    if (texture_config.is_render_target) usage_flags |= c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;

    var staging_offset: u64 = 0;
    var staging_slice_3d: ?transfer_queue.StagingSlice = null;
    if (data_opt) |data| {
        staging_slice_3d = self.staging_ring.allocate(data.len, self.current_frame_index) orelse return error.OutOfMemory;
        staging_offset = staging_slice_3d.?.buffer_offset;
    }

    const device = self.vulkan_device.vk_device;

    var image: c.VkImage = null;
    var image_info = std.mem.zeroes(c.VkImageCreateInfo);
    image_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    image_info.imageType = c.VK_IMAGE_TYPE_3D;
    image_info.extent.width = width;
    image_info.extent.height = height;
    image_info.extent.depth = depth;
    image_info.mipLevels = 1;
    image_info.arrayLayers = 1;
    image_info.format = vk_format;
    image_info.tiling = c.VK_IMAGE_TILING_OPTIMAL;
    image_info.initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    image_info.usage = usage_flags;
    image_info.samples = c.VK_SAMPLE_COUNT_1_BIT;
    image_info.sharingMode = c.VK_SHARING_MODE_EXCLUSIVE;

    try Utils.checkVk(c.vkCreateImage(device, &image_info, null, &image));
    errdefer c.vkDestroyImage(device, image, null);

    var mem_reqs: c.VkMemoryRequirements = undefined;
    c.vkGetImageMemoryRequirements(device, image, &mem_reqs);

    var memory: c.VkDeviceMemory = null;
    var alloc_info = std.mem.zeroes(c.VkMemoryAllocateInfo);
    alloc_info.sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_reqs.size;
    alloc_info.memoryTypeIndex = try Utils.findMemoryType(self.vulkan_device.physical_device, mem_reqs.memoryTypeBits, c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);
    try Utils.checkVk(c.vkAllocateMemory(device, &alloc_info, null, &memory));
    errdefer c.vkFreeMemory(device, memory, null);
    try Utils.checkVk(c.vkBindImageMemory(device, image, memory, 0));

    const transfer_cb = try self.prepareTransfer();
    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = if (data_opt != null) c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL else c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
    barrier.image = image;
    barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.baseMipLevel = 0;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.baseArrayLayer = 0;
    barrier.subresourceRange.layerCount = 1;
    barrier.srcAccessMask = 0;
    barrier.dstAccessMask = if (data_opt != null) c.VK_ACCESS_TRANSFER_WRITE_BIT else c.VK_ACCESS_SHADER_READ_BIT;

    c.vkCmdPipelineBarrier(
        transfer_cb,
        c.VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT,
        if (data_opt != null) c.VK_PIPELINE_STAGE_TRANSFER_BIT else c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );

    if (data_opt) |data| {
        if (staging_slice_3d == null) return error.OutOfMemory;
        const slice = staging_slice_3d.?;
        @memcpy(slice.ptr[0..data.len], data);

        var region = std.mem.zeroes(c.VkBufferImageCopy);
        region.bufferOffset = staging_offset;
        region.imageSubresource.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        region.imageSubresource.layerCount = 1;
        region.imageExtent = .{ .width = width, .height = height, .depth = depth };
        c.vkCmdCopyBufferToImage(transfer_cb, self.staging_ring.buffer, image, c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

        barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
        barrier.newLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(transfer_cb, c.VK_PIPELINE_STAGE_TRANSFER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, 0, 0, null, 0, null, 1, &barrier);
    }

    var view: c.VkImageView = null;
    var view_info = std.mem.zeroes(c.VkImageViewCreateInfo);
    view_info.sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = image;
    view_info.viewType = c.VK_IMAGE_VIEW_TYPE_3D;
    view_info.format = vk_format;
    view_info.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
    view_info.subresourceRange.baseMipLevel = 0;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.baseArrayLayer = 0;
    view_info.subresourceRange.layerCount = 1;

    const sampler = try Utils.createSampler(self.vulkan_device, texture_config, 1, self.vulkan_device.max_anisotropy);
    errdefer c.vkDestroySampler(device, sampler, null);

    try Utils.checkVk(c.vkCreateImageView(device, &view_info, null, &view));
    errdefer c.vkDestroyImageView(device, view, null);

    const handle = self.next_texture_handle;
    self.next_texture_handle += 1;
    try self.textures.put(handle, .{
        .image = image,
        .memory = memory,
        .view = view,
        .sampler = sampler,
        .width = width,
        .height = height,
        .depth = depth,
        .format = format,
        .config = texture_config,
        .is_3d = true,
        .is_owned = true,
    });

    return handle;
}
