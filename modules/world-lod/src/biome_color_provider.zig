const world_core = @import("world-core");
const BiomeId = world_core.BiomeId;
const BlockType = world_core.BlockType;

pub const BiomeColors = struct {
    grass: [3]f32 = .{ 0.22, 0.72, 0.16 },
    foliage: [3]f32 = .{ 0.14, 0.58, 0.12 },
    water: [3]f32 = .{ 0.12, 0.38, 0.78 },
};

pub fn getBiomeColors(biome_id: BiomeId) BiomeColors {
    return switch (biome_id) {
        .deep_ocean => .{ .water = .{ 0.1, 0.2, 0.5 } },
        .frozen_ocean => .{ .grass = .{ 0.78, 0.88, 0.92 }, .foliage = .{ 0.66, 0.78, 0.82 }, .water = .{ 0.32, 0.54, 0.74 } },
        .cold_ocean => .{ .water = .{ 0.10, 0.32, 0.62 } },
        .warm_ocean => .{ .water = .{ 0.08, 0.50, 0.82 } },
        .tropical => .{ .grass = .{ 0.18, 0.74, 0.18 }, .foliage = .{ 0.10, 0.62, 0.10 }, .water = .{ 0.05, 0.55, 0.85 } },
        .plains => .{},
        .forest => .{ .grass = .{ 0.18, 0.64, 0.16 }, .foliage = .{ 0.12, 0.52, 0.12 } },
        .birch_forest => .{ .grass = .{ 0.24, 0.68, 0.18 }, .foliage = .{ 0.18, 0.58, 0.14 } },
        .dark_forest => .{ .grass = .{ 0.12, 0.46, 0.12 }, .foliage = .{ 0.08, 0.36, 0.08 } },
        .flower_forest => .{ .grass = .{ 0.30, 0.72, 0.18 }, .foliage = .{ 0.20, 0.58, 0.12 } },
        .taiga => .{ .grass = .{ 0.24, 0.56, 0.24 }, .foliage = .{ 0.18, 0.46, 0.18 } },
        .snowy_taiga => .{ .grass = .{ 0.62, 0.74, 0.70 }, .foliage = .{ 0.16, 0.40, 0.24 } },
        .old_growth_taiga => .{ .grass = .{ 0.20, 0.48, 0.28 }, .foliage = .{ 0.12, 0.34, 0.20 } },
        .desert => .{ .grass = .{ 0.75, 0.70, 0.35 } },
        .snow_tundra => .{ .grass = .{ 0.7, 0.75, 0.8 } },
        .snowy_mountains => .{ .grass = .{ 0.85, 0.90, 0.95 } },
        .stony_shore => .{ .grass = .{ 0.48, 0.52, 0.50 }, .foliage = .{ 0.34, 0.42, 0.36 }, .water = .{ 0.10, 0.34, 0.62 } },
        .snowy_beach => .{ .grass = .{ 0.82, 0.90, 0.94 }, .foliage = .{ 0.68, 0.78, 0.82 }, .water = .{ 0.22, 0.46, 0.70 } },
        .meadow => .{ .grass = .{ 0.32, 0.74, 0.24 }, .foliage = .{ 0.20, 0.58, 0.18 } },
        .grove => .{ .grass = .{ 0.20, 0.48, 0.24 }, .foliage = .{ 0.16, 0.38, 0.18 } },
        .snowy_slopes => .{ .grass = .{ 0.82, 0.88, 0.94 }, .foliage = .{ 0.64, 0.72, 0.70 } },
        .jagged_peaks => .{ .grass = .{ 0.56, 0.56, 0.54 }, .foliage = .{ 0.44, 0.46, 0.42 } },
        .frozen_peaks => .{ .grass = .{ 0.76, 0.88, 0.96 }, .foliage = .{ 0.68, 0.78, 0.82 } },
        .stony_peaks => .{ .grass = .{ 0.62, 0.58, 0.48 }, .foliage = .{ 0.46, 0.44, 0.34 } },
        .swamp => .{ .grass = .{ 0.26, 0.58, 0.18 }, .foliage = .{ 0.22, 0.52, 0.16 }, .water = .{ 0.16, 0.38, 0.30 } },
        .frozen_river => .{ .grass = .{ 0.78, 0.88, 0.92 }, .foliage = .{ 0.66, 0.78, 0.82 }, .water = .{ 0.36, 0.58, 0.78 } },
        .jungle => .{ .grass = .{ 0.10, 0.76, 0.08 }, .foliage = .{ 0.08, 0.62, 0.08 } },
        .savanna => .{ .grass = .{ 0.55, 0.55, 0.30 }, .foliage = .{ 0.50, 0.50, 0.28 } },
        .badlands => .{ .grass = .{ 0.5, 0.4, 0.3 } },
        .mushroom_fields => .{ .grass = .{ 0.4, 0.8, 0.4 } },
        .foothills => .{ .grass = .{ 0.24, 0.62, 0.22 }, .foliage = .{ 0.18, 0.50, 0.16 } },
        .dry_plains => .{ .grass = .{ 0.55, 0.50, 0.28 } },
        .coastal_plains => .{ .grass = .{ 0.24, 0.66, 0.24 }, .foliage = .{ 0.18, 0.52, 0.16 } },
        else => .{},
    };
}

