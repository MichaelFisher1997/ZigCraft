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
