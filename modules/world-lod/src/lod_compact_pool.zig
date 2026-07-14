//! Shared storage for compact LOD3/4 samples. Freed ranges are not reusable
//! until the same completed frame slot is observed at a later frame serial.
const std = @import("std");
const rhi = @import("engine-rhi");
const LODMesh = @import("lod_mesh.zig").LODMesh;
const LODMeshResources = @import("lod_mesh_resources.zig").LODMeshResources;

pub const CompactLODPool = struct {
    pub const CAPACITY_BYTES = 64 * 1024 * 1024;
    const Range = struct { offset: usize, size: usize };
    const Retired = struct { range: Range, serial: u64, frame_slot: usize };

    pub const MemoryStats = struct {
        capacity_bytes: usize = 0,
        allocated_bytes: usize = 0,
        free_bytes: usize = 0,
        retired_bytes: usize = 0,
    };

    allocator: std.mem.Allocator,
    buffer_handle: rhi.BufferHandle = 0,
    capacity_bytes: usize,
    /// Live bytes. Retired bytes remain unavailable but are not live mesh data.
    allocated_bytes: usize = 0,
    free_bytes: usize = 0,
    retired_bytes: usize = 0,
    free_ranges: std.ArrayListUnmanaged(Range) = .empty,
    retired: std.ArrayListUnmanaged(Retired) = .empty,
    last_completed_serial: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) CompactLODPool {
        return .{ .allocator = allocator, .capacity_bytes = CAPACITY_BYTES };
    }

    fn initForTest(allocator: std.mem.Allocator, capacity_bytes: usize) CompactLODPool {
        return .{ .allocator = allocator, .capacity_bytes = capacity_bytes };
    }

    pub fn deinit(self: *CompactLODPool, resources: LODMeshResources) void {
        if (self.buffer_handle != 0) resources.destroyBuffer(self.buffer_handle);
        self.free_ranges.deinit(self.allocator);
        self.retired.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn memoryStats(self: *const CompactLODPool) MemoryStats {
        // A configured capacity is not GPU memory until the backing buffer is
        // successfully created. This prevents accounting a failed allocation.
        return .{
            .capacity_bytes = if (self.buffer_handle != 0) self.capacity_bytes else 0,
            .allocated_bytes = self.allocated_bytes,
            .free_bytes = self.free_bytes,
            .retired_bytes = self.retired_bytes,
        };
    }

    pub fn upload(self: *CompactLODPool, mesh: *LODMesh, resources: LODMeshResources) rhi.RhiError!void {
        const tile = mesh.compact_tile orelse return error.InvalidState;
        const bytes = std.mem.sliceAsBytes(tile.samples);
        if (bytes.len == 0 or bytes.len % 16 != 0) return error.InvalidState;
        try self.ensureBuffer(resources);
        const range = try self.allocate(bytes.len);
        errdefer self.releaseRange(range) catch {};
        try resources.updateBuffer(self.buffer_handle, range.offset, bytes);

        mesh.mutex.lock();
        defer mesh.mutex.unlock();
        // A range must never be overwritten in place. Callers retire a compact
        // mesh before remeshing, so seeing one here proves a lifecycle bug.
        if (mesh.compact_sample_bytes != 0) return error.InvalidState;
        mesh.compact_sample_offset = @intCast(range.offset / 16);
        mesh.compact_sample_bytes = range.size;
        mesh.buffer_handle = self.buffer_handle;
        mesh.vertex_count = mesh.compact_index_count;
        mesh.opaque_vertex_count = mesh.compact_index_count;
        mesh.water_vertex_count = if (mesh.compact_has_water) mesh.compact_index_count else 0;
        mesh.ready = true;
        var mutable_tile = mesh.compact_tile.?;
        mutable_tile.deinit();
        mesh.compact_tile = null;
    }

    /// Retire a compact range at the serial/frame-slot that last submitted a
    /// draw. `collectRetired` only returns it after that slot is completed and
    /// reused at a strictly later serial.
    pub fn retireMesh(self: *CompactLODPool, mesh: *LODMesh, serial: u64, frame_slot: usize) void {
        if (!mesh.isCompact()) return;
        mesh.mutex.lock();
        defer mesh.mutex.unlock();
        if (mesh.compact_sample_bytes != 0) {
            const range = Range{ .offset = @as(usize, mesh.compact_sample_offset) * 16, .size = mesh.compact_sample_bytes };
            self.retired.append(self.allocator, .{ .range = range, .serial = serial, .frame_slot = frame_slot }) catch {
                // Never reuse on bookkeeping failure. The mesh state is still
                // cleared below so a CPU fallback cannot render stale offsets.
                self.allocated_bytes -= range.size;
                self.retired_bytes += range.size;
                self.clearMeshUnlocked(mesh);
                return;
            };
            self.allocated_bytes -= range.size;
            self.retired_bytes += range.size;
        }
        self.clearMeshUnlocked(mesh);
    }

    /// `completed_serial` comes from the monotonic WorldRenderer frame serial;
    /// the completed slot is supplied only after its frame fence has made it
    /// reusable. Older or duplicate serials cannot reclaim anything.
    pub fn collectRetired(self: *CompactLODPool, completed_serial: u64, completed_frame_slot: usize) void {
        if (self.last_completed_serial) |last| {
            if (completed_serial <= last) return;
        }
        self.last_completed_serial = completed_serial;
        var i: usize = 0;
        while (i < self.retired.items.len) {
            const retired = self.retired.items[i];
            if (retired.frame_slot == completed_frame_slot and completed_serial > retired.serial) {
                self.releaseRange(retired.range) catch {
                    // Keep the range retired on allocation failure; it remains
                    // safe and will be retried at a later completed boundary.
                    i += 1;
                    continue;
                };
                self.retired_bytes -= retired.range.size;
                _ = self.retired.swapRemove(i);
            } else i += 1;
        }
    }

    fn ensureBuffer(self: *CompactLODPool, resources: LODMeshResources) rhi.RhiError!void {
        if (self.buffer_handle != 0) return;
        // The fixed pool can contain at most a bounded number of minimum-size
        // tiles. Reserve retirement metadata up front so pressure cannot turn
        // a fence-safe retirement into a permanently leaked range.
        try self.retired.ensureTotalCapacity(self.allocator, 16_384);
        const handle = try resources.createBuffer(self.capacity_bytes, .storage);
        errdefer resources.destroyBuffer(handle);
        try self.free_ranges.append(self.allocator, .{ .offset = 0, .size = self.capacity_bytes });
        self.buffer_handle = handle;
        self.free_bytes = self.capacity_bytes;
    }

    fn allocate(self: *CompactLODPool, size: usize) rhi.RhiError!Range {
        if (size == 0 or size % 16 != 0) return error.InvalidState;
        for (self.free_ranges.items, 0..) |*range, i| if (range.size >= size) {
            const result = Range{ .offset = range.offset, .size = size };
            range.offset += size;
            range.size -= size;
            if (range.size == 0) _ = self.free_ranges.swapRemove(i);
            self.free_bytes -= size;
            self.allocated_bytes += size;
            return result;
        };
        return error.OutOfMemory;
    }

    fn releaseRange(self: *CompactLODPool, range: Range) !void {
        var insert_at: usize = 0;
        while (insert_at < self.free_ranges.items.len and self.free_ranges.items[insert_at].offset < range.offset) : (insert_at += 1) {}
        try self.free_ranges.insert(self.allocator, insert_at, range);
        self.free_bytes += range.size;

        var i = if (insert_at > 0) insert_at - 1 else insert_at;
        while (i + 1 < self.free_ranges.items.len) {
            const current = self.free_ranges.items[i];
            const next = self.free_ranges.items[i + 1];
            if (current.offset + current.size != next.offset) {
                i += 1;
                continue;
            }
            self.free_ranges.items[i].size += next.size;
            _ = self.free_ranges.orderedRemove(i + 1);
        }
    }

    fn clearMeshUnlocked(_: *CompactLODPool, mesh: *LODMesh) void {
        if (mesh.compact_tile) |*tile| tile.deinit();
        mesh.compact_tile = null;
        mesh.compact = false;
        mesh.compact_sample_offset = 0;
        mesh.compact_sample_bytes = 0;
        mesh.compact_index_count = 0;
        mesh.compact_tile_width = 0;
        mesh.compact_has_water = false;
        mesh.buffer_handle = 0;
        mesh.vertex_count = 0;
        mesh.opaque_vertex_count = 0;
        mesh.water_vertex_offset = 0;
        mesh.water_vertex_count = 0;
        mesh.vertex_offset = 0;
        mesh.capacity = 0;
        mesh.pooled = false;
        mesh.ready = false;
    }
};

