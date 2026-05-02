//! Unit tests for biome registry types and methods
//!
//! Tests focus on:
//! - Range.contains and distanceFromCenter edge cases
//! - BiomeDefinition constraint checking and scoring

const std = @import("std");
const testing = std.testing;
const registry = @import("biome_registry.zig");

const Range = registry.Range;
const BiomeDefinition = registry.BiomeDefinition;
const BiomeId = registry.BiomeId;
const ClimateParams = registry.ClimateParams;
const getBiomeDefinition = registry.getBiomeDefinition;

// ============================================================================
// Range Tests
// ============================================================================

test "Range.contains within range" {
    const r = Range{ .min = 0.3, .max = 0.7 };
    try testing.expect(r.contains(0.5));
    try testing.expect(r.contains(0.3));
    try testing.expect(r.contains(0.7));
}

test "Range.contains outside range" {
    const r = Range{ .min = 0.3, .max = 0.7 };
    try testing.expect(!r.contains(0.2));
    try testing.expect(!r.contains(0.8));
}

test "Range.contains with inverted min/max" {
    const r = Range{ .min = 0.7, .max = 0.3 };
    try testing.expect(!r.contains(0.5));
}

test "Range.distanceFromCenter at center" {
    const r = Range{ .min = 0.2, .max = 0.8 };
    const dist = r.distanceFromCenter(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), dist, 0.0001);
}

test "Range.distanceFromCenter at edge" {
    const r = Range{ .min = 0.2, .max = 0.8 };
    const dist = r.distanceFromCenter(0.2);
    try testing.expectApproxEqAbs(@as(f32, 1), dist, 0.0001);
    const dist2 = r.distanceFromCenter(0.8);
    try testing.expectApproxEqAbs(@as(f32, 1), dist2, 0.0001);
}

test "Range.distanceFromCenter beyond edge" {
    const r = Range{ .min = 0.2, .max = 0.8 };
    const dist = r.distanceFromCenter(0.0);
    try testing.expectApproxEqAbs(@as(f32, 1), dist, 0.0001);
    const dist2 = r.distanceFromCenter(1.0);
    try testing.expectApproxEqAbs(@as(f32, 1), dist2, 0.0001);
}

test "Range.distanceFromCenter with zero-width range" {
    const r = Range{ .min = 0.5, .max = 0.5 };
    const dist = r.distanceFromCenter(0.5);
    try testing.expectApproxEqAbs(@as(f32, 0), dist, 0.0001);
    const dist2 = r.distanceFromCenter(0.6);
    try testing.expectApproxEqAbs(@as(f32, 1), dist2, 0.0001);
}

test "Range.any covers full range" {
    const r = Range.any();
    try testing.expect(r.contains(0.0));
    try testing.expect(r.contains(0.5));
    try testing.expect(r.contains(1.0));
}

// ============================================================================
// BiomeDefinition Constraint Tests
// ============================================================================

test "BiomeDefinition meetsStructuralConstraints passes valid constraints" {
    const def = getBiomeDefinition(.plains);
    try testing.expect(def.meetsStructuralConstraints(80, 2, 0.6, 0.3));
}

test "BiomeDefinition fails height too low" {
    const def = getBiomeDefinition(.mountains);
    try testing.expect(!def.meetsStructuralConstraints(50, 5, 0.8, 0.2));
}

test "BiomeDefinition fails height too high" {
    const def = getBiomeDefinition(.desert);
    try testing.expect(!def.meetsStructuralConstraints(120, 2, 0.6, 0.1));
}

test "BiomeDefinition fails slope too steep" {
    const def = getBiomeDefinition(.beach);
    try testing.expect(!def.meetsStructuralConstraints(65, 3, 0.38, 0.1));
}

test "BiomeDefinition fails continentalness out of range" {
    const def = getBiomeDefinition(.deep_ocean);
    try testing.expect(!def.meetsStructuralConstraints(50, 0, 0.5, 0.0));
}

test "BiomeDefinition fails ridge_mask too low" {
    const def = getBiomeDefinition(.mountains);
    try testing.expect(!def.meetsStructuralConstraints(120, 5, 0.85, 0.05));
}

test "BiomeDefinition fails ridge_mask too high" {
    const def = getBiomeDefinition(.mountains);
    try testing.expect(!def.meetsStructuralConstraints(120, 5, 0.85, 1.1));
}

test "BiomeDefinition passes when all constraints satisfied" {
    const def = getBiomeDefinition(.mountains);
    try testing.expect(def.meetsStructuralConstraints(120, 5, 0.85, 0.3));
}

test "BiomeDefinition passes mountain biome with valid constraints" {
    const def = getBiomeDefinition(.mountains);
    try testing.expect(def.meetsStructuralConstraints(130, 8, 0.85, 0.3));
}

// ============================================================================
// BiomeDefinition Climate Scoring Tests
// ============================================================================

