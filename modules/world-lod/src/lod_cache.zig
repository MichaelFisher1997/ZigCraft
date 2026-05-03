//! Disk serialization for generated LOD source data.

const std = @import("std");

const world_core = @import("world-core");
const LODLevel = @import("lod_types.zig").LODLevel;
const LODSimplifiedData = world_core.LODSimplifiedData;
const LODMaterialLayers = world_core.LODMaterialLayers;
const LODWaterState = world_core.LODWaterState;
const LODLightingHint = world_core.LODLightingHint;
const LODVegetationHint = world_core.LODVegetationHint;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;

pub const MAGIC: u32 = 0x5A4C4F44; // "ZLOD"
pub const CACHE_VERSION: u8 = 1;
pub const HEADER_SIZE: usize = 42;

pub const Key = struct {
    seed: u64,
    generator_identity_hash: u64,
    generator_version: u32,
    rx: i32,
    rz: i32,
    lod: LODLevel,
};

pub const CacheError = error{
    InvalidMagic,
    UnsupportedVersion,
    DataTooShort,
    InvalidKey,
    InvalidWidth,
    InvalidBiome,
    InvalidBlock,
    ChecksumMismatch,
};

const BIOME_COUNT: usize = @typeInfo(BiomeId).@"enum".fields.len;
const BLOCK_COUNT: usize = @typeInfo(BlockType).@"enum".fields.len;
const HEIGHT_WIRE_SIZE: usize = @sizeOf(f32);
const BIOME_WIRE_SIZE: usize = @sizeOf(BiomeId);
const BLOCK_WIRE_SIZE: usize = @sizeOf(BlockType);
const COLOR_WIRE_SIZE: usize = @sizeOf(u32);
const MATERIAL_LAYERS_WIRE_SIZE: usize = 3 * BLOCK_WIRE_SIZE;
const WATER_WIRE_SIZE: usize = @sizeOf(u8) + 3 * @sizeOf(f32);
const LIGHTING_WIRE_SIZE: usize = 2 * @sizeOf(u8) + @sizeOf(f32);
const VEGETATION_WIRE_SIZE: usize = 4 * @sizeOf(f32) + 2 * BLOCK_WIRE_SIZE;
const CELL_WIRE_SIZE: usize = HEIGHT_WIRE_SIZE + BIOME_WIRE_SIZE + BLOCK_WIRE_SIZE + COLOR_WIRE_SIZE + MATERIAL_LAYERS_WIRE_SIZE + WATER_WIRE_SIZE + LIGHTING_WIRE_SIZE + VEGETATION_WIRE_SIZE;

comptime {
    std.debug.assert(MATERIAL_LAYERS_WIRE_SIZE == 3);
    std.debug.assert(WATER_WIRE_SIZE == 13);
    std.debug.assert(LIGHTING_WIRE_SIZE == 6);
    std.debug.assert(VEGETATION_WIRE_SIZE == 18);
    std.debug.assert(CELL_WIRE_SIZE == 50);
}

fn payloadSize(count: usize) usize {
    return count * CELL_WIRE_SIZE;
}

pub fn serializedSize(data: *const LODSimplifiedData) usize {
    const count = @as(usize, @intCast(data.width)) * @as(usize, @intCast(data.width));
    return HEADER_SIZE + payloadSize(count);
}

fn writeF32(buf: []u8, value: f32) void {
    std.mem.writeInt(u32, buf[0..4], @as(u32, @bitCast(value)), .little);
}

fn readF32(buf: []const u8) f32 {
    return @as(f32, @bitCast(std.mem.readInt(u32, buf[0..4], .little)));
}

fn writeBlock(buf: []u8, block: BlockType) void {
    buf[0] = @intFromEnum(block);
}

fn readBlock(byte: u8) !BlockType {
    if (byte >= BLOCK_COUNT) return CacheError.InvalidBlock;
    return std.enums.fromInt(BlockType, byte) orelse CacheError.InvalidBlock;
}

fn readBiome(byte: u8) !BiomeId {
    if (byte >= BIOME_COUNT) return CacheError.InvalidBiome;
    return std.enums.fromInt(BiomeId, byte) orelse CacheError.InvalidBiome;
}

