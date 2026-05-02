//! Biome data definitions, type declarations, and registry.
//! This module is the leaf dependency for the biome subsystem — it has no
//! imports from other biome_* modules.

const std = @import("std");
const BlockType = @import("world-core").BlockType;
const DecorationRule = @import("decoration_types.zig").DecorationRule;
const tree_registry = @import("tree_registry.zig");
pub const TreeType = tree_registry.TreeType;

/// Minimum sum threshold for biome blend calculation to avoid division by near-zero values
pub const BLEND_EPSILON: f32 = 0.0001;

/// Represents a range of values for biome parameter matching
pub const Range = struct {
    min: f32,
    max: f32,

    /// Check if a value falls within this range
    pub fn contains(self: Range, value: f32) bool {
        return value >= self.min and value <= self.max;
    }

    /// Get normalized distance from center (0 = at center, 1 = at edge)
    pub fn distanceFromCenter(self: Range, value: f32) f32 {
        const center = (self.min + self.max) * 0.5;
        const half_width = (self.max - self.min) * 0.5;
        if (half_width <= 0) return if (value == center) 0 else 1;
        return @min(1.0, @abs(value - center) / half_width);
    }

    /// Convenience for "any value"
    pub fn any() Range {
        return .{ .min = 0.0, .max = 1.0 };
    }
};

/// Color tints for visual biome identity (RGB 0-1)
pub const ColorTints = struct {
    grass: [3]f32 = .{ 0.22, 0.72, 0.16 }, // Default green
    foliage: [3]f32 = .{ 0.14, 0.58, 0.12 },
    water: [3]f32 = .{ 0.12, 0.38, 0.78 },
};

/// Vegetation profile for biome-driven placement
pub const VegetationProfile = struct {
    tree_types: []const TreeType = &.{},
    decoration_rules: []const DecorationRule = &.{},
    seagrass_density: f32 = 0.0,
    kelp_density: f32 = 0.0,
    coral_density: f32 = 0.0,
    seaweed_density: f32 = 0.0,
};

/// Terrain modifiers applied during height computation
pub const TerrainModifier = struct {
    /// Multiplier for hill/mountain amplitude (1.0 = normal)
    height_amplitude: f32 = 1.0,
    /// How much to smooth/flatten terrain (0 = no change, 1 = fully flat)
    smoothing: f32 = 0.0,
    /// Clamp height near sea level (for swamps)
    clamp_to_sea_level: bool = false,
    /// Additional height offset
    height_offset: f32 = 0.0,

    /// Apply biome terrain shaping to a sampled height without mutating the
    /// live generation pipeline.
    pub fn applyHeight(self: TerrainModifier, base_height: f32, sea_level: f32) f32 {
        var height = sea_level + (base_height - sea_level) * self.height_amplitude;
        height += (sea_level - height) * self.smoothing;
        if (self.clamp_to_sea_level) height = sea_level;
        return height + self.height_offset;
    }
};

/// Surface block configuration
pub const SurfaceBlocks = struct {
    top: BlockType = .grass,
    filler: BlockType = .dirt,
    depth_range: i32 = 3,
};

/// Complete biome definition - data-driven and extensible
pub const BiomeDefinition = struct {
    id: BiomeId,
    name: []const u8,

    // Parameter ranges for selection
    temperature: Range,
    humidity: Range,
    elevation: Range = Range.any(),
    continentalness: Range = Range.any(),
    ruggedness: Range = Range.any(),

    // Structural constraints - terrain structure determines biome eligibility
    min_height: i32 = 0, // Minimum absolute height (blocks from y=0)
    max_height: i32 = 256, // Maximum absolute height
    max_slope: i32 = 255, // Maximum allowed slope in blocks (0 = flat)
    min_ridge_mask: f32 = 0.0, // Minimum ridge mask value
    max_ridge_mask: f32 = 1.0, // Maximum ridge mask value

    // Selection tuning
    priority: i32 = 0, // Higher priority wins ties
    blend_weight: f32 = 1.0, // For future blending

    // Biome properties
    surface: SurfaceBlocks = .{},
    vegetation: VegetationProfile = .{},
    terrain: TerrainModifier = .{},
    colors: ColorTints = .{},

    /// Check if biome meets structural constraints (height, slope, continentalness, ridge)
    pub fn meetsStructuralConstraints(self: BiomeDefinition, height: i32, slope: i32, continentalness: f32, ridge_mask: f32) bool {
        if (height < self.min_height) return false;
        if (height > self.max_height) return false;
        if (slope > self.max_slope) return false;
        if (!self.continentalness.contains(continentalness)) return false;
        if (ridge_mask < self.min_ridge_mask or ridge_mask > self.max_ridge_mask) return false;
        return true;
    }

    /// Score how well this biome matches the given climate parameters
    /// Only temperature, humidity, and elevation affect the score (structural already filtered)
    pub fn scoreClimate(self: BiomeDefinition, params: ClimateParams) f32 {
        // Check if within climate ranges
        if (!self.temperature.contains(params.temperature)) return 0;
        if (!self.humidity.contains(params.humidity)) return 0;
        if (!self.elevation.contains(params.elevation)) return 0;

        // Compute weighted distance from ideal center
        const t_dist = self.temperature.distanceFromCenter(params.temperature);
        const h_dist = self.humidity.distanceFromCenter(params.humidity);
        const e_dist = self.elevation.distanceFromCenter(params.elevation);

        // Average distance (lower is better)
        const avg_dist = (t_dist + h_dist + e_dist) / 3.0;

        // Convert to score (higher is better), add priority bonus
        return (1.0 - avg_dist) + @as(f32, @floatFromInt(self.priority)) * 0.01;
    }
};

/// Climate parameters computed per (x,z) column
pub const ClimateParams = struct {
    temperature: f32, // 0=cold, 1=hot (altitude-adjusted)
    humidity: f32, // 0=dry, 1=wet
    elevation: f32, // Normalized: 0=sea level, 1=max height
    continentalness: f32, // 0=deep ocean, 1=deep inland
    ruggedness: f32, // 0=smooth, 1=mountainous (erosion inverted)
};

/// Biome identifiers - shared with core chunk storage.
pub const BiomeId = @import("world-core").BiomeId;

