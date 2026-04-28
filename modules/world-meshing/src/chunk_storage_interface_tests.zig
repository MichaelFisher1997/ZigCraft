const std = @import("std");
const testing = std.testing;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const ChunkKey = @import("world-core").ChunkKey;
const IChunkStorage = @import("chunk_storage.zig").IChunkStorage;

test "ChunkStorage.init creates empty storage" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    try testing.expectEqual(@as(usize, 0), storage.count());
}

test "ChunkStorage.init next_job_token starts at 1" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    try testing.expectEqual(@as(u32, 1), storage.next_job_token);
}

test "ChunkStorage.getOrCreate creates new chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data = try storage.getOrCreate(5, -3);
    try testing.expectEqual(@as(i32, 5), data.chunk.chunk_x);
    try testing.expectEqual(@as(i32, -3), data.chunk.chunk_z);
    try testing.expectEqual(@as(usize, 1), storage.count());
}

test "ChunkStorage.getOrCreate returns existing chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data1 = try storage.getOrCreate(5, -3);
    const data2 = try storage.getOrCreate(5, -3);

    try testing.expect(data1 == data2);
    try testing.expectEqual(@as(usize, 1), storage.count());
}

test "ChunkStorage.getOrCreate assigns sequential job tokens" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data1 = try storage.getOrCreate(0, 0);
    const data2 = try storage.getOrCreate(1, 0);
    const data3 = try storage.getOrCreate(2, 0);

    try testing.expectEqual(@as(u32, 1), data1.chunk.job_token);
    try testing.expectEqual(@as(u32, 2), data2.chunk.job_token);
    try testing.expectEqual(@as(u32, 3), data3.chunk.job_token);
}

test "ChunkStorage.get returns chunk when exists" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    _ = try storage.getOrCreate(10, 20);
    const data = storage.get(10, 20);

    try testing.expect(data != null);
    try testing.expectEqual(@as(i32, 10), data.?.chunk.chunk_x);
    try testing.expectEqual(@as(i32, 20), data.?.chunk.chunk_z);
}

test "ChunkStorage.get returns null when not exists" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data = storage.get(999, 999);
    try testing.expectEqual(null, data);
}

test "ChunkStorage.totalVertexCount with no chunks" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    try testing.expectEqual(@as(u64, 0), storage.totalVertexCount());
}

test "ChunkStorage interface returns correct count" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    _ = try storage.getOrCreate(0, 0);
    _ = try storage.getOrCreate(1, 0);

    const iface = storage.interface();
    try testing.expectEqual(@as(usize, 2), iface.count());
}

test "ChunkStorage interface get returns chunk via vtable" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    _ = try storage.getOrCreate(42, 99);
    const iface = storage.interface();

    const data = iface.get(42, 99);
    try testing.expect(data != null);
    try testing.expectEqual(@as(i32, 42), data.?.chunk.chunk_x);
    try testing.expectEqual(@as(i32, 99), data.?.chunk.chunk_z);
}

test "ChunkStorage interface get returns null for missing chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const iface = storage.interface();
    const data = iface.get(999, 999);
    try testing.expectEqual(null, data);
}

test "ChunkStorage multiple chunks at different positions" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    try testing.expectEqual(@as(usize, 0), storage.count());

    _ = try storage.getOrCreate(0, 0);
    try testing.expectEqual(@as(usize, 1), storage.count());

    _ = try storage.getOrCreate(-10, 5);
    try testing.expectEqual(@as(usize, 2), storage.count());

    _ = try storage.getOrCreate(100, -200);
    try testing.expectEqual(@as(usize, 3), storage.count());

    const result = storage.get(-10, 5);
    try testing.expect(result != null);
}

test "ChunkStorage interface isChunkRenderable returns false for fresh chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    _ = try storage.getOrCreate(0, 0);
    const iface = storage.interface();

    const is_renderable = iface.isChunkRenderable(0, 0);
    try testing.expect(!is_renderable);
}

test "ChunkKey eql same x same z returns true" {
    const a = ChunkKey{ .x = 3, .z = 7 };
    const b = ChunkKey{ .x = 3, .z = 7 };
    try testing.expect(a.eql(b));
}

test "ChunkKey eql different x same z" {
    const a = ChunkKey{ .x = 3, .z = 7 };
    const b = ChunkKey{ .x = 5, .z = 7 };
    try testing.expect(!a.eql(b));
}

test "ChunkKey eql same x different z" {
    const a = ChunkKey{ .x = 3, .z = 7 };
    const b = ChunkKey{ .x = 3, .z = 9 };
    try testing.expect(!a.eql(b));
}
