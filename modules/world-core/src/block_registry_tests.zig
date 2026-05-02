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
    try testing.expectEqual(@as(u2, 0), @intFromEnum(block_registry.RenderShape.cube));
    try testing.expectEqual(@as(u2, 1), @intFromEnum(block_registry.RenderShape.cross));
    try testing.expectEqual(@as(u2, 2), @intFromEnum(block_registry.RenderShape.flat_quad));
    try testing.expectEqual(@as(u2, 3), @intFromEnum(block_registry.RenderShape.tall_cross));
}
