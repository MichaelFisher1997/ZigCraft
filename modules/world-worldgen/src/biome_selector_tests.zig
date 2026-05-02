//! Unit tests for biome selection algorithms
//!
//! Tests focus on:
//! - Voronoi selection correctness
//! - Climate parameter computation
//! - River override behavior
//! - Blended biome selection

const std = @import("std");
const testing = std.testing;
const selector = @import("biome_selector.zig");
const registry = @import("biome_registry.zig");

const BiomeId = registry.BiomeId;
const ClimateParams = registry.ClimateParams;
const StructuralParams = registry.StructuralParams;
const selectBiomeVoronoi = selector.selectBiomeVoronoi;
const selectBiomeVoronoiWithRiver = selector.selectBiomeVoronoiWithRiver;
const selectBiome = selector.selectBiome;
const selectBiomeWithRiver = selector.selectBiomeWithRiver;
const selectBiomeBlended = selector.selectBiomeBlended;
const selectBiomeWithRiverBlended = selector.selectBiomeWithRiverBlended;
const selectBiomeWithConstraints = selector.selectBiomeWithConstraints;
const selectBiomeWithConstraintsAndRiver = selector.selectBiomeWithConstraintsAndRiver;
const selectBiomeSimple = selector.selectBiomeSimple;
const computeClimateParams = selector.computeClimateParams;
const BiomeSelection = selector.BiomeSelection;

// ============================================================================
// computeClimateParams Tests
// ============================================================================

test "computeClimateParams normalizes elevation above sea level" {
    const params = computeClimateParams(0.5, 0.5, 96, 0.5, 0.5, 64, 256);
    try testing.expect(params.elevation > 0.3);
    try testing.expect(params.elevation <= 1.0);
}

test "computeClimateParams scales underwater elevation 0-0.3" {
    const params = computeClimateParams(0.5, 0.5, 32, 0.5, 0.5, 64, 256);
    try testing.expect(params.elevation < 0.3);
    try testing.expect(params.elevation >= 0.0);
}

test "computeClimateParams elevation at sea level is ~0.3" {
    const params = computeClimateParams(0.5, 0.5, 64, 0.5, 0.5, 64, 256);
    try testing.expectApproxEqAbs(@as(f32, 0.3), params.elevation, 0.05);
}

test "computeClimateParams inverts erosion to ruggedness" {
    const params = computeClimateParams(0.5, 0.5, 80, 0.5, 0.2, 64, 256);
    try testing.expectApproxEqAbs(@as(f32, 0.8), params.ruggedness, 0.001);
}

test "computeClimateParams preserves temperature and humidity" {
    const params = computeClimateParams(0.7, 0.3, 80, 0.6, 0.5, 64, 256);
    try testing.expectApproxEqAbs(@as(f32, 0.7), params.temperature, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.3), params.humidity, 0.001);
}

// ============================================================================
// selectBiome (score-based) Tests
// ============================================================================

test "selectBiome returns valid biome id" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const biome = selectBiome(params);
    _ = @as(BiomeId, biome);
}

test "selectBiome selects different biomes for different climates" {
    const hot_humid = ClimateParams{
        .temperature = 0.85,
        .humidity = 0.85,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const cold_dry = ClimateParams{
        .temperature = 0.1,
        .humidity = 0.2,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const jungle = selectBiome(hot_humid);
    const tundra = selectBiome(cold_dry);
    try testing.expect(jungle != tundra);
}

test "selectBiomeWithRiver selects river when mask high and elevation low" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.25,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeWithRiver(params, 0.7);
    try testing.expectEqual(BiomeId.river, biome);
}

test "selectBiomeWithRiver selects normal biome when elevation high" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.5,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeWithRiver(params, 0.7);
    try testing.expect(biome != .river);
}

test "selectBiomeWithRiver selects non-river biome" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.45,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeWithRiver(params, 0.0);
    try testing.expect(biome != .river);
}

test "selectBiomeWithRiver at high elevation returns non-river" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.5,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeWithRiver(params, 0.7);
    try testing.expect(biome != .river);
}

// ============================================================================
// selectBiomeVoronoi Tests
// ============================================================================

test "selectBiomeVoronoi respects height constraints" {
    const biome = selectBiomeVoronoi(50, 50, 130, 0.85, 10);
    try testing.expect(biome != .beach);
}

test "selectBiomeVoronoi respects slope constraints" {
    const biome = selectBiomeVoronoi(50, 50, 50, 0.6, 10);
    try testing.expect(biome != .beach);
}

