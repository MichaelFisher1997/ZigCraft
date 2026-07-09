const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const log = @import("engine-core").log;
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

    const is_headless = ctx.swapchain.swapchain.headless_mode;
    const src_layout: c.VkImageLayout = if (is_headless) c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL else c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;
    const dst_layout = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;

    var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
    barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.srcAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.dstAccessMask = c.VK_ACCESS_TRANSFER_READ_BIT;
    barrier.oldLayout = src_layout;
    barrier.newLayout = dst_layout;
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
    barrier.dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_READ_BIT | c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
    barrier.oldLayout = dst_layout;
    barrier.newLayout = src_layout;

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

    device.submitGuarded(submit_info, fence) catch |err| {
        log.log.err("screenshot: vkQueueSubmit failed: {}", .{err});
        return false;
    };
    const fence_result = c.vkWaitForFences(vk, 1, &fence, c.VK_TRUE, 5_000_000_000);
    if (fence_result != c.VK_SUCCESS) {
        log.log.err("screenshot: fence wait failed or timed out ({})", .{fence_result});
        return false;
    }

    const mapped_ptr = staging.mapped_ptr orelse {
        log.log.err("screenshot: staging buffer not mapped", .{});
        return false;
    };
    const bytes: [*]const u8 = @ptrCast(@alignCast(mapped_ptr));

    return writeImage(bytes, width, height, path, image_format);
}

const ScreenshotFormat = enum {
    png,
    jpeg,
    gif,
    webp,
};

fn writeImage(data: [*]const u8, width: u32, height: u32, path: []const u8, format: c.VkFormat) bool {
    const output_format = detectScreenshotFormat(path) orelse {
        log.log.err("screenshot: unsupported image path '{s}' (use .png, .jpg, .jpeg, .gif, or .webp)", .{path});
        return false;
    };

    return switch (output_format) {
        .png => writePNG(data, width, height, path, format),
        .jpeg, .gif, .webp => unsupportedEncoder(path, output_format),
    };
}

fn unsupportedEncoder(path: []const u8, format: ScreenshotFormat) bool {
    log.log.err("screenshot: {s} output is allowed but not implemented yet for '{s}'; use .png", .{ @tagName(format), path });
    return false;
}

fn detectScreenshotFormat(path: []const u8) ?ScreenshotFormat {
    if (hasExtension(path, ".png")) return .png;
    if (hasExtension(path, ".jpg") or hasExtension(path, ".jpeg")) return .jpeg;
    if (hasExtension(path, ".gif")) return .gif;
    if (hasExtension(path, ".webp")) return .webp;
    return null;
}

fn hasExtension(path: []const u8, ext: []const u8) bool {
    if (path.len < ext.len) return false;
    const tail = path[path.len - ext.len ..];
    for (tail, ext) |a, b| {
        if (std.ascii.toLower(a) != b) return false;
    }
    return true;
}

fn writePNG(data: [*]const u8, width: u32, height: u32, path: []const u8, format: c.VkFormat) bool {
    if (width > 16384) {
        log.log.err("screenshot: width {} exceeds max supported 16384", .{width});
        return false;
    }

    const allocator = std.heap.page_allocator;
    const row_bytes: usize = @as(usize, width) * 3;
    const raw_size: usize = (@as(usize, height) * (row_bytes + 1));
    const raw = allocator.alloc(u8, raw_size) catch {
        log.log.err("screenshot: failed to allocate PNG scanlines", .{});
        return false;
    };
    defer allocator.free(raw);

    const is_bgra = format == c.VK_FORMAT_B8G8R8A8_UNORM or format == c.VK_FORMAT_B8G8R8A8_SRGB;
    const needs_srgb_encode = format == c.VK_FORMAT_B8G8R8A8_UNORM or format == c.VK_FORMAT_R8G8B8A8_UNORM;
    const red_index: usize = if (is_bgra) 2 else 0;
    const blue_index: usize = if (is_bgra) 0 else 2;

    var y: u32 = 0;
    while (y < height) : (y += 1) {
        const row_start = @as(usize, y) * (row_bytes + 1);
        raw[row_start] = 0;
        var x: u32 = 0;
        while (x < width) : (x += 1) {
            const src_offset: usize = (@as(usize, y) * width + x) * 4;
            const dst_offset: usize = row_start + 1 + @as(usize, x) * 3;
            const red = data[src_offset + red_index];
            const green = data[src_offset + 1];
            const blue = data[src_offset + blue_index];
            raw[dst_offset] = if (needs_srgb_encode) linearByteToSrgb(red) else red;
            raw[dst_offset + 1] = if (needs_srgb_encode) linearByteToSrgb(green) else green;
            raw[dst_offset + 2] = if (needs_srgb_encode) linearByteToSrgb(blue) else blue;
        }
    }

    const block_count = (raw_size + 65534) / 65535;
    const zlib_capacity = 2 + raw_size + block_count * 5 + 4;
    const zlib = allocator.alloc(u8, zlib_capacity) catch {
        log.log.err("screenshot: failed to allocate PNG zlib stream", .{});
        return false;
    };
    defer allocator.free(zlib);

    const zlib_len = writeStoredZlib(zlib, raw);

    const file = fs.cwd().createFile(path, .{}) catch {
        log.log.err("screenshot: failed to create file '{s}'", .{path});
        return false;
    };
    defer file.close();

    file.writeAll(&.{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }) catch return false;

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8;
    ihdr[9] = 2;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;

    writePngChunk(file, "IHDR", &ihdr) catch return false;
    writePngChunk(file, "sRGB", &.{0}) catch return false;
    writePngChunk(file, "IDAT", zlib[0..zlib_len]) catch return false;
    writePngChunk(file, "IEND", &.{}) catch return false;

    log.log.info("screenshot: saved {}x{} PNG to '{s}'", .{ width, height, path });
    return true;
}

