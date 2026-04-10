const std = @import("std");
const testing = std.testing;

const Chunk = @import("chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const PackedLight = @import("chunk.zig").PackedLight;
const BlockType = @import("block.zig").BlockType;
const block_registry = @import("block_registry.zig");
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const ChunkKey = @import("chunk_storage.zig").ChunkKey;

test "Chunk getHighestSolidY finds top of solid column" {
    var chunk = Chunk.init(0, 0);
    chunk.fillLayer(0, .bedrock);
    chunk.fillLayer(1, .stone);
    chunk.fillLayer(2, .dirt);
    chunk.fillLayer(3, .grass);

    try testing.expectEqual(@as(u32, 3), chunk.getHighestSolidY(0, 0));
    try testing.expectEqual(@as(u32, 3), chunk.getHighestSolidY(15, 15));
}

test "Chunk getHighestSolidY returns 0 for air column" {
    var chunk = Chunk.init(0, 0);
    try testing.expectEqual(@as(u32, 0), chunk.getHighestSolidY(0, 0));
}

test "Chunk getHighestSolidY stops at water" {
    var chunk = Chunk.init(0, 0);
    chunk.fillLayer(0, .bedrock);
    chunk.fillLayer(1, .stone);
    chunk.fillLayer(2, .water);
    chunk.fillLayer(3, .air);

    try testing.expectEqual(@as(u32, 1), chunk.getHighestSolidY(0, 0));
}

test "Chunk generateFlat creates correct layer sequence" {
    var chunk = Chunk.init(0, 0);
    chunk.generateFlat(64);

    try testing.expectEqual(BlockType.bedrock, chunk.getBlock(0, 0, 0));
    try testing.expectEqual(BlockType.stone, chunk.getBlock(0, 1, 0));
    try testing.expectEqual(BlockType.stone, chunk.getBlock(0, 60, 0));
    try testing.expectEqual(BlockType.dirt, chunk.getBlock(0, 61, 0));
    try testing.expectEqual(BlockType.grass, chunk.getBlock(0, 64, 0));
    try testing.expectEqual(BlockType.air, chunk.getBlock(0, 65, 0));
    try testing.expectEqual(BlockType.air, chunk.getBlock(0, 255, 0));
    try testing.expect(chunk.generated);
}

test "Chunk updateSkylightColumn decreases through air" {
    var chunk = Chunk.init(0, 0);
    chunk.fillLayer(0, .bedrock);
    chunk.fillLayer(1, .bedrock);
    chunk.fillLayer(2, .bedrock);

    chunk.updateSkylightColumn(8, 8);

    try testing.expectEqual(@as(u4, 0), chunk.getSkyLight(8, 0, 8));
    try testing.expectEqual(@as(u4, 0), chunk.getSkyLight(8, 1, 8));
    try testing.expectEqual(@as(u4, 15), chunk.getSkyLight(8, 2, 8));
    try testing.expectEqual(@as(u4, 15), chunk.getSkyLight(8, 3, 8));
    try testing.expectEqual(@as(u4, 15), chunk.getSkyLight(8, 4, 8));
}

test "BlockDefinition occludes same fluid type" {
    const water_def = block_registry.getBlockDefinition(.water);
    try testing.expect(water_def.occludes(water_def, .top));
}

test "BlockDefinition occludes same transparent type" {
    const glass_def = block_registry.getBlockDefinition(.glass);
    try testing.expect(glass_def.occludes(glass_def, .east));
}

test "BlockDefinition air does not occlude" {
    const air_def = block_registry.getBlockDefinition(.air);
    try testing.expect(!air_def.occludes(air_def, .top));
}

test "BlockDefinition solid occludes air" {
    const stone_def = block_registry.getBlockDefinition(.stone);
    try testing.expect(stone_def.occludes(block_registry.getBlockDefinition(.air), .top));
}

test "BlockDefinition does not occlude different transparent blocks" {
    const glass_def = block_registry.getBlockDefinition(.glass);
    const leaves_def = block_registry.getBlockDefinition(.leaves);
    try testing.expect(!glass_def.occludes(leaves_def, .top));
}

test "BlockDefinition occludes solid non-transparent" {
    const stone_def = block_registry.getBlockDefinition(.stone);
    const air_def = block_registry.getBlockDefinition(.air);
    const water_def = block_registry.getBlockDefinition(.water);
    try testing.expect(stone_def.occludes(air_def, .top));
    try testing.expect(stone_def.occludes(water_def, .top));
}

test "BlockDefinition getFaceColor applies shade" {
    const grass_def = block_registry.getBlockDefinition(.grass);
    const top_color = grass_def.getFaceColor(.top);
    const bottom_color = grass_def.getFaceColor(.bottom);

    try testing.expect(top_color[0] >= bottom_color[0]);
    try testing.expectApproxEqAbs(top_color[0], bottom_color[0] * 2.0, 0.001);
}

test "ChunkKey hash is deterministic" {
    const key1 = ChunkKey{ .x = 5, .z = -3 };
    const key2 = ChunkKey{ .x = 5, .z = -3 };
    try testing.expectEqual(key1.hash(), key2.hash());
}

test "ChunkKey hash different for different coords" {
    const key1 = ChunkKey{ .x = 5, .z = -3 };
    const key2 = ChunkKey{ .x = 5, .z = -2 };
    try testing.expect(key1.hash() != key2.hash());
}

test "ChunkKey eql returns true for same coords" {
    const key1 = ChunkKey{ .x = 5, .z = -3 };
    const key2 = ChunkKey{ .x = 5, .z = -3 };
    try testing.expect(key1.eql(key2));
}

test "ChunkKey eql returns false for different coords" {
    const key1 = ChunkKey{ .x = 5, .z = -3 };
    const key2 = ChunkKey{ .x = 5, .z = -2 };
    try testing.expect(!key1.eql(key2));
}

test "ChunkStorage init creates empty storage" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    try testing.expectEqual(@as(usize, 0), storage.count());
    try testing.expectEqual(@as(u32, 1), storage.next_job_token);
}

test "ChunkStorage getOrCreate creates chunk with correct position" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data = try storage.getOrCreate(3, -7);
    try testing.expectEqual(@as(i32, 3), data.chunk.chunk_x);
    try testing.expectEqual(@as(i32, -7), data.chunk.chunk_z);
    try testing.expectEqual(@as(usize, 1), storage.count());
}

test "ChunkStorage getOrCreate returns existing chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data1 = try storage.getOrCreate(1, 2);
    data1.chunk.chunk_x = 999;

    const data2 = try storage.getOrCreate(1, 2);
    try testing.expectEqual(@as(i32, 999), data2.chunk.chunk_x);
    try testing.expectEqual(@as(usize, 1), storage.count());
}

test "ChunkStorage get returns null for missing chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    _ = try storage.getOrCreate(1, 2);
    try testing.expect(storage.get(99, 99) == null);
}