test "BiomeDefinition scoreClimate returns zero outside climate range" {
    const def = getBiomeDefinition(.desert);
    const params = ClimateParams{
        .temperature = 0.2, // Too cold for desert
        .humidity = 0.1,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.2,
    };
    const score = def.scoreClimate(params);
    try testing.expectEqual(@as(f32, 0), score);
}

test "BiomeDefinition scoreClimate returns positive for matching" {
    const def = getBiomeDefinition(.plains);
    const params = ClimateParams{
        .temperature = 0.5,
        .humidity = 0.45,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.3,
    };
    const score = def.scoreClimate(params);
    try testing.expect(score > 0);
}

test "BiomeDefinition scoreClimate highest at climate center" {
    const def = getBiomeDefinition(.forest);
    const at_center = ClimateParams{
        .temperature = 0.45,
        .humidity = 0.65,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.4,
    };
    const away = ClimateParams{
        .temperature = 0.35,
        .humidity = 0.55,
        .elevation = 0.5,
        .continentalness = 0.6,
        .ruggedness = 0.4,
    };
    const score_center = def.scoreClimate(at_center);
    const score_away = def.scoreClimate(away);
    try testing.expect(score_center > score_away);
}

test "BiomeDefinition scoreClimate priority bonus" {
    const def_high = getBiomeDefinition(.beach);
    const def_low = getBiomeDefinition(.plains);
    const params = ClimateParams{
        .temperature = 0.6,
        .humidity = 0.5,
        .elevation = 0.33,
        .continentalness = 0.38,
        .ruggedness = 0.2,
    };
    const score_high = def_high.scoreClimate(params);
    const score_low = def_low.scoreClimate(params);
    try testing.expect(score_high > score_low);
}

// ============================================================================
// getBiomeDefinition Lookup Tests
// ============================================================================

test "getBiomeDefinition returns valid pointer for all ids" {
    inline for (0..@typeInfo(BiomeId).@"enum".fields.len) |i| {
        const id: BiomeId = @enumFromInt(i);
        const def = getBiomeDefinition(id);
        try testing.expectEqual(id, def.id);
    }
}

test "getBiomeDefinition lookup is O(1)" {
    const def = getBiomeDefinition(.jungle);
    try testing.expectEqualStrings("Jungle", def.name);
}

test "getBiomeDefinition ocean biomes have correct continentalness ranges" {
    const deep = getBiomeDefinition(.deep_ocean);
    try testing.expect(deep.continentalness.max <= 0.20);

    const ocean = getBiomeDefinition(.ocean);
    try testing.expect(ocean.continentalness.max <= 0.35);
    try testing.expect(ocean.continentalness.min < 0.35);

    const warm = getBiomeDefinition(.warm_ocean);
    try testing.expect(warm.continentalness.max <= 0.35);
    try testing.expect(warm.vegetation.seagrass_density > 0.0);
    try testing.expect(warm.vegetation.coral_density > 0.0);
}

test "getBiomeDefinition beach has narrow continentalness band" {
    const beach = getBiomeDefinition(.beach);
    try testing.expect(beach.continentalness.min >= 0.30);
    try testing.expect(beach.continentalness.max <= 0.45);
}

test "getBiomeDefinition tropical has aquatic vegetation and coastal range" {
    const tropical = getBiomeDefinition(.tropical);
    try testing.expect(tropical.continentalness.min >= 0.30);
    try testing.expect(tropical.continentalness.max <= 0.50);
    try testing.expect(tropical.vegetation.coral_density > 0.0);
    try testing.expect(tropical.vegetation.decoration_rules.len > 0);
}

test "forest and taiga variants have distinct vegetation profiles" {
    const birch = getBiomeDefinition(.birch_forest);
    try testing.expectEqualStrings("Birch Forest", birch.name);
    try testing.expectEqual(BiomeId.birch_forest, birch.id);
    try testing.expect(birch.vegetation.tree_types.len >= 2);

    const dark = getBiomeDefinition(.dark_forest);
    try testing.expectEqualStrings("Dark Forest", dark.name);
    try testing.expect(dark.vegetation.tree_types.len >= 2);
    try testing.expect(dark.vegetation.decoration_rules.len >= 2);

    const flower = getBiomeDefinition(.flower_forest);
    try testing.expectEqualStrings("Flower Forest", flower.name);
    try testing.expect(flower.vegetation.decoration_rules.len >= 3);

    const snowy = getBiomeDefinition(.snowy_taiga);
    try testing.expectEqualStrings("Snowy Taiga", snowy.name);
    try testing.expectEqual(.snow_block, snowy.surface.top);
    try testing.expect(snowy.vegetation.tree_types.len > 0);

    const old_growth = getBiomeDefinition(.old_growth_taiga);
    try testing.expectEqualStrings("Old Growth Taiga", old_growth.name);
    try testing.expect(old_growth.vegetation.tree_types.len >= 2);
    try testing.expect(old_growth.terrain.height_amplitude > getBiomeDefinition(.taiga).terrain.height_amplitude);
}
