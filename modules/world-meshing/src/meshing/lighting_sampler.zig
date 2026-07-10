//! Light sampling for chunk meshing.
//!
//! Extracts sky and block light values at face boundaries,
//! with cross-chunk neighbor fallback for edges.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const PackedLight = world_core.PackedLight;
const Face = world_core.Face;
const block_registry = world_core.block_registry;
const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;
const SUBCHUNK_SIZE = boundary.SUBCHUNK_SIZE;

const SmoothLightSample = struct { light: PackedLight };

/// Normalized light values ready for vertex emission.
pub const NormalizedLight = struct {
    skylight: f32,
    blocklight: [3]f32,
};

/// Sample light from the exposed air side of a face boundary.
/// `positive_side = true` samples the +axis side (`s`), `false` samples the -axis side (`s - 1`).
pub inline fn sampleLightAtBoundary(chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, u: u32, v: u32, si: u32, positive_side: bool) PackedLight {
    const y_off: i32 = @intCast(si * SUBCHUNK_SIZE);
    return switch (axis) {
        .top => chunk.getLightSafe(@intCast(u), if (positive_side) s else s - 1, @intCast(v)),
        .east => boundary.getLightCross(chunk, neighbors, if (positive_side) s else s - 1, y_off + @as(i32, @intCast(u)), @intCast(v)),
        .south => boundary.getLightCross(chunk, neighbors, @intCast(u), y_off + @as(i32, @intCast(v)), if (positive_side) s else s - 1),
        else => unreachable,
    };
}

/// Convert a PackedLight into normalized [0.0, 1.0] values for vertex attributes.
pub inline fn normalizeLightValues(light: PackedLight) NormalizedLight {
    return .{
        .skylight = @as(f32, @floatFromInt(light.getSkyLight())) / 15.0,
        .blocklight = .{
            @as(f32, @floatFromInt(light.getBlockLightR())) / 15.0,
            @as(f32, @floatFromInt(light.getBlockLightG())) / 15.0,
            @as(f32, @floatFromInt(light.getBlockLightB())) / 15.0,
        },
    };
}

pub fn sampleSmoothLightAtVertex(chunk: *const Chunk, neighbors: NeighborChunks, pos: [3]f32, normal: [3]f32) NormalizedLight {
    const sample = sampleSmoothRawAtVertex(chunk, neighbors, pos, normal);
    return normalizeLightValues(sample.light);
}

fn sampleSmoothRawAtVertex(chunk: *const Chunk, neighbors: NeighborChunks, pos: [3]f32, normal: [3]f32) SmoothLightSample {
    const gx: i32 = @intFromFloat(@round(pos[0]));
    const gy: i32 = @intFromFloat(@round(pos[1]));
    const gz: i32 = @intFromFloat(@round(pos[2]));

    var xs = [_]i32{ gx - 1, gx };
    var ys = [_]i32{ gy - 1, gy };
    var zs = [_]i32{ gz - 1, gz };

    if (normal[0] > 0.5) xs = .{ gx, gx } else if (normal[0] < -0.5) xs = .{ gx - 1, gx - 1 };
    if (normal[1] > 0.5) ys = .{ gy, gy } else if (normal[1] < -0.5) ys = .{ gy - 1, gy - 1 };
    if (normal[2] > 0.5) zs = .{ gz, gz } else if (normal[2] < -0.5) zs = .{ gz - 1, gz - 1 };

    var sky_sum: u32 = 0;
    var r_sum: u32 = 0;
    var g_sum: u32 = 0;
    var b_sum: u32 = 0;
    var count: u32 = 0;
    var has_direct_sun = false;

    for (xs) |x| {
        for (ys) |y| {
            for (zs) |z| {
                const block = boundary.getBlockCross(chunk, neighbors, x, y, z);
                const def = block_registry.getBlockDefinition(block);
                if (def.isOpaque() and def.getLightEmissionLevel() == 0) continue;

                const light = boundary.getLightCross(chunk, neighbors, x, y, z);
                const sky = light.getSkyLight();
                if (sky == 15) has_direct_sun = true;
                sky_sum += sky;
                r_sum += light.getBlockLightR();
                g_sum += light.getBlockLightG();
                b_sum += light.getBlockLightB();
                count += 1;
            }
        }
    }

    const denom = @max(count, 1);
    if (count == 0 or (sky_sum == 0 and r_sum == 0 and g_sum == 0 and b_sum == 0)) {
        return sampleExposedCell(chunk, neighbors, pos, normal);
    }

    const sky_avg: u4 = @intCast(@min(15, (sky_sum + denom / 2) / denom));
    return .{
        .light = PackedLight.initRGB(
            if (has_direct_sun) 15 else sky_avg,
            @intCast(@min(15, (r_sum + denom / 2) / denom)),
            @intCast(@min(15, (g_sum + denom / 2) / denom)),
            @intCast(@min(15, (b_sum + denom / 2) / denom)),
        ),
    };
}

fn sampleExposedCell(chunk: *const Chunk, neighbors: NeighborChunks, pos: [3]f32, normal: [3]f32) SmoothLightSample {
    const cell = exposedCellFromVertex(pos, normal);

    const light = boundary.getLightCross(chunk, neighbors, cell[0], cell[1], cell[2]);
    return .{ .light = light };
}

fn exposedCellFromVertex(pos: [3]f32, normal: [3]f32) [3]i32 {
    var x: i32 = @intFromFloat(@round(pos[0]));
    var y: i32 = @intFromFloat(@round(pos[1]));
    var z: i32 = @intFromFloat(@round(pos[2]));

    if (normal[0] < -0.5) x -= 1;
    if (normal[1] < -0.5) y -= 1;
    if (normal[2] < -0.5) z -= 1;

    return .{ x, y, z };
}

test "sampleLightAtBoundary samples positive side for top faces" {
    var chunk = Chunk.init(0, 0);
    chunk.setLight(3, 5, 4, PackedLight.init(2, 0));
    chunk.setLight(3, 6, 4, PackedLight.init(13, 0));

    const light = sampleLightAtBoundary(&chunk, .empty, .top, 6, 3, 4, 0, true);
    try std.testing.expectEqual(@as(u4, 13), light.getSkyLight());
}

test "sampleLightAtBoundary samples positive side for east faces" {
    var chunk = Chunk.init(0, 0);
    chunk.setLight(5, 7, 8, PackedLight.init(1, 0));
    chunk.setLight(6, 7, 8, PackedLight.init(14, 0));

    const light = sampleLightAtBoundary(&chunk, .empty, .east, 6, 7, 8, 0, true);
    try std.testing.expectEqual(@as(u4, 14), light.getSkyLight());
}

test "sampleLightAtBoundary samples negative side for opposite faces" {
    var chunk = Chunk.init(0, 0);
    chunk.setLight(8, 9, 10, PackedLight.init(11, 0));
    chunk.setLight(8, 9, 11, PackedLight.init(3, 0));

    const light = sampleLightAtBoundary(&chunk, .empty, .south, 11, 8, 9, 0, false);
    try std.testing.expectEqual(@as(u4, 11), light.getSkyLight());
}