test "compact pool capacity is sample aligned" {
    try std.testing.expectEqual(@as(usize, 0), CompactLODPool.CAPACITY_BYTES % 16);
}

test "compact pool retires only at a later completed frame-slot boundary" {
    var pool = CompactLODPool.initForTest(std.testing.allocator, 64);
    defer {
        pool.free_ranges.deinit(std.testing.allocator);
        pool.retired.deinit(std.testing.allocator);
    }
    try pool.free_ranges.append(std.testing.allocator, .{ .offset = 0, .size = 64 });
    pool.free_bytes = 64;
    // This test exercises bookkeeping without creating a GPU backing buffer.
    const range = try pool.allocate(16);
    try pool.retired.append(std.testing.allocator, .{ .range = range, .serial = 10, .frame_slot = 1 });
    pool.allocated_bytes -= 16;
    pool.retired_bytes += 16;

    pool.collectRetired(10, 1);
    try std.testing.expectEqual(@as(usize, 48), pool.free_bytes);
    pool.collectRetired(11, 0);
    try std.testing.expectEqual(@as(usize, 48), pool.free_bytes);
    pool.collectRetired(11, 1); // duplicate serial cannot reclaim.
    try std.testing.expectEqual(@as(usize, 48), pool.free_bytes);
    pool.collectRetired(12, 1);
    try std.testing.expectEqual(@as(usize, 64), pool.free_bytes);
    try std.testing.expectEqual(@as(usize, 0), pool.retired_bytes);
}

test "compact pool reports exhaustion without reusing retired bytes" {
    var pool = CompactLODPool.initForTest(std.testing.allocator, 32);
    defer {
        pool.free_ranges.deinit(std.testing.allocator);
        pool.retired.deinit(std.testing.allocator);
    }
    try pool.free_ranges.append(std.testing.allocator, .{ .offset = 0, .size = 32 });
    pool.free_bytes = 32;
    const a = try pool.allocate(16);
    const b = try pool.allocate(16);
    try std.testing.expectError(error.OutOfMemory, pool.allocate(16));
    try pool.retired.append(std.testing.allocator, .{ .range = a, .serial = 4, .frame_slot = 0 });
    pool.allocated_bytes -= 16;
    pool.retired_bytes += 16;
    try std.testing.expectError(error.OutOfMemory, pool.allocate(16));
    pool.collectRetired(5, 0);
    _ = try pool.allocate(16);
    try std.testing.expectEqual(@as(usize, 16), b.size);
}
