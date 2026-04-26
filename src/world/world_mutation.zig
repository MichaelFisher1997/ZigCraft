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
                    log.log.debug("GPU block buffer update failed: {}", .{err});
                };
            }
        }

        LightingComputer.computeSkylight(&data.chunk, self.allocator) catch |err| {
            log.log.debug("Skylight recompute failed for chunk ({}, {}): {}", .{ cp.chunk_x, cp.chunk_z, err });
        };

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
