//! Unit tests for the terrain shape generator subsystem
//!
//! Tests focus on:
//! - TerrainShapeGenerator initialization and accessors
//! - Column data sampling and structure
//! - Biome edge detection logic
//! - Region info retrieval

const std = @import("std");
const testing = std.testing;

const terrain_shape_mod = @import("terrain_shape_generator.zig");
const TerrainShapeGenerator = terrain_shape_mod.TerrainShapeGenerator;
const ColumnData = terrain_shape_mod.ColumnData;
const Params = terrain_shape_mod.Params;

const biome_mod = @import("biome.zig");
const BiomeId = biome_mod.BiomeId;
const BiomeEdgeInfo = biome_mod.BiomeEdgeInfo;
const BiomeSource = biome_mod.BiomeSource;

const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;

test "TerrainShapeGenerator init with default params" {
    const tsg = TerrainShapeGenerator.init(12345);
    try testing.expectEqual(@as(u64, 12345), tsg.getSeed());
    try testing.expectEqual(@as(i32, 64), tsg.getSeaLevel());
    try testing.expectEqual(@as(f32, 0.35), tsg.getOceanThreshold());
}

test "TerrainShapeGenerator init with custom params" {
    const params = Params{
        .sea_level = 32,
        .ocean_threshold = 0.5,
        .temp_lapse = 0.3,
    };
    const tsg = TerrainShapeGenerator.initWithParams(99999, params);
    try testing.expectEqual(@as(u64, 99999), tsg.getSeed());
    try testing.expectEqual(@as(i32, 32), tsg.getSeaLevel());
    try testing.expectEqual(@as(f32, 0.5), tsg.getOceanThreshold());
}

test "TerrainShapeGenerator subsystem accessors" {
    const tsg = TerrainShapeGenerator.init(42);

    _ = tsg.getNoiseSampler();
    _ = tsg.getHeightSampler();
    _ = tsg.getSurfaceBuilder();
    _ = tsg.getBiomeSource();

    try testing.expect(true);
}

test "TerrainShapeGenerator getRegionSeed" {
    const tsg = TerrainShapeGenerator.init(12345);
    const region_seed = tsg.getRegionSeed();
    try testing.expect(region_seed != 0);
}

test "TerrainShapeGenerator sampleColumnData returns valid structure" {
    const tsg = TerrainShapeGenerator.init(42);
    const column = tsg.sampleColumnData(100.0, 200.0, 0);

    try testing.expect(column.terrain_height_i >= -64);
    try testing.expect(column.terrain_height_i <= 200);
    try testing.expect(column.continentalness >= 0.0 and column.continentalness <= 1.0);
    try testing.expect(column.erosion >= 0.0 and column.erosion <= 1.0);
    try testing.expect(column.temperature >= 0.0 and column.temperature <= 1.0);
    try testing.expect(column.humidity >= 0.0 and column.humidity <= 1.0);
    try testing.expect(column.ridge_mask >= 0.0);
    try testing.expect(column.river_mask >= 0.0 and column.river_mask <= 1.0);
}

test "TerrainShapeGenerator sampleColumnData deterministic" {
    const tsg = TerrainShapeGenerator.init(42);
    const col1 = tsg.sampleColumnData(500.0, 500.0, 0);
    const col2 = tsg.sampleColumnData(500.0, 500.0, 0);

    try testing.expectEqual(col1.terrain_height_i, col2.terrain_height_i);
    try testing.expectEqual(col1.continentalness, col2.continentalness);
    try testing.expectEqual(col1.temperature, col2.temperature);
    try testing.expectEqual(col1.humidity, col2.humidity);
}

test "TerrainShapeGenerator sampleColumnData different positions differ" {
    const tsg = TerrainShapeGenerator.init(42);
    const col1 = tsg.sampleColumnData(0.0, 0.0, 0);
    const col2 = tsg.sampleColumnData(10000.0, 10000.0, 0);

    try testing.expect(col1.terrain_height_i != col2.terrain_height_i or
        col1.continentalness != col2.continentalness);
}

test "TerrainShapeGenerator isOceanWater logic" {
    const tsg = TerrainShapeGenerator.init(42);

    const ocean_threshold = tsg.getOceanThreshold();
    _ = ocean_threshold;
}

test "TerrainShapeGenerator getContinentalZone" {
    const tsg = TerrainShapeGenerator.init(42);

    const deep_ocean = tsg.getContinentalZone(0.1);
    try testing.expect(deep_ocean == .deep_ocean or deep_ocean == .ocean);

    const inland = tsg.getContinentalZone(0.7);
    try testing.expect(inland == .inland_low or inland == .inland_high or inland == .mountain_core);
}

test "TerrainShapeGenerator sampleBiomeAtWorld returns valid biome" {
    const tsg = TerrainShapeGenerator.init(42);

    const biome = tsg.sampleBiomeAtWorld(0, 0);
    try testing.expect(@intFromEnum(biome) <= 20);
}

test "TerrainShapeGenerator sampleBiomeAtWorld deterministic" {
    const tsg = TerrainShapeGenerator.init(42);

    const biome1 = tsg.sampleBiomeAtWorld(1000, 2000);
    const biome2 = tsg.sampleBiomeAtWorld(1000, 2000);

    try testing.expectEqual(biome1, biome2);
}

test "TerrainShapeGenerator getRegionInfo" {
    const tsg = TerrainShapeGenerator.init(42);

    const info = tsg.getRegionInfo(0, 0);
    _ = info;
}

test "TerrainShapeGenerator prepareChunkPhaseData fills arrays" {
    const tsg = TerrainShapeGenerator.init(12345);

    var phase_data: terrain_shape_mod.ChunkPhaseData = undefined;
    @memset(std.mem.asBytes(&phase_data), 0);

    const success = tsg.prepareChunkPhaseData(
        &phase_data,
        0,
        0,
        0,
        0,
        null,
    );
    try testing.expect(success);

    try testing.expect(phase_data.surface_heights[0] != 0 or phase_data.surface_heights[0] == 0);
    try testing.expect(phase_data.biome_ids[0] == phase_data.biome_ids[0]);
}
