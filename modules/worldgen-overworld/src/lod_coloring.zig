//! LOD surface color selection for overworld biome samples.

const std = @import("std");
const world_core = @import("world-core");
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const block_registry = world_core.block_registry;

pub fn colorForSample(biome_id: BiomeId, surface_block: BlockType) u32 {
    return switch (surface_block) {
        .air => 0,
        .grass => packFloatColor(grassTint(biome_id)),
        .water => packFloatColor(waterTint(biome_id)),
        .leaves, .mangrove_leaves, .jungle_leaves, .acacia_leaves, .birch_leaves, .spruce_leaves => packFloatColor(foliageTint(biome_id)),
        else => packBlockColor(surface_block),
    };
}

pub fn grassTint(biome_id: BiomeId) [3]f32 {
    return switch (biome_id) {
        .forest => .{ 0.18, 0.64, 0.16 },
        .birch_forest => .{ 0.24, 0.68, 0.18 },
        .dark_forest => .{ 0.12, 0.46, 0.12 },
        .flower_forest => .{ 0.30, 0.72, 0.18 },
        .taiga => .{ 0.24, 0.56, 0.24 },
        .snowy_taiga => .{ 0.62, 0.74, 0.70 },
        .old_growth_taiga => .{ 0.20, 0.48, 0.28 },
        .desert => .{ 0.75, 0.70, 0.35 },
        .snow_tundra, .snowy_beach, .frozen_ocean, .frozen_river => .{ 0.7, 0.75, 0.8 },
        .snowy_mountains => .{ 0.85, 0.90, 0.95 },
        .meadow => .{ 0.32, 0.74, 0.24 },
        .grove => .{ 0.20, 0.48, 0.24 },
        .snowy_slopes => .{ 0.82, 0.88, 0.94 },
        .jagged_peaks => .{ 0.56, 0.56, 0.54 },
        .frozen_peaks => .{ 0.76, 0.88, 0.96 },
        .stony_peaks => .{ 0.62, 0.58, 0.48 },
        .swamp => .{ 0.26, 0.58, 0.18 },
        .jungle => .{ 0.10, 0.76, 0.08 },
        .savanna => .{ 0.55, 0.55, 0.30 },
        .badlands => .{ 0.5, 0.4, 0.3 },
        .mushroom_fields => .{ 0.4, 0.8, 0.4 },
        .foothills => .{ 0.24, 0.62, 0.22 },
        .dry_plains => .{ 0.55, 0.50, 0.28 },
        .coastal_plains => .{ 0.24, 0.66, 0.24 },
        .stony_shore => .{ 0.48, 0.52, 0.50 },
        else => .{ 0.22, 0.72, 0.16 },
    };
}

pub fn foliageTint(biome_id: BiomeId) [3]f32 {
    return switch (biome_id) {
        .forest => .{ 0.12, 0.52, 0.12 },
        .birch_forest => .{ 0.18, 0.58, 0.14 },
        .dark_forest => .{ 0.08, 0.36, 0.08 },
        .flower_forest => .{ 0.20, 0.58, 0.12 },
        .taiga => .{ 0.18, 0.46, 0.18 },
        .meadow => .{ 0.20, 0.58, 0.18 },
        .grove => .{ 0.16, 0.38, 0.18 },
        .snowy_slopes => .{ 0.64, 0.72, 0.70 },
        .jagged_peaks => .{ 0.44, 0.46, 0.42 },
        .frozen_peaks => .{ 0.68, 0.78, 0.82 },
        .stony_peaks => .{ 0.46, 0.44, 0.34 },
        .snowy_taiga => .{ 0.16, 0.40, 0.24 },
        .old_growth_taiga => .{ 0.12, 0.34, 0.20 },
        .swamp => .{ 0.22, 0.52, 0.16 },
        .jungle => .{ 0.08, 0.62, 0.08 },
        .savanna => .{ 0.50, 0.50, 0.28 },
        .foothills => .{ 0.18, 0.50, 0.16 },
        .coastal_plains => .{ 0.18, 0.52, 0.16 },
        else => .{ 0.14, 0.58, 0.12 },
    };
}

pub fn waterTint(biome_id: BiomeId) [3]f32 {
    return switch (biome_id) {
        .deep_ocean => .{ 0.1, 0.2, 0.5 },
        .frozen_ocean, .frozen_river => .{ 0.32, 0.54, 0.74 },
        .cold_ocean, .stony_shore, .snowy_beach => .{ 0.10, 0.34, 0.62 },
        .swamp => .{ 0.16, 0.38, 0.30 },
        else => .{ 0.12, 0.38, 0.78 },
    };
}

pub fn packFloatColor(color: [3]f32) u32 {
    const r: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0));
    return (r << 16) | (g << 8) | b;
}

fn packBlockColor(block_type: BlockType) u32 {
    const color = block_registry.getBlockDefinition(block_type).default_color;
    return packFloatColor(color);
}
