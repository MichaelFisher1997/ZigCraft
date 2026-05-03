//! Unit tests for terrain modifier height semantics.

const std = @import("std");
const testing = std.testing;
const biome_registry = @import("biome_registry.zig");
const TerrainModifier = biome_registry.TerrainModifier;
const getBiomeDefinition = biome_registry.getBiomeDefinition;

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

test "TerrainModifier blend interpolates shaping for biome seams" {
    const plains = TerrainModifier{ .height_amplitude = 0.7, .smoothing = 0.2 };
    const coastal = TerrainModifier{ .height_amplitude = 0.5, .smoothing = 0.3 };
    const blended = TerrainModifier.blend(plains, coastal, 0.5);

    try testing.expectApproxEqAbs(@as(f32, 0.6), blended.height_amplitude, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.25), blended.smoothing, 0.0001);

    const base_height: f32 = 92.0;
    const plains_height = plains.applyHeight(base_height, SEA_LEVEL);
    const coastal_height = coastal.applyHeight(base_height, SEA_LEVEL);
    const blended_height = blended.applyHeight(base_height, SEA_LEVEL);

    try testing.expect(blended_height > coastal_height);
    try testing.expect(blended_height < plains_height);
}

test "TerrainModifier blend clamps t and switches sea-level clamp at midpoint" {
    const raised = TerrainModifier{ .height_offset = 10.0 };
    const wetland = TerrainModifier{ .clamp_to_sea_level = true };

    try testing.expectApproxEqAbs(@as(f32, 10.0), TerrainModifier.blend(raised, wetland, -1.0).height_offset, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), TerrainModifier.blend(raised, wetland, 2.0).height_offset, 0.0001);
    try testing.expect(!TerrainModifier.blend(raised, wetland, 0.49).clamp_to_sea_level);
    try testing.expect(TerrainModifier.blend(raised, wetland, 0.5).clamp_to_sea_level);
}

test "wetland terrain modifiers flatten and lower sampled heights" {
    const base_low: f32 = 80.0;
    const base_high: f32 = 112.0;
    const plains = getBiomeDefinition(.plains).terrain;
    const swamp = getBiomeDefinition(.swamp).terrain;
    const mangrove = getBiomeDefinition(.mangrove_swamp).terrain;
    const marsh = getBiomeDefinition(.marsh).terrain;

    try testing.expectApproxEqAbs(SEA_LEVEL, swamp.applyHeight(base_high, SEA_LEVEL), 0.0001);
    try testing.expectApproxEqAbs(SEA_LEVEL, mangrove.applyHeight(base_high, SEA_LEVEL), 0.0001);

    const plains_relief = plains.applyHeight(base_high, SEA_LEVEL) - plains.applyHeight(base_low, SEA_LEVEL);
    const marsh_relief = marsh.applyHeight(base_high, SEA_LEVEL) - marsh.applyHeight(base_low, SEA_LEVEL);
    try testing.expect(marsh.applyHeight(base_high, SEA_LEVEL) < plains.applyHeight(base_high, SEA_LEVEL));
    try testing.expect(marsh_relief < plains_relief);
}

test "wetland terrain keeps swamp and mangrove surfaces vegetation-compatible" {
    const swamp = getBiomeDefinition(.swamp);
    const mangrove = getBiomeDefinition(.mangrove_swamp);

    try testing.expectApproxEqAbs(SEA_LEVEL, swamp.terrain.applyHeight(96.0, SEA_LEVEL), 0.0001);
    try testing.expectApproxEqAbs(SEA_LEVEL, mangrove.terrain.applyHeight(96.0, SEA_LEVEL), 0.0001);
    try testing.expectEqual(.grass, swamp.surface.top);
    try testing.expectEqual(.mud, mangrove.surface.top);
}
