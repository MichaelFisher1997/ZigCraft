//! Greedy meshing algorithm for chunk mesh generation.
//!
//! Builds 16x16 face masks for each slice along an axis, then greedily
//! merges adjacent faces with matching properties into larger quads.
//! Delegates AO, lighting, and biome color to their respective modules.

const std = @import("std");

const Chunk = @import("../chunk.zig").Chunk;
const PackedLight = @import("../chunk.zig").PackedLight;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const BlockType = @import("../block.zig").BlockType;
const Face = @import("../block.zig").Face;
const block_registry = @import("../block_registry.zig");
const TextureAtlas = @import("../../engine/graphics/texture_atlas.zig").TextureAtlas;
const rhi_mod = @import("../../engine/graphics/rhi.zig");
const Vertex = rhi_mod.Vertex;

const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;
const SUBCHUNK_SIZE = boundary.SUBCHUNK_SIZE;

const ao_calculator = @import("ao_calculator.zig");
const lighting_sampler = @import("lighting_sampler.zig");
const biome_color_sampler = @import("biome_color_sampler.zig");

/// Maximum light level difference (per channel) allowed when merging adjacent
/// faces into a single greedy quad. A tolerance of 1 produces imperceptible
/// banding while significantly reducing vertex count.
const MAX_LIGHT_DIFF_FOR_MERGE: u8 = 1;

/// Maximum per-channel color difference allowed when merging adjacent faces.
/// 0.02 is roughly 5/256 — below the perceptible threshold for biome tint
/// gradients, keeping quads large without visible color steps.
const MAX_COLOR_DIFF_FOR_MERGE: f32 = 0.02;

const FaceKey = struct {
    block: BlockType,
    side: bool,
    light: PackedLight,
    color: [3]f32,
};

