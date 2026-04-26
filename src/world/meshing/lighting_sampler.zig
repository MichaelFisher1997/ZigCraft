//! Light sampling for chunk meshing.
//!
//! Extracts sky and block light values at face boundaries,
//! with cross-chunk neighbor fallback for edges.

const std = @import("std");
const Chunk = @import("../chunk.zig").Chunk;
const PackedLight = @import("../chunk.zig").PackedLight;
const unpackEntranceDirX = @import("../chunk.zig").unpackEntranceDirX;
const unpackEntranceDirZ = @import("../chunk.zig").unpackEntranceDirZ;
const Face = @import("../block.zig").Face;
const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;
const SUBCHUNK_SIZE = boundary.SUBCHUNK_SIZE;

/// Normalized light values ready for vertex emission.
pub const NormalizedLight = struct {
    skylight: f32,
    blocklight: [3]f32,
    entrance_bounce: f32,
    entrance_dir: [2]f32,
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

pub inline fn sampleEntranceBounceAtBoundary(chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, u: u32, v: u32, si: u32, positive_side: bool) u4 {
    const y_off: i32 = @intCast(si * SUBCHUNK_SIZE);
    return switch (axis) {
        .top => chunk.getEntranceBounceSafe(@intCast(u), if (positive_side) s else s - 1, @intCast(v)),
        .east => boundary.getEntranceBounceCross(chunk, neighbors, if (positive_side) s else s - 1, y_off + @as(i32, @intCast(u)), @intCast(v)),
        .south => boundary.getEntranceBounceCross(chunk, neighbors, @intCast(u), y_off + @as(i32, @intCast(v)), if (positive_side) s else s - 1),
        else => unreachable,
    };
}

pub inline fn sampleEntranceDirAtBoundary(chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, u: u32, v: u32, si: u32, positive_side: bool) u8 {
    const y_off: i32 = @intCast(si * SUBCHUNK_SIZE);
    return switch (axis) {
        .top => chunk.getEntranceDirSafe(@intCast(u), if (positive_side) s else s - 1, @intCast(v)),
        .east => boundary.getEntranceDirCross(chunk, neighbors, if (positive_side) s else s - 1, y_off + @as(i32, @intCast(u)), @intCast(v)),
        .south => boundary.getEntranceDirCross(chunk, neighbors, @intCast(u), y_off + @as(i32, @intCast(v)), if (positive_side) s else s - 1),
        else => unreachable,
    };
}

/// Convert a PackedLight into normalized [0.0, 1.0] values for vertex attributes.
pub inline fn normalizeLightValues(light: PackedLight, entrance_bounce: u4, entrance_dir: u8) NormalizedLight {
    const dir_x = unpackEntranceDirX(entrance_dir);
    const dir_z = unpackEntranceDirZ(entrance_dir);
    return .{
        .skylight = @as(f32, @floatFromInt(light.getSkyLight())) / 15.0,
        .blocklight = .{
            @as(f32, @floatFromInt(light.getBlockLightR())) / 15.0,
            @as(f32, @floatFromInt(light.getBlockLightG())) / 15.0,
            @as(f32, @floatFromInt(light.getBlockLightB())) / 15.0,
        },
        .entrance_bounce = @as(f32, @floatFromInt(entrance_bounce)) / 15.0,
        .entrance_dir = .{
            @as(f32, @floatFromInt(dir_x)),
            @as(f32, @floatFromInt(dir_z)),
        },
    };
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
