//! Tall cross/billboard meshing for 2-block-high vegetation.
//!
//! Emits the same two diagonal billboard planes as cross meshing, but stretches
//! them across two vertical blocks from the bottom block position.
//!
//! Design note: unlike vanilla Minecraft which uses separate upper/lower block
//! types for tall vegetation, this engine stores tall vegetation (tall_grass,
//! tall_seagrass) as a SINGLE block whose billboard quad spans two
//! vertical blocks (y to y+2). Each tall_cross block is therefore
//! self-contained: it is found at its own Y position and renders the full
//! 2-block height from there. There is no separate "top half" block to detect,
//! so no look-back at the block below is needed.

const std = @import("std");

const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const PackedLight = world_core.PackedLight;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const block_registry = world_core.block_registry;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi_mod = @import("engine-rhi");
const Vertex = rhi_mod.Vertex;

const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;
const SUBCHUNK_SIZE = boundary.SUBCHUNK_SIZE;
const lighting_sampler = @import("lighting_sampler.zig");
const biome_colors = @import("../biome_colors.zig");

pub fn meshTallCrossBlocks(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    neighbors: NeighborChunks,
    si: u32,
    cutout_list: *std.ArrayListUnmanaged(Vertex),
    atlas: *const TextureAtlas,
) !void {
    const y0: i32 = @intCast(si * SUBCHUNK_SIZE);
    const y1: i32 = y0 + SUBCHUNK_SIZE;

    var y: i32 = y0;
    while (y < y1) : (y += 1) {
        var z: u32 = 0;
        while (z < CHUNK_SIZE_Z) : (z += 1) {
            var x: u32 = 0;
            while (x < CHUNK_SIZE_X) : (x += 1) {
                const block = chunk.getBlockSafe(@intCast(x), y, @intCast(z));
                const def = block_registry.getBlockDefinition(block);
                if (def.render_shape != .tall_cross) continue;

                const xi: i32 = @intCast(x);
                const zi: i32 = @intCast(z);
                const light = sampleTallCrossLight(chunk, neighbors, xi, y, zi);
                const norm_light = lighting_sampler.normalizeLightValues(light);
                const col = getTallCrossColor(chunk, neighbors, xi, zi, def);

                const tiles = atlas.getTilesForBlock(@intFromEnum(block));
                const tile_id: u16 = @intCast(tiles.side);

                const xf: f32 = @floatFromInt(x);
                const yf: f32 = @floatFromInt(y);
                const zf: f32 = @floatFromInt(z);

                try emitTallCrossQuad(allocator, cutout_list, .{ xf, yf, zf }, .{ xf + 1, yf + 2, zf + 1 }, col, norm_light, tile_id);
                try emitTallCrossQuad(allocator, cutout_list, .{ xf + 1, yf, zf }, .{ xf, yf + 2, zf + 1 }, col, norm_light, tile_id);
            }
        }
    }
}

fn sampleTallCrossLight(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) PackedLight {
    var result = PackedLight.init(0, 0);
    var oy: i32 = 0;
    while (oy <= 1) : (oy += 1) {
        var ox: i32 = -1;
        while (ox <= 1) : (ox += 1) {
            var oz: i32 = -1;
            while (oz <= 1) : (oz += 1) {
                const light = boundary.getLightCross(chunk, neighbors, x + ox, y + oy, z + oz);
                result.sky_light = @max(result.sky_light, light.getSkyLight());
                result.block_light_r = @max(result.block_light_r, light.getBlockLightR());
                result.block_light_g = @max(result.block_light_g, light.getBlockLightG());
                result.block_light_b = @max(result.block_light_b, light.getBlockLightB());
            }
        }
    }
    return result;
}

fn getTallCrossColor(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, z: i32, def: *const block_registry.BlockDefinition) [3]f32 {
    const tint: [3]f32 = if (def.is_tintable) blk: {
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
                r += colors.grass[0];
                g += colors.grass[1];
                b += colors.grass[2];
                count += 1.0;
            }
        }
        break :blk .{ r / count, g / count, b / count };
    } else .{ 1.0, 1.0, 1.0 };

    return .{
        def.default_color[0] * tint[0],
        def.default_color[1] * tint[1],
        def.default_color[2] * tint[2],
    };
}

fn emitTallCrossQuad(
    allocator: std.mem.Allocator,
    verts: *std.ArrayListUnmanaged(Vertex),
    p0: [3]f32,
    p1: [3]f32,
    col: [3]f32,
    light: lighting_sampler.NormalizedLight,
    tile_id: u16,
) !void {
    const bl = [3]f32{ p0[0], p0[1], p0[2] };
    const br = [3]f32{ p1[0], p0[1], p1[2] };
    const tr = [3]f32{ p1[0], p1[1], p1[2] };
    const tl = [3]f32{ p0[0], p1[1], p0[2] };

    const dx = p1[0] - p0[0];
    const dz = p1[2] - p0[2];
    const len = @sqrt(dx * dx + dz * dz);
    const normal = [3]f32{ -dz / len, 0, dx / len };
    const ao: f32 = 1.0;

    const positions = [4][3]f32{ bl, br, tr, tl };
    const uv = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };

    const v = [6][3]f32{ positions[0], positions[1], positions[2], positions[0], positions[2], positions[3] };
    const u = [6][2]f32{ uv[0], uv[1], uv[2], uv[0], uv[2], uv[3] };

    for (0..6) |i| {
        try verts.append(allocator, Vertex.init(v[i], col, normal, u[i], tile_id, light.skylight, light.blocklight, ao));
    }
}
