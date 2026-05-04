const std = @import("std");
const testing = std.testing;
const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;
const Chunk = @import("world-core").Chunk;

test "getBlockCross cross-chunk east neighbor returns neighbor block" {
    var chunk = Chunk.init(0, 0);
    var east = Chunk.init(1, 0);
    east.setBlock(0, 64, 8, .glowstone);
    const neighbors = NeighborChunks{ .east = &east };
    try testing.expectEqual(.glowstone, boundary.getBlockCross(&chunk, neighbors, 16, 64, 8));
}

test "getBlockCross cross-chunk north neighbor returns neighbor block" {
    var chunk = Chunk.init(0, 1);
    var north = Chunk.init(0, 0);
    north.setBlock(8, 64, 15, .water);
    const neighbors = NeighborChunks{ .north = &north };
    try testing.expectEqual(.water, boundary.getBlockCross(&chunk, neighbors, 8, 64, -1));
}

test "getBlockCross null neighbor returns air" {
    var chunk = Chunk.init(0, 0);
    try testing.expectEqual(.air, boundary.getBlockCross(&chunk, .empty, 16, 64, 8));
    try testing.expectEqual(.air, boundary.getBlockCross(&chunk, .empty, -1, 64, 8));
    try testing.expectEqual(.air, boundary.getBlockCross(&chunk, .empty, 8, 64, 16));
}

test "getEntranceBounceCross cross-chunk west neighbor returns neighbor value" {
    var chunk = Chunk.init(1, 0);
    var west = Chunk.init(0, 0);
    west.setEntranceBounce(15, 64, 8, 5);
    const neighbors = NeighborChunks{ .west = &west };
    try testing.expectEqual(@as(u4, 5), boundary.getEntranceBounceCross(&chunk, neighbors, -1, 64, 8));
}

test "getEntranceBounceCross out of Y range returns zero" {
    var chunk = Chunk.init(0, 0);
    try testing.expectEqual(@as(u4, 0), boundary.getEntranceBounceCross(&chunk, .empty, 5, -1, 10));
    try testing.expectEqual(@as(u4, 0), boundary.getEntranceBounceCross(&chunk, .empty, 5, 256, 10));
}

test "getEntranceDirCross cross-chunk south neighbor returns neighbor value" {
    var chunk = Chunk.init(0, 0);
    var south = Chunk.init(0, 1);
    south.setEntranceDir(8, 64, 0, 99);
    const neighbors = NeighborChunks{ .south = &south };
    try testing.expectEqual(@as(u8, 99), boundary.getEntranceDirCross(&chunk, neighbors, 8, 64, 16));
}

test "getEntranceDirCross null neighbor on boundary returns zero" {
    var chunk = Chunk.init(0, 0);
    try testing.expectEqual(@as(u8, 0), boundary.getEntranceDirCross(&chunk, .empty, 16, 64, 8));
    try testing.expectEqual(@as(u8, 0), boundary.getEntranceDirCross(&chunk, .empty, -1, 64, 8));
}
