const std = @import("std");
const testing = std.testing;
const world_core = @import("world-core");
const NeighborChunks = @import("boundary.zig").NeighborChunks;
const isEmittingSubchunk = @import("boundary.zig").isEmittingSubchunk;
const getBlockCross = @import("boundary.zig").getBlockCross;
const getLightCross = @import("boundary.zig").getLightCross;
const getEntranceBounceCross = @import("boundary.zig").getEntranceBounceCross;
const getEntranceDirCross = @import("boundary.zig").getEntranceDirCross;
const getBiomeAt = @import("boundary.zig").getBiomeAt;
const Face = world_core.Face;
const Chunk = world_core.Chunk;
const BlockType = world_core.BlockType;
const Biome = world_core.Biome;

test "NeighborChunks.empty has all null neighbors" {
    const empty = NeighborChunks.empty;
    try testing.expectEqual(null, empty.north);
    try testing.expectEqual(null, empty.south);
    try testing.expectEqual(null, empty.east);
    try testing.expectEqual(null, empty.west);
}

test "getBlockCross returns current chunk block in bounds" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    const neighbors = NeighborChunks.empty;
    try testing.expectEqual(BlockType.stone, getBlockCross(&chunk, neighbors, 8, 64, 8));
}

test "getBlockCross returns air for west boundary without neighbor" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    const neighbors = NeighborChunks.empty;
    try testing.expectEqual(BlockType.air, getBlockCross(&chunk, neighbors, -1, 64, 8));
}

test "getBlockCross returns air for east boundary without neighbor" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    const neighbors = NeighborChunks.empty;
    try testing.expectEqual(BlockType.air, getBlockCross(&chunk, neighbors, 16, 64, 8));
}

test "getBlockCross wraps to west neighbor on x boundary" {
    var chunk = Chunk.init(0, 0);
    var west_chunk = Chunk.init(-1, 0);
    west_chunk.setBlock(15, 64, 8, .diamond_block);
    const neighbors = NeighborChunks{ .west = &west_chunk };
    try testing.expectEqual(BlockType.diamond_block, getBlockCross(&chunk, neighbors, -1, 64, 8));
}

test "getBlockCross wraps to east neighbor on x boundary" {
    var chunk = Chunk.init(0, 0);
    var east_chunk = Chunk.init(1, 0);
    east_chunk.setBlock(0, 64, 8, .gold_block);
    const neighbors = NeighborChunks{ .east = &east_chunk };
    try testing.expectEqual(BlockType.gold_block, getBlockCross(&chunk, neighbors, 16, 64, 8));
}

test "getLightCross returns max light above world" {
    var chunk = Chunk.init(0, 0);
    const neighbors = NeighborChunks.empty;
    const light = getLightCross(&chunk, neighbors, 8, 300, 8);
    try testing.expectEqual(@as(u4, 15), light.sky_light);
}

test "getLightCross returns zero for negative y" {
    var chunk = Chunk.init(0, 0);
    const neighbors = NeighborChunks.empty;
    const light = getLightCross(&chunk, neighbors, 8, -5, 8);
    try testing.expectEqual(@as(u4, 0), light.sky_light);
    try testing.expectEqual(@as(u4, 0), light.getBlockLight());
}

test "getEntranceBounceCross returns 0 for y out of bounds" {
    var chunk = Chunk.init(0, 0);
    const neighbors = NeighborChunks.empty;
    try testing.expectEqual(@as(u4, 0), getEntranceBounceCross(&chunk, neighbors, 8, -1, 8));
    try testing.expectEqual(@as(u4, 0), getEntranceBounceCross(&chunk, neighbors, 8, 256, 8));
}

test "getEntranceDirCross returns 0 for y out of bounds" {
    var chunk = Chunk.init(0, 0);
    const neighbors = NeighborChunks.empty;
    try testing.expectEqual(@as(u8, 0), getEntranceDirCross(&chunk, neighbors, 8, -1, 8));
    try testing.expectEqual(@as(u8, 0), getEntranceDirCross(&chunk, neighbors, 8, 256, 8));
}

test "getBiomeAt returns in-bounds biome" {
    var chunk = Chunk.init(0, 0);
    chunk.setBiome(5, 5, .forest);
    const neighbors = NeighborChunks.empty;
    try testing.expectEqual(Biome.forest, getBiomeAt(&chunk, neighbors, 5, 5));
}

test "getBiomeAt returns biome at corner edge" {
    var chunk = Chunk.init(0, 0);
    chunk.setBiome(0, 15, .desert);
    const neighbors = NeighborChunks.empty;
    try testing.expectEqual(Biome.desert, getBiomeAt(&chunk, neighbors, 0, 15));
}
