//! LOD transition seam stitching helpers.

const std = @import("std");
const LODLevel = @import("lod_types.zig").LODLevel;

/// Edge direction for seam stitching.
pub const EdgeDir = enum {
    north, // -Z
    south, // +Z
    east, // +X
    west, // -X
};

/// Seam stitching configuration.
pub const SeamConfig = struct {
    /// Enable seam stitching.
    enabled: bool = true,
    /// Number of blend cells at the edge.
    blend_cells: u32 = 2,
    /// Height interpolation factor (0 = this LOD, 1 = neighbor LOD).
    blend_factor: f32 = 0.5,
};

/// Stitch LOD mesh edge to match neighbor LOD level.
/// This adjusts edge vertices to blend between LOD levels and prevent gaps.
pub fn stitchEdge(
    mesh_heightmap: []f32,
    mesh_width: u32,
    neighbor_heightmap: []const f32,
    neighbor_width: u32,
    edge: EdgeDir,
    this_lod: LODLevel,
    neighbor_lod: LODLevel,
    config: SeamConfig,
) void {
    if (!config.enabled) return;

    const this_scale = this_lod.scale();
    const neighbor_scale = neighbor_lod.scale();

    // Only stitch if neighbor is coarser (higher LOD number).
    if (neighbor_scale <= this_scale) return;

    const scale_ratio = neighbor_scale / this_scale;
    const blend_cells = @min(config.blend_cells, mesh_width / 4);

    switch (edge) {
        .north => {
            var x: u32 = 0;
            while (x < mesh_width) : (x += 1) {
                var z: u32 = 0;
                while (z < blend_cells) : (z += 1) {
                    const idx = x + z * mesh_width;
                    if (idx >= mesh_heightmap.len) continue;

                    const nx = x / scale_ratio;
                    const nz: u32 = 0;
                    const nidx = @min(nx + nz * neighbor_width, neighbor_width * neighbor_width - 1);
                    if (nidx >= neighbor_heightmap.len) continue;

                    const this_h = mesh_heightmap[idx];
                    const neighbor_h = neighbor_heightmap[nidx];
                    const t = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(blend_cells));
                    const blend = 1.0 - t;
                    mesh_heightmap[idx] = this_h * (1.0 - blend * config.blend_factor) + neighbor_h * blend * config.blend_factor;
                }
            }
        },
        .south => {
            var x: u32 = 0;
            while (x < mesh_width) : (x += 1) {
                var z: u32 = 0;
                while (z < blend_cells) : (z += 1) {
                    const actual_z = mesh_width - 1 - z;
                    const idx = x + actual_z * mesh_width;
                    if (idx >= mesh_heightmap.len) continue;

                    const nx = x / scale_ratio;
                    const nz = neighbor_width - 1;
                    const nidx = @min(nx + nz * neighbor_width, neighbor_width * neighbor_width - 1);
                    if (nidx >= neighbor_heightmap.len) continue;

                    const this_h = mesh_heightmap[idx];
                    const neighbor_h = neighbor_heightmap[nidx];
                    const t = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(blend_cells));
                    const blend = 1.0 - t;
                    mesh_heightmap[idx] = this_h * (1.0 - blend * config.blend_factor) + neighbor_h * blend * config.blend_factor;
                }
            }
        },
        .west => {
            var z: u32 = 0;
            while (z < mesh_width) : (z += 1) {
                var x: u32 = 0;
                while (x < blend_cells) : (x += 1) {
                    const idx = x + z * mesh_width;
                    if (idx >= mesh_heightmap.len) continue;

                    const nx: u32 = 0;
                    const nz = z / scale_ratio;
                    const nidx = @min(nx + nz * neighbor_width, neighbor_width * neighbor_width - 1);
                    if (nidx >= neighbor_heightmap.len) continue;

                    const this_h = mesh_heightmap[idx];
                    const neighbor_h = neighbor_heightmap[nidx];
                    const t = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(blend_cells));
                    const blend = 1.0 - t;
                    mesh_heightmap[idx] = this_h * (1.0 - blend * config.blend_factor) + neighbor_h * blend * config.blend_factor;
                }
            }
        },
        .east => {
            var z: u32 = 0;
            while (z < mesh_width) : (z += 1) {
                var x: u32 = 0;
                while (x < blend_cells) : (x += 1) {
                    const actual_x = mesh_width - 1 - x;
                    const idx = actual_x + z * mesh_width;
                    if (idx >= mesh_heightmap.len) continue;

                    const nx = neighbor_width - 1;
                    const nz = z / scale_ratio;
                    const nidx = @min(nx + nz * neighbor_width, neighbor_width * neighbor_width - 1);
                    if (nidx >= neighbor_heightmap.len) continue;

                    const this_h = mesh_heightmap[idx];
                    const neighbor_h = neighbor_heightmap[nidx];
                    const t = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(blend_cells));
                    const blend = 1.0 - t;
                    mesh_heightmap[idx] = this_h * (1.0 - blend * config.blend_factor) + neighbor_h * blend * config.blend_factor;
                }
            }
        },
    }
}

test "stitchEdge basic" {
    var mesh_hm = [_]f32{ 100, 100, 100, 100, 90, 90, 90, 90, 80, 80, 80, 80, 70, 70, 70, 70 };
    const neighbor_hm = [_]f32{ 50, 50, 50, 50 };

    stitchEdge(
        &mesh_hm,
        4,
        &neighbor_hm,
        2,
        .north,
        .lod1,
        .lod2,
        .{ .blend_cells = 2 },
    );

    try std.testing.expect(mesh_hm[0] < 100);
    try std.testing.expectEqual(@as(f32, 70), mesh_hm[12]);
}
