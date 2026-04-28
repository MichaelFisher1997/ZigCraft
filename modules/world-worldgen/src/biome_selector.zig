//! Biome selection algorithms: Voronoi, score-based, blended, and LOD-simplified.
//! All selection functions are pure — they read from the registry but have no side effects.

const std = @import("std");
const registry = @import("biome_registry.zig");

const BiomeId = registry.BiomeId;
const ClimateParams = registry.ClimateParams;
const StructuralParams = registry.StructuralParams;
const BIOME_REGISTRY = registry.BIOME_REGISTRY;
const BIOME_POINTS = registry.BIOME_POINTS;
const BLEND_EPSILON = registry.BLEND_EPSILON;

// ============================================================================
// Voronoi Biome Selection (Issue #106)
// ============================================================================

/// Select biome using Voronoi diagram in heat/humidity space
/// Returns the biome whose point is closest to the given heat/humidity values
pub fn selectBiomeVoronoi(heat: f32, humidity: f32, height: i32, continentalness: f32, slope: i32) BiomeId {
    var min_dist: f32 = std.math.inf(f32);
    var closest: BiomeId = .plains;

    for (BIOME_POINTS) |point| {
        // Check height constraint
        if (height < point.y_min or height > point.y_max) continue;

        // Check slope constraint
        if (slope > point.max_slope) continue;

        // Check continentalness constraint
        if (continentalness < point.min_continental or continentalness > point.max_continental) continue;

        // Calculate weighted Euclidean distance in heat/humidity space
        const d_heat = heat - point.heat;
        const d_humidity = humidity - point.humidity;
        var dist = @sqrt(d_heat * d_heat + d_humidity * d_humidity);

        // Weight adjusts effective cell size (larger weight = closer distance = more likely)
        dist /= point.weight;

        if (dist < min_dist) {
            min_dist = dist;
            closest = point.id;
        }
    }

    return closest;
}

/// Select biome using Voronoi with river override
pub fn selectBiomeVoronoiWithRiver(
    heat: f32,
    humidity: f32,
    height: i32,
    continentalness: f32,
    slope: i32,
    river_mask: f32,
) BiomeId {
    // River biome takes priority when river mask is active
    // Issue #110: Allow rivers at higher elevations (canyons)
    if (river_mask > 0.5 and height < 120) {
        return .river;
    }
    return selectBiomeVoronoi(heat, humidity, height, continentalness, slope);
}

// ============================================================================
// Score-based Biome Selection
// ============================================================================

/// Select the best matching biome for given climate parameters
pub fn selectBiome(params: ClimateParams) BiomeId {
    var best_score: f32 = 0;
    var best_biome: BiomeId = .plains; // Default fallback

    for (BIOME_REGISTRY) |biome| {
        const s = biome.scoreClimate(params);
        if (s > best_score) {
            best_score = s;
            best_biome = biome.id;
        }
    }

    return best_biome;
}

/// Select biome with river override
pub fn selectBiomeWithRiver(params: ClimateParams, river_mask: f32) BiomeId {
    // River biome takes priority when river mask is active
    if (river_mask > 0.5 and params.elevation < 0.35) {
        return .river;
    }
    return selectBiome(params);
}

/// Compute ClimateParams from raw generator values
pub fn computeClimateParams(
    temperature: f32,
    humidity: f32,
    height: i32,
    continentalness: f32,
    erosion: f32,
    sea_level: i32,
    max_height: i32,
) ClimateParams {
    // Normalize elevation: 0 = below sea, 0.3 = sea level, 1.0 = max height
    // Use conditional to avoid integer overflow when height < sea_level
    const height_above_sea: i32 = if (height > sea_level) height - sea_level else 0;
    const elevation_range = max_height - sea_level;
    const elevation = if (elevation_range > 0)
        0.3 + 0.7 * @as(f32, @floatFromInt(height_above_sea)) / @as(f32, @floatFromInt(elevation_range))
    else
        0.3;

    // For underwater: scale 0-0.3
    const final_elevation = if (height < sea_level)
        0.3 * @as(f32, @floatFromInt(@max(0, height))) / @as(f32, @floatFromInt(sea_level))
    else
        elevation;

    return .{
        .temperature = temperature,
        .humidity = humidity,
        .elevation = @min(1.0, final_elevation),
        .continentalness = continentalness,
        .ruggedness = 1.0 - erosion, // Invert erosion: low erosion = high ruggedness
    };
}

// ============================================================================
// Blended Biome Selection
// ============================================================================

/// Result of blended biome selection
pub const BiomeSelection = struct {
    primary: BiomeId,
    secondary: BiomeId,
    blend_factor: f32, // 0.0 = pure primary, up to 0.5 = mix of secondary
    primary_score: f32,
    secondary_score: f32,
};

