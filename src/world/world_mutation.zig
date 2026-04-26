//! World mutation coordinator — single path for all block edits.
//!
//! Every block mutation (place, break, etc.) goes through `applyBlockMutation()`.
//! The coordinator handles:
//!   1. Writing the block to chunk data
//!   2. Signalling the GPU block buffer (if active)
//!   3. Recomputing skylight for the affected chunk
//!   4. Marking neighbor chunks dirty when the edit touches a boundary
//!
//! Callers should never call `Chunk.setBlock` directly for runtime player edits.

const std = @import("std");
const log = @import("../engine/core/log.zig");
const BlockType = @import("block.zig").BlockType;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const ChunkData = @import("chunk_storage.zig").ChunkData;
const worldToChunk = @import("chunk.zig").worldToChunk;
const worldToLocal = @import("chunk.zig").worldToLocal;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const LightingComputer = @import("worldgen/lighting_computer.zig").LightingComputer;
const GpuBlockBuffer = @import("gpu_block_buffer.zig").GpuBlockBuffer;

pub const WorldMutationCoordinator = struct {
    storage: *ChunkStorage,
    allocator: std.mem.Allocator,
    gpu_block_buffer: ?*GpuBlockBuffer,
    gpu_mesher_active: bool,

    pub fn init(storage: *ChunkStorage, allocator: std.mem.Allocator, gpu_block_buffer: ?*GpuBlockBuffer, gpu_mesher_active: bool) WorldMutationCoordinator {
        return .{
            .storage = storage,
            .allocator = allocator,
            .gpu_block_buffer = gpu_block_buffer,
            .gpu_mesher_active = gpu_mesher_active,
        };
    }

    pub const MutationResult = struct {
        chunk_data: *ChunkData,
        chunk_x: i32,
        chunk_z: i32,
        local_x: u32,
        local_y: u32,
        local_z: u32,
    };

    pub fn applyBlockMutation(self: *WorldMutationCoordinator, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !?MutationResult {
        if (world_y < 0 or world_y >= 256) return null;

        const cp = worldToChunk(world_x, world_z);
        const data = try self.storage.getOrCreate(cp.chunk_x, cp.chunk_z);
        const local = worldToLocal(world_x, world_z);

        data.chunk.setBlock(local.x, @intCast(world_y), local.z, block);

        if (self.gpu_mesher_active) {
            if (self.gpu_block_buffer) |buf| {
                buf.updateBlock(cp.chunk_x, cp.chunk_z, local.x, @intCast(world_y), local.z, @intFromEnum(block)) catch |err| {
                    log.log.warn("GPU block buffer update failed: {}", .{err});
                };
            }
        }

        try LightingComputer.computeSkylight(&data.chunk, self.allocator);

        self.invalidateNeighbors(cp.chunk_x, cp.chunk_z, local.x, local.z);

        return .{
            .chunk_data = data,
            .chunk_x = cp.chunk_x,
            .chunk_z = cp.chunk_z,
            .local_x = local.x,
            .local_y = @intCast(world_y),
            .local_z = local.z,
        };
    }

    fn invalidateNeighbors(self: *WorldMutationCoordinator, cx: i32, cz: i32, local_x: u32, local_z: u32) void {
        if (local_x == 0) {
            if (self.storage.get(cx - 1, cz)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
        if (local_x == CHUNK_SIZE_X - 1) {
            if (self.storage.get(cx + 1, cz)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
        if (local_z == 0) {
            if (self.storage.get(cx, cz - 1)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
        if (local_z == CHUNK_SIZE_Z - 1) {
            if (self.storage.get(cx, cz + 1)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
    }
};

test "WorldMutationCoordinator places block within bounds" {
    const testing = std.testing;

    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    var mutation = WorldMutationCoordinator.init(&storage, testing.allocator, null, false);
    const result = (try mutation.applyBlockMutation(1, 64, 2, .stone)).?;

    try testing.expectEqual(@as(i32, 0), result.chunk_x);
    try testing.expectEqual(@as(i32, 0), result.chunk_z);
    try testing.expectEqual(@as(u32, 1), result.local_x);
    try testing.expectEqual(@as(u32, 64), result.local_y);
    try testing.expectEqual(@as(u32, 2), result.local_z);
    try testing.expectEqual(BlockType.stone, result.chunk_data.chunk.getBlock(1, 64, 2));
}

test "WorldMutationCoordinator ignores out-of-bounds y" {
    const testing = std.testing;

    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    var mutation = WorldMutationCoordinator.init(&storage, testing.allocator, null, false);
    try testing.expect((try mutation.applyBlockMutation(1, -1, 2, .stone)) == null);
    try testing.expect((try mutation.applyBlockMutation(1, 256, 2, .stone)) == null);
    try testing.expectEqual(@as(usize, 0), storage.count());
}

test "WorldMutationCoordinator marks boundary neighbors dirty" {
    const testing = std.testing;

    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const center = try storage.getOrCreate(0, 0);
    const west = try storage.getOrCreate(-1, 0);
    const east = try storage.getOrCreate(1, 0);
    const north = try storage.getOrCreate(0, -1);
    const south = try storage.getOrCreate(0, 1);
    center.chunk.dirty = false;
    west.chunk.dirty = false;
    east.chunk.dirty = false;
    north.chunk.dirty = false;
    south.chunk.dirty = false;

    var mutation = WorldMutationCoordinator.init(&storage, testing.allocator, null, false);
    _ = try mutation.applyBlockMutation(0, 64, 0, .stone);
    try testing.expect(west.chunk.dirty);
    try testing.expect(north.chunk.dirty);
    try testing.expect(!east.chunk.dirty);
    try testing.expect(!south.chunk.dirty);

    west.chunk.dirty = false;
    north.chunk.dirty = false;
    _ = try mutation.applyBlockMutation(CHUNK_SIZE_X - 1, 64, CHUNK_SIZE_Z - 1, .dirt);
    try testing.expect(east.chunk.dirty);
    try testing.expect(south.chunk.dirty);
}

test "WorldMutationCoordinator propagates allocation failure" {
    const testing = std.testing;

    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var storage = ChunkStorage.init(failing.allocator());
    defer storage.deinitWithoutRHI();

    var mutation = WorldMutationCoordinator.init(&storage, failing.allocator(), null, false);
    try testing.expectError(error.OutOfMemory, mutation.applyBlockMutation(1, 64, 2, .stone));
}
