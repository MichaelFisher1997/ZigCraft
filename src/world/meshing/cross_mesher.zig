//! Cross/billboard meshing for vegetation blocks.
//!
//! Emits 2 diagonal quads (X-shaped billboard) per cross block instead of
//! the standard 6-face cube. Each quad is double-sided (front + back faces).

const std = @import("std");

const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const BlockType = @import("../block.zig").BlockType;
const block_registry = @import("../block_registry.zig");
const TextureAtlas = @import("../../engine/graphics/texture_atlas.zig").TextureAtlas;
const rhi_mod = @import("../../engine/graphics/rhi.zig");
const Vertex = rhi_mod.Vertex;

const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;
const SUBCHUNK_SIZE = boundary.SUBCHUNK_SIZE;
const lighting_sampler = @import("lighting_sampler.zig");
const biome_mod = @import("../worldgen/biome.zig");

pub fn meshCrossBlocks(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    neighbors: NeighborChunks,
    si: u32,
    cutout_list: *std.ArrayListUnmanaged(Vertex),
    atlas: *const TextureAtlas,
) !void {
    _ = neighbors;
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
                if (def.render_shape != .cross) continue;

                const light = chunk.getLightSafe(@intCast(x), y, @intCast(z));
                const norm_light = lighting_sampler.normalizeLightValues(light);

                const tint: [3]f32 = if (def.is_tintable) blk: {
                    const biome_id = chunk.getBiome(x, z);
                    const biome_def = biome_mod.getBiomeDefinition(biome_id);
                    break :blk biome_def.colors.grass;
                } else .{ 1.0, 1.0, 1.0 };

                const base_col = def.default_color;
                const col = [3]f32{
                    base_col[0] * tint[0],
                    base_col[1] * tint[1],
                    base_col[2] * tint[2],
                };

                const tiles = atlas.getTilesForBlock(@intFromEnum(block));
                const tid: f32 = @floatFromInt(tiles.side);

                const xf: f32 = @floatFromInt(x);
                const yf: f32 = @floatFromInt(y);
                const zf: f32 = @floatFromInt(z);

                try emitCrossQuad(allocator, cutout_list, .{ xf, yf, zf }, .{ xf + 1, yf + 1, zf + 1 }, col, norm_light, tid);
                try emitCrossQuad(allocator, cutout_list, .{ xf + 1, yf, zf }, .{ xf, yf + 1, zf + 1 }, col, norm_light, tid);
            }
        }
    }
}

fn emitCrossQuad(
    allocator: std.mem.Allocator,
    verts: *std.ArrayListUnmanaged(Vertex),
    p0: [3]f32,
    p1: [3]f32,
    col: [3]f32,
    light: lighting_sampler.NormalizedLight,
    tid: f32,
) !void {
    const bl = [3]f32{ p0[0], p0[1], p0[2] };
    const br = [3]f32{ p1[0], p0[1], p1[2] };
    const tr = [3]f32{ p1[0], p1[1], p1[2] };
    const tl = [3]f32{ p0[0], p1[1], p0[2] };

    const dx = p1[0] - p0[0];
    const dz = p1[2] - p0[2];
    const len = @sqrt(dx * dx + dz * dz);
    const nf_front = [3]f32{ -dz / len, 0, dx / len };
    const nf_back = [3]f32{ dz / len, 0, -dx / len };

    const ao: f32 = 1.0;

    const positions = [4][3]f32{ bl, br, tr, tl };
    const uv = [4][2]f32{ .{ 0, 1 }, .{ 1, 1 }, .{ 1, 0 }, .{ 0, 0 } };

    // Front face (2 triangles)
    try verts.append(allocator, Vertex{ .pos = positions[0], .color = col, .normal = nf_front, .uv = uv[0], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
    try verts.append(allocator, Vertex{ .pos = positions[1], .color = col, .normal = nf_front, .uv = uv[1], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
    try verts.append(allocator, Vertex{ .pos = positions[2], .color = col, .normal = nf_front, .uv = uv[2], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
    try verts.append(allocator, Vertex{ .pos = positions[0], .color = col, .normal = nf_front, .uv = uv[0], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
    try verts.append(allocator, Vertex{ .pos = positions[2], .color = col, .normal = nf_front, .uv = uv[2], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
    try verts.append(allocator, Vertex{ .pos = positions[3], .color = col, .normal = nf_front, .uv = uv[3], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });

    // Back face (2 triangles, reversed winding)
    try verts.append(allocator, Vertex{ .pos = positions[1], .color = col, .normal = nf_back, .uv = uv[1], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
    try verts.append(allocator, Vertex{ .pos = positions[0], .color = col, .normal = nf_back, .uv = uv[0], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
    try verts.append(allocator, Vertex{ .pos = positions[3], .color = col, .normal = nf_back, .uv = uv[3], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
    try verts.append(allocator, Vertex{ .pos = positions[1], .color = col, .normal = nf_back, .uv = uv[1], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
    try verts.append(allocator, Vertex{ .pos = positions[3], .color = col, .normal = nf_back, .uv = uv[3], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
    try verts.append(allocator, Vertex{ .pos = positions[2], .color = col, .normal = nf_back, .uv = uv[2], .tile_id = tid, .skylight = light.skylight, .blocklight = light.blocklight, .ao = ao });
}
