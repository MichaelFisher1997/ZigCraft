//! Biome color blending for chunk meshing.
//!
//! Computes biome-tinted colors for blocks using 3x3 biome averaging.
//! Grass top faces, leaves, and water receive biome tints.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const BlockType = world_core.BlockType;
const Face = world_core.Face;
const block_registry = world_core.block_registry;
const biome_colors = @import("../biome_colors.zig");
const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;

/// Calculate the biome-tinted color for a block face.
/// Returns {1, 1, 1} (no tint) for blocks that don't receive biome coloring.
/// `s`, `u`, `v` are local coordinates on the slice plane (depending on `axis`).
pub inline fn getBlockColor(chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, face: Face, s: i32, u: u32, v: u32, block: BlockType) [3]f32 {
    if (block == .grass) {
        if (face != .top) return .{ 1.0, 1.0, 1.0 };
    } else if (!isLeafBlock(block) and block != .water) {
        return .{ 1.0, 1.0, 1.0 };
    }

    var x: i32 = undefined;
    var z: i32 = undefined;

    switch (axis) {
        .top => {
            x = @intCast(u);
            z = @intCast(v);
        },
        .east => {
            x = s;
            z = @intCast(v);
        },
        .south => {
            x = @intCast(u);
            z = s;
        },
        else => {
            x = @intCast(u);
            z = @intCast(v);
        },
    }

    var r: f32 = 0;
    var g: f32 = 0;
    var b: f32 = 0;
    var count: f32 = 0;

    var ox: i32 = -1;
    while (ox <= 1) : (ox += 1) {
        var oz: i32 = -1;
        while (oz <= 1) : (oz += 1) {
            const biome_id = boundary.getBiomeAt(chunk, neighbors, x + ox, z + oz);
            const colors = biome_colors.getBiomeColors(biome_id);
            const col = switch (block) {
                .grass => colors.grass,
                .leaves => colors.foliage,
                .water => colors.water,
                else => if (isLeafBlock(block)) leafVariantTint(block, colors.foliage) else .{ 1.0, 1.0, 1.0 },
            };
            r += col[0];
            g += col[1];
            b += col[2];
            count += 1.0;
        }
    }

    std.debug.assert(count > 0);
    return .{ r / count, g / count, b / count };
}

fn isLeafBlock(block: BlockType) bool {
    return switch (block) {
        .leaves,
        .mangrove_leaves,
        .jungle_leaves,
        .acacia_leaves,
        .birch_leaves,
        .spruce_leaves,
        => true,
        else => false,
    };
}

fn leafVariantTint(block: BlockType, biome_foliage: [3]f32) [3]f32 {
    const base = block_registry.getBlockDefinition(block).default_color;
    return .{
        base[0] * 0.70 + biome_foliage[0] * 0.30,
        base[1] * 0.70 + biome_foliage[1] * 0.30,
        base[2] * 0.70 + biome_foliage[2] * 0.30,
    };
}

test "variant leaves receive green biome tint" {
    var chunk = Chunk.init(0, 0);
    chunk.setBiome(8, 8, .forest);

    const birch = getBlockColor(&chunk, .empty, .top, .top, 64, 8, 8, .birch_leaves);
    try std.testing.expect(birch[1] > birch[0]);
    try std.testing.expect(birch[1] > birch[2]);
    try std.testing.expect(birch[2] < 0.35);

    const spruce = getBlockColor(&chunk, .empty, .top, .top, 64, 8, 8, .spruce_leaves);
    try std.testing.expect(spruce[1] > spruce[2]);
    try std.testing.expect(spruce[0] < 0.25);
}