/// Process a single 16x16 slice along the given axis, producing greedy-merged quads.
/// Populates solid_list, cutout_list, and fluid_list with generated vertices.
pub fn meshSlice(
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    neighbors: NeighborChunks,
    axis: Face,
    s: i32,
    si: u32,
    solid_list: *std.ArrayListUnmanaged(Vertex),
    cutout_list: *std.ArrayListUnmanaged(Vertex),
    fluid_list: *std.ArrayListUnmanaged(Vertex),
    atlas: *const TextureAtlas,
) !void {
    if (axis != .top and axis != .east and axis != .south) return error.UnsupportedFace;

    const du: u32 = 16;
    const dv: u32 = 16;
    var mask = try allocator.alloc(?FaceKey, du * dv);
    defer allocator.free(mask);
    @memset(mask, null);

    // Phase 1: Build the face mask
    var v: u32 = 0;
    while (v < dv) : (v += 1) {
        var u: u32 = 0;
        while (u < du) : (u += 1) {
            const res = boundary.getBlocksAtBoundary(chunk, neighbors, axis, s, u, v, si);
            const b1 = res[0];
            const b2 = res[1];

            const y_min: i32 = @intCast(si * SUBCHUNK_SIZE);
            const y_max: i32 = y_min + SUBCHUNK_SIZE;

            const b1_def = block_registry.getBlockDefinition(b1);
            const b2_def = block_registry.getBlockDefinition(b2);

            const b1_emits = b1_def.is_solid or (b1_def.is_fluid and !b2_def.is_fluid);
            const b2_emits = b2_def.is_solid or (b2_def.is_fluid and !b1_def.is_fluid);

            if (boundary.isEmittingSubchunk(axis, s - 1, u, v, y_min, y_max) and b1_emits and !b2_def.occludes(b1_def, axis)) {
                const light = lighting_sampler.sampleLightAtBoundary(chunk, neighbors, axis, s, u, v, si);
                const color = biome_color_sampler.getBlockColor(chunk, neighbors, axis, s - 1, u, v, b1);
                mask[u + v * du] = .{ .block = b1, .side = true, .light = light, .color = color };
            } else if (boundary.isEmittingSubchunk(axis, s, u, v, y_min, y_max) and b2_emits and !b1_def.occludes(b2_def, axis)) {
                const light = lighting_sampler.sampleLightAtBoundary(chunk, neighbors, axis, s, u, v, si);
                const color = biome_color_sampler.getBlockColor(chunk, neighbors, axis, s, u, v, b2);
                mask[u + v * du] = .{ .block = b2, .side = false, .light = light, .color = color };
            }
        }
    }

    // Phase 2: Greedy rectangle expansion
    var sv: u32 = 0;
    while (sv < dv) : (sv += 1) {
        var su: u32 = 0;
        while (su < du) : (su += 1) {
            const k_opt = mask[su + sv * du];
            if (k_opt == null) continue;
            const k = k_opt.?;

            var width: u32 = 1;
            while (su + width < du) : (width += 1) {
                const nxt_opt = mask[su + width + sv * du];
                if (nxt_opt == null) break;
                const nxt = nxt_opt.?;
                if (nxt.block != k.block or nxt.side != k.side) break;
                const sky_diff = @as(i8, @intCast(nxt.light.getSkyLight())) - @as(i8, @intCast(k.light.getSkyLight()));
                const r_diff = @as(i8, @intCast(nxt.light.getBlockLightR())) - @as(i8, @intCast(k.light.getBlockLightR()));
                const g_diff = @as(i8, @intCast(nxt.light.getBlockLightG())) - @as(i8, @intCast(k.light.getBlockLightG()));
                const b_diff = @as(i8, @intCast(nxt.light.getBlockLightB())) - @as(i8, @intCast(k.light.getBlockLightB()));
                if (@abs(sky_diff) > MAX_LIGHT_DIFF_FOR_MERGE or @abs(r_diff) > MAX_LIGHT_DIFF_FOR_MERGE or @abs(g_diff) > MAX_LIGHT_DIFF_FOR_MERGE or @abs(b_diff) > MAX_LIGHT_DIFF_FOR_MERGE) break;

                const diff_r = @abs(nxt.color[0] - k.color[0]);
                const diff_g = @abs(nxt.color[1] - k.color[1]);
                const diff_b = @abs(nxt.color[2] - k.color[2]);
                if (diff_r > MAX_COLOR_DIFF_FOR_MERGE or diff_g > MAX_COLOR_DIFF_FOR_MERGE or diff_b > MAX_COLOR_DIFF_FOR_MERGE) break;
            }
            var height: u32 = 1;
            var dvh: u32 = 1;
            outer: while (sv + dvh < dv) : (dvh += 1) {
                var duw: u32 = 0;
                while (duw < width) : (duw += 1) {
                    const nxt_opt = mask[su + duw + (sv + dvh) * du];
                    if (nxt_opt == null) break :outer;
                    const nxt = nxt_opt.?;
                    if (nxt.block != k.block or nxt.side != k.side) break :outer;
                    const sky_diff = @as(i8, @intCast(nxt.light.getSkyLight())) - @as(i8, @intCast(k.light.getSkyLight()));
                    const r_diff = @as(i8, @intCast(nxt.light.getBlockLightR())) - @as(i8, @intCast(k.light.getBlockLightR()));
                    const g_diff = @as(i8, @intCast(nxt.light.getBlockLightG())) - @as(i8, @intCast(k.light.getBlockLightG()));
                    const b_diff = @as(i8, @intCast(nxt.light.getBlockLightB())) - @as(i8, @intCast(k.light.getBlockLightB()));
                    if (@abs(sky_diff) > MAX_LIGHT_DIFF_FOR_MERGE or @abs(r_diff) > MAX_LIGHT_DIFF_FOR_MERGE or @abs(g_diff) > MAX_LIGHT_DIFF_FOR_MERGE or @abs(b_diff) > MAX_LIGHT_DIFF_FOR_MERGE) break :outer;

                    const diff_r = @abs(nxt.color[0] - k.color[0]);
                    const diff_g = @abs(nxt.color[1] - k.color[1]);
                    const diff_b = @abs(nxt.color[2] - k.color[2]);
                    if (diff_r > MAX_COLOR_DIFF_FOR_MERGE or diff_g > MAX_COLOR_DIFF_FOR_MERGE or diff_b > MAX_COLOR_DIFF_FOR_MERGE) break :outer;
                }
                height += 1;
            }

            const k_def = block_registry.getBlockDefinition(k.block);
            const target = switch (k_def.render_pass) {
                .fluid => fluid_list,
                .cutout => cutout_list,
                else => solid_list,
            };
            try addGreedyFace(allocator, target, axis, s, su, sv, width, height, k_def, k.side, si, k.light, k.color, chunk, neighbors, atlas);

            var dy: u32 = 0;
            while (dy < height) : (dy += 1) {
                var dx: u32 = 0;
                while (dx < width) : (dx += 1) {
                    mask[su + dx + (sv + dy) * du] = null;
                }
            }
            su += width - 1;
        }
    }
}

