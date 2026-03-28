const std = @import("std");
const c = @import("../../../c.zig").c;
const log = @import("../../core/log.zig");
const Utils = @import("utils.zig");
const VulkanContext = @import("rhi_context_types.zig").VulkanContext;

pub fn captureScreenshot(ctx: *VulkanContext, path: []const u8) bool {
    const device = &ctx.vulkan_device;
    const vk = device.vk_device;

    if (ctx.swapchain.swapchain.images.items.len == 0) {
        log.log.err("screenshot: no swapchain images available", .{});
        return false;
    }

    const image_index = ctx.frames.current_image_index;
    const swapchain_image = ctx.swapchain.swapchain.images.items[image_index];
    const extent = ctx.swapchain.getExtent();
    const image_format = ctx.swapchain.getImageFormat();
    const width = extent.width;
    const height = extent.height;

    _ = c.vkDeviceWaitIdle(vk);

    const image_size: u64 = @as(u64, width) * height * 4;

    const staging = Utils.createVulkanBuffer(
        device,
        image_size,
        c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
        c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
    ) catch {
        log.log.err("screenshot: failed to create staging buffer", .{});
        return false;
    };
    defer {
        c.vkDestroyBuffer(vk, staging.buffer, null);
        c.vkFreeMemory(vk, staging.memory, null);
    }

    var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
    pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.queueFamilyIndex = device.graphics_family;
    pool_info.flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT;

    var command_pool: c.VkCommandPool = null;
    Utils.checkVk(c.vkCreateCommandPool(vk, &pool_info, null, &command_pool)) catch {
        log.log.err("screenshot: failed to create command pool", .{});
        return false;
    };
    defer c.vkDestroyCommandPool(vk, command_pool, null);

    var cmd_alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
    cmd_alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cmd_alloc_info.commandPool = command_pool;
    cmd_alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cmd_alloc_info.commandBufferCount = 1;

    var cmd_buffer: c.VkCommandBuffer = null;
    Utils.checkVk(c.vkAllocateCommandBuffers(vk, &cmd_alloc_info, &cmd_buffer)) catch {
        log.log.err("screenshot: failed to allocate command buffer", .{});
        return false;
    };

    var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
    begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    _ = c.vkBeginCommandBuffer(cmd_buffer, &begin_info);

    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = c.VK_ACCESS_MEMORY_READ_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.image = swapchain_image;
    barrier.subresourceRange = .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .baseMipLevel = 0,
        .levelCount = 1,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };

    c.vkCmdPipelineBarrier(
        cmd_buffer,
        c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );

    var region = std.mem.zeroes(c.VkBufferImageCopy);
    region.bufferOffset = 0;
    region.bufferRowLength = 0;
    region.bufferImageHeight = 0;
    region.imageSubresource = .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .mipLevel = 0,
        .baseArrayLayer = 0,
        .layerCount = 1,
    };
    region.imageOffset = .{ .x = 0, .y = 0, .z = 0 };
    region.imageExtent = .{ .width = width, .height = height, .depth = 1 };

    c.vkCmdCopyImageToBuffer(
        cmd_buffer,
        swapchain_image,
        c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
        staging.buffer,
        1,
        &region,
    );

    barrier.srcAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_MEMORY_READ_BIT;
    barrier.oldLayout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    barrier.newLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    c.vkCmdPipelineBarrier(
        cmd_buffer,
        c.VK_PIPELINE_STAGE_TRANSFER_BIT,
        c.VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,
        0,
        0,
        null,
        0,
        null,
        1,
        &barrier,
    );

    _ = c.vkEndCommandBuffer(cmd_buffer);

    var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
    fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    var fence: c.VkFence = null;
    Utils.checkVk(c.vkCreateFence(vk, &fence_info, null, &fence)) catch {
        log.log.err("screenshot: failed to create fence", .{});
        return false;
    };
    defer c.vkDestroyFence(vk, fence, null);

    var submit_info = std.mem.zeroes(c.VkSubmitInfo);
    submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit_info.commandBufferCount = 1;
    submit_info.pCommandBuffers = &cmd_buffer;

    Utils.checkVk(c.vkQueueSubmit(device.queue, 1, &submit_info, fence)) catch {
        log.log.err("screenshot: failed to submit command buffer", .{});
        return false;
    };
    _ = c.vkWaitForFences(vk, 1, &fence, c.VK_TRUE, std.math.maxInt(u64));

    const mapped_ptr = staging.mapped_ptr orelse {
        log.log.err("screenshot: staging buffer not mapped", .{});
        return false;
    };
    const bytes: [*]const u8 = @ptrCast(@alignCast(mapped_ptr));

    writePPM(bytes, width, height, path, image_format);

    return true;
}

fn writePPM(data: [*]const u8, width: u32, height: u32, path: []const u8, format: c.VkFormat) void {
    const file = std.fs.cwd().createFile(path, .{}) catch {
        log.log.err("screenshot: failed to create file '{s}'", .{path});
        return;
    };
    defer file.close();

    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "P6\n{d} {d}\n255\n", .{ width, height }) catch return;
    file.writeAll(header) catch return;

    const is_bgra = format == c.VK_FORMAT_B8G8R8A8_UNORM or format == c.VK_FORMAT_B8G8R8A8_SRGB;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        var row_buf: [4096 * 3]u8 = undefined;
        const row_bytes = width * 3;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src_offset: usize = (@as(usize, y) * width + x) * 4;
            const dst_offset: usize = x * 3;
            if (is_bgra) {
                row_buf[dst_offset] = data[src_offset + 2];
                row_buf[dst_offset + 1] = data[src_offset + 1];
                row_buf[dst_offset + 2] = data[src_offset];
            } else {
                row_buf[dst_offset] = data[src_offset];
                row_buf[dst_offset + 1] = data[src_offset + 1];
                row_buf[dst_offset + 2] = data[src_offset + 2];
            }
        }
        file.writeAll(row_buf[0..row_bytes]) catch return;
    }

    log.log.info("screenshot: saved {}x{} to '{s}'", .{ width, height, path });
}
