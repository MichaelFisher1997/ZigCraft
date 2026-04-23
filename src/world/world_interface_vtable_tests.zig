const std = @import("std");
const testing = std.testing;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const IChunkStorage = @import("chunk_storage.zig").IChunkStorage;
const ChunkKey = @import("chunk_storage.zig").ChunkKey;
const ChunkData = @import("chunk_storage.zig").ChunkData;

test "IChunkStorage interface count delegates to storage" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    _ = try storage.getOrCreate(0, 0);
    _ = try storage.getOrCreate(1, 1);

    const iface: IChunkStorage = storage.interface();
    try testing.expectEqual(@as(usize, 2), iface.count());
}

test "IChunkStorage interface get returns null for non-existent chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const iface: IChunkStorage = storage.interface();
    try testing.expectEqual(@as(?*ChunkData, null), iface.get(99, 99));
}

test "IChunkStorage interface get returns correct chunk via vtable" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const created = try storage.getOrCreate(7, 11);
    const iface: IChunkStorage = storage.interface();

    const retrieved = iface.get(7, 11);
    try testing.expect(retrieved != null);
    try testing.expectEqual(@as(*ChunkData, created), retrieved.?);
}

test "IChunkStorage interface get distinct positions" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data1 = try storage.getOrCreate(1, 2);
    const data2 = try storage.getOrCreate(3, 4);
    const iface: IChunkStorage = storage.interface();

    try testing.expectEqual(@as(*ChunkData, data1), iface.get(1, 2));
    try testing.expectEqual(@as(*ChunkData, data2), iface.get(3, 4));
    try testing.expectEqual(@as(?*ChunkData, null), iface.get(1, 4));
}

test "IChunkStorage interface totalVertexCount zero for empty storage" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const iface: IChunkStorage = storage.interface();
    try testing.expectEqual(@as(u64, 0), iface.totalVertexCount());
}

test "IChunkStorage interface totalVertexCount zero for fresh chunks" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    _ = try storage.getOrCreate(0, 0);
    _ = try storage.getOrCreate(1, 1);

    const iface: IChunkStorage = storage.interface();
    try testing.expectEqual(@as(u64, 0), iface.totalVertexCount());
}

test "IChunkStorage interface isChunkRenderable false for fresh chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    _ = try storage.getOrCreate(0, 0);
    const iface: IChunkStorage = storage.interface();

    try testing.expectEqual(false, iface.isChunkRenderable(0, 0));
}

test "IChunkStorage interface isChunkRenderable false for missing chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const iface: IChunkStorage = storage.interface();
    try testing.expectEqual(false, iface.isChunkRenderable(0, 0));
}

test "IChunkStorage count matches ChunkStorage.count()" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const iface: IChunkStorage = storage.interface();

    try testing.expectEqual(storage.count(), iface.count());

    _ = try storage.getOrCreate(0, 0);
    try testing.expectEqual(storage.count(), iface.count());

    _ = try storage.getOrCreate(-5, 10);
    try testing.expectEqual(storage.count(), iface.count());
}

test "IChunkStorage isChunkRenderable matches storage method result" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    _ = try storage.getOrCreate(0, 0);
    const iface: IChunkStorage = storage.interface();

    try testing.expectEqual(false, iface.isChunkRenderable(0, 0));
}
