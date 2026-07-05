const std = @import("std");
const testing = std.testing;
const GpuBlockBuffer = @import("gpu_block_buffer.zig").GpuBlockBuffer;
const rhi = @import("engine-rhi").rhi;

/// Minimal mock `ResourceManager` for exercising `GpuBlockBuffer` without a GPU.
///
/// Only the buffer lifecycle hooks (`createBuffer`, `updateBuffer`, `destroyBuffer`)
/// are exercised by `GpuBlockBuffer`; the remaining `IResourceFactory` vtable entries
/// are stubbed so the `ResourceManager` can be constructed in tests.
const MockRm = struct {
    buffer_count: usize = 0,
    update_count: usize = 0,
    destroy_count: usize = 0,

    fn resourceManager(self: *MockRm) rhi.ResourceManager {
        return .{ .factory = .{
            .ptr = self,
            .vtable = &.{
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
        } };
    }

    fn createBuffer(ptr: *anyopaque, size: usize, usage: rhi.BufferUsage) rhi.RhiError!rhi.BufferHandle {
        _ = size;
        _ = usage;
        const self: *MockRm = @ptrCast(@alignCast(ptr));
        self.buffer_count += 1;
        return 1;
    }
    fn uploadBuffer(ptr: *anyopaque, handle: rhi.BufferHandle, data: []const u8) rhi.RhiError!void {
        _ = ptr;
        _ = handle;
        _ = data;
    }
    fn updateBuffer(ptr: *anyopaque, handle: rhi.BufferHandle, offset: usize, data: []const u8) rhi.RhiError!void {
        _ = handle;
        _ = offset;
        _ = data;
        const self: *MockRm = @ptrCast(@alignCast(ptr));
        self.update_count += 1;
    }
    fn destroyBuffer(ptr: *anyopaque, handle: rhi.BufferHandle) void {
        _ = handle;
        const self: *MockRm = @ptrCast(@alignCast(ptr));
        self.destroy_count += 1;
    }
    fn createTexture(ptr: *anyopaque, width: u32, height: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
        _ = ptr;
        _ = width;
        _ = height;
        _ = format;
        _ = config;
        _ = data;
        return error.Unknown;
    }
    fn createTexture3D(ptr: *anyopaque, width: u32, height: u32, depth: u32, format: rhi.TextureFormat, config: rhi.TextureConfig, data: ?[]const u8) rhi.RhiError!rhi.TextureHandle {
        _ = ptr;
        _ = width;
        _ = height;
        _ = depth;
        _ = format;
        _ = config;
        _ = data;
        return error.Unknown;
    }
    fn destroyTexture(ptr: *anyopaque, handle: rhi.TextureHandle) void {
        _ = ptr;
        _ = handle;
    }
    fn updateTexture(ptr: *anyopaque, handle: rhi.TextureHandle, data: []const u8) rhi.RhiError!void {
        _ = ptr;
        _ = handle;
        _ = data;
    }
    fn createShader(ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) rhi.RhiError!rhi.ShaderHandle {
        _ = ptr;
        _ = vertex_src;
        _ = fragment_src;
        return error.Unknown;
    }
    fn destroyShader(ptr: *anyopaque, handle: rhi.ShaderHandle) void {
        _ = ptr;
        _ = handle;
    }
    fn mapBuffer(ptr: *anyopaque, handle: rhi.BufferHandle) rhi.RhiError!?*anyopaque {
        _ = ptr;
        _ = handle;
        return null;
    }
    fn unmapBuffer(ptr: *anyopaque, handle: rhi.BufferHandle) void {
        _ = ptr;
        _ = handle;
    }
};

test "GpuBlockBuffer.getSlotForChunk returns allocated slot" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 16);
    defer buf.deinit();

    const slot = try buf.allocate(3, -7);
    try testing.expectEqual(slot, buf.getSlotForChunk(3, -7).?);
}

test "GpuBlockBuffer.getSlotForChunk returns null for unallocated chunk" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 16);
    defer buf.deinit();

    _ = try buf.allocate(1, 1);
    try testing.expectEqual(null, buf.getSlotForChunk(2, 2));
}

