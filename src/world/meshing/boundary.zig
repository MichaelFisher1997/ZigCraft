//! Cross-chunk boundary utilities for meshing.
//!
//! Provides safe block, light, and biome lookups that cross chunk boundaries
//! using the four horizontal neighbor chunks. Shared by AO, lighting, and
//! biome color sampling stages.

const Chunk = @import("../chunk.zig").Chunk;
const PackedLight = @import("../chunk.zig").PackedLight;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const MAX_LIGHT = @import("../chunk.zig").MAX_LIGHT;
const BlockType = @import("../block.zig").BlockType;
const Face = @import("../block.zig").Face;
const biome_mod = @import("../worldgen/biome.zig");
const std = @import("std");

pub const NeighborChunks = struct {
    north: ?*const Chunk = null,
    south: ?*const Chunk = null,
    east: ?*const Chunk = null,
    west: ?*const Chunk = null,

    pub const empty = NeighborChunks{
        .north = null,
        .south = null,
        .east = null,
        .west = null,
    };
};

pub const SUBCHUNK_SIZE: u32 = 16;
pub const NUM_SUBCHUNKS: u32 = 16;

/// Check if a face's emitting block falls within the current subchunk Y range.
pub inline fn isEmittingSubchunk(axis: Face, s: i32, u: u32, v: u32, y_min: i32, y_max: i32) bool {
    const y: i32 = switch (axis) {
        .top => s,
        .east => @as(i32, @intCast(u)) + y_min,
        .south => @as(i32, @intCast(v)) + y_min,
        else => unreachable,
    };
    return y >= y_min and y < y_max;
}

/// Get the two blocks on either side of a face boundary.
pub inline fn getBlocksAtBoundary(chunk: *const Chunk, neighbors: NeighborChunks, axis: Face, s: i32, u: u32, v: u32, si: u32) [2]BlockType {
    const y_off: i32 = @intCast(si * SUBCHUNK_SIZE);
    return switch (axis) {
        .top => .{ chunk.getBlockSafe(@intCast(u), s - 1, @intCast(v)), chunk.getBlockSafe(@intCast(u), s, @intCast(v)) },
        .east => .{
            getBlockCross(chunk, neighbors, s - 1, y_off + @as(i32, @intCast(u)), @intCast(v)),
            getBlockCross(chunk, neighbors, s, y_off + @as(i32, @intCast(u)), @intCast(v)),
        },
        .south => .{
            getBlockCross(chunk, neighbors, @intCast(u), y_off + @as(i32, @intCast(v)), s - 1),
            getBlockCross(chunk, neighbors, @intCast(u), y_off + @as(i32, @intCast(v)), s),
        },
        else => unreachable,
    };
}

/// Get block type with cross-chunk neighbor lookup.
pub inline fn getBlockCross(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) BlockType {
    if (x < 0) return if (neighbors.west) |w| w.getBlockSafe(CHUNK_SIZE_X - 1, y, z) else .air;
    if (x >= CHUNK_SIZE_X) return if (neighbors.east) |e| e.getBlockSafe(0, y, z) else .air;
    if (z < 0) return if (neighbors.north) |n| n.getBlockSafe(x, y, CHUNK_SIZE_Z - 1) else .air;
    if (z >= CHUNK_SIZE_Z) return if (neighbors.south) |s| s.getBlockSafe(x, y, 0) else .air;
    return chunk.getBlockSafe(x, y, z);
}

/// Get light with cross-chunk neighbor lookup.
pub inline fn getLightCross(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) PackedLight {
    if (y >= CHUNK_SIZE_Y) return PackedLight.init(MAX_LIGHT, 0);
    if (y < 0) return PackedLight.init(0, 0);

    if (x < 0) return if (neighbors.west) |w| w.getLightSafe(CHUNK_SIZE_X - 1, y, z) else PackedLight.init(MAX_LIGHT, 0);
    if (x >= CHUNK_SIZE_X) return if (neighbors.east) |e| e.getLightSafe(0, y, z) else PackedLight.init(MAX_LIGHT, 0);
    if (z < 0) return if (neighbors.north) |n| n.getLightSafe(x, y, CHUNK_SIZE_Z - 1) else PackedLight.init(MAX_LIGHT, 0);
    if (z >= CHUNK_SIZE_Z) return if (neighbors.south) |s| s.getLightSafe(x, y, 0) else PackedLight.init(MAX_LIGHT, 0);
    return chunk.getLightSafe(x, y, z);
}

