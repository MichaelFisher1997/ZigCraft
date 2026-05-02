const std = @import("std");
const testing = std.testing;
const block_registry = @import("block_registry.zig");
const BlockType = @import("block.zig").BlockType;
const BlockDefinition = block_registry.BlockDefinition;
const Face = @import("block.zig").Face;

test "BlockDefinition.occludes air returns false" {
    const air = block_registry.getBlockDefinition(.air);
    const stone = block_registry.getBlockDefinition(.stone);
    try testing.expect(!air.occludes(stone, .top));
}

test "BlockDefinition.occludes solid blocks" {
    const stone = block_registry.getBlockDefinition(.stone);
    const air = block_registry.getBlockDefinition(.air);
    try testing.expect(stone.occludes(air, .top));
}

test "BlockDefinition.occludes same fluid culls" {
    const water = block_registry.getBlockDefinition(.water);
    const water2 = block_registry.getBlockDefinition(.water);
    try testing.expect(water.occludes(water2, .top));
}

test "BlockDefinition.occludes same transparent culls" {
    const glass = block_registry.getBlockDefinition(.glass);
    const glass2 = block_registry.getBlockDefinition(.glass);
    try testing.expect(glass.occludes(glass2, .east));
}

test "BlockDefinition.occludes different transparent blocks" {
    const glass = block_registry.getBlockDefinition(.glass);
    const leaves = block_registry.getBlockDefinition(.leaves);
    try testing.expect(!glass.occludes(leaves, .top));
}

test "BlockDefinition.occludes ignores face argument" {
    const stone = block_registry.getBlockDefinition(.stone);
    const air = block_registry.getBlockDefinition(.air);
    try testing.expect(stone.occludes(air, .top));
    try testing.expect(stone.occludes(air, .bottom));
    try testing.expect(stone.occludes(air, .north));
    try testing.expect(stone.occludes(air, .south));
    try testing.expect(stone.occludes(air, .east));
    try testing.expect(stone.occludes(air, .west));
}

test "BlockDefinition.getLightEmissionLevel glowstone is max" {
    const glowstone = block_registry.getBlockDefinition(.glowstone);
    try testing.expectEqual(@as(u4, 15), glowstone.getLightEmissionLevel());
}

test "BlockDefinition.getLightEmissionLevel torch lower emission" {
    const torch = block_registry.getBlockDefinition(.torch);
    try testing.expectEqual(@as(u4, 15), torch.getLightEmissionLevel());
}

test "BlockDefinition.getLightEmissionLevel lava moderate emission" {
    const lava = block_registry.getBlockDefinition(.lava);
    try testing.expectEqual(@as(u4, 15), lava.getLightEmissionLevel());
}

test "BlockDefinition.getLightEmissionLevel non-emissive is zero" {
    const stone = block_registry.getBlockDefinition(.stone);
    try testing.expectEqual(@as(u4, 0), stone.getLightEmissionLevel());
}

test "BlockDefinition.getLightEmissionLevel water is zero" {
    const water = block_registry.getBlockDefinition(.water);
    try testing.expectEqual(@as(u4, 0), water.getLightEmissionLevel());
}

test "BlockDefinition.getFaceColor applies shading to default color" {
    const grass = block_registry.getBlockDefinition(.grass);
    const top_color = grass.getFaceColor(.top);
    const bottom_color = grass.getFaceColor(.bottom);
    try testing.expect(top_color[0] > bottom_color[0]);
}

test "BlockDefinition.getFaceColor bottom has 0.5x shade" {
    const grass = block_registry.getBlockDefinition(.grass);
    const top_color = grass.getFaceColor(.top);
    const bottom_color = grass.getFaceColor(.bottom);
    try testing.expectApproxEqAbs(top_color[0] * 0.5, bottom_color[0], 0.001);
}

test "getBlockDefinition returns correct block type id" {
    const def = block_registry.getBlockDefinition(.stone);
    try testing.expectEqual(.stone, def.id);
}

test "getBlockDefinition returns correct name" {
    const def = block_registry.getBlockDefinition(.glowstone);
    try testing.expectEqual(@as(usize, 9), def.name.len);
}

test "RenderPass enum has expected variants" {
    try testing.expectEqual(@as(u2, 0), @intFromEnum(block_registry.RenderPass.solid));
    try testing.expectEqual(@as(u2, 1), @intFromEnum(block_registry.RenderPass.cutout));
    try testing.expectEqual(@as(u2, 2), @intFromEnum(block_registry.RenderPass.fluid));
    try testing.expectEqual(@as(u2, 3), @intFromEnum(block_registry.RenderPass.translucent));
}

