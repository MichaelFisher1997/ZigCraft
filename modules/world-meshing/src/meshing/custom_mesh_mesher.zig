//! Custom mesh meshing for non-cube fixture blocks.
//!
//! This is the render-shape foundation for custom geometry. Variants are driven
//! only by immutable block registry data, so worker-thread meshing remains
//! deterministic until per-block state/orientation exists.

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
const biome_color_sampler = @import("biome_color_sampler.zig");

const Box = struct {
    min: [3]f32,
    max: [3]f32,
};

const FaceQuad = struct {
    positions: [4][3]f32,
    normal: [3]f32,
    tile_id: u16,
};

pub fn meshCustomMeshBlocks(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    neighbors: NeighborChunks,
    si: u32,
    solid_list: *std.ArrayListUnmanaged(Vertex),
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
                if (def.render_shape != .custom_mesh) continue;

                const xi: i32 = @intCast(x);
                const zi: i32 = @intCast(z);
                const light = sampleCustomLight(chunk, neighbors, xi, y, zi);
                const entrance_bounce = sampleCustomEntranceBounce(chunk, neighbors, xi, y, zi);
                const entrance_dir = boundary.getEntranceDirCross(chunk, neighbors, xi, y, zi);
                const norm_light = lighting_sampler.normalizeLightValues(light, entrance_bounce, entrance_dir);
                const color = biome_color_sampler.getBlockColor(chunk, neighbors, .top, .top, y + 1, x, z, block);

                const xf: f32 = @floatFromInt(x);
                const yf: f32 = @floatFromInt(y);
                const zf: f32 = @floatFromInt(z);
                const tiles = atlas.getTilesForBlock(@intFromEnum(block));

                switch (def.render_shape_data.custom_mesh) {
                    .slab => try emitBox(allocator, solid_list, .{ .min = .{ xf, yf, zf }, .max = .{ xf + 1, yf + 0.5, zf + 1 } }, color, norm_light, tiles),
                    .stairs => {
                        try emitBox(allocator, solid_list, .{ .min = .{ xf, yf, zf }, .max = .{ xf + 1, yf + 0.5, zf + 1 } }, color, norm_light, tiles);
                        try emitBox(allocator, solid_list, .{ .min = .{ xf, yf + 0.5, zf + 0.5 }, .max = .{ xf + 1, yf + 1, zf + 1 } }, color, norm_light, tiles);
                    },
                    .none, .door, .fence => {},
                }
            }
        }
    }
}

fn sampleCustomLight(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) PackedLight {
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

fn sampleCustomEntranceBounce(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) u4 {
    var result: u4 = 0;
    var oy: i32 = 0;
    while (oy <= 1) : (oy += 1) {
        var ox: i32 = -1;
        while (ox <= 1) : (ox += 1) {
            var oz: i32 = -1;
            while (oz <= 1) : (oz += 1) {
                result = @max(result, boundary.getEntranceBounceCross(chunk, neighbors, x + ox, y + oy, z + oz));
            }
        }
    }
    return result;
}

fn emitBox(
    allocator: std.mem.Allocator,
    verts: *std.ArrayListUnmanaged(Vertex),
    box: Box,
    color: [3]f32,
    light: lighting_sampler.NormalizedLight,
    tiles: TextureAtlas.BlockTiles,
) !void {
    const x0 = box.min[0];
    const y0 = box.min[1];
    const z0 = box.min[2];
    const x1 = box.max[0];
    const y1 = box.max[1];
    const z1 = box.max[2];

    const quads = [_]FaceQuad{
        .{ .positions = .{ .{ x0, y1, z1 }, .{ x1, y1, z1 }, .{ x1, y1, z0 }, .{ x0, y1, z0 } }, .normal = .{ 0, 1, 0 }, .tile_id = tiles.top },
        .{ .positions = .{ .{ x0, y0, z0 }, .{ x1, y0, z0 }, .{ x1, y0, z1 }, .{ x0, y0, z1 } }, .normal = .{ 0, -1, 0 }, .tile_id = tiles.bottom },
        .{ .positions = .{ .{ x0, y0, z0 }, .{ x0, y0, z1 }, .{ x0, y1, z1 }, .{ x0, y1, z0 } }, .normal = .{ -1, 0, 0 }, .tile_id = tiles.side },
        .{ .positions = .{ .{ x1, y0, z1 }, .{ x1, y0, z0 }, .{ x1, y1, z0 }, .{ x1, y1, z1 } }, .normal = .{ 1, 0, 0 }, .tile_id = tiles.side },
        .{ .positions = .{ .{ x1, y0, z0 }, .{ x0, y0, z0 }, .{ x0, y1, z0 }, .{ x1, y1, z0 } }, .normal = .{ 0, 0, -1 }, .tile_id = tiles.side },
        .{ .positions = .{ .{ x0, y0, z1 }, .{ x1, y0, z1 }, .{ x1, y1, z1 }, .{ x0, y1, z1 } }, .normal = .{ 0, 0, 1 }, .tile_id = tiles.side },
    };

    for (quads) |quad| {
        try emitQuad(allocator, verts, quad, color, light);
    }
}

fn emitQuad(
    allocator: std.mem.Allocator,
    verts: *std.ArrayListUnmanaged(Vertex),
    quad: FaceQuad,
    color: [3]f32,
    light: lighting_sampler.NormalizedLight,
) !void {
    const uv = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };
    const idx = [6]usize{ 0, 1, 2, 0, 2, 3 };
    const ao: f32 = 1.0;

    for (idx) |i| {
        try verts.append(allocator, Vertex.initWithEntrance(quad.positions[i], color, quad.normal, uv[i], quad.tile_id, light.skylight, light.blocklight, ao, light.entrance_bounce, light.entrance_dir));
    }
}
