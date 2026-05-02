//! Biome color lookup for LOD rendering and minimap.

const BiomeId = @import("biome_registry.zig").BiomeId;

/// Get biome color for LOD rendering (packed RGB)
/// Colors adjusted to match textured output (grass/surface colors)
pub fn getBiomeColor(biome_id: BiomeId) u32 {
    return switch (biome_id) {
        .deep_ocean => 0x1A3380, // Darker blue
        .ocean => 0x3366CC, // Standard ocean blue
        .warm_ocean => 0x1F8FCC, // Brighter warm ocean
        .tropical => 0x2BBF9A, // Tropical shallows
        .beach => 0xDDBB88, // Sand color
        .plains => 0x4D8033, // Darker grass green
        .forest => 0x2D591A, // Darker forest green
        .taiga => 0x476647, // Muted taiga green
        .desert => 0xD4B36A, // Warm desert sand
        .snow_tundra => 0xDDEEFF, // Snow
        .mountains => 0x888888, // Stone grey
        .snowy_mountains => 0xCCDDEE, // Snowy stone
        .meadow => 0x66AA44, // Alpine meadow
        .grove => 0x345C38, // High spruce grove
        .snowy_slopes => 0xD6E6F2, // Snowy slope
        .jagged_peaks => 0x8F8F8A, // Exposed stone peak
        .frozen_peaks => 0xB8DFF5, // Ice peak
        .stony_peaks => 0x9C9278, // Warm stony peak
        .river => 0x4488CC, // River blue
        .swamp => 0x334D33, // Dark swamp green
        .mangrove_swamp => 0x264026, // Muted mangrove
        .jungle => 0x1A661A, // Vibrant jungle green
        .savanna => 0x8C8C4D, // Dry savanna green
        .badlands => 0xAA6633, // Terracotta orange
        .mushroom_fields => 0x995577, // Mycelium purple
        .foothills => 0x597340, // Transitional green
        .marsh => 0x405933, // Transitional wetland
        .dry_plains => 0x8C8047, // Transitional dry plains
        .coastal_plains => 0x598047, // Transitional coastal
    };
}