pub fn getGrassTintColor(biome_id: BiomeId) u32 {
    return packRgb(getBiomeColors(biome_id).grass);
}

pub fn getFoliageTintColor(biome_id: BiomeId) u32 {
    return packRgb(getBiomeColors(biome_id).foliage);
}

pub fn getWaterTintColor(biome_id: BiomeId) u32 {
    return packRgb(getBiomeColors(biome_id).water);
}

pub fn getBlockTintColor(biome_id: BiomeId, block: BlockType) u32 {
    if (block == .grass) return getGrassTintColor(biome_id);
    if (block == .water) return getWaterTintColor(biome_id);
    if (isLeafBlock(block)) return getLeafTintColor(biome_id, block);
    return 0xFFFFFF;
}

pub fn getLeafTintColor(biome_id: BiomeId, block: BlockType) u32 {
    const foliage = getBiomeColors(biome_id).foliage;
    if (block == .leaves) return packRgb(foliage);

    const base = world_core.block_registry.getBlockDefinition(block).default_color;
    return packRgb(.{
        base[0] * 0.70 + foliage[0] * 0.30,
        base[1] * 0.70 + foliage[1] * 0.30,
        base[2] * 0.70 + foliage[2] * 0.30,
    });
}

fn isLeafBlock(block: BlockType) bool {
    return switch (block) {
        .leaves,
        .mangrove_leaves,
        .jungle_leaves,
        .acacia_leaves,
        .birch_leaves,
        .spruce_leaves,
        => true,
        else => false,
    };
}

fn packRgb(color: [3]f32) u32 {
    const r: u32 = @intFromFloat(@round(clamp01(color[0]) * 255.0));
    const g: u32 = @intFromFloat(@round(clamp01(color[1]) * 255.0));
    const b: u32 = @intFromFloat(@round(clamp01(color[2]) * 255.0));
    return (r << 16) | (g << 8) | b;
}

fn clamp01(value: f32) f32 {
    if (value < 0.0) return 0.0;
    if (value > 1.0) return 1.0;
    return value;
}

pub fn getBiomeColor(biome_id: BiomeId) u32 {
    return switch (biome_id) {
        .deep_ocean, .ocean, .warm_ocean, .cold_ocean, .frozen_ocean, .river, .frozen_river => getWaterTintColor(biome_id),
        else => getGrassTintColor(biome_id),
    };
}

test "LOD biome color provider matches chunk grass tint" {
    try @import("std").testing.expectEqual(@as(u32, 0x38B829), getGrassTintColor(.plains));
    try @import("std").testing.expectEqual(@as(u32, 0x2EA329), getGrassTintColor(.forest));
}

test "LOD biome color provider matches chunk foliage tint" {
    try @import("std").testing.expectEqual(@as(u32, 0x24941F), getFoliageTintColor(.plains));
    try @import("std").testing.expectEqual(@as(u32, 0x1F851F), getFoliageTintColor(.forest));
}
