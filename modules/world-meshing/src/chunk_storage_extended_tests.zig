const std = @import("std");
const testing = std.testing;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const IChunkStorage = @import("chunk_storage.zig").IChunkStorage;

test "ChunkStorage.getOrCreate idempotent" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const data1 = try storage.getOrCreate(0, 0);
    const data2 = try storage.getOrCreate(0, 0);
    try testing.expect(data1 == data2);
    try testing.expectEqual(@as(usize, 1), storage.count());
}

test "ChunkStorage.getOrCreate distinct positions" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const data1 = try storage.getOrCreate(0, 0);
    const data2 = try storage.getOrCreate(1, 0);
    const data3 = try storage.getOrCreate(0, 1);
    try testing.expect(data1 != data2);
    try testing.expect(data2 != data3);
    try testing.expectEqual(@as(usize, 3), storage.count());
}

test "ChunkStorage.getOrCreate negative coordinates" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const data = try storage.getOrCreate(-5, -10);
    try testing.expectEqual(@as(i32, -5), data.chunk.chunk_x);
    try testing.expectEqual(@as(i32, -10), data.chunk.chunk_z);
}

test "ChunkStorage interface returns wrapper" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const iface = storage.interface();
    try testing.expectEqual(@as(usize, 0), iface.count());
}

test "ChunkStorage interface.get returns null for missing" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const iface = storage.interface();
    try testing.expectEqual(null, iface.get(99, 99));
}

test "ChunkStorage interface.get returns data after create" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    _ = try storage.getOrCreate(42, -7);
    const iface = storage.interface();
    const data = iface.get(42, -7);
    try testing.expect(data != null);
    try testing.expectEqual(@as(i32, 42), data.?.chunk.chunk_x);
    try testing.expectEqual(@as(i32, -7), data.?.chunk.chunk_z);
}

test "ChunkStorage interface.totalVertexCount with no meshes" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    _ = try storage.getOrCreate(0, 0);
    _ = try storage.getOrCreate(1, 1);
    const iface = storage.interface();
    try testing.expectEqual(@as(u64, 0), iface.totalVertexCount());
}

test "ChunkStorage interface.isChunkRenderable false for missing" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const iface = storage.interface();
    try testing.expectEqual(false, iface.isChunkRenderable(0, 0));
}

test "ChunkStorage interface.isChunkRenderable false for new chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    _ = try storage.getOrCreate(0, 0);
    const iface = storage.interface();
    try testing.expectEqual(false, iface.isChunkRenderable(0, 0));
}

test "ChunkStorage next_job_token increments on create" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    try testing.expectEqual(@as(u32, 1), storage.next_job_token);
    _ = try storage.getOrCreate(0, 0);
    try testing.expectEqual(@as(u32, 2), storage.next_job_token);
    _ = try storage.getOrCreate(1, 0);
    try testing.expectEqual(@as(u32, 3), storage.next_job_token);
}

test "ChunkStorage created chunk has correct job_token" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const data1 = try storage.getOrCreate(0, 0);
    try testing.expectEqual(@as(u32, 1), data1.chunk.job_token);
    const data2 = try storage.getOrCreate(1, 0);
    try testing.expectEqual(@as(u32, 2), data2.chunk.job_token);
}
