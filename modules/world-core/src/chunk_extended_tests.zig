const std = @import("std");
const testing = std.testing;
const Chunk = @import("chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("chunk_constants.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk_constants.zig").CHUNK_SIZE_Z;
const CHUNK_SIZE_Y = @import("chunk_constants.zig").CHUNK_SIZE_Y;
const BlockType = @import("block.zig").BlockType;

test "Chunk.pin increments pin_count" {
    var chunk = Chunk.init(0, 0);
    try testing.expectEqual(@as(u32, 0), chunk.pin_count.load(.monotonic));
    chunk.pin();
    try testing.expectEqual(@as(u32, 1), chunk.pin_count.load(.monotonic));
    chunk.pin();
    try testing.expectEqual(@as(u32, 2), chunk.pin_count.load(.monotonic));
}

test "Chunk.unpin decrements pin_count" {
    var chunk = Chunk.init(0, 0);
    chunk.pin();
    chunk.pin();
    chunk.pin();
    try testing.expectEqual(@as(u32, 3), chunk.pin_count.load(.monotonic));
    chunk.unpin();
    try testing.expectEqual(@as(u32, 2), chunk.pin_count.load(.monotonic));
}

test "Chunk.isPinned true when pinned" {
    var chunk = Chunk.init(0, 0);
    try testing.expect(!chunk.isPinned());
    chunk.pin();
    try testing.expect(chunk.isPinned());
}

test "Chunk.isPinned false when unpinned" {
    var chunk = Chunk.init(0, 0);
    chunk.pin();
    chunk.unpin();
    try testing.expect(!chunk.isPinned());
}

test "Chunk.getWorldX returns chunk_x * CHUNK_SIZE_X" {
    var chunk = Chunk.init(3, 5);
    try testing.expectEqual(@as(i32, 3 * CHUNK_SIZE_X), chunk.getWorldX());
}

test "Chunk.getWorldZ returns chunk_z * CHUNK_SIZE_Z" {
    var chunk = Chunk.init(3, 5);
    try testing.expectEqual(@as(i32, 5 * CHUNK_SIZE_Z), chunk.getWorldZ());
}

test "Chunk.getWorldX and getWorldZ work with negative coordinates" {
    var chunk = Chunk.init(-2, -3);
    try testing.expectEqual(@as(i32, -2 * CHUNK_SIZE_X), chunk.getWorldX());
    try testing.expectEqual(@as(i32, -3 * CHUNK_SIZE_Z), chunk.getWorldZ());
}

test "Chunk.fill sets all blocks to given type" {
    var chunk = Chunk.init(0, 0);
    chunk.fill(.cobblestone);
    for (0..CHUNK_SIZE_X) |x| {
        for (0..CHUNK_SIZE_Y) |y| {
            for (0..CHUNK_SIZE_Z) |z| {
                try testing.expectEqual(BlockType.cobblestone, chunk.getBlock(@intCast(x), @intCast(y), @intCast(z)));
            }
        }
    }
}

test "Chunk.fill marks chunk dirty" {
    var chunk = Chunk.init(0, 0);
    chunk.dirty = false;
    try testing.expect(!chunk.dirty);
    chunk.fill(.stone);
    try testing.expect(chunk.dirty);
}

test "Chunk.fillLayer sets single Y layer" {
    var chunk = Chunk.init(0, 0);
    chunk.fillLayer(64, .sand);
    for (0..CHUNK_SIZE_X) |x| {
        for (0..CHUNK_SIZE_Z) |z| {
            try testing.expectEqual(BlockType.sand, chunk.getBlock(@intCast(x), 64, @intCast(z)));
        }
    }
    for (0..CHUNK_SIZE_X) |x| {
        for (0..CHUNK_SIZE_Z) |z| {
            try testing.expectEqual(BlockType.air, chunk.getBlock(@intCast(x), 0, @intCast(z)));
        }
    }
}

test "Chunk.getBlockSafe returns air for x out of bounds" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(0, 64, 0, .stone);
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(-1, 64, 0));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(CHUNK_SIZE_X, 64, 0));
}

test "Chunk.getBlockSafe returns air for z out of bounds" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(8, 64, -1));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(8, 64, CHUNK_SIZE_Z));
}

test "Chunk.getBlockSafe returns air for y out of bounds" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(8, -1, 8));
    try testing.expectEqual(BlockType.air, chunk.getBlockSafe(8, CHUNK_SIZE_Y, 8));
}

test "Chunk.getIndex returns consistent values" {
    try testing.expectEqual(@as(usize, 0), Chunk.getIndex(0, 0, 0));
    try testing.expectEqual(@as(usize, 1), Chunk.getIndex(1, 0, 0));
    try testing.expectEqual(@as(usize, 16), Chunk.getIndex(0, 0, 1));
    try testing.expectEqual(@as(usize, 256), Chunk.getIndex(0, 1, 0));
}

test "Chunk.setBlockLight and getBlockLight" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlockLight(5, 64, 5, 7);
    try testing.expectEqual(@as(u4, 7), chunk.getBlockLight(5, 64, 5));
}

test "Chunk live map surface includes foliage and reacts to removal" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(3, 64, 5, .grass);
    chunk.setBlock(3, 70, 5, .leaves);

    try testing.expectEqual(@as(u32, 2), chunk.rebuildMapSurface());
    const column = 3 + 5 * CHUNK_SIZE_X;
    try testing.expectEqual(BlockType.leaves, chunk.map_surface_blocks[column]);
    try testing.expectEqual(@as(i16, 70), chunk.map_surface_heights[column]);
    try testing.expect(chunk.mapSurfaceIsCurrent());

    chunk.setBlock(3, 70, 5, .air);
    try testing.expect(!chunk.mapSurfaceIsCurrent());
    _ = chunk.rebuildMapSurface();
    try testing.expectEqual(BlockType.grass, chunk.map_surface_blocks[column]);
    try testing.expectEqual(@as(i16, 64), chunk.map_surface_heights[column]);
}

test "Chunk live map surface includes water" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 60, 8, .sand);
    chunk.setBlock(8, 64, 8, .water);
    _ = chunk.rebuildMapSurface();
    const column = 8 + 8 * CHUNK_SIZE_X;
    try testing.expectEqual(BlockType.water, chunk.map_surface_blocks[column]);
    try testing.expectEqual(@as(i16, 64), chunk.map_surface_heights[column]);
}
