const std = @import("std");
const testing = std.testing;
const Chunk = @import("chunk.zig").Chunk;
const CHUNK_SIZE_Y = @import("chunk.zig").CHUNK_SIZE_Y;
const BlockType = @import("block.zig").BlockType;
const PackedLight = @import("chunk.zig").PackedLight;
const MAX_LIGHT = @import("chunk.zig").MAX_LIGHT;
const block_registry = @import("block_registry.zig");

test "Chunk.getHighestSolidY returns 0 for empty column" {
    var chunk = Chunk.init(0, 0);
    try testing.expectEqual(@as(u32, 0), chunk.getHighestSolidY(8, 8));
}

test "Chunk.getHighestSolidY returns correct Y for single block" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .stone);
    try testing.expectEqual(@as(u32, 64), chunk.getHighestSolidY(8, 8));
}

test "Chunk.getHighestSolidY ignores water" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .water);
    try testing.expectEqual(@as(u32, 0), chunk.getHighestSolidY(8, 8));
}

test "Chunk.getHighestSolidY finds top of stacked blocks" {
    var chunk = Chunk.init(0, 0);
    for (0..64) |y| {
        chunk.setBlock(8, @intCast(y), 8, .stone);
    }
    try testing.expectEqual(@as(u32, 63), chunk.getHighestSolidY(8, 8));
}

test "Chunk.generateFlat creates bedrock at y=0" {
    var chunk = Chunk.init(0, 0);
    chunk.generateFlat(32);
    try testing.expectEqual(BlockType.bedrock, chunk.getBlock(8, 0, 8));
}

test "Chunk.generateFlat creates stone below ground" {
    var chunk = Chunk.init(0, 0);
    chunk.generateFlat(32);
    try testing.expectEqual(BlockType.stone, chunk.getBlock(8, 10, 8));
}

test "Chunk.generateFlat creates dirt at correct depth" {
    var chunk = Chunk.init(0, 0);
    chunk.generateFlat(32);
    // ground_level=32: dirt is at y < 32 but >= 29 (ground_level - 3)
    // So dirt at y=29, 30, 31; stone at y=28
    try testing.expectEqual(BlockType.stone, chunk.getBlock(8, 28, 8));
    try testing.expectEqual(BlockType.dirt, chunk.getBlock(8, 29, 8));
    try testing.expectEqual(BlockType.dirt, chunk.getBlock(8, 31, 8));
    try testing.expectEqual(BlockType.grass, chunk.getBlock(8, 32, 8));
}

test "Chunk.generateFlat creates grass at surface" {
    var chunk = Chunk.init(0, 0);
    chunk.generateFlat(32);
    try testing.expectEqual(BlockType.grass, chunk.getBlock(8, 32, 8));
}

test "Chunk.generateFlat creates air above surface" {
    var chunk = Chunk.init(0, 0);
    chunk.generateFlat(32);
    try testing.expectEqual(BlockType.air, chunk.getBlock(8, 33, 8));
}

test "Chunk.generateFlat marks chunk as generated and dirty" {
    var chunk = Chunk.init(0, 0);
    try testing.expect(!chunk.generated);
    try testing.expect(chunk.dirty);
    chunk.generateFlat(32);
    try testing.expect(chunk.generated);
    try testing.expect(chunk.dirty);
}

test "Chunk.updateSkylightColumn propagates light from top" {
    var chunk = Chunk.init(0, 0);
    chunk.generateFlat(64);
    chunk.updateSkylightColumn(8, 8);
    try testing.expectEqual(@as(u4, MAX_LIGHT), chunk.getSkyLight(8, 255, 8));
}

test "Chunk.updateSkylightColumn stops at opaque block" {
    var chunk = Chunk.init(0, 0);
    chunk.generateFlat(64);
    chunk.updateSkylightColumn(8, 8);
    try testing.expectEqual(@as(u4, 0), chunk.getSkyLight(8, 63, 8));
}

test "Chunk.updateSkylightColumn water reduces light below water" {
    var chunk = Chunk.init(0, 0);
    chunk.setBlock(8, 64, 8, .water);
    chunk.setBlock(8, 65, 8, .air);
    chunk.setBlock(8, 66, 8, .air);
    chunk.updateSkylightColumn(8, 8);
    // Water block itself gets full light (15), then sky_light is reduced to 14 for next block
    try testing.expectEqual(@as(u4, MAX_LIGHT), chunk.getSkyLight(8, 64, 8));
    // Block below water gets reduced light
    try testing.expectEqual(@as(u4, MAX_LIGHT - 1), chunk.getSkyLight(8, 63, 8));
}

test "Chunk.updateSkylightColumn light propagates through air" {
    var chunk = Chunk.init(0, 0);
    chunk.updateSkylightColumn(8, 8);
    // y=66 is above world, getLightSafe handles bounds
    const light = chunk.getLightSafe(8, 66, 8);
    try testing.expectEqual(@as(u4, MAX_LIGHT), light.sky_light);
}

test "Chunk.getBiome and setBiome" {
    var chunk = Chunk.init(0, 0);
    const plains = chunk.getBiome(8, 8);
    try testing.expectEqual(@as(u8, 3), @intFromEnum(plains));
    chunk.setBiome(8, 8, .desert);
    try testing.expectEqual(.desert, chunk.getBiome(8, 8));
}

test "Chunk.light init defaults to zero" {
    var chunk = Chunk.init(0, 0);
    const light = chunk.getLight(0, 0, 0);
    try testing.expectEqual(@as(u4, 0), light.sky_light);
    try testing.expectEqual(@as(u4, 0), light.block_light_r);
}

test "Chunk.setBlock marks dirty and modified" {
    var chunk = Chunk.init(0, 0);
    try testing.expect(chunk.dirty);
    try testing.expect(!chunk.modified);
    chunk.setBlock(0, 0, 0, .stone);
    try testing.expect(chunk.dirty);
    try testing.expect(chunk.modified);
}

test "Chunk.getLightSafe returns max light above world" {
    var chunk = Chunk.init(0, 0);
    const light = chunk.getLightSafe(8, 300, 8);
    try testing.expectEqual(@as(u4, MAX_LIGHT), light.sky_light);
}

test "Chunk.getLightSafe returns zero for negative y" {
    var chunk = Chunk.init(0, 0);
    const light = chunk.getLightSafe(8, -5, 8);
    try testing.expectEqual(@as(u4, 0), light.sky_light);
    try testing.expectEqual(@as(u4, 0), light.getBlockLight());
}
