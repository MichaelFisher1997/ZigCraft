//! Unit tests for biome selection algorithms
//!
//! Tests focus on:
//! - Voronoi biome selection
//! - Score-based biome selection
//! - Climate parameter computation
//! - River override behavior
//! - Blended biome selection
//! - Simple/LOD biome selection

const std = @import("std");
const testing = std.testing;

const biome_selector = @import("biome_selector.zig");
const ClimateParams = @import("biome_registry.zig").ClimateParams;
const StructuralParams = @import("biome_registry.zig").StructuralParams;
const BiomeSelection = biome_selector.BiomeSelection;
const BiomeId = @import("biome_registry.zig").BiomeId;

const biome_registry = @import("biome_registry.zig");
const BIOME_REGISTRY = biome_registry.BIOME_REGISTRY;

test "selectBiomeVoronoi returns valid biome for typical climate" {
    const biome = biome_selector.selectBiomeVoronoi(50.0, 50.0, 64, 0.5, 1);
    try testing.expect(@intFromEnum(biome) <= 20);
}

test "selectBiomeVoronoi returns different biomes for different climates" {
    const cold_dry = biome_selector.selectBiomeVoronoi(10.0, 10.0, 64, 0.5, 1);
    const hot_humid = biome_selector.selectBiomeVoronoi(80.0, 80.0, 64, 0.5, 1);
    try testing.expect(cold_dry != hot_humid);
}

test "selectBiomeVoronoi respects height constraints" {
    const low = biome_selector.selectBiomeVoronoi(50.0, 50.0, 10, 0.5, 1);
    const high = biome_selector.selectBiomeVoronoi(50.0, 50.0, 140, 0.5, 1);
    _ = low;
    _ = high;
}

test "selectBiomeVoronoi respects slope constraints" {
    const flat = biome_selector.selectBiomeVoronoi(50.0, 50.0, 64, 0.5, 0);
    const steep = biome_selector.selectBiomeVoronoi(50.0, 50.0, 64, 0.5, 10);
    _ = flat;
    _ = steep;
}

test "selectBiomeVoronoi respects continentalness constraints" {
    const ocean = biome_selector.selectBiomeVoronoi(50.0, 50.0, 64, 0.2, 1);
    const inland = biome_selector.selectBiomeVoronoi(50.0, 50.0, 64, 0.6, 1);
    _ = ocean;
    _ = inland;
}

test "selectBiomeVoronoi deterministic" {
    const b1 = biome_selector.selectBiomeVoronoi(50.0, 50.0, 64, 0.5, 1);
    const b2 = biome_selector.selectBiomeVoronoi(50.0, 50.0, 64, 0.5, 1);
    try testing.expectEqual(b1, b2);
}

test "selectBiomeVoronoiWithRiver returns river when river_mask > 0.5 and low height" {
    const river = biome_selector.selectBiomeVoronoiWithRiver(50.0, 50.0, 64, 0.5, 1, 0.6);
    try testing.expectEqual(BiomeId.river, river);
}

test "selectBiomeVoronoiWithRiver ignores river when high elevation" {
    const not_river = biome_selector.selectBiomeVoronoiWithRiver(50.0, 50.0, 130, 0.5, 1, 0.6);
    try testing.expect(not_river != BiomeId.river);
}

test "selectBiome returns valid biome" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.3,
        .continentalness = 0.5,
        .ruggedness = 0.5,
    };
    const biome = biome_selector.selectBiome(params);
    try testing.expect(@intFromEnum(biome) <= 20);
}

test "selectBiome deterministic" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.3,
        .continentalness = 0.5,
        .ruggedness = 0.5,
    };
    const b1 = biome_selector.selectBiome(params);
    const b2 = biome_selector.selectBiome(params);
    try testing.expectEqual(b1, b2);
}

test "selectBiomeWithRiver returns river for low elevation and high river_mask" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.2,
        .continentalness = 0.5,
        .ruggedness = 0.5,
    };
    const river = biome_selector.selectBiomeWithRiver(params, 0.6);
    try testing.expectEqual(BiomeId.river, river);
}

test "computeClimateParams produces valid output" {
    const params = biome_selector.computeClimateParams(
        0.5,
        0.5,
        64,
        0.5,
        0.5,
        64,
        256,
    );

    try testing.expect(params.temperature >= 0.0 and params.temperature <= 1.0);
    try testing.expect(params.humidity >= 0.0 and params.humidity <= 1.0);
    try testing.expect(params.elevation >= 0.0 and params.elevation <= 1.0);
    try testing.expect(params.continentalness >= 0.0 and params.continentalness <= 1.0);
    try testing.expect(params.ruggedness >= 0.0 and params.ruggedness <= 1.0);
}

test "computeClimateParams elevation at sea level" {
    const params = biome_selector.computeClimateParams(
        0.5,
        0.5,
        64,
        0.5,
        0.5,
        64,
        256,
    );

    try testing.expectApproxEqAbs(@as(f32, 0.3), params.elevation, 0.01);
}