/// Select top 2 biomes for blending
pub fn selectBiomeBlended(params: ClimateParams) BiomeSelection {
    var best_score: f32 = 0.0;
    var best_biome: ?BiomeId = null;
    var second_score: f32 = 0.0;
    var second_biome: ?BiomeId = null;

    for (BIOME_REGISTRY) |biome| {
        const s = biome.scoreClimate(params);
        if (s > best_score) {
            second_score = best_score;
            second_biome = best_biome;
            best_score = s;
            best_biome = biome.id;
        } else if (s > second_score) {
            second_score = s;
            second_biome = biome.id;
        }
    }

    const primary = best_biome orelse .plains;
    const secondary = second_biome orelse primary;

    var blend: f32 = 0.0;
    const sum = best_score + second_score;
    if (sum > BLEND_EPSILON) {
        blend = second_score / sum;
    }

    return .{
        .primary = primary,
        .secondary = secondary,
        .blend_factor = blend,
        .primary_score = best_score,
        .secondary_score = second_score,
    };
}

/// Select blended biomes with river override
pub fn selectBiomeWithRiverBlended(params: ClimateParams, river_mask: f32) BiomeSelection {
    const selection = selectBiomeBlended(params);

    // If distinctly river, override primary with blending
    if (params.elevation < 0.35) {
        const river_edge0 = 0.45;
        const river_edge1 = 0.55;

        if (river_mask > river_edge0) {
            const t = std.math.clamp((river_mask - river_edge0) / (river_edge1 - river_edge0), 0.0, 1.0);
            const river_factor = t * t * (3.0 - 2.0 * t);

            // Blend towards river:
            // river_factor = 1.0 -> Pure River
            // river_factor = 0.0 -> Pure Land (selection.primary)
            // We set Primary=River, Secondary=Land, Blend=(1-river_factor)
            return .{
                .primary = .river,
                .secondary = selection.primary,
                .blend_factor = 1.0 - river_factor,
                .primary_score = 1.0, // River wins
                .secondary_score = selection.primary_score,
            };
        }
    }
    return selection;
}

// ============================================================================
// Constraint-based Selection (Voronoi + structural filtering)
// ============================================================================

/// Select biome using Voronoi diagram in heat/humidity space (Issue #106)
/// Climate temperature/humidity are converted to heat/humidity scale (0-100)
/// Structural constraints (height, continentalness) filter eligible biomes
pub fn selectBiomeWithConstraints(climate: ClimateParams, structural: StructuralParams) BiomeId {
    // Convert climate params to Voronoi heat/humidity scale (0-100)
    // Temperature 0-1 -> Heat 0-100
    // Humidity 0-1 -> Humidity 0-100
    const heat = climate.temperature * 100.0;
    const humidity = climate.humidity * 100.0;

    return selectBiomeVoronoi(heat, humidity, structural.height, structural.continentalness, structural.slope);
}

/// Select biome with structural constraints and river override
pub fn selectBiomeWithConstraintsAndRiver(climate: ClimateParams, structural: StructuralParams, river_mask: f32) BiomeId {
    // Convert climate params to Voronoi heat/humidity scale (0-100)
    const heat = climate.temperature * 100.0;
    const humidity = climate.humidity * 100.0;

    return selectBiomeVoronoiWithRiver(heat, humidity, structural.height, structural.continentalness, structural.slope, river_mask);
}

// ============================================================================
// LOD-optimized Biome Functions (Issue #114)
// ============================================================================

/// Simplified biome selection for LOD2+ (no structural constraints).
///
/// Intentionally excludes transition micro-biomes (foothills, marsh, dry_plains,
/// coastal_plains), special biomes (mushroom_fields, mangrove_swamp), beach,
/// and mountain variants. These are either rare, narrow-band, or structurally
/// dependent biomes that don't significantly affect distant terrain silhouette.
/// The full Voronoi selection handles them when chunks enter LOD0/LOD1 range.
pub fn selectBiomeSimple(climate: ClimateParams) BiomeId {
    const heat = climate.temperature * 100.0;
    const humidity = climate.humidity * 100.0;
    const continental = climate.continentalness;

    // Ocean check
    if (continental < 0.35) {
        if (continental < 0.20) return .deep_ocean;
        return .ocean;
    }

    // Simple land biome selection based on heat/humidity
    if (heat < 20) {
        return if (humidity > 50) .taiga else .snow_tundra;
    } else if (heat < 40) {
        return if (humidity > 60) .taiga else .plains;
    } else if (heat < 60) {
        return if (humidity > 70) .forest else .plains;
    } else if (heat < 80) {
        return if (humidity > 60) .jungle else if (humidity > 30) .savanna else .desert;
    } else {
        return if (humidity > 40) .badlands else .desert;
    }
}