/// Voronoi point defining a biome's position in climate space
/// Biomes are selected by finding the closest point to the sampled heat/humidity
pub const BiomePoint = struct {
    id: BiomeId,
    heat: f32, // 0-100 scale (cold to hot)
    humidity: f32, // 0-100 scale (dry to wet)
    weight: f32 = 1.0, // Cell size multiplier (larger = bigger biome regions)
    y_min: i32 = 0, // Minimum Y level
    y_max: i32 = 256, // Maximum Y level
    /// Maximum allowed slope in blocks (0 = flat, 255 = vertical cliff)
    max_slope: i32 = 255,
    /// Minimum continentalness (0-1). Set > 0.35 for land-only biomes
    min_continental: f32 = 0.0,
    /// Maximum continentalness. Set < 0.35 for ocean-only biomes
    max_continental: f32 = 1.0,
};

/// Structural constraints for biome selection
pub const StructuralParams = struct {
    height: i32,
    slope: i32,
    continentalness: f32,
    ridge_mask: f32,
};

// ============================================================================
// Voronoi Biome Points (Issue #106)
// ============================================================================

/// Voronoi biome points - defines where each biome sits in heat/humidity space
/// Heat: 0=frozen, 50=temperate, 100=scorching
/// Humidity: 0=arid, 50=normal, 100=saturated
pub const BIOME_POINTS = [_]BiomePoint{
    // === Ocean Biomes (continental < 0.35) ===
    .{ .id = .deep_ocean, .heat = 50, .humidity = 50, .weight = 1.5, .max_continental = 0.20 },
    .{ .id = .frozen_ocean, .heat = 5, .humidity = 55, .weight = 1.1, .max_continental = 0.35 },
    .{ .id = .cold_ocean, .heat = 22, .humidity = 55, .weight = 1.1, .min_continental = 0.10, .max_continental = 0.35 },
    .{ .id = .ocean, .heat = 50, .humidity = 50, .weight = 1.5, .min_continental = 0.20, .max_continental = 0.35 },
    .{ .id = .warm_ocean, .heat = 85, .humidity = 75, .weight = 0.9, .min_continental = 0.20, .max_continental = 0.35 },
    .{ .id = .tropical, .heat = 95, .humidity = 90, .weight = 0.7, .min_continental = 0.30, .max_continental = 0.48, .max_slope = 3, .y_max = 72 },

    // === Coastal Biomes ===
    .{ .id = .snowy_beach, .heat = 8, .humidity = 45, .weight = 0.7, .max_slope = 2, .min_continental = 0.35, .max_continental = 0.42, .y_max = 70 },
    .{ .id = .stony_shore, .heat = 30, .humidity = 45, .weight = 0.7, .min_continental = 0.35, .max_continental = 0.45, .y_max = 82 },
    .{ .id = .beach, .heat = 60, .humidity = 50, .weight = 0.6, .max_slope = 2, .min_continental = 0.35, .max_continental = 0.42, .y_max = 70 },

    // === Cold Biomes ===
    .{ .id = .snow_tundra, .heat = 5, .humidity = 30, .weight = 1.0, .min_continental = 0.42 },
    .{ .id = .taiga, .heat = 20, .humidity = 60, .weight = 1.0, .min_continental = 0.42 },
    .{ .id = .snowy_taiga, .heat = 8, .humidity = 72, .weight = 0.5, .min_continental = 0.48 },
    .{ .id = .old_growth_taiga, .heat = 30, .humidity = 86, .weight = 0.45, .min_continental = 0.55 },
    .{ .id = .snowy_mountains, .heat = 10, .humidity = 40, .weight = 0.8, .min_continental = 0.68, .y_min = 112 },
    .{ .id = .grove, .heat = 18, .humidity = 65, .weight = 0.75, .min_continental = 0.66, .y_min = 88, .y_max = 132, .max_slope = 12 },
    .{ .id = .snowy_slopes, .heat = 8, .humidity = 45, .weight = 0.7, .min_continental = 0.72, .y_min = 112, .y_max = 165 },
    .{ .id = .frozen_peaks, .heat = 4, .humidity = 35, .weight = 0.55, .min_continental = 0.78, .y_min = 138 },

    // === Temperate Biomes ===
    .{ .id = .plains, .heat = 50, .humidity = 45, .weight = 1.5, .min_continental = 0.42 }, // Large weight = common
    .{ .id = .forest, .heat = 45, .humidity = 65, .weight = 1.2, .min_continental = 0.42 },
    .{ .id = .birch_forest, .heat = 50, .humidity = 62, .weight = 0.7, .min_continental = 0.48 },
    .{ .id = .dark_forest, .heat = 42, .humidity = 82, .weight = 0.6, .min_continental = 0.55 },
    .{ .id = .flower_forest, .heat = 55, .humidity = 72, .weight = 0.5, .min_continental = 0.48, .max_slope = 5 },
    .{ .id = .mountains, .heat = 40, .humidity = 50, .weight = 0.8, .min_continental = 0.66, .y_min = 102 },
    .{ .id = .meadow, .heat = 45, .humidity = 55, .weight = 0.75, .min_continental = 0.64, .y_min = 82, .y_max = 122, .max_slope = 10 },
    .{ .id = .jagged_peaks, .heat = 32, .humidity = 45, .weight = 0.55, .min_continental = 0.78, .y_min = 136 },

    // === Warm/Wet Biomes ===
    .{ .id = .swamp, .heat = 65, .humidity = 85, .weight = 0.8, .max_slope = 3, .min_continental = 0.42, .y_max = 72 },
    .{ .id = .mangrove_swamp, .heat = 75, .humidity = 90, .weight = 0.6, .max_slope = 3, .min_continental = 0.35, .max_continental = 0.50, .y_max = 68 },
    .{ .id = .jungle, .heat = 85, .humidity = 85, .weight = 0.9, .min_continental = 0.50 },
    .{ .id = .bamboo_jungle, .heat = 88, .humidity = 92, .weight = 0.5, .min_continental = 0.55 },
    .{ .id = .sparse_jungle, .heat = 78, .humidity = 62, .weight = 0.7, .min_continental = 0.50 },

    // === Hot/Dry Biomes ===
    .{ .id = .desert, .heat = 90, .humidity = 10, .weight = 1.2, .min_continental = 0.42, .y_max = 90 },
    .{ .id = .savanna, .heat = 80, .humidity = 30, .weight = 1.0, .min_continental = 0.42 },
    .{ .id = .savanna_plateau, .heat = 78, .humidity = 28, .weight = 0.6, .min_continental = 0.55, .y_min = 80 },
    .{ .id = .windswept_savanna, .heat = 82, .humidity = 22, .weight = 0.5, .min_continental = 0.55 },
    .{ .id = .badlands, .heat = 85, .humidity = 15, .weight = 0.7, .min_continental = 0.55 },
    .{ .id = .wooded_badlands, .heat = 83, .humidity = 25, .weight = 0.5, .min_continental = 0.60 },
    .{ .id = .eroded_badlands, .heat = 87, .humidity = 10, .weight = 0.4, .min_continental = 0.60 },
    .{ .id = .stony_peaks, .heat = 65, .humidity = 25, .weight = 0.55, .min_continental = 0.78, .y_min = 132 },

    // === Special Biomes ===
    .{ .id = .mushroom_fields, .heat = 50, .humidity = 80, .weight = 0.3, .min_continental = 0.35, .max_continental = 0.45 },
    .{ .id = .river, .heat = 50, .humidity = 70, .weight = 0.4, .min_continental = 0.42 }, // Selected by river mask, not Voronoi
    .{ .id = .frozen_river, .heat = 8, .humidity = 70, .weight = 0.4, .min_continental = 0.42 }, // Selected by river mask, not Voronoi

    // === Transition Biomes (created by edge detection, but need Voronoi fallback) ===
    // These have extreme positions so they're rarely selected directly
    .{ .id = .foothills, .heat = 45, .humidity = 45, .weight = 0.5, .min_continental = 0.55, .y_min = 75, .y_max = 100 },
    .{ .id = .marsh, .heat = 55, .humidity = 78, .weight = 0.5, .min_continental = 0.42, .y_max = 68 },
    .{ .id = .dry_plains, .heat = 70, .humidity = 25, .weight = 0.6, .min_continental = 0.42 },
    .{ .id = .coastal_plains, .heat = 55, .humidity = 50, .weight = 0.5, .min_continental = 0.35, .max_continental = 0.48 },
};