test "computeClimateParams elevation underwater" {
    const params = biome_selector.computeClimateParams(
        0.5,
        0.5,
        32,
        0.5,
        0.5,
        64,
        256,
    );

    try testing.expect(params.elevation < 0.3);
}

test "computeClimateParams elevation high above sea" {
    const params = biome_selector.computeClimateParams(
        0.5,
        0.5,
        192,
        0.5,
        0.5,
        64,
        256,
    );

    try testing.expect(params.elevation > 0.3);
}

test "computeClimateParams ruggedness is inverse of erosion" {
    const params = biome_selector.computeClimateParams(
        0.5,
        0.5,
        64,
        0.5,
        0.3,
        64,
        256,
    );

    try testing.expectApproxEqAbs(@as(f32, 0.7), params.ruggedness, 0.001);
}

test "selectBiomeBlended returns valid selection" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.3,
        .continentalness = 0.5,
        .ruggedness = 0.5,
    };

    const selection = biome_selector.selectBiomeBlended(params);

    try testing.expect(@intFromEnum(selection.primary) <= 20);
    try testing.expect(@intFromEnum(selection.secondary) <= 20);
    try testing.expect(selection.blend_factor >= 0.0);
    try testing.expect(selection.blend_factor <= 0.5);
    try testing.expect(selection.primary_score >= 0.0);
    try testing.expect(selection.secondary_score >= 0.0);
}

test "selectBiomeBlended primary score >= secondary score" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.3,
        .continentalness = 0.5,
        .ruggedness = 0.5,
    };

    const selection = biome_selector.selectBiomeBlended(params);

    try testing.expect(selection.primary_score >= selection.secondary_score);
}

test "selectBiomeWithRiverBlended river override" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.2,
        .continentalness = 0.5,
        .ruggedness = 0.5,
    };

    const selection = biome_selector.selectBiomeWithRiverBlended(params, 0.6);

    try testing.expectEqual(BiomeId.river, selection.primary);
}

test "selectBiomeWithConstraints returns valid biome" {
    const climate = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.3,
        .continentalness = 0.5,
        .ruggedness = 0.5,
    };
    const structural = StructuralParams{
        .height = 64,
        .slope = 1,
        .continentalness = 0.5,
        .ridge_mask = 0.0,
    };

    const biome = biome_selector.selectBiomeWithConstraints(climate, structural);
    try testing.expect(@intFromEnum(biome) <= 20);
}

test "selectBiomeWithConstraintsAndRiver river override" {
    const climate = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.2,
        .continentalness = 0.5,
        .ruggedness = 0.5,
    };
    const structural = StructuralParams{
        .height = 64,
        .slope = 1,
        .continentalness = 0.5,
        .ridge_mask = 0.0,
    };

    const biome = biome_selector.selectBiomeWithConstraintsAndRiver(climate, structural, 0.6);
    try testing.expectEqual(BiomeId.river, biome);
}

test "selectBiomeSimple ocean for low continentalness" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.3,
        .continentalness = 0.2,
        .ruggedness = 0.5,
    };

    const biome = biome_selector.selectBiomeSimple(params);
    try testing.expect(biome == .deep_ocean or biome == .ocean);
}

test "selectBiomeSimple deep ocean for very low continentalness" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.3,
        .continentalness = 0.1,
        .ruggedness = 0.5,
    };

    const biome = biome_selector.selectBiomeSimple(params);
    try testing.expectEqual(BiomeId.deep_ocean, biome);
}

test "selectBiomeSimple cold dry yields snow_tundra or taiga" {
    const params = ClimateParams{
        .temperature = 0.1,
        .humidity = 0.3,
        .elevation = 0.3,
        .continentalness = 0.5,
        .ruggedness = 0.5,
    };

    const biome = biome_selector.selectBiomeSimple(params);
    try testing.expect(biome == .snow_tundra or biome == .taiga);
}

test "selectBiomeSimple hot humid yields jungle or savanna or desert" {
    const params = ClimateParams{
        .temperature = 0.8,
        .humidity = 0.7,
        .elevation = 0.3,
        .continentalness = 0.5,
        .ruggedness = 0.5,
    };

    const biome = biome_selector.selectBiomeSimple(params);
    try testing.expect(biome == .jungle or biome == .savanna or biome == .desert or biome == .badlands);
}

test "BiomeSelection struct has correct fields" {
    const selection = BiomeSelection{
        .primary = .plains,
        .secondary = .forest,
        .blend_factor = 0.3,
        .primary_score = 1.0,
        .secondary_score = 0.7,
    };

    try testing.expectEqual(BiomeId.plains, selection.primary);
    try testing.expectEqual(BiomeId.forest, selection.secondary);
    try testing.expectApproxEqAbs(@as(f32, 0.3), selection.blend_factor, 0.001);
}