fn linearByteToSrgb(value: u8) u8 {
    const linear = @as(f32, @floatFromInt(value)) / 255.0;
    const encoded = if (linear <= 0.0031308)
        linear * 12.92
    else
        1.055 * std.math.pow(f32, linear, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@round(std.math.clamp(encoded, 0.0, 1.0) * 255.0));
}

test "linear screenshot bytes encode to sRGB" {
    try std.testing.expectEqual(@as(u8, 0), linearByteToSrgb(0));
    try std.testing.expectEqual(@as(u8, 255), linearByteToSrgb(255));
    try std.testing.expectApproxEqAbs(@as(f32, 118.0), @as(f32, @floatFromInt(linearByteToSrgb(46))), 1.0);
}

fn writeStoredZlib(dest: []u8, raw: []const u8) usize {
    var out: usize = 0;
    dest[out] = 0x78;
    out += 1;
    dest[out] = 0x01;
    out += 1;

    var offset: usize = 0;
    while (offset < raw.len) {
        const remaining = raw.len - offset;
        const len: u16 = @intCast(@min(remaining, 65535));
        const block_len: usize = @intCast(len);
        const final_block = offset + block_len == raw.len;
        dest[out] = if (final_block) 0x01 else 0x00;
        out += 1;
        std.mem.writeInt(u16, dest[out..][0..2], len, .little);
        out += 2;
        std.mem.writeInt(u16, dest[out..][0..2], ~len, .little);
        out += 2;
        @memcpy(dest[out..][0..block_len], raw[offset..][0..block_len]);
        out += block_len;
        offset += block_len;
    }

    std.mem.writeInt(u32, dest[out..][0..4], adler32(raw), .big);
    out += 4;
    return out;
}

fn writePngChunk(file: anytype, chunk_type: []const u8, payload: []const u8) !void {
    std.debug.assert(chunk_type.len == 4);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .big);
    try file.writeAll(&len_buf);
    try file.writeAll(chunk_type);
    try file.writeAll(payload);

    var crc_buf: [4]u8 = undefined;
    const crc = pngCrc(chunk_type, payload);
    std.mem.writeInt(u32, &crc_buf, crc, .big);
    try file.writeAll(&crc_buf);
}

fn pngCrc(chunk_type: []const u8, payload: []const u8) u32 {
    var crc: u32 = 0xFFFF_FFFF;
    crc = updateCrc(crc, chunk_type);
    crc = updateCrc(crc, payload);
    return crc ^ 0xFFFF_FFFF;
}

fn updateCrc(initial: u32, bytes: []const u8) u32 {
    var crc = initial;
    for (bytes) |byte| {
        crc ^= byte;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            const mask: u32 = if ((crc & 1) != 0) 0xEDB8_8320 else 0;
            crc = (crc >> 1) ^ mask;
        }
    }
    return crc;
}

fn adler32(bytes: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (bytes) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}