// ============================================================================
// Biome Registry - All biome definitions
// ============================================================================

pub const BIOME_REGISTRY: []const BiomeDefinition = &.{
    // === Ocean Biomes ===
    .{
        .id = .deep_ocean,
        .name = "Deep Ocean",
        .temperature = Range.any(),
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.25 },
        .continentalness = .{ .min = 0.0, .max = 0.20 },
        .priority = 2,
        .surface = .{ .top = .gravel, .filler = .gravel, .depth_range = 4 },
        .vegetation = .{ .tree_types = &.{} },
        .colors = .{ .water = .{ 0.1, 0.2, 0.5 } },
    },
    .{
        .id = .ocean,
        .name = "Ocean",
        .temperature = Range.any(),
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.30 },
        .continentalness = .{ .min = 0.0, .max = 0.35 },
        .priority = 1,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{} },
    },
    .{
        .id = .frozen_ocean,
        .name = "Frozen Ocean",
        .temperature = .{ .min = 0.0, .max = 0.15 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.32 },
        .continentalness = .{ .min = 0.0, .max = 0.35 },
        .priority = 4,
        .surface = .{ .top = .packed_ice, .filler = .gravel, .depth_range = 4 },
        .vegetation = .{ .tree_types = &.{} },
        .colors = .{ .grass = .{ 0.78, 0.88, 0.92 }, .foliage = .{ 0.66, 0.78, 0.82 }, .water = .{ 0.32, 0.54, 0.74 } },
    },
    .{
        .id = .cold_ocean,
        .name = "Cold Ocean",
        .temperature = .{ .min = 0.15, .max = 0.30 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.32 },
        .continentalness = .{ .min = 0.0, .max = 0.35 },
        .priority = 3,
        .surface = .{ .top = .gravel, .filler = .gravel, .depth_range = 4 },
        .vegetation = .{
            .tree_types = &.{},
            .seagrass_density = 0.08,
            .kelp_density = 0.10,
            .seaweed_density = 0.04,
            .decoration_rules = &.{.{ .block = .kelp, .place_on = &.{ .gravel, .clay }, .chance = 0.04, .requires_water = true, .min_water_depth = 6, .max_water_depth = 30 }},
        },
        .colors = .{ .water = .{ 0.10, 0.32, 0.62 } },
    },
    .{
        .id = .warm_ocean,
        .name = "Warm Ocean",
        .temperature = .{ .min = 0.70, .max = 1.0 },
        .humidity = .{ .min = 0.50, .max = 1.0 },
        .elevation = .{ .min = 0.0, .max = 0.32 },
        .continentalness = .{ .min = 0.20, .max = 0.35 },
        .priority = 3,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 3 },
        .vegetation = .{
            .tree_types = &.{},
            .seagrass_density = 0.18,
            .kelp_density = 0.06,
            .coral_density = 0.08,
            .decoration_rules = &.{
                .{ .block = .seaweed, .place_on = &.{ .sand, .gravel, .clay }, .chance = 0.08, .requires_water = true, .min_water_depth = 3, .max_water_depth = 16 },
                .{ .block = .coral_block, .place_on = &.{ .sand, .gravel }, .chance = 0.025, .requires_water = true, .min_water_depth = 2, .max_water_depth = 10 },
            },
        },
        .colors = .{ .water = .{ 0.08, 0.50, 0.82 } },
    },
    .{
        .id = .tropical,
        .name = "Tropical",
        .temperature = .{ .min = 0.85, .max = 1.0 },
        .humidity = .{ .min = 0.75, .max = 1.0 },
        .elevation = .{ .min = 0.25, .max = 0.42 },
        .continentalness = .{ .min = 0.32, .max = 0.48 },
        .max_slope = 3,
        .priority = 8,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 3 },
        .vegetation = .{
            .tree_types = &.{.jungle},
            .seagrass_density = 0.14,
            .coral_density = 0.12,
            .seaweed_density = 0.06,
            .decoration_rules = &.{
                .{ .block = .coral_block, .place_on = &.{ .sand, .gravel }, .chance = 0.04, .requires_water = true, .min_water_depth = 2, .max_water_depth = 8 },
                .{ .block = .seaweed, .place_on = &.{ .sand, .gravel }, .chance = 0.06, .requires_water = true, .min_water_depth = 2, .max_water_depth = 12 },
            },
        },
        .colors = .{ .grass = .{ 0.18, 0.74, 0.18 }, .foliage = .{ 0.10, 0.62, 0.10 }, .water = .{ 0.05, 0.55, 0.85 } },
    },
    .{
        .id = .beach,
        .name = "Beach",
        .temperature = .{ .min = 0.2, .max = 1.0 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.28, .max = 0.38 },
        .continentalness = .{ .min = 0.35, .max = 0.42 }, // NARROW beach band
        .max_slope = 2,
        .priority = 10,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{} },
    },
    .{
        .id = .stony_shore,
        .name = "Stony Shore",
        .temperature = .{ .min = 0.20, .max = 0.45 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.28, .max = 0.45 },
        .continentalness = .{ .min = 0.35, .max = 0.45 },
        .max_slope = 8,
        .priority = 11,
        .surface = .{ .top = .stone, .filler = .gravel, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{} },
        .terrain = .{ .height_amplitude = 0.8, .smoothing = 0.1 },
        .colors = .{ .grass = .{ 0.48, 0.52, 0.50 }, .foliage = .{ 0.34, 0.42, 0.36 }, .water = .{ 0.10, 0.34, 0.62 } },
    },
    .{
        .id = .snowy_beach,
        .name = "Snowy Beach",
        .temperature = .{ .min = 0.0, .max = 0.18 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.28, .max = 0.38 },
        .continentalness = .{ .min = 0.35, .max = 0.42 },
        .max_slope = 2,
        .priority = 12,
        .surface = .{ .top = .snow_block, .filler = .sand, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{} },
        .colors = .{ .grass = .{ 0.82, 0.90, 0.94 }, .foliage = .{ 0.68, 0.78, 0.82 }, .water = .{ 0.22, 0.46, 0.70 } },
    },

    // === Land Biomes (continentalness > 0.45) ===
    .{
        .id = .plains,
        .name = "Plains",
        .temperature = Range.any(),
        .humidity = Range.any(),
        .elevation = .{ .min = 0.25, .max = 0.70 },
        .continentalness = .{ .min = 0.45, .max = 1.0 },
        .ruggedness = Range.any(),
        .priority = 0, // Fallback
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.sparse_oak}, .decoration_rules = &.{.{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.3 }} },
        .terrain = .{ .height_amplitude = 0.7, .smoothing = 0.2 },
    },
    .{
        .id = .forest,
        .name = "Forest",
        .temperature = .{ .min = 0.35, .max = 0.75 },
        .humidity = .{ .min = 0.40, .max = 1.0 },
        .elevation = .{ .min = 0.25, .max = 0.70 },
        .continentalness = .{ .min = 0.45, .max = 1.0 },
        .ruggedness = .{ .min = 0.0, .max = 0.60 },
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .oak, .birch, .dense_oak }, .decoration_rules = &.{.{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.4 }} },
        .colors = .{ .grass = .{ 0.18, 0.64, 0.16 }, .foliage = .{ 0.12, 0.52, 0.12 } },
    },
    .{
        .id = .taiga,
        .name = "Taiga",
        .temperature = .{ .min = 0.15, .max = 0.45 },
        .humidity = .{ .min = 0.30, .max = 0.90 },
        .elevation = .{ .min = 0.25, .max = 0.75 },
        .continentalness = .{ .min = 0.45, .max = 1.0 },
        .priority = 6,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.spruce}, .decoration_rules = &.{.{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.2 }} },
        .colors = .{ .grass = .{ 0.24, 0.56, 0.24 }, .foliage = .{ 0.18, 0.46, 0.18 } },
    },
    .{
        .id = .birch_forest,
        .name = "Birch Forest",
        .temperature = .{ .min = 0.40, .max = 0.70 },
        .humidity = .{ .min = 0.45, .max = 0.85 },
        .elevation = .{ .min = 0.25, .max = 0.70 },
        .continentalness = .{ .min = 0.48, .max = 1.0 },
        .ruggedness = .{ .min = 0.0, .max = 0.55 },
        .priority = 7,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .birch, .dense_birch }, .decoration_rules = &.{
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.35 },
            .{ .block = .flower_yellow, .place_on = &.{.grass}, .chance = 0.03 },
        } },
        .colors = .{ .grass = .{ 0.24, 0.68, 0.18 }, .foliage = .{ 0.18, 0.58, 0.14 } },
    },
    .{
        .id = .dark_forest,
        .name = "Dark Forest",
        .temperature = .{ .min = 0.35, .max = 0.65 },
        .humidity = .{ .min = 0.70, .max = 1.0 },
        .elevation = .{ .min = 0.25, .max = 0.68 },
        .continentalness = .{ .min = 0.55, .max = 1.0 },
        .ruggedness = .{ .min = 0.0, .max = 0.50 },
        .priority = 8,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .dense_oak, .oak }, .decoration_rules = &.{
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.25 },
            .{ .block = .red_mushroom_block, .place_on = &.{.grass}, .chance = 0.015 },
            .{ .block = .brown_mushroom_block, .place_on = &.{.grass}, .chance = 0.015 },
        } },
        .colors = .{ .grass = .{ 0.12, 0.46, 0.12 }, .foliage = .{ 0.08, 0.36, 0.08 } },
    },
    .{
        .id = .flower_forest,
        .name = "Flower Forest",
        .temperature = .{ .min = 0.45, .max = 0.75 },
        .humidity = .{ .min = 0.55, .max = 0.90 },
        .elevation = .{ .min = 0.25, .max = 0.65 },
        .continentalness = .{ .min = 0.48, .max = 0.90 },
        .ruggedness = .{ .min = 0.0, .max = 0.45 },
        .max_slope = 5,
        .priority = 8,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .sparse_oak, .birch }, .decoration_rules = &.{
            .{ .block = .flower_red, .place_on = &.{.grass}, .chance = 0.14 },
            .{ .block = .flower_yellow, .place_on = &.{.grass}, .chance = 0.14 },
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.45 },
        } },
        .terrain = .{ .height_amplitude = 0.65, .smoothing = 0.25 },
        .colors = .{ .grass = .{ 0.30, 0.72, 0.18 }, .foliage = .{ 0.20, 0.58, 0.12 } },
    },
    .{
        .id = .snowy_taiga,
        .name = "Snowy Taiga",
        .temperature = .{ .min = 0.0, .max = 0.22 },
        .humidity = .{ .min = 0.45, .max = 0.95 },
        .elevation = .{ .min = 0.30, .max = 0.75 },
        .continentalness = .{ .min = 0.48, .max = 1.0 },
        .priority = 7,
        .surface = .{ .top = .snow_block, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.spruce}, .decoration_rules = &.{.{ .block = .tall_grass, .place_on = &.{.snow_block}, .chance = 0.08 }} },
        .colors = .{ .grass = .{ 0.62, 0.74, 0.70 }, .foliage = .{ 0.16, 0.40, 0.24 } },
    },
    .{
        .id = .old_growth_taiga,
        .name = "Old Growth Taiga",
        .temperature = .{ .min = 0.18, .max = 0.40 },
        .humidity = .{ .min = 0.65, .max = 1.0 },
        .elevation = .{ .min = 0.32, .max = 0.80 },
        .continentalness = .{ .min = 0.55, .max = 1.0 },
        .ruggedness = .{ .min = 0.05, .max = 0.70 },
        .priority = 8,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .dense_spruce, .spruce }, .decoration_rules = &.{
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.15 },
            .{ .block = .cobblestone, .place_on = &.{.grass}, .chance = 0.04 },
        } },
        .terrain = .{ .height_amplitude = 1.05, .smoothing = 0.05 },
        .colors = .{ .grass = .{ 0.20, 0.48, 0.28 }, .foliage = .{ 0.12, 0.34, 0.20 } },
    },
    .{
        .id = .desert,
        .name = "Desert",
        .temperature = .{ .min = 0.80, .max = 1.0 }, // Very hot
        .humidity = .{ .min = 0.0, .max = 0.20 }, // Very dry
        .elevation = .{ .min = 0.35, .max = 0.60 },
        .continentalness = .{ .min = 0.60, .max = 1.0 }, // Inland
        .ruggedness = .{ .min = 0.0, .max = 0.35 },
        .max_height = 90,
        .max_slope = 4,
        .priority = 6,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 6 },
        .vegetation = .{ .tree_types = &.{}, .decoration_rules = &.{
            .{ .block = .cactus, .place_on = &.{.sand}, .chance = 0.015 },
            .{ .block = .dead_bush, .place_on = &.{.sand}, .chance = 0.02 },
        } },
        .terrain = .{ .height_amplitude = 0.5, .smoothing = 0.4 },
        .colors = .{ .grass = .{ 0.75, 0.70, 0.35 } },
    },
    .{
        .id = .swamp,
        .name = "Swamp",
        .temperature = .{ .min = 0.50, .max = 0.80 },
        .humidity = .{ .min = 0.70, .max = 1.0 },
        .elevation = .{ .min = 0.28, .max = 0.40 },
        .continentalness = .{ .min = 0.55, .max = 0.75 }, // Coastal to mid-inland
        .ruggedness = .{ .min = 0.0, .max = 0.30 },
        .max_slope = 3,
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{.swamp_oak} },
        .terrain = .{ .clamp_to_sea_level = true, .height_offset = -2 },
        .colors = .{
            .grass = .{ 0.24, 0.54, 0.20 },
            .foliage = .{ 0.18, 0.46, 0.16 },
            .water = .{ 0.18, 0.38, 0.30 },
        },
    },
    .{
        .id = .snow_tundra,
        .name = "Snow Tundra",
        .temperature = .{ .min = 0.0, .max = 0.25 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.30, .max = 0.70 },
        .continentalness = .{ .min = 0.60, .max = 1.0 }, // Inland
        .min_height = 70,
        .max_slope = 255,
        .priority = 4,
        .surface = .{ .top = .snow_block, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.spruce} },
        .colors = .{ .grass = .{ 0.7, 0.75, 0.8 } },
    },

    // === Mountain Biomes (continentalness > 0.75) ===
    .{
        .id = .mountains,
        .name = "Mountains",
        .temperature = .{ .min = 0.25, .max = 1.0 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.62, .max = 1.0 },
        .continentalness = .{ .min = 0.72, .max = 1.0 }, // Must be inland high or core
        .ruggedness = .{ .min = 0.60, .max = 1.0 },
        .min_height = 102,
        .min_ridge_mask = 0.1,
        .priority = 2,
        .surface = .{ .top = .stone, .filler = .stone, .depth_range = 1 },
        .vegetation = .{ .tree_types = &.{.sparse_oak} },
        .terrain = .{ .height_amplitude = 1.35, .smoothing = 0.04, .height_offset = 4.0 },
    },
    .{
        .id = .snowy_mountains,
        .name = "Snowy Mountains",
        .temperature = .{ .min = 0.0, .max = 0.35 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.62, .max = 1.0 },
        .continentalness = .{ .min = 0.72, .max = 1.0 },
        .ruggedness = .{ .min = 0.55, .max = 1.0 },
        .min_height = 112,
        .max_slope = 255,
        .priority = 2,
        .surface = .{ .top = .snow_block, .filler = .stone, .depth_range = 1 },
        .vegetation = .{ .tree_types = &.{} },
        .terrain = .{ .height_amplitude = 1.35, .smoothing = 0.05, .height_offset = 6.0 },
        .colors = .{ .grass = .{ 0.85, 0.90, 0.95 } },
    },
    .{
        .id = .meadow,
        .name = "Meadow",
        .temperature = .{ .min = 0.25, .max = 0.65 },
        .humidity = .{ .min = 0.35, .max = 0.85 },
        .elevation = .{ .min = 0.50, .max = 0.74 },
        .continentalness = .{ .min = 0.64, .max = 0.95 },
        .ruggedness = .{ .min = 0.20, .max = 0.68 },
        .min_height = 82,
        .max_height = 122,
        .max_slope = 10,
        .priority = 7,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.sparse_oak}, .decoration_rules = &.{
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.55 },
            .{ .block = .flower_red, .place_on = &.{.grass}, .chance = 0.08 },
            .{ .block = .flower_yellow, .place_on = &.{.grass}, .chance = 0.10 },
        } },
        .terrain = .{ .height_amplitude = 0.82, .smoothing = 0.35, .height_offset = 2.0 },
        .colors = .{ .grass = .{ 0.32, 0.74, 0.24 }, .foliage = .{ 0.20, 0.58, 0.18 } },
    },
    .{
        .id = .grove,
        .name = "Grove",
        .temperature = .{ .min = 0.05, .max = 0.35 },
        .humidity = .{ .min = 0.45, .max = 0.95 },
        .elevation = .{ .min = 0.52, .max = 0.80 },
        .continentalness = .{ .min = 0.66, .max = 0.98 },
        .ruggedness = .{ .min = 0.25, .max = 0.78 },
        .min_height = 88,
        .max_height = 132,
        .max_slope = 12,
        .priority = 8,
        .surface = .{ .top = .podzol, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.spruce}, .decoration_rules = &.{
            .{ .block = .tall_grass, .place_on = &.{ .podzol, .grass }, .chance = 0.12 },
            .{ .block = .mossy_cobblestone, .place_on = &.{ .podzol, .grass }, .chance = 0.025 },
            .{ .block = .snow_layer, .place_on = &.{.podzol}, .chance = 0.10, .y_min = 95 },
        } },
        .terrain = .{ .height_amplitude = 0.95, .smoothing = 0.25, .height_offset = 4.0 },
        .colors = .{ .grass = .{ 0.20, 0.48, 0.24 }, .foliage = .{ 0.16, 0.38, 0.18 } },
    },
    .{
        .id = .snowy_slopes,
        .name = "Snowy Slopes",
        .temperature = .{ .min = 0.0, .max = 0.22 },
        .humidity = .{ .min = 0.20, .max = 0.85 },
        .elevation = .{ .min = 0.64, .max = 0.92 },
        .continentalness = .{ .min = 0.72, .max = 1.0 },
        .ruggedness = .{ .min = 0.42, .max = 0.90 },
        .min_height = 112,
        .max_height = 165,
        .priority = 8,
        .surface = .{ .top = .snow_block, .filler = .stone, .depth_range = 1 },
        .vegetation = .{ .tree_types = &.{.spruce}, .decoration_rules = &.{
            .{ .block = .snow_layer, .place_on = &.{.snow_block}, .chance = 0.35 },
            .{ .block = .packed_ice, .place_on = &.{.snow_block}, .chance = 0.015 },
        } },
        .terrain = .{ .height_amplitude = 1.18, .smoothing = 0.14, .height_offset = 6.0 },
        .colors = .{ .grass = .{ 0.82, 0.88, 0.94 }, .foliage = .{ 0.64, 0.72, 0.70 } },
    },
    .{
        .id = .jagged_peaks,
        .name = "Jagged Peaks",
        .temperature = .{ .min = 0.10, .max = 0.50 },
        .humidity = .{ .min = 0.20, .max = 0.75 },
        .elevation = .{ .min = 0.78, .max = 1.0 },
        .continentalness = .{ .min = 0.78, .max = 1.0 },
        .ruggedness = .{ .min = 0.70, .max = 1.0 },
        .min_height = 136,
        .min_ridge_mask = 0.45,
        .priority = 9,
        .surface = .{ .top = .stone, .filler = .stone, .depth_range = 1 },
        .vegetation = .{ .tree_types = &.{}, .decoration_rules = &.{
            .{ .block = .cobblestone, .place_on = &.{.stone}, .chance = 0.06 },
            .{ .block = .gravel, .place_on = &.{.stone}, .chance = 0.03 },
        } },
        .terrain = .{ .height_amplitude = 1.55, .height_offset = 14.0 },
        .colors = .{ .grass = .{ 0.56, 0.56, 0.54 }, .foliage = .{ 0.44, 0.46, 0.42 } },
    },
    .{
        .id = .frozen_peaks,
        .name = "Frozen Peaks",
        .temperature = .{ .min = 0.0, .max = 0.18 },
        .humidity = .{ .min = 0.15, .max = 0.70 },
        .elevation = .{ .min = 0.78, .max = 1.0 },
        .continentalness = .{ .min = 0.78, .max = 1.0 },
        .ruggedness = .{ .min = 0.58, .max = 1.0 },
        .min_height = 138,
        .priority = 9,
        .surface = .{ .top = .packed_ice, .filler = .stone, .depth_range = 1 },
        .vegetation = .{ .tree_types = &.{}, .decoration_rules = &.{
            .{ .block = .snow_layer, .place_on = &.{ .packed_ice, .ice, .blue_ice }, .chance = 0.25 },
            .{ .block = .blue_ice, .place_on = &.{.packed_ice}, .chance = 0.03 },
        } },
        .terrain = .{ .height_amplitude = 1.45, .smoothing = 0.04, .height_offset = 12.0 },
        .colors = .{ .grass = .{ 0.76, 0.88, 0.96 }, .foliage = .{ 0.68, 0.78, 0.82 } },
    },
    .{
        .id = .stony_peaks,
        .name = "Stony Peaks",
        .temperature = .{ .min = 0.45, .max = 0.85 },
        .humidity = .{ .min = 0.0, .max = 0.45 },
        .elevation = .{ .min = 0.74, .max = 1.0 },
        .continentalness = .{ .min = 0.78, .max = 1.0 },
        .ruggedness = .{ .min = 0.52, .max = 1.0 },
        .min_height = 132,
        .priority = 8,
        .surface = .{ .top = .stone, .filler = .stone, .depth_range = 1 },
        .vegetation = .{ .tree_types = &.{}, .decoration_rules = &.{
            .{ .block = .gravel, .place_on = &.{.stone}, .chance = 0.08 },
            .{ .block = .dead_bush, .place_on = &.{ .coarse_dirt, .gravel }, .chance = 0.015 },
        } },
        .terrain = .{ .height_amplitude = 1.38, .smoothing = 0.03, .height_offset = 10.0 },
        .colors = .{ .grass = .{ 0.62, 0.58, 0.48 }, .foliage = .{ 0.46, 0.44, 0.34 } },
    },

    // === Special Biomes ===
    .{
        .id = .mangrove_swamp,
        .name = "Mangrove Swamp",
        .temperature = .{ .min = 0.7, .max = 0.9 },
        .humidity = .{ .min = 0.8, .max = 1.0 },
        .elevation = .{ .min = 0.2, .max = 0.4 },
        .continentalness = .{ .min = 0.45, .max = 0.60 }, // Coastal swamp
        .priority = 6,
        .surface = .{ .top = .mud, .filler = .mud, .depth_range = 4 },
        .vegetation = .{ .tree_types = &.{.mangrove} },
        .terrain = .{ .clamp_to_sea_level = true, .height_offset = -1 },
        .colors = .{ .grass = .{ 0.26, 0.58, 0.18 }, .foliage = .{ 0.22, 0.52, 0.16 }, .water = .{ 0.16, 0.38, 0.30 } },
    },
    .{
        .id = .jungle,
        .name = "Jungle",
        .temperature = .{ .min = 0.75, .max = 1.0 },
        .humidity = .{ .min = 0.7, .max = 1.0 },
        .elevation = .{ .min = 0.30, .max = 0.75 },
        .continentalness = .{ .min = 0.60, .max = 1.0 },
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.jungle}, .decoration_rules = &.{
            .{ .block = .bamboo, .place_on = &.{.grass}, .chance = 0.08 },
            .{ .block = .melon, .place_on = &.{.grass}, .chance = 0.04 },
        } },
        .colors = .{ .grass = .{ 0.10, 0.76, 0.08 }, .foliage = .{ 0.08, 0.62, 0.08 } },
    },
    .{
        .id = .bamboo_jungle,
        .name = "Bamboo Jungle",
        .temperature = .{ .min = 0.80, .max = 1.0 },
        .humidity = .{ .min = 0.85, .max = 1.0 },
        .elevation = .{ .min = 0.30, .max = 0.70 },
        .continentalness = .{ .min = 0.55, .max = 1.0 },
        .priority = 6,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.jungle}, .decoration_rules = &.{
            .{ .block = .bamboo, .place_on = &.{.grass}, .chance = 0.35 },
            .{ .block = .melon, .place_on = &.{.grass}, .chance = 0.02 },
        } },
        .colors = .{ .grass = .{ 0.14, 0.78, 0.10 }, .foliage = .{ 0.10, 0.64, 0.08 } },
    },
    .{
        .id = .sparse_jungle,
        .name = "Sparse Jungle",
        .temperature = .{ .min = 0.70, .max = 0.90 },
        .humidity = .{ .min = 0.50, .max = 0.70 },
        .elevation = .{ .min = 0.30, .max = 0.70 },
        .continentalness = .{ .min = 0.50, .max = 1.0 },
        .priority = 4,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.jungle}, .decoration_rules = &.{
            .{ .block = .bamboo, .place_on = &.{.grass}, .chance = 0.03 },
            .{ .block = .melon, .place_on = &.{.grass}, .chance = 0.02 },
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.4 },
        } },
        .terrain = .{ .height_amplitude = 0.8, .smoothing = 0.15 },
        .colors = .{ .grass = .{ 0.18, 0.72, 0.14 }, .foliage = .{ 0.14, 0.58, 0.12 } },
    },
    .{
        .id = .savanna,
        .name = "Savanna",
        .temperature = .{ .min = 0.65, .max = 1.0 },
        .humidity = .{ .min = 0.20, .max = 0.50 },
        .elevation = .{ .min = 0.30, .max = 0.65 },
        .continentalness = .{ .min = 0.55, .max = 1.0 },
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.acacia}, .decoration_rules = &.{
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.5 },
            .{ .block = .dead_bush, .place_on = &.{.grass}, .chance = 0.01 },
        } },
        .colors = .{ .grass = .{ 0.55, 0.55, 0.30 }, .foliage = .{ 0.50, 0.50, 0.28 } },
    },
    .{
        .id = .savanna_plateau,
        .name = "Savanna Plateau",
        .temperature = .{ .min = 0.65, .max = 0.95 },
        .humidity = .{ .min = 0.20, .max = 0.45 },
        .elevation = .{ .min = 0.50, .max = 0.72 },
        .continentalness = .{ .min = 0.55, .max = 1.0 },
        .ruggedness = .{ .min = 0.0, .max = 0.40 },
        .min_height = 80,
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.acacia}, .decoration_rules = &.{
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.4 },
            .{ .block = .dead_bush, .place_on = &.{.grass}, .chance = 0.02 },
        } },
        .terrain = .{ .height_amplitude = 0.6, .smoothing = 0.3, .height_offset = 8.0 },
        .colors = .{ .grass = .{ 0.58, 0.56, 0.30 }, .foliage = .{ 0.52, 0.50, 0.28 } },
    },
    .{
        .id = .windswept_savanna,
        .name = "Windswept Savanna",
        .temperature = .{ .min = 0.70, .max = 1.0 },
        .humidity = .{ .min = 0.15, .max = 0.40 },
        .elevation = .{ .min = 0.35, .max = 0.80 },
        .continentalness = .{ .min = 0.55, .max = 1.0 },
        .ruggedness = .{ .min = 0.50, .max = 1.0 },
        .priority = 5,
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.acacia}, .decoration_rules = &.{
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.25 },
            .{ .block = .dead_bush, .place_on = &.{.grass}, .chance = 0.04 },
            .{ .block = .cobblestone, .place_on = &.{.grass}, .chance = 0.02 },
        } },
        .terrain = .{ .height_amplitude = 1.3, .smoothing = 0.0 },
        .colors = .{ .grass = .{ 0.48, 0.50, 0.28 }, .foliage = .{ 0.44, 0.46, 0.26 } },
    },
    .{
        .id = .badlands,
        .name = "Badlands",
        .temperature = .{ .min = 0.7, .max = 1.0 },
        .humidity = .{ .min = 0.0, .max = 0.3 },
        .elevation = .{ .min = 0.4, .max = 0.8 },
        .continentalness = .{ .min = 0.70, .max = 1.0 },
        .ruggedness = .{ .min = 0.4, .max = 1.0 },
        .priority = 6,
        .surface = .{ .top = .red_sand, .filler = .terracotta, .depth_range = 5 },
        .vegetation = .{ .tree_types = &.{}, .decoration_rules = &.{.{ .block = .cactus, .place_on = &.{.red_sand}, .chance = 0.02 }} },
        .colors = .{ .grass = .{ 0.5, 0.4, 0.3 } },
    },
    .{
        .id = .wooded_badlands,
        .name = "Wooded Badlands",
        .temperature = .{ .min = 0.70, .max = 0.95 },
        .humidity = .{ .min = 0.15, .max = 0.35 },
        .elevation = .{ .min = 0.45, .max = 0.80 },
        .continentalness = .{ .min = 0.60, .max = 1.0 },
        .ruggedness = .{ .min = 0.30, .max = 0.75 },
        .max_slope = 8,
        .priority = 5,
        .surface = .{ .top = .red_sand, .filler = .terracotta, .depth_range = 4 },
        .vegetation = .{ .tree_types = &.{.sparse_oak}, .decoration_rules = &.{
            .{ .block = .cactus, .place_on = &.{.red_sand}, .chance = 0.015 },
            .{ .block = .dead_bush, .place_on = &.{.red_sand}, .chance = 0.03 },
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.15 },
        } },
        .terrain = .{ .height_amplitude = 1.0, .smoothing = 0.1 },
        .colors = .{ .grass = .{ 0.52, 0.42, 0.32 }, .foliage = .{ 0.46, 0.38, 0.28 } },
    },
    .{
        .id = .eroded_badlands,
        .name = "Eroded Badlands",
        .temperature = .{ .min = 0.75, .max = 1.0 },
        .humidity = .{ .min = 0.0, .max = 0.20 },
        .elevation = .{ .min = 0.50, .max = 0.95 },
        .continentalness = .{ .min = 0.60, .max = 1.0 },
        .ruggedness = .{ .min = 0.70, .max = 1.0 },
        .priority = 7,
        .surface = .{ .top = .red_sand, .filler = .terracotta, .depth_range = 6 },
        .vegetation = .{ .tree_types = &.{}, .decoration_rules = &.{
            .{ .block = .cactus, .place_on = &.{.red_sand}, .chance = 0.025 },
            .{ .block = .dead_bush, .place_on = &.{.red_sand}, .chance = 0.02 },
        } },
        .terrain = .{ .height_amplitude = 1.8, .smoothing = 0.0 },
        .colors = .{ .grass = .{ 0.48, 0.38, 0.28 } },
    },
    .{
        .id = .mushroom_fields,
        .name = "Mushroom Fields",
        .temperature = .{ .min = 0.4, .max = 0.7 },
        .humidity = .{ .min = 0.7, .max = 1.0 },
        .continentalness = .{ .min = 0.0, .max = 0.15 }, // Deep ocean islands only
        .max_height = 50,
        .priority = 20,
        .surface = .{ .top = .mycelium, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .huge_red_mushroom, .huge_brown_mushroom }, .decoration_rules = &.{
            .{ .block = .red_mushroom_block, .place_on = &.{.mycelium}, .chance = 0.1 },
            .{ .block = .brown_mushroom_block, .place_on = &.{.mycelium}, .chance = 0.1 },
        } },
        .colors = .{ .grass = .{ 0.4, 0.8, 0.4 } },
    },
    .{
        .id = .river,
        .name = "River",
        .temperature = Range.any(),
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.35 },
        // River should NEVER win normal biome scoring - impossible range
        .continentalness = .{ .min = -1.0, .max = -0.5 },
        .priority = 15,
        .surface = .{ .top = .sand, .filler = .sand, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{} },
    },
    .{
        .id = .frozen_river,
        .name = "Frozen River",
        .temperature = .{ .min = 0.0, .max = 0.20 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.0, .max = 0.35 },
        // Frozen River should only be selected by river override.
        .continentalness = .{ .min = -1.0, .max = -0.5 },
        .priority = 16,
        .surface = .{ .top = .ice, .filler = .gravel, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{} },
        .colors = .{ .grass = .{ 0.78, 0.88, 0.92 }, .foliage = .{ 0.66, 0.78, 0.82 }, .water = .{ 0.36, 0.58, 0.78 } },
    },

    // === Transition Micro-Biomes ===
    // These should NEVER win natural climate selection.
    // They are ONLY injected by edge detection (Issue #102).
    // Use impossible continental ranges so they can't match naturally.
    .{
        .id = .foothills,
        .name = "Foothills",
        .temperature = .{ .min = 0.20, .max = 0.90 },
        .humidity = Range.any(),
        .elevation = .{ .min = 0.25, .max = 0.65 },
        .continentalness = .{ .min = -1.0, .max = -0.5 }, // IMPOSSIBLE: edge-injection only
        .ruggedness = .{ .min = 0.30, .max = 0.80 },
        .priority = 0, // Lowest priority
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{ .sparse_oak, .spruce }, .decoration_rules = &.{.{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.4 }} },
        .terrain = .{ .height_amplitude = 1.1, .smoothing = 0.1 },
        .colors = .{ .grass = .{ 0.24, 0.62, 0.22 }, .foliage = .{ 0.18, 0.50, 0.16 } },
    },
    .{
        .id = .marsh,
        .name = "Marsh",
        .temperature = .{ .min = 0.40, .max = 0.75 },
        .humidity = .{ .min = 0.55, .max = 0.80 },
        .elevation = .{ .min = 0.28, .max = 0.42 },
        .continentalness = .{ .min = -1.0, .max = -0.5 }, // IMPOSSIBLE: edge-injection only
        .ruggedness = .{ .min = 0.0, .max = 0.30 },
        .priority = 0, // Lowest priority
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 2 },
        .vegetation = .{ .tree_types = &.{.swamp_oak}, .decoration_rules = &.{.{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.5 }} },
        .terrain = .{ .height_offset = -1, .smoothing = 0.3 },
        .colors = .{
            .grass = .{ 0.20, 0.58, 0.20 },
            .foliage = .{ 0.16, 0.50, 0.16 },
            .water = .{ 0.16, 0.40, 0.34 },
        },
    },
    .{
        .id = .dry_plains,
        .name = "Dry Plains",
        .temperature = .{ .min = 0.60, .max = 0.85 },
        .humidity = .{ .min = 0.20, .max = 0.40 },
        .elevation = .{ .min = 0.32, .max = 0.58 },
        .continentalness = .{ .min = -1.0, .max = -0.5 }, // IMPOSSIBLE: edge-injection only
        .ruggedness = .{ .min = 0.0, .max = 0.40 },
        .priority = 0, // Lowest priority
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{.acacia}, .decoration_rules = &.{
            .{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.3 },
            .{ .block = .dead_bush, .place_on = &.{.grass}, .chance = 0.02 },
        } },
        .terrain = .{ .height_amplitude = 0.6, .smoothing = 0.25 },
        .colors = .{ .grass = .{ 0.55, 0.50, 0.28 } }, // Less yellow, more natural
    },
    .{
        .id = .coastal_plains,
        .name = "Coastal Plains",
        .temperature = .{ .min = 0.30, .max = 0.80 },
        .humidity = .{ .min = 0.30, .max = 0.70 },
        .elevation = .{ .min = 0.28, .max = 0.45 },
        .continentalness = .{ .min = -1.0, .max = -0.5 }, // IMPOSSIBLE: edge-injection only
        .ruggedness = .{ .min = 0.0, .max = 0.35 },
        .priority = 0, // Lowest priority
        .surface = .{ .top = .grass, .filler = .dirt, .depth_range = 3 },
        .vegetation = .{ .tree_types = &.{}, .decoration_rules = &.{.{ .block = .tall_grass, .place_on = &.{.grass}, .chance = 0.4 }} }, // No trees
        .terrain = .{ .height_amplitude = 0.5, .smoothing = 0.3 },
        .colors = .{ .grass = .{ 0.24, 0.66, 0.24 }, .foliage = .{ 0.18, 0.52, 0.16 } },
    },
};

