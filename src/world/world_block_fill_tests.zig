const std = @import("std");
const testing = std.testing;
const Chunk = @import("chunk.zig").Chunk;
const BlockType = @import("block.zig").BlockType;

test "Chunk.fillLayer y=0 creates bedrock layer" {
    var chunk = Chunk.init(0, 0);
    chunk.fillLayer(0, .bedrock);

    for (0..16) |x| {
        for (0..16) |z| {
            try testing.expectEqual(BlockType.bedrock, chunk.getBlock(@intCast(x), 0, @intCast(z)));
        }
    }
}

test "Chunk.fillLayer sets only specified y level" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    chunk.fillLayer(32, .dirt);

    try testing.expectEqual(BlockType.dirt, chunk.getBlock(8, 32, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 31, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 33, 8));
    try testing.expectEqual(BlockType.stone, chunk.getBlock(8, 64, 8));
}

test "Chunk.fillLayer marks chunk as dirty" {
    var chunk = Chunk.init(0, 0);
    chunk.dirty = false;

    chunk.fillLayer(10, .stone);
    try testing.expect(chunk.dirty);
}

test "Chunk.fillLayer with water at bottom" {
    var chunk = Chunk.init(0, 0);
    chunk.fillLayer(0, .water);

    for (0..16) |x| {
        for (0..16) |z| {
            try testing.expectEqual(BlockType.water, chunk.getBlock(@intCast(x), 0, @intCast(z)));
        }
    }
}

test "Chunk.fillLayer with air clears column" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    chunk.setBlock(8, 65, 8, .stone);

    chunk.fillLayer(64, .air);
    chunk.fillLayer(65, .air);

    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 64, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 65, 8));
}

test "Chunk.generateFlat with ground level 3" {
    var chunk = Chunk.init(0, 0);
    chunk.generateFlat(3);

    try testing.expectEqual(BlockType.bedrock, chunk.getBlock(8, 0, 8));
    try testing.expectEqual(BlockType.dirt, chunk.getBlock(8, 1, 8));
    try testing.expectEqual(BlockType.dirt, chunk.getBlock(8, 2, 8));
    try testing.expectEqual(BlockType.grass, chunk.getBlock(8, 3, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 4, 8));
}

test "Chunk.generateFlat with high ground level" {
    var chunk = Chunk.init(0, 0);
    chunk.generateFlat(200);

    try testing.expectEqual(BlockType.bedrock, chunk.getBlock(8, 0, 8));
    try testing.expectEqual(BlockType.dirt, chunk.getBlock(8, 198, 8));
    try testing.expectEqual(BlockType.grass, chunk.getBlock(8, 200, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 201, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 255, 8));
}

test "Chunk.setBlock does not affect neighboring blocks" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);

    try testing.expectEqual(BlockType.stone, chunk.getBlock(8, 64, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(7, 64, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(9, 64, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 63, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 65, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 64, 7));
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 64, 9));
}

test "Chunk.getBlockSafe returns air for all out of bounds x" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);

    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(-1, 64, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(16, 64, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(17, 64, 8));
}

test "Chunk.getBlockSafe returns air for all out of bounds z" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);

    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(8, 64, -1));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(8, 64, 16));
}
