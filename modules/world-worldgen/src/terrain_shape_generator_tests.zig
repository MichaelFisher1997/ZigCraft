//! Unit tests for terrain shape generator types
//!
//! Tests focus on:
//! - ColumnData struct initialization and defaults
//! - Params struct defaults
//! - ChunkPhaseData array dimensions

const std = @import("std");
const testing = std.testing;
const terrain_shape_mod = @import("terrain_shape_generator.zig");

const ColumnData = terrain_shape_mod.ColumnData;
const Params = terrain_shape_mod.Params;
const ChunkPhaseData = terrain_shape_mod.ChunkPhaseData;

const CHUNK_SIZE_X = @import("world-core").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("world-core").CHUNK_SIZE_Z;

// ============================================================================
// ColumnData Tests
// ============================================================================

test "ColumnData initialization sets all fields" {
    const data = ColumnData{
        .terrain_height = 80.0,
        .terrain_height_i = 80,
        .continentalness = 0.6,
        .erosion = 0.4,
        .river_mask = 0.2,
        .temperature = 0.5,
        .humidity = 0.6,
        .ridge_mask = 0.3,
        .is_underwater = false,
        .is_ocean = false,
        .cave_region = 0.5,
    };
    try testing.expectEqual(@as(f32, 80.0), data.terrain_height);
    try testing.expectEqual(@as(i32, 80), data.terrain_height_i);
    try testing.expectEqual(@as(f32, 0.6), data.continentalness);
    try testing.expect(!data.is_underwater);
    try testing.expect(!data.is_ocean);
}

test "ColumnData can represent underwater ocean column" {
    const data = ColumnData{
        .terrain_height = 50.0,
        .terrain_height_i = 50,
        .continentalness = 0.2,
        .erosion = 0.5,
        .river_mask = 0.0,
        .temperature = 0.5,
        .humidity = 0.5,
        .ridge_mask = 0.1,
        .is_underwater = true,
        .is_ocean = true,
        .cave_region = 0.6,
    };
    try testing.expect(data.is_underwater);
    try testing.expect(data.is_ocean);
    try testing.expect(data.terrain_height < 64.0);
}

// ============================================================================
// Params Tests
// ============================================================================

test "Params default values" {
    const params = Params{};
    try testing.expectEqual(@as(f32, 0.25), params.temp_lapse);
    try testing.expectEqual(@as(i32, 64), params.sea_level);
    try testing.expectEqual(@as(f32, 0.37), params.ocean_threshold);
    try testing.expectEqual(@as(f32, 0.48), params.ridge_inland_min);
    try testing.expectEqual(@as(f32, 0.68), params.ridge_inland_max);
    try testing.expectEqual(@as(f32, 0.46), params.ridge_sparsity);
    try testing.expect(!params.disable_caves);
}

test "Params can be customized" {
    const params = Params{
        .temp_lapse = 0.5,
        .sea_level = 32,
        .ocean_threshold = 0.4,
        .ridge_inland_min = 0.4,
        .ridge_inland_max = 0.8,
        .ridge_sparsity = 0.3,
        .disable_caves = true,
    };
    try testing.expectEqual(@as(f32, 0.5), params.temp_lapse);
    try testing.expectEqual(@as(i32, 32), params.sea_level);
    try testing.expectEqual(@as(f32, 0.4), params.ocean_threshold);
    try testing.expect(params.disable_caves);
}

// ============================================================================
// ChunkPhaseData Tests
// ============================================================================

test "ChunkPhaseData has correct array sizes" {
    const phase_data: ChunkPhaseData = undefined;
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.surface_heights.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.biome_ids.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.secondary_biome_ids.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.biome_blends.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.filler_depths.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.is_underwater_flags.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.is_ocean_water_flags.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.cave_region_values.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.continentalness_values.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.erosion_values.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.ridge_masks.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.river_masks.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.temperatures.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.humidities.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.slopes.len);
    try testing.expectEqual(@as(usize, CHUNK_SIZE_X * CHUNK_SIZE_Z), phase_data.coastal_types.len);
}

test "ChunkPhaseData arrays are large enough for 16x16 chunk" {
    try testing.expect(CHUNK_SIZE_X >= 16);
    try testing.expect(CHUNK_SIZE_Z >= 16);
    try testing.expectEqual(@as(usize, 256), CHUNK_SIZE_X * CHUNK_SIZE_Z);
}
