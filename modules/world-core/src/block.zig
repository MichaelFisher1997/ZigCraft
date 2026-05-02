//! Block types and their properties.

const voxel = @import("engine-math").voxel;

/// Biome types for terrain generation
/// NOTE: This enum is kept for compatibility. See worldgen/biome.zig for
/// the data-driven BiomeDefinition system.
/// Per worldgen-revamp.md: includes transition micro-biomes
pub const Biome = enum(u8) {
    deep_ocean = 0,
    ocean = 1,
    beach = 2,
    plains = 3,
    forest = 4,
    taiga = 5,
    desert = 6,
    snow_tundra = 7,
    mountains = 8,
    snowy_mountains = 9,
    river = 10,
    swamp = 11,
    mangrove_swamp = 12,
    jungle = 13,
    savanna = 14,
    badlands = 15,
    mushroom_fields = 16,
    // Per worldgen-revamp.md Section 4.3: Transition micro-biomes
    foothills = 17,
    marsh = 18,
    dry_plains = 19,
    coastal_plains = 20,
    warm_ocean = 21,
    tropical = 22,
    bamboo_jungle = 23,
    sparse_jungle = 24,
    wooded_badlands = 25,
    eroded_badlands = 26,
    savanna_plateau = 27,
    windswept_savanna = 28,

    /// Get surface block for this biome
    /// Prefer using BiomeDefinition.surface from worldgen/biome.zig
    pub fn getSurfaceBlock(self: Biome) BlockType {
        return switch (self) {
            .deep_ocean, .ocean, .warm_ocean => .gravel,
            .tropical => .sand,
            .beach => .sand,
            .plains, .forest, .swamp, .jungle, .savanna, .foothills, .marsh, .dry_plains, .coastal_plains, .bamboo_jungle, .sparse_jungle, .savanna_plateau, .windswept_savanna => .grass,
            .wooded_badlands, .eroded_badlands => .red_sand,
            .taiga => .grass,
            .desert => .sand,
            .snow_tundra, .snowy_mountains => .snow_block,
            .mountains => .stone,
            .river => .sand,
            .mangrove_swamp => .mud,
            .badlands => .red_sand,
            .mushroom_fields => .mycelium,
        };
    }

    /// Get filler block (subsurface) for this biome
    /// Prefer using BiomeDefinition.surface from worldgen/biome.zig
    pub fn getFillerBlock(self: Biome) BlockType {
        return switch (self) {
            .deep_ocean => .gravel,
            .ocean, .warm_ocean, .tropical => .sand,
            .beach, .desert, .river => .sand,
            .plains, .forest, .taiga, .swamp, .jungle, .savanna, .foothills, .marsh, .dry_plains, .coastal_plains, .bamboo_jungle, .sparse_jungle, .savanna_plateau, .windswept_savanna => .dirt,
            .snow_tundra => .dirt,
            .mountains, .snowy_mountains => .stone,
            .mangrove_swamp => .mud,
            .badlands, .wooded_badlands, .eroded_badlands => .terracotta,
            .mushroom_fields => .dirt,
        };
    }

    /// Get ocean floor block for this biome
    pub fn getOceanFloorBlock(self: Biome, depth: f32) BlockType {
        _ = self;
        if (depth > 30) return .gravel; // Deep ocean floor
        if (depth > 15) return .clay; // Mid-depth
        return .sand; // Shallow
    }
};

pub const BlockType = enum(u8) {
    air = 0,
    stone = 1,
    dirt = 2,
    grass = 3,
    sand = 4,
    water = 5,
    wood = 6,
    leaves = 7,
    cobblestone = 8,
    bedrock = 9,
    gravel = 10,
    glass = 11,
    snow_block = 12,
    cactus = 13,
    coal_ore = 14,
    iron_ore = 15,
    gold_ore = 16,
    clay = 17,
    glowstone = 18,
    mud = 19,
    mangrove_log = 20,
    mangrove_leaves = 21,
    mangrove_roots = 22,
    jungle_log = 23,
    jungle_leaves = 24,
    melon = 25,
    bamboo = 26,
    acacia_log = 27,
    acacia_leaves = 28,
    acacia_sapling = 29,
    terracotta = 30,
    red_sand = 31,
    mycelium = 32,
    mushroom_stem = 33,
    red_mushroom_block = 34,
    brown_mushroom_block = 35,
    tall_grass = 36,
    flower_red = 37,
    flower_yellow = 38,
    dead_bush = 39,
    birch_log = 40,
    birch_leaves = 41,
    spruce_log = 42,
    spruce_leaves = 43,
    vine = 44,
    torch = 45,
    lava = 46,
    snow_layer = 47,
    ice = 48,
    packed_ice = 49,
    blue_ice = 50,
    coarse_dirt = 51,
    rooted_dirt = 52,
    podzol = 53,
    mossy_cobblestone = 54,
    white_terracotta = 55,
    orange_terracotta = 56,
    magenta_terracotta = 57,
    light_blue_terracotta = 58,
    yellow_terracotta = 59,
    lime_terracotta = 60,
    pink_terracotta = 61,
    gray_terracotta = 62,
    light_gray_terracotta = 63,
    cyan_terracotta = 64,
    purple_terracotta = 65,
    blue_terracotta = 66,
    brown_terracotta = 67,
    green_terracotta = 68,
    red_terracotta = 69,
    black_terracotta = 70,
    seagrass = 71,
    kelp = 72,
    seaweed = 73,
    coral_block = 74,
    coral_fan = 75,
    tall_seagrass = 76,

    _,
};

pub const Face = voxel.Face;

/// All 6 faces for iteration
pub const ALL_FACES = voxel.ALL_FACES;