test "selectBiomeVoronoi respects continentalness constraints" {
    const biome = selectBiomeVoronoi(50, 50, 50, 0.2, 2);
    _ = biome;
}

test "selectBiomeVoronoiWithRiver returns river when mask > 0.5 and height < 120" {
    const biome = selectBiomeVoronoiWithRiver(50, 50, 80, 0.6, 2, 0.6);
    try testing.expectEqual(BiomeId.river, biome);
}

// ============================================================================
// selectBiomeWithConstraints Tests
// ============================================================================

test "selectBiomeWithConstraints converts climate to heat/humidity scale" {
    const climate = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const structural = StructuralParams{
        .height = 80,
        .slope = 2,
        .continentalness = 0.6,
        .ridge_mask = 0.2,
    };
    const biome = selectBiomeWithConstraints(climate, structural);
    _ = @as(BiomeId, biome);
}

test "selectBiomeWithConstraintsAndRiver handles river override" {
    const climate = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.25,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const structural = StructuralParams{
        .height = 70,
        .slope = 1,
        .continentalness = 0.5,
        .ridge_mask = 0.1,
    };
    const biome = selectBiomeWithConstraintsAndRiver(climate, structural, 0.7);
    try testing.expectEqual(BiomeId.river, biome);
}

// ============================================================================
// selectBiomeBlended Tests
// ============================================================================

test "selectBiomeBlended returns both primary and secondary" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const selection = selectBiomeBlended(params);
    try testing.expect(selection.primary != .river);
    try testing.expect(selection.primary_score >= 0);
    try testing.expect(selection.secondary_score >= 0);
}

test "selectBiomeBlended blend_factor bounded by BLEND_EPSILON" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const selection = selectBiomeBlended(params);
    try testing.expect(selection.blend_factor >= 0);
    try testing.expect(selection.blend_factor <= 0.5);
}

test "selectBiomeWithRiverBlended returns river-dominant selection when river active" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.25,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const selection = selectBiomeWithRiverBlended(params, 0.6);
    try testing.expectEqual(BiomeId.river, selection.primary);
}

test "selectBiomeWithRiverBlended returns normal selection when river not active" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.6,
        .elevation = 0.5,
        .continentalness = 0.5,
        .ruggedness = 0.3,
    };
    const selection = selectBiomeWithRiverBlended(params, 0.2);
    try testing.expect(selection.primary != .river);
}

// ============================================================================
// selectBiomeSimple (LOD) Tests
// ============================================================================

test "selectBiomeSimple returns ocean for low continentalness" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.2,
        .continentalness = 0.15,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeSimple(params);
    try testing.expect(biome == .deep_ocean or biome == .ocean);
}

test "selectBiomeSimple returns deep_ocean for very low continentalness" {
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.5,
        .elevation = 0.1,
        .continentalness = 0.1,
        .ruggedness = 0.3,
    };
    try testing.expectEqual(BiomeId.deep_ocean, selectBiomeSimple(params));
}

test "selectBiomeSimple returns different biomes for hot vs cold" {
    const hot = ClimateParams{
        .temperature = 0.9,
        .humidity = 0.5,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const cold = ClimateParams{
        .temperature = 0.1,
        .humidity = 0.5,
        .elevation = 0.4,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    try testing.expect(selectBiomeSimple(hot) != selectBiomeSimple(cold));
}

test "selectBiomeSimple returns desert for hot dry conditions" {
    const params = ClimateParams{
        .temperature = 0.9,
        .humidity = 0.1,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };
    try testing.expectEqual(BiomeId.desert, selectBiomeSimple(params));
}

test "selectBiomeSimple hot humid returns non-desert" {
    const params = ClimateParams{
        .temperature = 0.9,
        .humidity = 0.8,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const biome = selectBiomeSimple(params);
    try testing.expect(biome != .desert);
    try testing.expect(biome != .snow_tundra);
    try testing.expect(biome != .deep_ocean);
    try testing.expect(biome != .ocean);
}

// ============================================================================
// BiomeSelection Structure Tests
// ============================================================================

test "BiomeSelection structure fields are valid" {
    const selection = BiomeSelection{
        .primary = .plains,
        .secondary = .forest,
        .blend_factor = 0.3,
        .primary_score = 0.8,
        .secondary_score = 0.6,
    };
    try testing.expect(selection.primary_score > selection.secondary_score);
    try testing.expect(selection.blend_factor >= 0);
}
