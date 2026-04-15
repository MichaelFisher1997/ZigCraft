const std = @import("std");
const testing = std.testing;
const Biome = @import("block.zig").Biome;
const BlockType = @import("block.zig").BlockType;
const block_registry = @import("block_registry.zig");
const getBlockDefinition = block_registry.getBlockDefinition;

test "Biome.getSurfaceBlock deep_ocean and ocean return gravel" {
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

test "Biome.getSurfaceBlock snowy biomes return snow_block" {
    try testing.expectEqual(BlockType.snow_block, Biome.snow_tundra.getSurfaceBlock());
    try testing.expectEqual(BlockType.snow_block, Biome.snowy_mountains.getSurfaceBlock());
}

test "Biome.getSurfaceBlock mountains returns stone" {
    try testing.expectEqual(BlockType.stone, Biome.mountains.getSurfaceBlock());
}

test "Biome.getSurfaceBlock river returns sand" {
    try testing.expectEqual(BlockType.sand, Biome.river.getSurfaceBlock());
}

test "Biome.getSurfaceBlock mangrove_swamp returns mud" {
    try testing.expectEqual(BlockType.mud, Biome.mangrove_swamp.getSurfaceBlock());
}

test "Biome.getSurfaceBlock badlands returns red_sand" {
    try testing.expectEqual(BlockType.red_sand, Biome.badlands.getSurfaceBlock());
}

test "Biome.getSurfaceBlock mushroom_fields returns mycelium" {
    try testing.expectEqual(BlockType.mycelium, Biome.mushroom_fields.getSurfaceBlock());
}

test "Biome.getSurfaceBlock micro-biomes return grass" {
    try testing.expectEqual(BlockType.grass, Biome.foothills.getSurfaceBlock());
    try testing.expectEqual(BlockType.grass, Biome.marsh.getSurfaceBlock());
    try testing.expectEqual(BlockType.grass, Biome.dry_plains.getSurfaceBlock());
    try testing.expectEqual(BlockType.grass, Biome.coastal_plains.getSurfaceBlock());
}

test "Biome.getFillerBlock deep_ocean returns gravel" {
    try testing.expectEqual(BlockType.gravel, Biome.deep_ocean.getFillerBlock());
}

test "Biome.getFillerBlock ocean returns sand" {
    try testing.expectEqual(BlockType.sand, Biome.ocean.getFillerBlock());
}

test "Biome.getFillerBlock beach and desert return sand" {
    try testing.expectEqual(BlockType.sand, Biome.beach.getFillerBlock());
    try testing.expectEqual(BlockType.sand, Biome.desert.getFillerBlock());
}

test "Biome.getFillerBlock taiga returns dirt" {
    try testing.expectEqual(BlockType.dirt, Biome.taiga.getFillerBlock());
}

test "Biome.getFillerBlock snowy_tundra returns dirt" {
    try testing.expectEqual(BlockType.dirt, Biome.snow_tundra.getFillerBlock());
}

test "Biome.getFillerBlock mountains returns stone" {
    try testing.expectEqual(BlockType.stone, Biome.mountains.getSurfaceBlock());
}

test "Biome.getFillerBlock mangrove_swamp returns mud" {
    try testing.expectEqual(BlockType.mud, Biome.mangrove_swamp.getFillerBlock());
}

test "Biome.getFillerBlock badlands returns terracotta" {
    try testing.expectEqual(BlockType.terracotta, Biome.badlands.getFillerBlock());
}

test "Biome.getOceanFloorBlock deep returns gravel" {
    try testing.expectEqual(BlockType.gravel, Biome.ocean.getOceanFloorBlock(40.0));
}

test "Biome.getOceanFloorBlock mid-depth returns clay" {
    try testing.expectEqual(BlockType.clay, Biome.ocean.getOceanFloorBlock(20.0));
}

test "Biome.getOceanFloorBlock shallow returns sand" {
    try testing.expectEqual(BlockType.sand, Biome.ocean.getOceanFloorBlock(5.0));
}

test "Biome.getOceanFloorBlock at 15 returns sand (boundary is > not >=)" {
    try testing.expectEqual(BlockType.sand, Biome.ocean.getOceanFloorBlock(15.0));
}

test "Biome.getOceanFloorBlock at 16 returns clay (boundary is > not >=)" {
    try testing.expectEqual(BlockType.clay, Biome.ocean.getOceanFloorBlock(16.0));
}

test "Biome.getOceanFloorBlock at 30 returns clay (boundary is > not >=)" {
    try testing.expectEqual(BlockType.clay, Biome.ocean.getOceanFloorBlock(30.0));
}

test "Biome.getOceanFloorBlock at 31 returns gravel (boundary is > not >=)" {
    try testing.expectEqual(BlockType.gravel, Biome.ocean.getOceanFloorBlock(31.0));
}

test "BlockType render_pass for solid blocks" {
    try testing.expectEqual(block_registry.RenderPass.solid, getBlockDefinition(.stone).render_pass);
    try testing.expectEqual(block_registry.RenderPass.solid, getBlockDefinition(.dirt).render_pass);
    try testing.expectEqual(block_registry.RenderPass.solid, getBlockDefinition(.bedrock).render_pass);
}

test "BlockType render_pass for fluid blocks" {
    try testing.expectEqual(block_registry.RenderPass.fluid, getBlockDefinition(.water).render_pass);
    try testing.expectEqual(block_registry.RenderPass.fluid, getBlockDefinition(.lava).render_pass);
}

test "BlockType render_pass for translucent blocks" {
    try testing.expectEqual(block_registry.RenderPass.translucent, getBlockDefinition(.glass).render_pass);
}

test "BlockType render_pass for cutout blocks" {
    try testing.expectEqual(block_registry.RenderPass.cutout, getBlockDefinition(.leaves).render_pass);
    try testing.expectEqual(block_registry.RenderPass.cutout, getBlockDefinition(.flower_red).render_pass);
    try testing.expectEqual(block_registry.RenderPass.cutout, getBlockDefinition(.tall_grass).render_pass);
    try testing.expectEqual(block_registry.RenderPass.cutout, getBlockDefinition(.vine).render_pass);
    try testing.expectEqual(block_registry.RenderPass.cutout, getBlockDefinition(.cactus).render_pass);
}

test "BlockType render_shape for cross blocks" {
    try testing.expectEqual(block_registry.RenderShape.cross, getBlockDefinition(.flower_red).render_shape);
    try testing.expectEqual(block_registry.RenderShape.cross, getBlockDefinition(.flower_yellow).render_shape);
    try testing.expectEqual(block_registry.RenderShape.cross, getBlockDefinition(.tall_grass).render_shape);
    try testing.expectEqual(block_registry.RenderShape.cross, getBlockDefinition(.dead_bush).render_shape);
    try testing.expectEqual(block_registry.RenderShape.cross, getBlockDefinition(.acacia_sapling).render_shape);
    try testing.expectEqual(block_registry.RenderShape.cross, getBlockDefinition(.bamboo).render_shape);
    try testing.expectEqual(block_registry.RenderShape.cross, getBlockDefinition(.torch).render_shape);
}

test "BlockType render_shape for cube blocks" {
    try testing.expectEqual(block_registry.RenderShape.cube, getBlockDefinition(.stone).render_shape);
    try testing.expectEqual(block_registry.RenderShape.cube, getBlockDefinition(.grass).render_shape);
    try testing.expectEqual(block_registry.RenderShape.cube, getBlockDefinition(.water).render_shape);
}

test "BlockType light_emission for glowstone" {
    const def = getBlockDefinition(.glowstone);
    try testing.expectEqual(@as(u4, 15), def.light_emission[0]);
    try testing.expectEqual(@as(u4, 14), def.light_emission[1]);
    try testing.expectEqual(@as(u4, 10), def.light_emission[2]);
}

test "BlockType light_emission for torch" {
    const def = getBlockDefinition(.torch);
    try testing.expectEqual(@as(u4, 15), def.light_emission[0]);
    try testing.expectEqual(@as(u4, 11), def.light_emission[1]);
    try testing.expectEqual(@as(u4, 6), def.light_emission[2]);
}

test "BlockType light_emission for lava" {
    const def = getBlockDefinition(.lava);
    try testing.expectEqual(@as(u4, 15), def.light_emission[0]);
    try testing.expectEqual(@as(u4, 8), def.light_emission[1]);
    try testing.expectEqual(@as(u4, 3), def.light_emission[2]);
}

test "BlockType is_tintable for leaves and water" {
    try testing.expect(getBlockDefinition(.leaves).is_tintable);
    try testing.expect(getBlockDefinition(.mangrove_leaves).is_tintable);
    try testing.expect(getBlockDefinition(.jungle_leaves).is_tintable);
    try testing.expect(getBlockDefinition(.acacia_leaves).is_tintable);
    try testing.expect(getBlockDefinition(.birch_leaves).is_tintable);
    try testing.expect(getBlockDefinition(.spruce_leaves).is_tintable);
    try testing.expect(getBlockDefinition(.vine).is_tintable);
    try testing.expect(getBlockDefinition(.tall_grass).is_tintable);
    try testing.expect(getBlockDefinition(.water).is_tintable);
}

test "BlockType is_tintable false for solid blocks" {
    try testing.expect(!getBlockDefinition(.stone).is_tintable);
    try testing.expect(!getBlockDefinition(.dirt).is_tintable);
    try testing.expect(!getBlockDefinition(.grass).is_tintable);
}

test "BlockType is_fluid for water and lava" {
    try testing.expect(getBlockDefinition(.water).is_fluid);
    try testing.expect(getBlockDefinition(.lava).is_fluid);
}

test "BlockType is_fluid false for solid blocks" {
    try testing.expect(!getBlockDefinition(.stone).is_fluid);
    try testing.expect(!getBlockDefinition(.dirt).is_fluid);
    try testing.expect(!getBlockDefinition(.glass).is_fluid);
}

test "BlockType texture names are set" {
    try testing.expect(getBlockDefinition(.grass).texture_top.len > 0);
    try testing.expect(getBlockDefinition(.grass).texture_bottom.len > 0);
    try testing.expect(getBlockDefinition(.grass).texture_side.len > 0);
}

test "BlockType texture names for wood variants" {
    const wood = getBlockDefinition(.wood);
    try testing.expect(wood.texture_top.len > 0);
    try testing.expect(wood.texture_side.len > 0);
}