test "GpuBlockBuffer.getSlotForChunk distinguishes distinct chunks" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 16);
    defer buf.deinit();

    const a = try buf.allocate(0, 0);
    const b = try buf.allocate(0, 1);
    const c = try buf.allocate(1, 0);
    try testing.expect(a != b);
    try testing.expect(a != c);
    try testing.expect(b != c);

    try testing.expectEqual(a, buf.getSlotForChunk(0, 0).?);
    try testing.expectEqual(b, buf.getSlotForChunk(0, 1).?);
    try testing.expectEqual(c, buf.getSlotForChunk(1, 0).?);
}

test "GpuBlockBuffer.freeByChunk removes slot and returns it" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 16);
    defer buf.deinit();

    const slot = try buf.allocate(-4, 9);
    const freed = buf.freeByChunk(-4, 9);
    try testing.expectEqual(slot, freed.?);
    try testing.expectEqual(null, buf.getSlotForChunk(-4, 9));
    try testing.expectEqual(null, buf.freeByChunk(-4, 9));
}

test "GpuBlockBuffer.freeByChunk only frees the matching chunk" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 16);
    defer buf.deinit();

    _ = try buf.allocate(5, 5);
    const keep = try buf.allocate(5, 6);

    const freed = buf.freeByChunk(5, 5);
    try testing.expect(freed != null);

    try testing.expectEqual(keep, buf.getSlotForChunk(5, 6).?);
    try testing.expectEqual(null, buf.getSlotForChunk(5, 5));
}

test "GpuBlockBuffer.free by slot clears reverse lookup" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 16);
    defer buf.deinit();

    const slot = try buf.allocate(12, -3);
    buf.free(slot);
    try testing.expectEqual(null, buf.getSlotForChunk(12, -3));
    try testing.expectEqual(null, buf.freeByChunk(12, -3));
}

test "GpuBlockBuffer.free by invalid slot is a no-op" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 16);
    defer buf.deinit();

    _ = try buf.allocate(1, 1);
    buf.free(9999);
    try testing.expectEqual(@as(usize, 1), buf.allocatedCount());
}

test "GpuBlockBuffer reuses freed slot for reallocated chunk" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 4);
    defer buf.deinit();

    const slot = try buf.allocate(2, 2);
    _ = buf.freeByChunk(2, 2);
    const reused = try buf.allocate(2, 2);
    try testing.expectEqual(slot, reused);
    try testing.expectEqual(slot, buf.getSlotForChunk(2, 2).?);
}

test "GpuBlockBuffer keeps reverse index consistent after many alloc/free cycles" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 32);
    defer buf.deinit();

    var i: i32 = 0;
    while (i < 16) : (i += 1) {
        _ = try buf.allocate(i, -i);
    }
    _ = buf.freeByChunk(3, -3);
    _ = buf.freeByChunk(7, -7);

    try testing.expectEqual(null, buf.getSlotForChunk(3, -3));
    try testing.expectEqual(null, buf.getSlotForChunk(7, -7));

    var j: i32 = 0;
    while (j < 16) : (j += 1) {
        if (j == 3 or j == 7) continue;
        try testing.expect(buf.getSlotForChunk(j, -j) != null);
    }

    const re3 = try buf.allocate(3, -3);
    try testing.expectEqual(re3, buf.getSlotForChunk(3, -3).?);
}

test "GpuBlockBuffer.updateBlock hits RHI for allocated chunk" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 8);
    defer buf.deinit();

    _ = try buf.allocate(1, 1);
    try buf.updateBlock(1, 1, 0, 0, 0, 1);
    try testing.expectEqual(@as(usize, 1), mock.update_count);
}

test "GpuBlockBuffer.updateBlock skips RHI for unallocated chunk" {
    var mock = MockRm{};
    const buf = try GpuBlockBuffer.init(testing.allocator, mock.resourceManager(), 8);
    defer buf.deinit();

    try buf.updateBlock(99, 99, 0, 0, 0, 1);
    try testing.expectEqual(@as(usize, 0), mock.update_count);
}
