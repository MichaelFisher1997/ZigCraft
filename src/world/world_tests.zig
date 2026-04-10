const std = @import("std");
const testing = std.testing;

const BlockType = @import("block.zig").BlockType;
const Face = @import("block.zig").Face;
const ALL_FACES = @import("block.zig").ALL_FACES;
const block_registry = @import("block_registry.zig");
const Chunk = @import("chunk.zig").Chunk;
const PackedLight = @import("chunk.zig").PackedLight;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const ChunkKey = @import("chunk_storage.zig").ChunkKey;

test "Face getShade returns correct values" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), Face.top.getShade(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), Face.bottom.getShade(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), Face.north.getShade(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), Face.south.getShade(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), Face.east.getShade(), 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), Face.west.getShade(), 0.001);
}

test "Face getNormal returns correct directions" {
    try testing.expectEqual([3]i8{ 0, 1, 0 }, Face.top.getNormal());
    try testing.expectEqual([3]i8{ 0, -1, 0 }, Face.bottom.getNormal());
    try testing.expectEqual([3]i8{ 0, 0, -1 }, Face.north.getNormal());
    try testing.expectEqual([3]i8{ 0, 0, 1 }, Face.south.getNormal());
    try testing.expectEqual([3]i8{ 1, 0, 0 }, Face.east.getNormal());
    try testing.expectEqual([3]i8{ -1, 0, 0 }, Face.west.getNormal());
}

test "Face getOffset matches normal" {
    for (ALL_FACES) |face| {
        const normal = face.getNormal();
        const offset = face.getOffset();
        try testing.expectEqual(normal[0], offset.x);
        try testing.expectEqual(normal[1], offset.y);
        try testing.expectEqual(normal[2], offset.z);
    }
}

test "BlockDefinition occludes air returns false" {
    const def = block_registry.getBlockDefinition(.air);
    try testing.expect(!def.occludes(def, .top));
}

test "BlockDefinition occludes same fluid returns true" {
    const def = block_registry.getBlockDefinition(.water);
    try testing.expect(def.occludes(def, .top));
}

test "BlockDefinition occludes same transparent returns true" {
    const def = block_registry.getBlockDefinition(.glass);
    try testing.expect(def.occludes(def, .top));
}

test "BlockDefinition occludes solid opaque returns true" {
    const def = block_registry.getBlockDefinition(.stone);
    try testing.expect(def.occludes(def, .top));
}

test "BlockDefinition occludes transparent by solid returns false" {
    const glass = block_registry.getBlockDefinition(.glass);
    const stone = block_registry.getBlockDefinition(.stone);
    try testing.expect(!glass.occludes(stone, .top));
}

test "BlockDefinition getFaceColor applies shade multiplier" {
    const def = block_registry.getBlockDefinition(.grass);
    const top_color = def.getFaceColor(.top);
    const bottom_color = def.getFaceColor(.bottom);
    try testing.expectApproxEqAbs(top_color[0], bottom_color[0] * 2.0, 0.001);
}

test "BlockDefinition getLightEmissionLevel returns max of RGB" {
    try testing.expectEqual(@as(u4, 15), block_registry.getBlockDefinition(.glowstone).getLightEmissionLevel());
    try testing.expectEqual(@as(u4, 15), block_registry.getBlockDefinition(.torch).getLightEmissionLevel());
    try testing.expectEqual(@as(u4, 0), block_registry.getBlockDefinition(.stone).getLightEmissionLevel());
}

test "PackedLight initRGB sets all channels correctly" {
    const light = PackedLight.initRGB(12, 4, 8, 2);
    try testing.expectEqual(@as(u4, 12), light.getSkyLight());
    try testing.expectEqual(@as(u4, 4), light.getBlockLightR());
    try testing.expectEqual(@as(u4, 8), light.getBlockLightG());
    try testing.expectEqual(@as(u4, 2), light.getBlockLightB());
}

test "ChunkKey hash is deterministic" {
    const key1 = ChunkKey{ .x = 5, .z = -3 };
    const key2 = ChunkKey{ .x = 5, .z = -3 };
    try testing.expectEqual(key1.hash(), key2.hash());
}

test "ChunkKey eql returns true for same values" {
    const a = ChunkKey{ .x = 10, .z = 20 };
    const b = ChunkKey{ .x = 10, .z = 20 };
    try testing.expect(a.eql(b));
}

test "ChunkKey eql returns false for different values" {
    const a = ChunkKey{ .x = 10, .z = 20 };
    const b = ChunkKey{ .x = 10, .z = 21 };
    try testing.expect(!a.eql(b));
}

test "ChunkStorage init creates empty storage" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    try testing.expectEqual(@as(usize, 0), storage.count());
}

test "ChunkStorage get returns null for missing chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    try testing.expect(storage.get(0, 0) == null);
}

test "ChunkStorage getOrCreate creates new chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const data = try storage.getOrCreate(1, -2);
    try testing.expectEqual(@as(i32, 1), data.chunk.chunk_x);
    try testing.expectEqual(@as(i32, -2), data.chunk.chunk_z);
    try testing.expectEqual(@as(usize, 1), storage.count());
}

test "ChunkStorage getOrCreate returns existing chunk" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const data1 = try storage.getOrCreate(3, 4);
    const data2 = try storage.getOrCreate(3, 4);
    try testing.expect(data1 == data2);
    try testing.expectEqual(@as(usize, 1), storage.count());
}
