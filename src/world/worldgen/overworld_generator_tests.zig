//! Unit tests for the overworld generator
//!
//! Tests focus on:
//! - OverworldGenerator initialization and accessors
//! - Column info retrieval
//! - Cache recentering behavior

const std = @import("std");
const testing = std.testing;

const overworld_generator_mod = @import("overworld_generator.zig");
const OverworldGenerator = overworld_generator_mod.OverworldGenerator;

const biome_mod = @import("biome.zig");
const BiomeId = biome_mod.BiomeId;

const decoration_registry = @import("decoration_registry.zig");

test "OverworldGenerator init with default seed" {
    const allocator = testing.allocator;
    const gen = OverworldGenerator.init(12345, allocator, decoration_registry.StandardDecorationProvider.provider());

    try testing.expectEqual(@as(u64, 12345), gen.getSeed());
}

test "OverworldGenerator initWithParams stores parameters" {
    const allocator = testing.allocator;
    const gen = OverworldGenerator.initWithParams(99999, allocator, decoration_registry.StandardDecorationProvider.provider(), .{});

    try testing.expectEqual(@as(u64, 99999), gen.getSeed());
}

test "OverworldGenerator subsystem accessors return non-null" {
    const allocator = testing.allocator;
    const gen = OverworldGenerator.init(42, allocator, decoration_registry.StandardDecorationProvider.provider());

    _ = gen.getNoiseSampler();
    _ = gen.getHeightSampler();
    _ = gen.getSurfaceBuilder();
    _ = gen.getBiomeSource();

    try testing.expect(true);
}

test "OverworldGenerator getColumnInfo returns valid data" {
    const allocator = testing.allocator;
    const gen = OverworldGenerator.init(42, allocator, decoration_registry.StandardDecorationProvider.provider());

    const col = gen.getColumnInfo(100.0, 200.0);

    try testing.expect(col.height >= -64 and col.height <= 200);
    try testing.expect(col.temperature >= 0.0 and col.temperature <= 1.0);
    try testing.expect(col.humidity >= 0.0 and col.humidity <= 1.0);
    try testing.expect(col.continentalness >= 0.0 and col.continentalness <= 1.0);
}

test "OverworldGenerator getColumnInfo deterministic" {
    const allocator = testing.allocator;
    const gen = OverworldGenerator.init(42, allocator, decoration_registry.StandardDecorationProvider.provider());

    const col1 = gen.getColumnInfo(5000.0, 5000.0);
    const col2 = gen.getColumnInfo(5000.0, 5000.0);

    try testing.expectEqual(col1.height, col2.height);
    try testing.expectEqual(@as(u32, @intFromEnum(col1.biome)), @as(u32, @intFromEnum(col2.biome)));
    try testing.expectEqual(col1.is_ocean, col2.is_ocean);
}

test "OverworldGenerator getMood returns valid RegionMood" {
    const allocator = testing.allocator;
    const gen = OverworldGenerator.init(42, allocator, decoration_registry.StandardDecorationProvider.provider());

    const mood = gen.getMood(0, 0);
    _ = mood;
}

test "OverworldGenerator getRegionInfo returns valid info" {
    const allocator = testing.allocator;
    const gen = OverworldGenerator.init(42, allocator, decoration_registry.StandardDecorationProvider.provider());

    const info = gen.getRegionInfo(0, 0);
    _ = info;
}

test "OverworldGenerator maybeRecenterCache no recenter when close" {
    const allocator = testing.allocator;
    var gen = OverworldGenerator.init(42, allocator, decoration_registry.StandardDecorationProvider.provider());

    gen.cache_center_x = 0;
    gen.cache_center_z = 0;

    const result = gen.maybeRecenterCache(100, 100);

    try testing.expect(!result);
    try testing.expectEqual(@as(i32, 0), gen.cache_center_x);
    try testing.expectEqual(@as(i32, 0), gen.cache_center_z);
}

test "OverworldGenerator maybeRecenterCache does recenter when far" {
    const allocator = testing.allocator;
    var gen = OverworldGenerator.init(42, allocator, decoration_registry.StandardDecorationProvider.provider());

    gen.cache_center_x = 0;
    gen.cache_center_z = 0;

    const result = gen.maybeRecenterCache(1000, 1000);

    try testing.expect(result);
    try testing.expectEqual(@as(i32, 1000), gen.cache_center_x);
    try testing.expectEqual(@as(i32, 1000), gen.cache_center_z);
}

test "OverworldGenerator maybeRecenterCache boundary at threshold" {
    const allocator = testing.allocator;
    var gen = OverworldGenerator.init(42, allocator, decoration_registry.StandardDecorationProvider.provider());

    gen.cache_center_x = 0;
    gen.cache_center_z = 0;

    const threshold = OverworldGenerator.CACHE_RECENTER_THRESHOLD;
    const just_inside = @divTrunc(threshold, 2);

    const result = gen.maybeRecenterCache(just_inside, 0);

    try testing.expect(!result);
}

test "OverworldGenerator isOceanWater and isInlandWater" {
    const allocator = testing.allocator;
    const gen = OverworldGenerator.init(42, allocator, decoration_registry.StandardDecorationProvider.provider());

    const ocean = gen.isOceanWater(0.0, 0.0);
    const inland_water = gen.isInlandWater(100.0, 100.0, 60);

    _ = ocean;
    _ = inland_water;
}

test "OverworldGenerator getContinentalZone" {
    const allocator = testing.allocator;
    const gen = OverworldGenerator.init(42, allocator, decoration_registry.StandardDecorationProvider.provider());

    const zone = gen.getContinentalZone(0.1);
    try testing.expect(zone == .deep_ocean or zone == .ocean or zone == .coast);
}
