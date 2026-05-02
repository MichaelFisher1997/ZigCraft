//! Flat quad meshing for floor-aligned cutout blocks.
//!
//! Emits one horizontal quad per block, slightly above the block base to avoid
//! z-fighting with the supporting cube top face.

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

const FLAT_QUAD_Y_OFFSET: f32 = 0.03125;

pub fn meshFlatQuadBlocks(
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
                if (def.render_shape != .flat_quad) continue;

                const xi: i32 = @intCast(x);
                const zi: i32 = @intCast(z);
                const light = sampleShapeLight(chunk, neighbors, xi, y, zi);
                const entrance_bounce = sampleShapeEntranceBounce(chunk, neighbors, xi, y, zi);
                const entrance_dir = boundary.getEntranceDirCross(chunk, neighbors, xi, y, zi);
                const norm_light = lighting_sampler.normalizeLightValues(light, entrance_bounce, entrance_dir);
                const col = getShapeColor(chunk, neighbors, xi, zi, def);

                const tiles = atlas.getTilesForBlock(@intFromEnum(block));
                const tile_id: u16 = @intCast(tiles.side);

                const xf: f32 = @floatFromInt(x);
                const yf: f32 = @as(f32, @floatFromInt(y)) + FLAT_QUAD_Y_OFFSET;
                const zf: f32 = @floatFromInt(z);

                try emitFlatQuad(allocator, cutout_list, xf, yf, zf, col, norm_light, tile_id);
            }
        }
    }
}

fn sampleShapeLight(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) PackedLight {
    var result = PackedLight.init(0, 0);
    var ox: i32 = -1;
    while (ox <= 1) : (ox += 1) {
        var oz: i32 = -1;
        while (oz <= 1) : (oz += 1) {
            const light = boundary.getLightCross(chunk, neighbors, x + ox, y, z + oz);
            result.sky_light = @max(result.sky_light, light.getSkyLight());
            result.block_light_r = @max(result.block_light_r, light.getBlockLightR());
            result.block_light_g = @max(result.block_light_g, light.getBlockLightG());
            result.block_light_b = @max(result.block_light_b, light.getBlockLightB());
        }
    }
    return result;
}

fn sampleShapeEntranceBounce(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) u4 {
    var result: u4 = 0;
    var ox: i32 = -1;
    while (ox <= 1) : (ox += 1) {
        var oz: i32 = -1;
        while (oz <= 1) : (oz += 1) {
            result = @max(result, boundary.getEntranceBounceCross(chunk, neighbors, x + ox, y, z + oz));
        }
    }
    return result;
}

fn getShapeColor(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, z: i32, def: *const block_registry.BlockDefinition) [3]f32 {
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

fn emitFlatQuad(
    allocator: std.mem.Allocator,
    verts: *std.ArrayListUnmanaged(Vertex),
    x: f32,
    y: f32,
    z: f32,
    col: [3]f32,
    light: lighting_sampler.NormalizedLight,
    tile_id: u16,
) !void {
    const positions = [4][3]f32{
        .{ x, y, z },
        .{ x + 1, y, z },
        .{ x + 1, y, z + 1 },
        .{ x, y, z + 1 },
    };
    const uv = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
    const normal = [3]f32{ 0, 1, 0 };
    const ao: f32 = 1.0;

    const v = [6][3]f32{ positions[0], positions[1], positions[2], positions[0], positions[2], positions[3] };
    const u = [6][2]f32{ uv[0], uv[1], uv[2], uv[0], uv[2], uv[3] };

    for (0..6) |i| {
        try verts.append(allocator, Vertex.initWithEntrance(v[i], col, normal, u[i], tile_id, light.skylight, light.blocklight, ao, light.entrance_bounce, light.entrance_dir));
    }
}
