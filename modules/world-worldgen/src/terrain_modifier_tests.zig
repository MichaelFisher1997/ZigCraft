//! Unit tests for terrain modifier height semantics.

const std = @import("std");
const testing = std.testing;
const TerrainModifier = @import("biome_registry.zig").TerrainModifier;

const SEA_LEVEL: f32 = 62.0;

test "TerrainModifier defaults preserve sampled height" {
    const modifier = TerrainModifier{};

    try testing.expectApproxEqAbs(@as(f32, 62.0), modifier.applyHeight(62.0, SEA_LEVEL), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 144.0), modifier.applyHeight(144.0, SEA_LEVEL), 0.0001);
}

test "TerrainModifier height_amplitude scales relief around sea level" {
    const flat = TerrainModifier{ .height_amplitude = 0.0 };
    const doubled = TerrainModifier{ .height_amplitude = 2.0 };

    try testing.expectApproxEqAbs(@as(f32, 62.0), flat.applyHeight(144.0, SEA_LEVEL), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 226.0), doubled.applyHeight(144.0, SEA_LEVEL), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 42.0), doubled.applyHeight(52.0, SEA_LEVEL), 0.0001);
}

test "TerrainModifier smoothing blends height toward sea level" {
    const unchanged = TerrainModifier{ .smoothing = 0.0 };
    const half = TerrainModifier{ .smoothing = 0.5 };
    const full = TerrainModifier{ .smoothing = 1.0 };

    try testing.expectApproxEqAbs(@as(f32, 102.0), unchanged.applyHeight(102.0, SEA_LEVEL), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 82.0), half.applyHeight(102.0, SEA_LEVEL), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 62.0), full.applyHeight(102.0, SEA_LEVEL), 0.0001);
}

test "TerrainModifier clamp_to_sea_level forces height before offset" {
    const modifier = TerrainModifier{ .clamp_to_sea_level = true, .height_offset = -2.0 };

    try testing.expectApproxEqAbs(@as(f32, 60.0), modifier.applyHeight(61.0, SEA_LEVEL), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 60.0), modifier.applyHeight(180.0, SEA_LEVEL), 0.0001);
}

test "TerrainModifier height_offset applies after shaping" {
    const raised = TerrainModifier{ .height_offset = 8.0 };
    const lowered = TerrainModifier{ .height_offset = -3.0 };

    try testing.expectApproxEqAbs(@as(f32, 70.0), raised.applyHeight(62.0, SEA_LEVEL), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 141.0), lowered.applyHeight(144.0, SEA_LEVEL), 0.0001);
}

test "TerrainModifier combines amplitude smoothing clamp and offset deterministically" {
    const shaped = TerrainModifier{ .height_amplitude = 1.5, .smoothing = 0.5, .height_offset = 4.0 };
    const clamped = TerrainModifier{ .height_amplitude = 1.5, .smoothing = 0.5, .clamp_to_sea_level = true, .height_offset = 4.0 };

    try testing.expectApproxEqAbs(@as(f32, 96.0), shaped.applyHeight(102.0, SEA_LEVEL), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 66.0), clamped.applyHeight(102.0, SEA_LEVEL), 0.0001);
}