test "RenderShape enum has expected variants" {
    try testing.expectEqual(@as(u3, 0), @intFromEnum(block_registry.RenderShape.cube));
    try testing.expectEqual(@as(u3, 1), @intFromEnum(block_registry.RenderShape.cross));
    try testing.expectEqual(@as(u3, 2), @intFromEnum(block_registry.RenderShape.flat_quad));
    try testing.expectEqual(@as(u3, 3), @intFromEnum(block_registry.RenderShape.tall_cross));
    try testing.expectEqual(@as(u3, 4), @intFromEnum(block_registry.RenderShape.wall_attached));
    try testing.expectEqual(@as(u3, 5), @intFromEnum(block_registry.RenderShape.custom_mesh));
}

test "AttachmentFaces walls contains only cardinal faces" {
    const walls = block_registry.AttachmentFaces.walls();
    try testing.expect(walls.contains(.north));
    try testing.expect(walls.contains(.south));
    try testing.expect(walls.contains(.east));
    try testing.expect(walls.contains(.west));
    try testing.expect(!walls.contains(.top));
    try testing.expect(!walls.contains(.bottom));
}

test "vine is wall-attached render shape fixture" {
    const vine = block_registry.getBlockDefinition(.vine);
    try testing.expectEqual(block_registry.RenderShape.wall_attached, vine.render_shape);
    const attachment = vine.render_shape_data.attachment orelse return error.TestExpectedEqual;
    try testing.expectEqual(Face.north, attachment.default_face);
    try testing.expect(attachment.allowed_faces.contains(attachment.default_face));
}

test "RenderShapeData can represent custom mesh variants" {
    const data = block_registry.RenderShapeData{ .custom_mesh = .stairs };
    try testing.expectEqual(block_registry.CustomMeshVariant.stairs, data.custom_mesh);
    try testing.expectEqual(null, data.attachment);
}

test "core natural block pack registry properties" {
    try testing.expectEqual(block_registry.RenderShape.flat_quad, block_registry.getBlockDefinition(.snow_layer).render_shape);
    try testing.expectEqual(block_registry.RenderPass.cutout, block_registry.getBlockDefinition(.snow_layer).render_pass);
    try testing.expect(!block_registry.getBlockDefinition(.snow_layer).is_solid);

    try testing.expectEqual(block_registry.RenderPass.translucent, block_registry.getBlockDefinition(.ice).render_pass);
    try testing.expect(block_registry.getBlockDefinition(.ice).is_solid);
    try testing.expect(block_registry.getBlockDefinition(.blue_ice).is_transparent);

    try testing.expectEqualStrings("podzol_top", block_registry.getBlockDefinition(.podzol).texture_top);
    try testing.expectEqualStrings("dirt", block_registry.getBlockDefinition(.podzol).texture_bottom);
    try testing.expectEqualStrings("podzol_side", block_registry.getBlockDefinition(.podzol).texture_side);

    try testing.expectEqual(block_registry.RenderPass.solid, block_registry.getBlockDefinition(.mossy_cobblestone).render_pass);
    try testing.expectEqual(block_registry.RenderPass.solid, block_registry.getBlockDefinition(.red_terracotta).render_pass);
    try testing.expectEqual(block_registry.RenderPass.solid, block_registry.getBlockDefinition(.white_terracotta).render_pass);
}

test "aquatic vegetation blocks use cutout shapes" {
    const seagrass = block_registry.getBlockDefinition(.seagrass);
    try testing.expect(!seagrass.is_solid);
    try testing.expectEqual(block_registry.RenderPass.cutout, seagrass.render_pass);
    try testing.expectEqual(block_registry.RenderShape.cross, seagrass.render_shape);

    const kelp = block_registry.getBlockDefinition(.kelp);
    try testing.expect(!kelp.is_solid);
    try testing.expectEqual(block_registry.RenderShape.tall_cross, kelp.render_shape);

    const coral_fan = block_registry.getBlockDefinition(.coral_fan);
    try testing.expect(!coral_fan.is_solid);
    try testing.expectEqual(block_registry.RenderShape.flat_quad, coral_fan.render_shape);
}

test "coral block is a solid underwater block" {
    const coral = block_registry.getBlockDefinition(.coral_block);
    try testing.expect(coral.is_solid);
    try testing.expectEqual(block_registry.RenderPass.solid, coral.render_pass);
}
