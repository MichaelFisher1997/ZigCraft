//! Edge detection types, transition rules, and boundary logic.
//! Determines when biome transitions are needed and which transition biome to use.

const BiomeId = @import("biome_registry.zig").BiomeId;

// ============================================================================
// Edge Detection Types and Constants (Issue #102)
// ============================================================================

/// Sampling step for edge detection (every N blocks)
pub const EDGE_STEP: u32 = 4;

/// Radii to check for neighboring biomes (in world blocks)
pub const EDGE_CHECK_RADII = [_]u32{ 4, 8, 12 };

/// Target width of transition bands (blocks)
pub const EDGE_WIDTH: u32 = 8;

/// Represents proximity to a biome boundary
pub const EdgeBand = enum(u2) {
    none = 0, // No edge detected
    outer = 1, // 8-12 blocks from boundary
    middle = 2, // 4-8 blocks from boundary
    inner = 3, // 0-4 blocks from boundary
};

/// Information about biome edge detection result
pub const BiomeEdgeInfo = struct {
    base_biome: BiomeId,
    neighbor_biome: ?BiomeId, // Different biome if edge detected
    edge_band: EdgeBand,
};

/// Rule defining which biome pairs need a transition zone
pub const TransitionRule = struct {
    biome_a: BiomeId,
    biome_b: BiomeId,
    transition: BiomeId,
};

/// Biome adjacency rules - pairs that need buffer biomes between them
pub const TRANSITION_RULES = [_]TransitionRule{
    // Hot/dry <-> Temperate
    .{ .biome_a = .desert, .biome_b = .forest, .transition = .dry_plains },
    .{ .biome_a = .desert, .biome_b = .plains, .transition = .dry_plains },
    .{ .biome_a = .desert, .biome_b = .taiga, .transition = .dry_plains },
    .{ .biome_a = .desert, .biome_b = .jungle, .transition = .savanna },

    // Cold <-> Temperate
    .{ .biome_a = .snow_tundra, .biome_b = .plains, .transition = .taiga },
    .{ .biome_a = .snow_tundra, .biome_b = .forest, .transition = .taiga },

    // Wetland <-> Forest
    .{ .biome_a = .swamp, .biome_b = .forest, .transition = .marsh },
    .{ .biome_a = .swamp, .biome_b = .plains, .transition = .marsh },

    // Mountain <-> Lowland
    .{ .biome_a = .mountains, .biome_b = .plains, .transition = .foothills },
    .{ .biome_a = .mountains, .biome_b = .forest, .transition = .foothills },
    .{ .biome_a = .snowy_mountains, .biome_b = .taiga, .transition = .foothills },
    .{ .biome_a = .snowy_mountains, .biome_b = .snow_tundra, .transition = .foothills },
};

/// Check if two biomes need a transition zone between them
pub fn needsTransition(a: BiomeId, b: BiomeId) bool {
    for (TRANSITION_RULES) |rule| {
        if ((rule.biome_a == a and rule.biome_b == b) or
            (rule.biome_a == b and rule.biome_b == a))
        {
            return true;
        }
    }
    return false;
}

/// Get the transition biome for a pair of biomes, if one is defined
pub fn getTransitionBiome(a: BiomeId, b: BiomeId) ?BiomeId {
    for (TRANSITION_RULES) |rule| {
        if ((rule.biome_a == a and rule.biome_b == b) or
            (rule.biome_a == b and rule.biome_b == a))
        {
            return rule.transition;
        }
    }
    return null;
}