pub fn serialize(data: *const LODSimplifiedData, key: Key, allocator: std.mem.Allocator) ![]u8 {
    const width_usize = @as(usize, @intCast(data.width));
    const count = width_usize * width_usize;
    const total_size = HEADER_SIZE + payloadSize(count);
    const buf = try allocator.alloc(u8, total_size);
    errdefer allocator.free(buf);

    var off: usize = 0;
    std.mem.writeInt(u32, buf[off..][0..4], MAGIC, .little);
    off += 4;
    buf[off] = CACHE_VERSION;
    off += 1;
    buf[off] = @intFromEnum(key.lod);
    off += 1;
    std.mem.writeInt(u32, buf[off..][0..4], 0, .little);
    off += 4;
    std.mem.writeInt(u64, buf[off..][0..8], key.seed, .little);
    off += 8;
    std.mem.writeInt(u64, buf[off..][0..8], key.generator_identity_hash, .little);
    off += 8;
    std.mem.writeInt(u32, buf[off..][0..4], key.generator_version, .little);
    off += 4;
    std.mem.writeInt(i32, buf[off..][0..4], key.rx, .little);
    off += 4;
    std.mem.writeInt(i32, buf[off..][0..4], key.rz, .little);
    off += 4;
    std.mem.writeInt(u32, buf[off..][0..4], data.width, .little);
    off += 4;

    for (data.heightmap) |height| {
        writeF32(buf[off..][0..4], height);
        off += 4;
    }
    for (data.biomes) |biome| {
        buf[off] = @intFromEnum(biome);
        off += 1;
    }
    for (data.top_blocks) |block| {
        writeBlock(buf[off..][0..1], block);
        off += 1;
    }
    for (data.colors) |color| {
        std.mem.writeInt(u32, buf[off..][0..4], color, .little);
        off += 4;
    }
    for (data.material_layers) |layers| {
        writeBlock(buf[off..][0..1], layers.surface);
        writeBlock(buf[off + 1 ..][0..1], layers.subsurface);
        writeBlock(buf[off + 2 ..][0..1], layers.foundation);
        off += 3;
    }
    for (data.water) |water| {
        buf[off] = if (water.is_surface) 1 else 0;
        off += 1;
        writeF32(buf[off..][0..4], water.surface_height);
        off += 4;
        writeF32(buf[off..][0..4], water.depth);
        off += 4;
        writeF32(buf[off..][0..4], water.coverage);
        off += 4;
    }
    for (data.lighting) |lighting| {
        buf[off] = lighting.sky_light;
        buf[off + 1] = lighting.block_light;
        off += 2;
        writeF32(buf[off..][0..4], lighting.ambient_occlusion);
        off += 4;
    }
    for (data.vegetation) |vegetation| {
        writeF32(buf[off..][0..4], vegetation.tree_coverage);
        off += 4;
        writeF32(buf[off..][0..4], vegetation.avg_tree_height);
        off += 4;
        writeF32(buf[off..][0..4], vegetation.offset_x);
        off += 4;
        writeF32(buf[off..][0..4], vegetation.offset_z);
        off += 4;
        writeBlock(buf[off..][0..1], vegetation.trunk);
        writeBlock(buf[off + 1 ..][0..1], vegetation.leaves);
        off += 2;
    }

    std.debug.assert(off == total_size);
    const crc = std.hash.Crc32.hash(buf[HEADER_SIZE..]);
    std.mem.writeInt(u32, buf[6..][0..4], crc, .little);
    return buf;
}

