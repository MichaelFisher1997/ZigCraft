const std = @import("std");
const testing = std.testing;
const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;
const PackedLight = @import("world-core").PackedLight;
const MAX_LIGHT = @import("world-core").MAX_LIGHT;
const Chunk = @import("world-core").Chunk;
const BiomeId = @import("world-core").BiomeId;

test "getLightCross within chunk bounds" {
    var chunk = Chunk.init(0, 0);
    chunk.setLight(8, 64, 8, PackedLight.init(10, 5));
    const light = boundary.getLightCross(&chunk, .empty, 8, 64, 8);
    try testing.expectEqual(@as(u4, 10), light.getSkyLight());
}

test "getLightCross returns max above world" {
    var chunk = Chunk.init(0, 0);
    const light = boundary.getLightCross(&chunk, .empty, 8, 300, 8);
    try testing.expectEqual(@as(u4, MAX_LIGHT), light.getSkyLight());
}

test "getLightCross returns zero below world" {
    var chunk = Chunk.init(0, 0);
    const light = boundary.getLightCross(&chunk, .empty, 8, -5, 8);
    try testing.expectEqual(@as(u4, 0), light.getSkyLight());
}

test "getLightCross cross-chunk east neighbor" {
    var chunk = Chunk.init(0, 0);
    var east = Chunk.init(1, 0);
    east.setLight(0, 64, 8, PackedLight.init(12, 7));
    const neighbors = NeighborChunks{ .east = &east };
    const light = boundary.getLightCross(&chunk, neighbors, 16, 64, 8);
    try testing.expectEqual(@as(u4, 12), light.getSkyLight());
}

test "getLightCross cross-chunk west neighbor" {
    var chunk = Chunk.init(1, 0);
    var west = Chunk.init(0, 0);
    west.setLight(15, 64, 8, PackedLight.init(8, 4));
    const neighbors = NeighborChunks{ .west = &west };
    const light = boundary.getLightCross(&chunk, neighbors, -1, 64, 8);
    try testing.expectEqual(@as(u4, 8), light.getSkyLight());
}

test "getLightCross cross-chunk north neighbor" {
    var chunk = Chunk.init(0, 1);
    var north = Chunk.init(0, 0);
    north.setLight(8, 64, 15, PackedLight.init(9, 3));
    const neighbors = NeighborChunks{ .north = &north };
    const light = boundary.getLightCross(&chunk, neighbors, 8, 64, -1);
    try testing.expectEqual(@as(u4, 9), light.getSkyLight());
}

test "getLightCross cross-chunk south neighbor" {
    var chunk = Chunk.init(0, 0);
    var south = Chunk.init(0, 1);
    south.setLight(8, 64, 0, PackedLight.init(11, 6));
    const neighbors = NeighborChunks{ .south = &south };
    const light = boundary.getLightCross(&chunk, neighbors, 8, 64, 16);
    try testing.expectEqual(@as(u4, 11), light.getSkyLight());
}

test "getLightCross null neighbor returns max light" {
    var chunk = Chunk.init(0, 0);
    const light = boundary.getLightCross(&chunk, .empty, 16, 64, 8);
    try testing.expectEqual(@as(u4, MAX_LIGHT), light.getSkyLight());
}

test "getBiomeAt within chunk" {
    var chunk = Chunk.init(0, 0);
    chunk.setBiome(8, 8, .desert);
    const biome = boundary.getBiomeAt(&chunk, .empty, 8, 8);
    try testing.expectEqual(.desert, biome);
}

test "getBiomeAt cross-chunk east" {
    var chunk = Chunk.init(0, 0);
    var east = Chunk.init(1, 0);
    east.setBiome(0, 8, .taiga);
    const neighbors = NeighborChunks{ .east = &east };
    const biome = boundary.getBiomeAt(&chunk, neighbors, 16, 8);
    try testing.expectEqual(.taiga, biome);
}

test "getBiomeAt cross-chunk diagonal falls back to neighbor edge" {
    var chunk = Chunk.init(0, 0);
    var west = Chunk.init(-1, 0);
    west.setBiome(15, 15, .forest);
    const neighbors = NeighborChunks{ .west = &west };
    const biome = boundary.getBiomeAt(&chunk, neighbors, -1, 16);
    try testing.expectEqual(.forest, biome);
}

test "getBiomeAt null neighbor falls back to current chunk" {
    var chunk = Chunk.init(0, 0);
    chunk.setBiome(0, 0, .plains);
    const biome = boundary.getBiomeAt(&chunk, .empty, -1, -1);
    try testing.expectEqual(.plains, biome);
}

test "NeighborChunks.empty has all null neighbors" {
    const empty = NeighborChunks.empty;
    try testing.expectEqual(null, empty.north);
    try testing.expectEqual(null, empty.south);
    try testing.expectEqual(null, empty.east);
    try testing.expectEqual(null, empty.west);
}
