const std = @import("std");
const testing = std.testing;
const Chunk = @import("chunk.zig").Chunk;
const BlockType = @import("block.zig").BlockType;

test "Chunk.fill sets all blocks to specified type" {
    var chunk = Chunk.init(0, 0);
    chunk.fill(.stone);

    for (0..16) |x| {
        for (0..256) |y| {
            for (0..16) |z| {
                try testing.expectEqual(BlockType.stone, chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)));
            }
        }
    }
}

test "Chunk.fill marks chunk as dirty" {
    var chunk = Chunk.init(0, 0);
    chunk.dirty = false;

    chunk.fill(.dirt);
    try testing.expect(chunk.dirty);
}

test "Chunk.fill with air" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(5, 64, 5, .stone);

    chunk.fill(.air);
    try testing.expectEqual(BlockType.air, chunk.getBlock(5, 64, 5));
}

test "Chunk.fill with water" {
    var chunk = Chunk.init(0, 0);
    chunk.fill(.water);

    for (0..16) |x| {
        for (0..16) |z| {
            try testing.expectEqual(BlockType.water, chunk.getBlock(@intCast(x), 64, @intCast(z)));
        }
    }
}

test "Chunk.fill does not affect modified flag" {
    var chunk = Chunk.init(0, 0);
    try testing.expect(!chunk.modified);

    chunk.setBlock(0, 0, 0, .stone);
    try testing.expect(chunk.modified);

    chunk.modified = false;
    chunk.fill(.dirt);
    try testing.expect(!chunk.modified);
}
