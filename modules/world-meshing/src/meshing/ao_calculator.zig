//! Ambient occlusion calculation for chunk meshing.
//!
//! Computes per-vertex AO values by sampling three neighbor blocks
//! (two orthogonal sides + diagonal corner) around each quad corner.

const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const Face = world_core.Face;
const block_registry = world_core.block_registry;
const boundary = @import("boundary.zig");
const NeighborChunks = boundary.NeighborChunks;

/// Get AO occlusion value at a block position (1.0 = occluding, 0.0 = open).
/// Uses cross-chunk neighbor lookup for positions near chunk edges.
pub inline fn getAOAt(chunk: *const Chunk, neighbors: NeighborChunks, x: i32, y: i32, z: i32) f32 {
    if (y < 0 or y >= CHUNK_SIZE_Y) return 0;

    const b: BlockType = blk: {
        if (x < 0 and z < 0) {
            break :blk if (neighbors.west) |w| w.getBlock(CHUNK_SIZE_X - 1, @intCast(y), 0) else .air;
        } else if (x < 0 and z >= CHUNK_SIZE_Z) {
            break :blk if (neighbors.west) |w| w.getBlock(CHUNK_SIZE_X - 1, @intCast(y), CHUNK_SIZE_Z - 1) else .air;
        } else if (x >= CHUNK_SIZE_X and z < 0) {
            break :blk if (neighbors.east) |e| e.getBlock(0, @intCast(y), 0) else .air;
        } else if (x >= CHUNK_SIZE_X and z >= CHUNK_SIZE_Z) {
            break :blk if (neighbors.east) |e| e.getBlock(0, @intCast(y), CHUNK_SIZE_Z - 1) else .air;
        } else if (x < 0) {
            break :blk if (neighbors.west) |w| w.getBlock(CHUNK_SIZE_X - 1, @intCast(y), @intCast(z)) else .air;
        } else if (x >= CHUNK_SIZE_X) {
            break :blk if (neighbors.east) |e| e.getBlock(0, @intCast(y), @intCast(z)) else .air;
        } else if (z < 0) {
            // x is already checked to be [0, CHUNK_SIZE_X-1]
            break :blk if (neighbors.north) |n| n.getBlock(@intCast(x), @intCast(y), CHUNK_SIZE_Z - 1) else .air;
        } else if (z >= CHUNK_SIZE_Z) {
            break :blk if (neighbors.south) |s| s.getBlock(@intCast(x), @intCast(y), 0) else .air;
        } else {
            break :blk chunk.getBlock(@intCast(x), @intCast(y), @intCast(z));
        }
    };

    const b_def = block_registry.getBlockDefinition(b);
    return if (b_def.is_solid and !b_def.is_transparent) 1.0 else 0.0;
}

test "getAOAt samples available neighbor for diagonal chunk corner" {
    var chunk = Chunk.init(0, 0);
    var west = Chunk.init(-1, 0);
    west.setBlock(CHUNK_SIZE_X - 1, 10, 0, .stone);

    const ao = getAOAt(&chunk, .{ .west = &west }, -1, 10, -1);
    try @import("std").testing.expectEqual(@as(f32, 1.0), ao);
}

/// Compute AO for a single vertex from three neighbor samples.
/// s1, s2: orthogonal side neighbors; c: diagonal corner neighbor.
/// Returns AO factor in range [0.4, 1.0] where 1.0 = no occlusion.
pub inline fn calculateVertexAO(s1: f32, s2: f32, c: f32) f32 {
    if (s1 > 0.5 and s2 > 0.5) return 0.4;
    return 1.0 - (s1 + s2 + c) * 0.2;
}

/// Calculate AO values for all 4 corners of a greedy quad.
/// Returns an array of 4 AO factors ready for vertex emission.
pub inline fn calculateQuadAO(
    chunk: *const Chunk,
    neighbors: NeighborChunks,
    axis: Face,
    forward: bool,
    p: [4][3]f32,
) [4]f32 {
    var ao: [4]f32 = undefined;
    for (0..4) |i| {
        const vertex_pos = p[i];
        const center = [3]f32{
            (p[0][0] + p[2][0]) * 0.5,
            (p[0][1] + p[2][1]) * 0.5,
            (p[0][2] + p[2][2]) * 0.5,
        };

        const dir_x: i32 = if (vertex_pos[0] > center[0]) 0 else -1;
        const dir_y: i32 = if (vertex_pos[1] > center[1]) 0 else -1;
        const dir_z: i32 = if (vertex_pos[2] > center[2]) 0 else -1;

        const vx = @as(i32, @intFromFloat(@floor(vertex_pos[0])));
        const vy = @as(i32, @intFromFloat(@floor(vertex_pos[1])));
        const vz = @as(i32, @intFromFloat(@floor(vertex_pos[2])));

        var s1: f32 = 0;
        var s2: f32 = 0;
        var c: f32 = 0;

        if (axis == .top) {
            const y_off: i32 = if (forward) 0 else -1;
            s1 = getAOAt(chunk, neighbors, vx + dir_x, vy + y_off, vz);
            s2 = getAOAt(chunk, neighbors, vx, vy + y_off, vz + dir_z);
            c = getAOAt(chunk, neighbors, vx + dir_x, vy + y_off, vz + dir_z);
        } else if (axis == .east) {
            const x_off: i32 = if (forward) 0 else -1;
            s1 = getAOAt(chunk, neighbors, vx + x_off, vy + dir_y, vz);
            s2 = getAOAt(chunk, neighbors, vx + x_off, vy, vz + dir_z);
            c = getAOAt(chunk, neighbors, vx + x_off, vy + dir_y, vz + dir_z);
        } else if (axis == .south) {
            const z_off: i32 = if (forward) 0 else -1;
            s1 = getAOAt(chunk, neighbors, vx + dir_x, vy, vz + z_off);
            s2 = getAOAt(chunk, neighbors, vx, vy + dir_y, vz + z_off);
            c = getAOAt(chunk, neighbors, vx + dir_x, vy + dir_y, vz + z_off);
        } else {
            unreachable;
        }

        ao[i] = calculateVertexAO(s1, s2, c);
    }
    return ao;
}