/// Comptime-generated lookup table for O(1) BiomeDefinition access by BiomeId.
const BIOME_COUNT = @typeInfo(BiomeId).@"enum".fields.len;

const BIOME_LOOKUP: [BIOME_COUNT]*const BiomeDefinition = blk: {
    var table: [BIOME_COUNT]*const BiomeDefinition = undefined;
    var filled = [_]bool{false} ** BIOME_COUNT;
    for (BIOME_REGISTRY) |*def| {
        const idx = @intFromEnum(def.id);
        table[idx] = def;
        filled[idx] = true;
    }
    // Verify every BiomeId has a definition
    for (0..BIOME_COUNT) |i| {
        if (!filled[i]) {
            @compileError("BIOME_REGISTRY is missing a BiomeDefinition entry");
        }
    }
    break :blk table;
};

/// Get the BiomeDefinition for a given BiomeId (O(1) comptime lookup).
pub fn getBiomeDefinition(id: BiomeId) *const BiomeDefinition {
    return BIOME_LOOKUP[@intFromEnum(id)];
}

pub fn isMountainFamilyTerrainBiome(id: BiomeId) bool {
    return switch (id) {
        .mountains,
        .snowy_mountains,
        .meadow,
        .grove,
        .snowy_slopes,
        .jagged_peaks,
        .frozen_peaks,
        .stony_peaks,
        => true,
        else => false,
    };
}
