//! Biome color blending for chunk meshing.
//!
//! Computes biome-tinted colors for blocks using 3x3 biome averaging.
//! Only grass (top face), leaves, and water receive biome tints.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const BlockType = world_core.BlockType;
const Face = world_core.Face;
const biome_colors = @import("../biome_colors.zig");
const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;

/// Calculate the biome-tinted color for a block face.
/// Returns {1, 1, 1} (no tint) for blocks that don't receive biome coloring.
/// `s`, `u`, `v` are local coordinates on the slice plane (depending on `axis`).
pub inline fn getBlockColor(chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, u: u32, v: u32, block: BlockType) [3]f32 {
    // Only apply biome tint to top face of grass, and all faces of leaves/water
    if (block == .grass) {
        // Grass: only tint the top face, sides and bottom get no tint
        if (axis != .top) return .{ 1.0, 1.0, 1.0 };
    } else if (block != .leaves and block != .water) {
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
                else => .{ 1.0, 1.0, 1.0 },
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
