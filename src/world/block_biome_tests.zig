const std = @import("std");
const testing = std.testing;
const BlockType = @import("block.zig").BlockType;
const Biome = @import("block.zig").Biome;

test "Biome.getSurfaceBlock deep ocean returns gravel" {
    try testing.expectEqual(BlockType.gravel, Biome.deep_ocean.getSurfaceBlock());
    try testing.expectEqual(BlockType.gravel, Biome.ocean.getSurfaceBlock());
}

test "Biome.getSurfaceBlock beach returns sand" {
    try testing.expectEqual(BlockType.sand, Biome.beach.getSurfaceBlock());
}

test "Biome.getSurfaceBlock plains and forest return grass" {
    try testing.expectEqual(BlockType.grass, Biome.plains.getSurfaceBlock());
    try testing.expectEqual(BlockType.grass, Biome.forest.getSurfaceBlock());
}

test "Biome.getSurfaceBlock desert returns sand" {
    try testing.expectEqual(BlockType.sand, Biome.desert.getSurfaceBlock());
}

test "Biome.getSurfaceBlock taiga returns grass" {
    try testing.expectEqual(BlockType.grass, Biome.taiga.getSurfaceBlock());
}

test "Biome.getSurfaceBlock snow tundra returns snow block" {
    try testing.expectEqual(BlockType.snow_block, Biome.snow_tundra.getSurfaceBlock());
    try testing.expectEqual(BlockType.snow_block, Biome.snowy_mountains.getSurfaceBlock());
}

test "Biome.getSurfaceBlock mountains returns stone" {
    try testing.expectEqual(BlockType.stone, Biome.mountains.getSurfaceBlock());
}

test "Biome.getSurfaceBlock river returns sand" {
    try testing.expectEqual(BlockType.sand, Biome.river.getSurfaceBlock());
}

test "Biome.getSurfaceBlock swamp returns grass" {
    try testing.expectEqual(BlockType.grass, Biome.swamp.getSurfaceBlock());
}

test "Biome.getSurfaceBlock mangrove swamp returns mud" {
    try testing.expectEqual(BlockType.mud, Biome.mangrove_swamp.getSurfaceBlock());
}

test "Biome.getSurfaceBlock jungle returns grass" {
    try testing.expectEqual(BlockType.grass, Biome.jungle.getSurfaceBlock());
}

test "Biome.getSurfaceBlock savanna returns grass" {
    try testing.expectEqual(BlockType.grass, Biome.savanna.getSurfaceBlock());
}

test "Biome.getSurfaceBlock badlands returns red sand" {
    try testing.expectEqual(BlockType.red_sand, Biome.badlands.getSurfaceBlock());
}

test "Biome.getSurfaceBlock mushroom fields returns mycelium" {
    try testing.expectEqual(BlockType.mycelium, Biome.mushroom_fields.getSurfaceBlock());
}

test "Biome.getSurfaceBlock transition biomes return grass" {
    try testing.expectEqual(BlockType.grass, Biome.foothills.getSurfaceBlock());
    try testing.expectEqual(BlockType.grass, Biome.marsh.getSurfaceBlock());
    try testing.expectEqual(BlockType.grass, Biome.dry_plains.getSurfaceBlock());
    try testing.expectEqual(BlockType.grass, Biome.coastal_plains.getSurfaceBlock());
}

test "Biome.getFillerBlock deep ocean returns gravel" {
    try testing.expectEqual(BlockType.gravel, Biome.deep_ocean.getFillerBlock());
}

test "Biome.getFillerBlock ocean returns sand" {
    try testing.expectEqual(BlockType.sand, Biome.ocean.getFillerBlock());
}

test "Biome.getFillerBlock beach and desert return sand" {
    try testing.expectEqual(BlockType.sand, Biome.beach.getFillerBlock());
    try testing.expectEqual(BlockType.sand, Biome.desert.getFillerBlock());
    try testing.expectEqual(BlockType.sand, Biome.river.getFillerBlock());
}

test "Biome.getFillerBlock plains and forest return dirt" {
    try testing.expectEqual(BlockType.dirt, Biome.plains.getFillerBlock());
    try testing.expectEqual(BlockType.dirt, Biome.forest.getFillerBlock());
}

test "Biome.getFillerBlock taiga returns dirt" {
    try testing.expectEqual(BlockType.dirt, Biome.taiga.getFillerBlock());
}

test "Biome.getFillerBlock swamp returns dirt" {
    try testing.expectEqual(BlockType.dirt, Biome.swamp.getFillerBlock());
}

test "Biome.getFillerBlock jungle returns dirt" {
    try testing.expectEqual(BlockType.dirt, Biome.jungle.getFillerBlock());
}

test "Biome.getFillerBlock snow tundra returns dirt" {
    try testing.expectEqual(BlockType.dirt, Biome.snow_tundra.getFillerBlock());
}

test "Biome.getFillerBlock mountains returns stone" {
    try testing.expectEqual(BlockType.stone, Biome.mountains.getFillerBlock());
    try testing.expectEqual(BlockType.stone, Biome.snowy_mountains.getFillerBlock());
}

test "Biome.getFillerBlock mangrove swamp returns mud" {
    try testing.expectEqual(BlockType.mud, Biome.mangrove_swamp.getFillerBlock());
}

test "Biome.getFillerBlock badlands returns terracotta" {
    try testing.expectEqual(BlockType.terracotta, Biome.badlands.getFillerBlock());
}

test "Biome.getFillerBlock mushroom fields returns dirt" {
    try testing.expectEqual(BlockType.dirt, Biome.mushroom_fields.getFillerBlock());
}

test "Biome.getFillerBlock transition biomes return dirt" {
    try testing.expectEqual(BlockType.dirt, Biome.foothills.getFillerBlock());
    try testing.expectEqual(BlockType.dirt, Biome.marsh.getFillerBlock());
    try testing.expectEqual(BlockType.dirt, Biome.dry_plains.getFillerBlock());
    try testing.expectEqual(BlockType.dirt, Biome.coastal_plains.getFillerBlock());
}

test "Biome.getOceanFloorBlock deep depth returns gravel" {
    try testing.expectEqual(BlockType.gravel, Biome.ocean.getOceanFloorBlock(50.0));
    try testing.expectEqual(BlockType.gravel, Biome.deep_ocean.getOceanFloorBlock(50.0));
}

test "Biome.getOceanFloorBlock mid depth returns clay" {
    try testing.expectEqual(BlockType.clay, Biome.ocean.getOceanFloorBlock(20.0));
    try testing.expectEqual(BlockType.clay, Biome.deep_ocean.getOceanFloorBlock(20.0));
}

test "Biome.getOceanFloorBlock shallow returns sand" {
    try testing.expectEqual(BlockType.sand, Biome.ocean.getOceanFloorBlock(10.0));
    try testing.expectEqual(BlockType.sand, Biome.deep_ocean.getOceanFloorBlock(5.0));
}

test "Biome.getOceanFloorBlock boundary at depth 15" {
    try testing.expectEqual(BlockType.clay, Biome.ocean.getOceanFloorBlock(15.0001));
    try testing.expectEqual(BlockType.sand, Biome.ocean.getOceanFloorBlock(15.0));
}

test "Biome.getOceanFloorBlock boundary at depth 30" {
    try testing.expectEqual(BlockType.gravel, Biome.ocean.getOceanFloorBlock(30.0001));
    try testing.expectEqual(BlockType.clay, Biome.ocean.getOceanFloorBlock(30.0));
}