pub fn deserialize(bytes: []const u8, key: Key, allocator: std.mem.Allocator) !LODSimplifiedData {
    if (bytes.len < HEADER_SIZE) return CacheError.DataTooShort;

    var off: usize = 0;
    if (std.mem.readInt(u32, bytes[off..][0..4], .little) != MAGIC) return CacheError.InvalidMagic;
    off += 4;

    if (bytes[off] != CACHE_VERSION) return CacheError.UnsupportedVersion;
    off += 1;
    const lod_byte = bytes[off];
    off += 1;
    if (lod_byte != @intFromEnum(key.lod)) return CacheError.InvalidKey;

    const stored_crc = std.mem.readInt(u32, bytes[off..][0..4], .little);
    off += 4;
    if (std.hash.Crc32.hash(bytes[HEADER_SIZE..]) != stored_crc) return CacheError.ChecksumMismatch;

    const seed = std.mem.readInt(u64, bytes[off..][0..8], .little);
    off += 8;
    const generator_identity_hash = std.mem.readInt(u64, bytes[off..][0..8], .little);
    off += 8;
    const generator_version = std.mem.readInt(u32, bytes[off..][0..4], .little);
    off += 4;
    const rx = std.mem.readInt(i32, bytes[off..][0..4], .little);
    off += 4;
    const rz = std.mem.readInt(i32, bytes[off..][0..4], .little);
    off += 4;
    const width = std.mem.readInt(u32, bytes[off..][0..4], .little);
    off += 4;

    if (seed != key.seed or generator_identity_hash != key.generator_identity_hash or generator_version != key.generator_version or rx != key.rx or rz != key.rz) return CacheError.InvalidKey;
    if (width != LODSimplifiedData.getGridSize(key.lod)) return CacheError.InvalidWidth;

    const count = @as(usize, @intCast(width)) * @as(usize, @intCast(width));
    const expected = HEADER_SIZE + payloadSize(count);
    if (bytes.len < expected) return CacheError.DataTooShort;

    var data = try LODSimplifiedData.init(allocator, key.lod);
    errdefer data.deinit();

    for (data.heightmap) |*height| {
        height.* = readF32(bytes[off..][0..4]);
        off += 4;
    }
    for (data.biomes) |*biome| {
        biome.* = try readBiome(bytes[off]);
        off += 1;
    }
    for (data.top_blocks) |*block| {
        block.* = try readBlock(bytes[off]);
        off += 1;
    }
    for (data.colors) |*color| {
        color.* = std.mem.readInt(u32, bytes[off..][0..4], .little);
        off += 4;
    }
    for (data.material_layers) |*layers| {
        layers.* = LODMaterialLayers{
            .surface = try readBlock(bytes[off]),
            .subsurface = try readBlock(bytes[off + 1]),
            .foundation = try readBlock(bytes[off + 2]),
        };
        off += 3;
    }
    for (data.water) |*water| {
        water.* = LODWaterState{
            .is_surface = bytes[off] != 0,
            .surface_height = readF32(bytes[off + 1 ..][0..4]),
            .depth = readF32(bytes[off + 5 ..][0..4]),
            .coverage = readF32(bytes[off + 9 ..][0..4]),
        };
        off += 13;
    }
    for (data.lighting) |*lighting| {
        lighting.* = LODLightingHint{
            .sky_light = bytes[off],
            .block_light = bytes[off + 1],
            .ambient_occlusion = readF32(bytes[off + 2 ..][0..4]),
        };
        off += 6;
    }
    for (data.vegetation) |*vegetation| {
        vegetation.* = LODVegetationHint{
            .tree_coverage = readF32(bytes[off..][0..4]),
            .avg_tree_height = readF32(bytes[off + 4 ..][0..4]),
            .offset_x = readF32(bytes[off + 8 ..][0..4]),
            .offset_z = readF32(bytes[off + 12 ..][0..4]),
            .trunk = try readBlock(bytes[off + 16]),
            .leaves = try readBlock(bytes[off + 17]),
        };
        off += 18;
    }

    std.debug.assert(off == expected);
    return data;
}

const testing = std.testing;

test "LOD cache round-trip preserves source data" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod2);
    defer data.deinit();

    data.setColumn(1, 2, 77.5, .forest, .{
        .surface = .grass,
        .subsurface = .dirt,
        .foundation = .stone,
    }, 0xFF336699, .{
        .is_surface = true,
        .surface_height = 63.0,
        .depth = 3.5,
        .coverage = 0.75,
    }, .{
        .sky_light = 12,
        .block_light = 2,
        .ambient_occlusion = 0.8,
    }, .{
        .tree_coverage = 0.4,
        .avg_tree_height = 8.0,
        .offset_x = 0.2,
        .offset_z = -0.3,
        .trunk = .wood,
        .leaves = .leaves,
    });

    const key = Key{ .seed = 1234, .generator_identity_hash = 99, .generator_version = 7, .rx = -2, .rz = 3, .lod = .lod2 };
    const bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(bytes);

    var decoded = try deserialize(bytes, key, testing.allocator);
    defer decoded.deinit();

    const idx = 1 + 2 * data.width;
    try testing.expectEqual(data.heightmap[idx], decoded.heightmap[idx]);
    try testing.expectEqual(data.biomes[idx], decoded.biomes[idx]);
    try testing.expectEqual(data.top_blocks[idx], decoded.top_blocks[idx]);
    try testing.expectEqual(data.colors[idx], decoded.colors[idx]);
    try testing.expectEqual(data.material_layers[idx].subsurface, decoded.material_layers[idx].subsurface);
    try testing.expectEqual(data.water[idx].depth, decoded.water[idx].depth);
    try testing.expectEqual(data.lighting[idx].sky_light, decoded.lighting[idx].sky_light);
    try testing.expectEqual(data.vegetation[idx].leaves, decoded.vegetation[idx].leaves);
}

test "LOD cache rejects checksum mismatch" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod1);
    defer data.deinit();

    const key = Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod1 };
    const bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(bytes);
    bytes[bytes.len - 1] ^= 0x01;

    try testing.expectError(CacheError.ChecksumMismatch, deserialize(bytes, key, testing.allocator));
}

test "LOD cache rejects mismatched cache key" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod1);
    defer data.deinit();

    const key = Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod1 };
    const bytes = try serialize(&data, key, testing.allocator);
    defer testing.allocator.free(bytes);

    const wrong_key = Key{ .seed = 1, .generator_identity_hash = 3, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod1 };
    try testing.expectError(CacheError.InvalidKey, deserialize(bytes, wrong_key, testing.allocator));
}

test "LOD cache payload size follows named wire fields" {
    try testing.expectEqual(@as(usize, 50), payloadSize(1));
    try testing.expectEqual(@as(usize, HEADER_SIZE + 50 * 4), HEADER_SIZE + payloadSize(4));
}