pub inline fn getEntranceBounceCross(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) u4 {
    if (y < 0 or y >= CHUNK_SIZE_Y) return 0;

    if (x < 0) return if (neighbors.west) |w| w.getEntranceBounceSafe(CHUNK_SIZE_X - 1, y, z) else 0;
    if (x >= CHUNK_SIZE_X) return if (neighbors.east) |e| e.getEntranceBounceSafe(0, y, z) else 0;
    if (z < 0) return if (neighbors.north) |n| n.getEntranceBounceSafe(x, y, CHUNK_SIZE_Z - 1) else 0;
    if (z >= CHUNK_SIZE_Z) return if (neighbors.south) |s| s.getEntranceBounceSafe(x, y, 0) else 0;
    return chunk.getEntranceBounceSafe(x, y, z);
}

pub inline fn getEntranceDirCross(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) u8 {
    if (y < 0 or y >= CHUNK_SIZE_Y) return 0;

    if (x < 0) return if (neighbors.west) |w| w.getEntranceDirSafe(CHUNK_SIZE_X - 1, y, z) else 0;
    if (x >= CHUNK_SIZE_X) return if (neighbors.east) |e| e.getEntranceDirSafe(0, y, z) else 0;
    if (z < 0) return if (neighbors.north) |n| n.getEntranceDirSafe(x, y, CHUNK_SIZE_Z - 1) else 0;
    if (z >= CHUNK_SIZE_Z) return if (neighbors.south) |s| s.getEntranceDirSafe(x, y, 0) else 0;
    return chunk.getEntranceDirSafe(x, y, z);
}

/// Get biome ID with cross-chunk neighbor lookup.
/// Handles diagonal corners (both X and Z out of bounds) by clamping to the
/// nearest in-bounds corner of the appropriate neighbor or current chunk.
pub inline fn getBiomeAt(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, z: i32) biome_mod.BiomeId {
    // Diagonal corners: both X and Z are out of bounds simultaneously.
    // We don't have diagonal neighbor chunks, so fall back to the X-axis
    // neighbor at its clamped Z edge, or the current chunk's nearest corner.
    if (x < 0 and z < 0) {
        if (neighbors.west) |w| return w.getBiome(CHUNK_SIZE_X - 1, 0);
        return chunk.getBiome(0, 0);
    }
    if (x < 0 and z >= CHUNK_SIZE_Z) {
        if (neighbors.west) |w| return w.getBiome(CHUNK_SIZE_X - 1, CHUNK_SIZE_Z - 1);
        return chunk.getBiome(0, CHUNK_SIZE_Z - 1);
    }
    if (x >= CHUNK_SIZE_X and z < 0) {
        if (neighbors.east) |e| return e.getBiome(0, 0);
        return chunk.getBiome(CHUNK_SIZE_X - 1, 0);
    }
    if (x >= CHUNK_SIZE_X and z >= CHUNK_SIZE_Z) {
        if (neighbors.east) |e| return e.getBiome(0, CHUNK_SIZE_Z - 1);
        return chunk.getBiome(CHUNK_SIZE_X - 1, CHUNK_SIZE_Z - 1);
    }

    // Single-axis boundary cases (Z is guaranteed in-bounds here)
    if (x < 0) {
        if (neighbors.west) |w| return w.getBiome(CHUNK_SIZE_X - 1, @intCast(z));
        return chunk.getBiome(0, @intCast(z));
    }
    if (x >= CHUNK_SIZE_X) {
        if (neighbors.east) |e| return e.getBiome(0, @intCast(z));
        return chunk.getBiome(CHUNK_SIZE_X - 1, @intCast(z));
    }

    // X is in-bounds; only Z may be out of bounds
    if (z < 0) {
        if (neighbors.north) |n| return n.getBiome(@intCast(x), CHUNK_SIZE_Z - 1);
        return chunk.getBiome(@intCast(x), 0);
    }
    if (z >= CHUNK_SIZE_Z) {
        if (neighbors.south) |s| return s.getBiome(@intCast(x), 0);
        return chunk.getBiome(@intCast(x), CHUNK_SIZE_Z - 1);
    }
    return chunk.getBiome(@intCast(x), @intCast(z));
}
