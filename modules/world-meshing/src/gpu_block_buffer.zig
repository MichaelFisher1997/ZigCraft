//! GPU block data buffer - uploads chunk block data to GPU storage buffer.
//!
//! This provides a GPU-visible storage buffer holding block data for all loaded
//! chunks. A compute meshing shader (future issue) can read blocks directly from
//! this buffer and output vertices on the GPU.
//!
//! ## Layout
//!
//! ```
//! Buffer: [chunk_0_blocks | chunk_1_blocks | ... | chunk_N_blocks]
//! Each chunk: 16 × 256 × 16 = 65536 bytes (BlockType is u8)
//! Total: max_chunks × 64KB
//! ```
//!
//! ## Slot Allocation
//!
//! Uses a free-list allocator to track which slots are in use.
//! - `allocate()`: reserves a slot for a chunk
//! - `free()`: returns a slot to the free list
//! - `upload()`: copies block data to the GPU buffer at a specific slot offset

const std = @import("std");
const log = @import("engine-core").log;
const rhi_mod = @import("engine-rhi").rhi;
const ResourceManager = rhi_mod.ResourceManager;
const BufferHandle = rhi_mod.BufferHandle;
const InvalidBufferHandle = rhi_mod.InvalidBufferHandle;
const BufferUsage = rhi_mod.BufferUsage;
const CHUNK_SIZE_X = @import("world-core").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("world-core").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("world-core").CHUNK_SIZE_Z;
const CHUNK_VOLUME = @import("world-core").CHUNK_VOLUME;

pub const MAX_GPU_CHUNKS: usize = 16384;
pub const SLOT_SIZE: usize = CHUNK_VOLUME;

pub const GpuBlockBuffer = struct {
    allocator: std.mem.Allocator,
    rm: ResourceManager,
    buffer: BufferHandle,
    capacity: usize,
    slot_size: usize,
    free_list: std.ArrayListUnmanaged(usize),
    slot_to_chunk: std.AutoArrayHashMapUnmanaged(usize, ChunkSlot),

    pub const ChunkSlot = struct {
        cx: i32,
        cz: i32,
    };

    pub fn init(allocator: std.mem.Allocator, rm: ResourceManager, max_chunks: usize) !*GpuBlockBuffer {
        const buffer = try allocator.create(GpuBlockBuffer);

        const capacity = @min(max_chunks, MAX_GPU_CHUNKS);
        const total_size = capacity * SLOT_SIZE;

        const buf_handle = try rm.createBuffer(total_size, .storage);
        errdefer rm.destroyBuffer(buf_handle);

        buffer.* = .{
            .allocator = allocator,
            .rm = rm,
            .buffer = buf_handle,
            .capacity = capacity,
            .slot_size = SLOT_SIZE,
            .free_list = .empty,
            .slot_to_chunk = .empty,
        };

        try buffer.free_list.ensureTotalCapacity(allocator, capacity);
        for (0..capacity) |i| {
            buffer.free_list.append(allocator, capacity - 1 - i) catch unreachable;
        }

        return buffer;
    }

    pub fn deinit(self: *GpuBlockBuffer) void {
        self.rm.destroyBuffer(self.buffer);
        self.free_list.deinit(self.allocator);
        self.slot_to_chunk.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn allocate(self: *GpuBlockBuffer, cx: i32, cz: i32) !usize {
        if (self.free_list.pop()) |slot| {
            try self.slot_to_chunk.put(self.allocator, slot, ChunkSlot{ .cx = cx, .cz = cz });
            return slot;
        }
        return error.OutOfMemory;
    }

    pub fn free(self: *GpuBlockBuffer, slot: usize) void {
        if (self.slot_to_chunk.swapRemove(slot)) {
            self.free_list.append(self.allocator, slot) catch {};
        }
    }

    pub fn freeByChunk(self: *GpuBlockBuffer, cx: i32, cz: i32) ?usize {
        var it = self.slot_to_chunk.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.cx == cx and entry.value_ptr.cz == cz) {
                const slot = entry.key_ptr.*;
                _ = self.slot_to_chunk.swapRemove(slot);
                self.free_list.append(self.allocator, slot) catch {};
                return slot;
            }
        }
        return null;
    }

    pub fn upload(self: *GpuBlockBuffer, slot: usize, blocks: []const u8) !void {
        std.debug.assert(blocks.len == SLOT_SIZE);
        const offset = slot * SLOT_SIZE;
        try self.rm.updateBuffer(self.buffer, offset, blocks);
    }

    pub fn update(self: *GpuBlockBuffer, slot: usize, offset: usize, data: []const u8) !void {
        const slot_offset = slot * SLOT_SIZE + offset;
        try self.rm.updateBuffer(self.buffer, slot_offset, data);
    }

    pub fn updateBlock(self: *GpuBlockBuffer, cx: i32, cz: i32, local_x: u32, local_y: u32, local_z: u32, block: u8) !void {
        if (self.getSlotForChunk(cx, cz)) |slot| {
            const offset = slot * SLOT_SIZE + local_x + local_z * CHUNK_SIZE_X + local_y * CHUNK_SIZE_X * CHUNK_SIZE_Z;
            const block_data: [1]u8 = .{block};
            try self.rm.updateBuffer(self.buffer, offset, &block_data);
        }
    }

    pub fn getSlotForChunk(self: *GpuBlockBuffer, cx: i32, cz: i32) ?usize {
        var it = self.slot_to_chunk.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.cx == cx and entry.value_ptr.cz == cz) {
                return entry.key_ptr.*;
            }
        }
        return null;
    }

    pub fn getBufferHandle(self: *GpuBlockBuffer) BufferHandle {
        return self.buffer;
    }

    pub fn allocatedCount(self: *GpuBlockBuffer) usize {
        return self.capacity - self.free_list.items.len;
    }

    pub fn stats(self: *GpuBlockBuffer) struct {
        allocated: usize,
        capacity: usize,
        used_bytes: usize,
    } {
        const allocated = self.allocatedCount();
        return .{
            .allocated = allocated,
            .capacity = self.capacity,
            .used_bytes = allocated * SLOT_SIZE,
        };
    }
};
