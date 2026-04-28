const std = @import("std");
const testing = std.testing;
const worldToChunk = @import("chunk.zig").worldToChunk;
const worldToChunkFromFloat = @import("chunk.zig").worldToChunkFromFloat;
const worldToLocal = @import("chunk.zig").worldToLocal;

test "worldToChunk boundary at exactly chunk size" {
    const result = worldToChunk(16, 16);
    try testing.expectEqual(@as(i32, 1), result.chunk_x);
    try testing.expectEqual(@as(i32, 1), result.chunk_z);
}

test "worldToChunk one block before chunk boundary" {
    const result = worldToChunk(15, 15);
    try testing.expectEqual(@as(i32, 0), result.chunk_x);
    try testing.expectEqual(@as(i32, 0), result.chunk_z);
}

test "worldToChunkFromFloat at exactly chunk boundary" {
    const result = worldToChunkFromFloat(16.0, 16.0);
    try testing.expectEqual(@as(i32, 1), result.chunk_x);
    try testing.expectEqual(@as(i32, 1), result.chunk_z);
}

test "worldToChunkFromFloat just below chunk boundary" {
    const result = worldToChunkFromFloat(15.9999, 15.9999);
    try testing.expectEqual(@as(i32, 0), result.chunk_x);
    try testing.expectEqual(@as(i32, 0), result.chunk_z);
}

test "worldToLocal at chunk origin returns zero" {
    const result = worldToLocal(0, 0);
    try testing.expectEqual(@as(u32, 0), result.x);
    try testing.expectEqual(@as(u32, 0), result.z);
}

test "worldToLocal at end of chunk returns max" {
    const result = worldToLocal(15, 15);
    try testing.expectEqual(@as(u32, 15), result.x);
    try testing.expectEqual(@as(u32, 15), result.z);
}

test "worldToLocal chunk wrap at negative boundary" {
    const result = worldToLocal(-16, -16);
    try testing.expectEqual(@as(u32, 0), result.x);
    try testing.expectEqual(@as(u32, 0), result.z);
}

test "worldToLocal one block past boundary wraps correctly" {
    const result = worldToLocal(16, 16);
    try testing.expectEqual(@as(u32, 0), result.x);
    try testing.expectEqual(@as(u32, 0), result.z);
}

test "worldToLocal large negative coordinate maps correctly" {
    const result = worldToLocal(-1000, -1000);
    try testing.expectEqual(@as(u32, 8), result.x);
    try testing.expectEqual(@as(u32, 8), result.z);
}

test "worldToChunkFromFloat positive coordinates round down floor" {
    const result = worldToChunkFromFloat(100.7, 200.3);
    try testing.expectEqual(@as(i32, 6), result.chunk_x);
    try testing.expectEqual(@as(i32, 12), result.chunk_z);
}

test "worldToChunkFromFloat zero coordinates" {
    const result = worldToChunkFromFloat(0.0, 0.0);
    try testing.expectEqual(@as(i32, 0), result.chunk_x);
    try testing.expectEqual(@as(i32, 0), result.chunk_z);
}

test "worldToChunkFromFloat negative fractional coordinates" {
    const result = worldToChunkFromFloat(-0.5, -0.5);
    try testing.expectEqual(@as(i32, -1), result.chunk_x);
    try testing.expectEqual(@as(i32, -1), result.chunk_z);
}
