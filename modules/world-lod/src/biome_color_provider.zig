const BiomeId = @import("world-core").BiomeId;

pub fn getBiomeColor(biome_id: BiomeId) u32 {
    return switch (biome_id) {
        .deep_ocean => 0x1A3380,
        .ocean => 0x3366CC,
        .beach => 0xDDBB88,
        .plains => 0x4D8033,
        .forest => 0x2D591A,
        .taiga => 0x476647,
        .desert => 0xD4B36A,
        .snow_tundra => 0xDDEEFF,
        .mountains => 0x888888,
        .snowy_mountains => 0xCCDDEE,
        .river => 0x4488CC,
        .swamp => 0x334D33,
        .mangrove_swamp => 0x264026,
        .jungle => 0x1A661A,
        .savanna => 0x8C8C4D,
        .badlands => 0xAA6633,
        .mushroom_fields => 0x995577,
        .foothills => 0x597340,
        .marsh => 0x405933,
        .dry_plains => 0x8C8047,
        .coastal_plains => 0x598047,
    };
}