/// Generate 6 vertices (2 triangles) for a greedy-merged quad.
/// Computes positions, UVs, normals, AO, lighting, and biome-tinted colors.
fn addGreedyFace(
    allocator: std.mem.Allocator,
    verts: *std.ArrayListUnmanaged(Vertex),
    axis: Face,
    s: i32,
    u: u32,
    v: u32,
    w: u32,
    h: u32,
    block_def: *const block_registry.BlockDefinition,
    forward: bool,
    si: u32,
    light: PackedLight,
    tint: [3]f32,
    chunk: *const Chunk,
    neighbors: NeighborChunks,
    atlas: *const TextureAtlas,
) !void {
    const face = if (forward) axis else switch (axis) {
        .top => Face.bottom,
        .east => Face.west,
        .south => Face.north,
        else => return error.UnsupportedFace,
    };
    const base_col = block_def.getFaceColor(face);
    const col = [3]f32{ base_col[0] * tint[0], base_col[1] * tint[1], base_col[2] * tint[2] };
    const norm = face.getNormal();
    const nf = [3]f32{ @floatFromInt(norm[0]), @floatFromInt(norm[1]), @floatFromInt(norm[2]) };
    const tiles = atlas.getTilesForBlock(@intFromEnum(block_def.id));
    const tid: f32 = @floatFromInt(switch (face) {
        .top => tiles.top,
        .bottom => tiles.bottom,
        else => tiles.side,
    });
    const wf: f32 = @floatFromInt(w);
    const hf: f32 = @floatFromInt(h);
    const sf: f32 = @floatFromInt(s);
    const uf: f32 = @floatFromInt(u);
    const vf: f32 = @floatFromInt(v);

    var p: [4][3]f32 = undefined;
    var uv: [4][2]f32 = undefined;
    switch (axis) {
        .top => {
            const y = sf;
            if (forward) {
                p[0] = .{ uf, y, vf + hf };
                p[1] = .{ uf + wf, y, vf + hf };
                p[2] = .{ uf + wf, y, vf };
                p[3] = .{ uf, y, vf };
            } else {
                p[0] = .{ uf, y, vf };
                p[1] = .{ uf + wf, y, vf };
                p[2] = .{ uf + wf, y, vf + hf };
                p[3] = .{ uf, y, vf + hf };
            }
            uv = [4][2]f32{ .{ 0, 0 }, .{ wf, 0 }, .{ wf, hf }, .{ 0, hf } };
        },
        .east => {
            const x = sf;
            const y0: f32 = @floatFromInt(si * SUBCHUNK_SIZE);
            if (forward) {
                p[0] = .{ x, y0 + uf, vf + hf };
                p[1] = .{ x, y0 + uf, vf };
                p[2] = .{ x, y0 + uf + wf, vf };
                p[3] = .{ x, y0 + uf + wf, vf + hf };
            } else {
                p[0] = .{ x, y0 + uf, vf };
                p[1] = .{ x, y0 + uf, vf + hf };
                p[2] = .{ x, y0 + uf + wf, vf + hf };
                p[3] = .{ x, y0 + uf + wf, vf };
            }
            uv = [4][2]f32{ .{ 0, wf }, .{ hf, wf }, .{ hf, 0 }, .{ 0, 0 } };
        },
        .south => {
            const z = sf;
            const y0: f32 = @floatFromInt(si * SUBCHUNK_SIZE);
            if (forward) {
                p[0] = .{ uf, y0 + vf, z };
                p[1] = .{ uf + wf, y0 + vf, z };
                p[2] = .{ uf + wf, y0 + vf + hf, z };
                p[3] = .{ uf, y0 + vf + hf, z };
            } else {
                p[0] = .{ uf + wf, y0 + vf, z };
                p[1] = .{ uf, y0 + vf, z };
                p[2] = .{ uf, y0 + vf + hf, z };
                p[3] = .{ uf + wf, y0 + vf + hf, z };
            }
            uv = [4][2]f32{ .{ 0, hf }, .{ wf, hf }, .{ wf, 0 }, .{ 0, 0 } };
        },
        else => return error.UnsupportedFace,
    }

    // Calculate AO for all 4 corners
    const ao = ao_calculator.calculateQuadAO(chunk, neighbors, axis, forward, p);

    // Choose triangle orientation to minimize AO artifacts (flipping the diagonal)
    var idxs: [6]usize = undefined;
    if (ao[0] + ao[2] < ao[1] + ao[3]) {
        idxs = .{ 1, 2, 3, 1, 3, 0 };
    } else {
        idxs = .{ 0, 1, 2, 0, 2, 3 };
    }

    // Normalize light values
    const norm_light = lighting_sampler.normalizeLightValues(light);

    for (idxs) |i| {
        try verts.append(allocator, Vertex{
            .pos = p[i],
            .color = col,
            .normal = nf,
            .uv = uv[i],
            .tile_id = tid,
            .skylight = norm_light.skylight,
            .blocklight = norm_light.blocklight,
            .ao = ao[i],
        });
    }
}
