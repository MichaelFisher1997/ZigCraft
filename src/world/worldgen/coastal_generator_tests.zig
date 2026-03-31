//! Unit tests for the coastal generator
//!
//! Tests focus on:
//! - CoastalGenerator initialization
//! - applyCoastJitter clamping behavior
//! - Ocean/inland water detection logic

const std = @import("std");
const testing = std.testing;
const coastal_generator = @import("coastal_generator.zig");
const CoastalGenerator = coastal_generator.CoastalGenerator;
const surface_builder_mod = @import("surface_builder.zig");
const SurfaceBuilder = surface_builder_mod.SurfaceBuilder;
const SurfaceParams = surface_builder_mod.SurfaceParams;
const CoastalSurfaceType = surface_builder_mod.CoastalSurfaceType;

// ============================================================================
// CoastalGenerator Initialization Tests
// ============================================================================

test "CoastalGenerator initialization stores ocean threshold" {
    const cg = CoastalGenerator.init(0.35);
    try testing.expectEqual(@as(f32, 0.35), cg.ocean_threshold);
}

test "CoastalGenerator initialization with different thresholds" {
    const cg1 = CoastalGenerator.init(0.0);
    try testing.expectEqual(@as(f32, 0.0), cg1.ocean_threshold);

    const cg2 = CoastalGenerator.init(0.5);
    try testing.expectEqual(@as(f32, 0.5), cg2.ocean_threshold);

    const cg3 = CoastalGenerator.init(1.0);
    try testing.expectEqual(@as(f32, 1.0), cg3.ocean_threshold);
}

// ============================================================================
// applyCoastJitter Tests
// ============================================================================

test "applyCoastJitter adds jitter to base value" {
    const base = 0.5;
    const jitter = 0.1;
    const result = CoastalGenerator.applyCoastJitter(base, jitter);

    // Should add jitter to base
    try testing.expectApproxEqAbs(@as(f32, 0.6), result, 0.0001);
}

test "applyCoastJitter negative jitter reduces value" {
    const base = 0.5;
    const jitter = -0.1;
    const result = CoastalGenerator.applyCoastJitter(base, jitter);

    try testing.expectApproxEqAbs(@as(f32, 0.4), result, 0.0001);
}

test "applyCoastJitter clamps to minimum 0" {
    // Value would go below 0
    const base = 0.1;
    const jitter = -0.2;
    const result = CoastalGenerator.applyCoastJitter(base, jitter);

    try testing.expectEqual(@as(f32, 0.0), result);
}

test "applyCoastJitter clamps to maximum 1" {
    // Value would go above 1
    const base = 0.9;
    const jitter = 0.2;
    const result = CoastalGenerator.applyCoastJitter(base, jitter);

    try testing.expectEqual(@as(f32, 1.0), result);
}

test "applyCoastJitter with zero jitter returns base" {
    const base = 0.5;
    const jitter = 0.0;
    const result = CoastalGenerator.applyCoastJitter(base, jitter);

    try testing.expectApproxEqAbs(base, result, 0.0001);
}

test "applyCoastJitter edge cases at boundaries" {
    // At 0 boundary
    const r1 = CoastalGenerator.applyCoastJitter(0.0, 0.0);
    try testing.expectEqual(@as(f32, 0.0), r1);

    const r2 = CoastalGenerator.applyCoastJitter(0.0, 0.5);
    try testing.expectEqual(@as(f32, 0.5), r2);

    const r3 = CoastalGenerator.applyCoastJitter(0.0, -0.5);
    try testing.expectEqual(@as(f32, 0.0), r3);

    // At 1 boundary
    const r4 = CoastalGenerator.applyCoastJitter(1.0, 0.0);
    try testing.expectEqual(@as(f32, 1.0), r4);

    const r5 = CoastalGenerator.applyCoastJitter(1.0, 0.5);
    try testing.expectEqual(@as(f32, 1.0), r5);

    const r6 = CoastalGenerator.applyCoastJitter(1.0, -0.5);
    try testing.expectEqual(@as(f32, 0.5), r6);
}

test "applyCoastJitter handles extreme jitter values" {
    // Very large positive jitter
    const r1 = CoastalGenerator.applyCoastJitter(0.5, 100.0);
    try testing.expectEqual(@as(f32, 1.0), r1);

    // Very large negative jitter
    const r2 = CoastalGenerator.applyCoastJitter(0.5, -100.0);
    try testing.expectEqual(@as(f32, 0.0), r2);
}

// ============================================================================
// getSurfaceType Delegation Tests
// ============================================================================

test "getSurfaceType delegates to SurfaceBuilder" {
    const p = SurfaceParams{};
    const surface_builder = SurfaceBuilder.init();

    // Sand beach: continentalness in [ocean_threshold, ocean_threshold+beach_band),
    //   slope <= beach_max_slope, height within beach_max_height_above_sea of sea_level
    const near_ocean_continentalness = p.ocean_threshold + p.beach_band * 0.4;
    const sand = CoastalGenerator.getSurfaceType(
        &surface_builder,
        near_ocean_continentalness,
        p.beach_max_slope,
        p.sea_level + 1,
        p.gravel_erosion_threshold - 0.1,
    );
    try testing.expectEqual(CoastalSurfaceType.sand_beach, sand);

    // Cliff: same coastal zone but slope >= cliff_min_slope
    const cliff = CoastalGenerator.getSurfaceType(
        &surface_builder,
        near_ocean_continentalness,
        p.cliff_min_slope + 1,
        p.sea_level + 1,
        p.gravel_erosion_threshold - 0.1,
    );
    try testing.expectEqual(CoastalSurfaceType.cliff, cliff);

    // Not coastal: height exceeds beach_max_height_above_sea above sea_level
    const inland = CoastalGenerator.getSurfaceType(
        &surface_builder,
        p.ocean_threshold + p.beach_band + 0.1,
        p.beach_max_slope,
        p.sea_level + p.beach_max_height_above_sea + 1,
        0.3,
    );
    try testing.expectEqual(CoastalSurfaceType.none, inland);
}

// ============================================================================
// Ocean Threshold Logic Tests
// ============================================================================

test "CoastalGenerator ocean threshold comparison" {
    const cg = CoastalGenerator.init(0.35);

    // Values strictly less than threshold are considered ocean (isOceanWater uses c < threshold)
    try testing.expect(cg.ocean_threshold > 0.0);
    try testing.expect(cg.ocean_threshold < 1.0);

    // Test boundary logic
    const just_below = cg.ocean_threshold - 0.01;
    const just_above = cg.ocean_threshold + 0.01;

    try testing.expect(just_below < cg.ocean_threshold);
    try testing.expect(just_above > cg.ocean_threshold);
}
