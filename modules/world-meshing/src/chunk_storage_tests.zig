const std = @import("std");
const testing = std.testing;
const ChunkKey = @import("world-core").ChunkKey;

test "ChunkKey.hash positive coordinates" {
    const key = ChunkKey{ .x = 5, .z = 10 };
    const h = key.hash();
    try testing.expect(h != 0);
}

test "ChunkKey.hash negative coordinates" {
    const key = ChunkKey{ .x = -5, .z = -10 };
    const h = key.hash();
    try testing.expect(h != 0);
}

test "ChunkKey.hash zero coordinates" {
    const key = ChunkKey{ .x = 0, .z = 0 };
    const h = key.hash();
    try testing.expect(h == 0);
}

test "ChunkKey.hash deterministic" {
    const key = ChunkKey{ .x = 42, .z = -17 };
    const h1 = key.hash();
    const h2 = key.hash();
    try testing.expectEqual(h1, h2);
}

test "ChunkKey.hash different positions differ" {
    const key1 = ChunkKey{ .x = 1, .z = 0 };
    const key2 = ChunkKey{ .x = 0, .z = 1 };
    try testing.expect(key1.hash() != key2.hash());
}

test "ChunkKey.eql identical keys" {
    const a = ChunkKey{ .x = 3, .z = 7 };
    const b = ChunkKey{ .x = 3, .z = 7 };
    try testing.expect(a.eql(b));
}

test "ChunkKey.eql different keys" {
    const a = ChunkKey{ .x = 3, .z = 7 };
    const b = ChunkKey{ .x = 7, .z = 3 };
    try testing.expect(!a.eql(b));
}

test "ChunkKey eql is reflexive" {
    var key = ChunkKey{ .x = 100, .z = -50 };
    try testing.expect(key.eql(key));
}
