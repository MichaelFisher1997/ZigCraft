//! Light sampling for chunk meshing.
//!
//! Extracts sky and block light values at face boundaries,
//! with cross-chunk neighbor fallback for edges.

const Chunk = @import("../chunk.zig").Chunk;
const PackedLight = @import("../chunk.zig").PackedLight;
const Face = @import("../block.zig").Face;
const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;
const SUBCHUNK_SIZE = boundary.SUBCHUNK_SIZE;

/// Normalized light values ready for vertex emission.
pub const NormalizedLight = struct {
    skylight: f32,
    blocklight: [3]f32,
};

/// Sample light at a face boundary, using cross-chunk neighbor lookup for X/Z axes.
pub inline fn sampleLightAtBoundary(chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, u: u32, v: u32, si: u32) PackedLight {
    const y_off: i32 = @intCast(si * SUBCHUNK_SIZE);
    return switch (axis) {
        .top => chunk.getLightSafe(@intCast(u), s, @intCast(v)),
        .east => boundary.getLightCross(chunk, neighbors, s - 1, y_off + @as(i32, @intCast(u)), @intCast(v)),
        .south => boundary.getLightCross(chunk, neighbors, @intCast(u), y_off + @as(i32, @intCast(v)), s - 1),
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
