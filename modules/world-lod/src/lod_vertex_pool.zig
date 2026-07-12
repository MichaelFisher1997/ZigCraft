//! Shared per-level vertex pool for distant LOD meshes.

const std = @import("std");
const sync = @import("sync");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const lod_mesh = @import("lod_mesh.zig");
const LODMesh = lod_mesh.LODMesh;
const LODMeshResources = lod_mesh.LODMeshResources;
const rhi_types = @import("engine-rhi");
const Vertex = rhi_types.Vertex;
const BufferHandle = rhi_types.BufferHandle;
const RhiError = rhi_types.RhiError;
const log = @import("engine-core").log;

const DEFAULT_INITIAL_CAPACITY_BYTES: usize = 8 * 1024 * 1024;
const COMPACTION_FRAGMENTATION_THRESHOLD: f32 = 0.35;

const FreeBlock = struct {
    offset: usize,
    size: usize,
};

const AllocationRecord = struct {
    mesh: *LODMesh,
    offset: usize,
    size: usize,
};

const MeshDrawState = LODMesh.DrawState;

/// Owns one large vertex buffer for a single LOD level and sub-allocates mesh ranges.
pub const LODVertexPool = struct {
    allocator: std.mem.Allocator,
    lod_level: LODLevel,
    buffer_handle: BufferHandle = 0,
    capacity_bytes: usize = 0,
    initial_capacity_bytes: usize = DEFAULT_INITIAL_CAPACITY_BYTES,
    free_blocks: std.ArrayListUnmanaged(FreeBlock) = .empty,
    allocations: std.ArrayListUnmanaged(AllocationRecord) = .empty,
    shadow: []u8 = undefined,
    mutex: sync.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, lod_level: LODLevel, initial_capacity_bytes: usize) LODVertexPool {
        return .{
            .allocator = allocator,
            .lod_level = lod_level,
            .initial_capacity_bytes = initial_capacity_bytes,
        };
    }

    pub fn deinit(self: *LODVertexPool, resources: LODMeshResources) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.buffer_handle != 0) {
            resources.destroyBuffer(self.buffer_handle);
            self.buffer_handle = 0;
        }
        if (self.capacity_bytes != 0) {
            self.allocator.free(self.shadow);
        }
        self.free_blocks.deinit(self.allocator);
        self.allocations.deinit(self.allocator);
        self.capacity_bytes = 0;
    }

    pub fn uploadMesh(self: *LODVertexPool, mesh: *LODMesh, resources: LODMeshResources) RhiError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        mesh.mutex.lock();
        defer mesh.mutex.unlock();

        const pending = mesh.pending_vertices orelse {
            if (mesh.bufferHandle() != 0 and mesh.vertexCount() > 0) {
                mesh.setDrawStateUnlocked(.{
                    .buffer_handle = mesh.bufferHandle(),
                    .vertex_offset = mesh.vertexOffset(),
                    .vertex_count = mesh.vertexCount(),
                    .capacity = @intCast(mesh.byteSize() / @sizeOf(Vertex)),
                    .pooled = mesh.isPooled(),
                    .ready = true,
                });
            }
            return;
        };

        if (pending.len == 0) {
            self.freeMeshUnlocked(mesh);
            mesh.markEmptyUploadedUnlocked();
            self.allocator.free(pending);
            mesh.pending_vertices = null;
            return;
        }

        const bytes = std.mem.sliceAsBytes(pending);

        const old_record_index = self.findRecordIndexUnlocked(mesh);
        const old_record = if (old_record_index) |idx| self.allocations.items[idx] else null;
        var record_index = old_record_index;
        var using_new_record = false;

        const large_update = bytes.len > lod_mesh.MAX_STAGING_UPDATE_BYTES;
        if (record_index == null or self.allocations.items[record_index.?].size < bytes.len or (large_update and old_record_index != null)) {
            const offset = try self.allocateBlockUnlocked(resources, bytes.len, mesh);
            errdefer self.releaseOffsetUnlocked(offset, bytes.len) catch {};
            try self.allocations.append(self.allocator, .{ .mesh = mesh, .offset = offset, .size = bytes.len });
            record_index = self.allocations.items.len - 1;
            using_new_record = true;
        }

        const record = &self.allocations.items[record_index.?];
        lod_mesh.updateBufferChunked(resources, self.buffer_handle, record.offset, bytes) catch |err| {
            if (using_new_record) {
                self.freeRecordUnlocked(record_index.?, false, mesh);
            }
            if (old_record) |old| {
                applyMeshDrawState(mesh, .{
                    .buffer_handle = self.buffer_handle,
                    .vertex_offset = old.offset,
                    .vertex_count = mesh.vertexCount(),
                    .capacity = @intCast(old.size / @sizeOf(Vertex)),
                    .pooled = true,
                    .ready = true,
                });
            } else {
                clearMeshDrawState(mesh);
            }
            return err;
        };
        @memcpy(self.shadow[record.offset .. record.offset + bytes.len], bytes);

        const new_offset = record.offset;
        const new_size = record.size;
        if (using_new_record) {
            if (old_record_index) |idx| {
                self.freeRecordUnlocked(idx, false, mesh);
            }
        }

        applyMeshDrawState(mesh, .{
            .buffer_handle = self.buffer_handle,
            .vertex_offset = new_offset,
            .vertex_count = @intCast(pending.len),
            .capacity = @intCast(new_size / @sizeOf(Vertex)),
            .pooled = true,
            .ready = true,
        });
        self.allocator.free(pending);
        mesh.pending_vertices = null;
    }

    pub fn destroyMesh(self: *LODVertexPool, mesh: *LODMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        mesh.mutex.lock();
        defer mesh.mutex.unlock();

        self.freeMeshUnlocked(mesh);

        if (mesh.pending_vertices) |pending| {
            self.allocator.free(pending);
            mesh.pending_vertices = null;
        }
        mesh.clearDrawStateUnlocked();
    }

    pub fn allocatedBytes(self: *LODVertexPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.allocatedBytesUnlocked();
    }

    pub fn gpuMemoryBytes(self: *LODVertexPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.capacity_bytes;
    }

    pub fn freeBytes(self: *LODVertexPool) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.freeBytesUnlocked();
    }

    pub fn fragmentationRatio(self: *LODVertexPool) f32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.fragmentationRatioUnlocked();
    }

    pub fn compact(self: *LODVertexPool, resources: LODMeshResources) RhiError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.compactUnlocked(resources, null);
    }

    fn allocateBlockUnlocked(self: *LODVertexPool, resources: LODMeshResources, size: usize, locked_mesh: ?*LODMesh) RhiError!usize {
        if (size == 0) return error.InvalidState;
        try self.ensureCapacityUnlocked(resources, size, locked_mesh);

        if (self.findBestFitUnlocked(size)) |idx| return self.takeBlockUnlocked(idx, size);

        if (self.freeBytesUnlocked() >= size) {
            try self.compactUnlocked(resources, locked_mesh);
            if (self.findBestFitUnlocked(size)) |idx| return self.takeBlockUnlocked(idx, size);
        }

        try self.ensureCapacityUnlocked(resources, self.capacity_bytes + size, locked_mesh);
        if (self.findBestFitUnlocked(size)) |idx| return self.takeBlockUnlocked(idx, size);
        return error.OutOfMemory;
    }

    fn ensureCapacityUnlocked(self: *LODVertexPool, resources: LODMeshResources, min_capacity: usize, locked_mesh: ?*LODMesh) RhiError!void {
        if (self.capacity_bytes >= min_capacity) return;

        var new_capacity = @max(self.initial_capacity_bytes, @as(usize, 1024));
        while (new_capacity < min_capacity) {
            new_capacity *= 2;
        }

        const new_shadow = self.allocator.alloc(u8, new_capacity) catch return error.OutOfMemory;
        errdefer self.allocator.free(new_shadow);
        if (self.capacity_bytes > 0) {
            @memcpy(new_shadow[0..self.capacity_bytes], self.shadow);
        }
        @memset(new_shadow[self.capacity_bytes..new_capacity], 0);

        const new_handle = try resources.createBuffer(new_capacity, .vertex);
        errdefer resources.destroyBuffer(new_handle);
        if (self.capacity_bytes > 0) {
            for (self.allocations.items) |record| {
                try lod_mesh.updateBufferChunked(resources, new_handle, record.offset, new_shadow[record.offset .. record.offset + record.size]);
            }
        }

        const old_handle = self.buffer_handle;
        const old_capacity = self.capacity_bytes;
        const old_shadow = if (old_capacity != 0) self.shadow else null;

        try self.releaseOffsetUnlocked(old_capacity, new_capacity - old_capacity);

        self.buffer_handle = new_handle;
        self.shadow = new_shadow;
        self.capacity_bytes = new_capacity;
        for (self.allocations.items) |record| {
            setMeshBufferHandle(record.mesh, new_handle, locked_mesh);
        }

        if (old_handle != 0) {
            resources.destroyBuffer(old_handle);
        }
        if (old_shadow) |shadow| self.allocator.free(shadow);
    }

    fn findBestFitUnlocked(self: *const LODVertexPool, size: usize) ?usize {
        var best_idx: ?usize = null;
        var best_size: usize = std.math.maxInt(usize);
        for (self.free_blocks.items, 0..) |block, idx| {
            if (block.size >= size and block.size < best_size) {
                best_idx = idx;
                best_size = block.size;
                if (block.size == size) break;
            }
        }
        return best_idx;
    }

    fn takeBlockUnlocked(self: *LODVertexPool, idx: usize, size: usize) usize {
        const block = self.free_blocks.items[idx];
        const offset = block.offset;
        if (block.size == size) {
            _ = self.free_blocks.orderedRemove(idx);
        } else {
            self.free_blocks.items[idx].offset += size;
            self.free_blocks.items[idx].size -= size;
        }
        return offset;
    }

    fn freeMeshUnlocked(self: *LODVertexPool, mesh: *LODMesh) void {
        if (self.findRecordIndexUnlocked(mesh)) |idx| {
            self.freeRecordUnlocked(idx, true, mesh);
        }
    }

    fn freeRecordUnlocked(self: *LODVertexPool, idx: usize, reset_mesh: bool, locked_mesh: ?*LODMesh) void {
        const record = self.allocations.items[idx];
        self.releaseOffsetUnlocked(record.offset, record.size) catch |err| {
            log.log.warn("LOD vertex pool failed to release {} bytes at {}: {}", .{ record.size, record.offset, err });
        };
        if (reset_mesh) {
            setMeshDrawState(record.mesh, .empty, locked_mesh);
        }
        _ = self.allocations.orderedRemove(idx);
    }

    fn releaseOffsetUnlocked(self: *LODVertexPool, offset: usize, size: usize) !void {
        if (size == 0) return;

        var insert_idx = self.free_blocks.items.len;
        for (self.free_blocks.items, 0..) |block, idx| {
            if (block.offset > offset) {
                insert_idx = idx;
                break;
            }
        }
        try self.free_blocks.insert(self.allocator, insert_idx, .{ .offset = offset, .size = size });
        self.coalesceAroundUnlocked(insert_idx);
    }

    fn coalesceAroundUnlocked(self: *LODVertexPool, start_idx: usize) void {
        var idx = start_idx;
        if (idx > 0 and self.free_blocks.items[idx - 1].offset + self.free_blocks.items[idx - 1].size == self.free_blocks.items[idx].offset) {
            self.free_blocks.items[idx - 1].size += self.free_blocks.items[idx].size;
            _ = self.free_blocks.orderedRemove(idx);
            idx -= 1;
        }
        while (idx + 1 < self.free_blocks.items.len and self.free_blocks.items[idx].offset + self.free_blocks.items[idx].size == self.free_blocks.items[idx + 1].offset) {
            self.free_blocks.items[idx].size += self.free_blocks.items[idx + 1].size;
            _ = self.free_blocks.orderedRemove(idx + 1);
        }
    }

    fn compactUnlocked(self: *LODVertexPool, resources: LODMeshResources, locked_mesh: ?*LODMesh) RhiError!void {
        if (self.allocations.items.len == 0) {
            self.free_blocks.clearRetainingCapacity();
            try self.releaseOffsetUnlocked(0, self.capacity_bytes);
            return;
        }

        std.mem.sort(AllocationRecord, self.allocations.items, {}, struct {
            fn lt(_: void, a: AllocationRecord, b: AllocationRecord) bool {
                return a.offset < b.offset;
            }
        }.lt);

        var cursor: usize = 0;
        for (self.allocations.items) |*record| {
            if (record.offset != cursor) {
                try lod_mesh.updateBufferChunked(resources, self.buffer_handle, cursor, self.shadow[record.offset .. record.offset + record.size]);
                std.mem.copyForwards(u8, self.shadow[cursor .. cursor + record.size], self.shadow[record.offset .. record.offset + record.size]);
                record.offset = cursor;
                setMeshPoolLocation(record.mesh, self.buffer_handle, cursor, locked_mesh);
            }
            cursor += record.size;
        }

        self.free_blocks.clearRetainingCapacity();
        if (cursor < self.capacity_bytes) {
            try self.releaseOffsetUnlocked(cursor, self.capacity_bytes - cursor);
        }
    }

    fn findRecordIndexUnlocked(self: *const LODVertexPool, mesh: *const LODMesh) ?usize {
        for (self.allocations.items, 0..) |record, idx| {
            if (record.mesh == mesh) return idx;
        }
        return null;
    }

    fn allocatedBytesUnlocked(self: *const LODVertexPool) usize {
        var total: usize = 0;
        for (self.allocations.items) |record| total += record.size;
        return total;
    }

    fn freeBytesUnlocked(self: *const LODVertexPool) usize {
        var total: usize = 0;
        for (self.free_blocks.items) |block| total += block.size;
        return total;
    }

    fn fragmentationRatioUnlocked(self: *const LODVertexPool) f32 {
        const total_free = self.freeBytesUnlocked();
        if (total_free == 0) return 0.0;
        var largest_free: usize = 0;
        for (self.free_blocks.items) |block| largest_free = @max(largest_free, block.size);
        return 1.0 - (@as(f32, @floatFromInt(largest_free)) / @as(f32, @floatFromInt(total_free)));
    }
};

fn clearMeshDrawState(mesh: *LODMesh) void {
    mesh.clearDrawStateUnlocked();
}

fn setMeshBufferHandle(mesh: *LODMesh, buffer_handle: BufferHandle, locked_mesh: ?*LODMesh) void {
    if (locked_mesh) |locked| {
        if (locked == mesh) {
            mesh.setBufferHandleUnlocked(buffer_handle);
            return;
        }
    }
    mesh.mutex.lock();
    defer mesh.mutex.unlock();
    mesh.setBufferHandleUnlocked(buffer_handle);
}

fn setMeshPoolLocation(mesh: *LODMesh, buffer_handle: BufferHandle, vertex_offset: usize, locked_mesh: ?*LODMesh) void {
    if (locked_mesh) |locked| {
        if (locked == mesh) {
            mesh.setPoolLocationUnlocked(buffer_handle, vertex_offset);
            return;
        }
    }
    mesh.mutex.lock();
    defer mesh.mutex.unlock();
    mesh.setPoolLocationUnlocked(buffer_handle, vertex_offset);
}

fn setMeshDrawState(mesh: *LODMesh, state: MeshDrawState, locked_mesh: ?*LODMesh) void {
    if (locked_mesh) |locked| {
        if (locked == mesh) {
            mesh.setDrawStateUnlocked(state);
            return;
        }
    }
    mesh.mutex.lock();
    defer mesh.mutex.unlock();
    mesh.setDrawStateUnlocked(state);
}

fn applyMeshDrawState(mesh: *LODMesh, state: MeshDrawState) void {
    mesh.setDrawStateUnlocked(state);
}

fn shouldCompactAfterEviction(pool: *LODVertexPool) bool {
    return pool.fragmentationRatio() > COMPACTION_FRAGMENTATION_THRESHOLD;
}

const TestResources = struct {
    next_handle: BufferHandle = 1,
    created: u32 = 0,
    destroyed: u32 = 0,
    uploaded: u32 = 0,
    updated: u32 = 0,
    total_updated_bytes: usize = 0,
    max_update_bytes: usize = 0,
    wait_idle: u32 = 0,
    fail_updates: bool = false,

    fn resources(self: *TestResources) LODMeshResources {
        return .{ .ptr = self, .vtable = &vtable };
    }

    fn createBuffer(ptr: *anyopaque, _: usize, _: rhi_types.BufferUsage) RhiError!BufferHandle {
        const self: *TestResources = @ptrCast(@alignCast(ptr));
        const handle = self.next_handle;
        self.next_handle += 1;
        self.created += 1;
        return handle;
    }

    fn uploadBuffer(ptr: *anyopaque, _: BufferHandle, _: []const u8) RhiError!void {
        const self: *TestResources = @ptrCast(@alignCast(ptr));
        self.uploaded += 1;
    }

    fn updateBuffer(ptr: *anyopaque, _: BufferHandle, _: usize, data: []const u8) RhiError!void {
        const self: *TestResources = @ptrCast(@alignCast(ptr));
        if (self.fail_updates) return error.GpuLost;
        self.updated += 1;
        self.total_updated_bytes += data.len;
        self.max_update_bytes = @max(self.max_update_bytes, data.len);
    }

    fn destroyBuffer(ptr: *anyopaque, _: BufferHandle) void {
        const self: *TestResources = @ptrCast(@alignCast(ptr));
        self.destroyed += 1;
    }

    fn waitIdle(ptr: *anyopaque) void {
        const self: *TestResources = @ptrCast(@alignCast(ptr));
        self.wait_idle += 1;
    }

    const vtable = LODMeshResources.VTable{
        .createBuffer = createBuffer,
        .uploadBuffer = uploadBuffer,
        .updateBuffer = updateBuffer,
        .destroyBuffer = destroyBuffer,
        .waitIdle = waitIdle,
    };
};

fn setPending(mesh: *LODMesh, allocator: std.mem.Allocator, count: usize) !void {
    const vertices = try allocator.alloc(Vertex, count);
    @memset(std.mem.sliceAsBytes(vertices), 0);
    mesh.pending_vertices = vertices;
}

test "LODVertexPool reuses freed ranges" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());

    var first = LODMesh.init(allocator, .lod1);
    var second = LODMesh.init(allocator, .lod1);
    var third = LODMesh.init(allocator, .lod1);
    try setPending(&first, allocator, 4);
    try setPending(&second, allocator, 4);
    try pool.uploadMesh(&first, resources.resources());
    try pool.uploadMesh(&second, resources.resources());

    const reused_offset = first.vertex_offset;
    pool.destroyMesh(&first);
    try setPending(&third, allocator, 4);
    try pool.uploadMesh(&third, resources.resources());

    try std.testing.expectEqual(reused_offset, third.vertex_offset);
    pool.destroyMesh(&second);
    pool.destroyMesh(&third);
}

test "LODVertexPool grows and preserves pooled handles" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 64);
    defer pool.deinit(resources.resources());

    var first = LODMesh.init(allocator, .lod1);
    var second = LODMesh.init(allocator, .lod1);
    try setPending(&first, allocator, 4);
    try pool.uploadMesh(&first, resources.resources());
    const old_handle = first.buffer_handle;

    try setPending(&second, allocator, 64);
    try pool.uploadMesh(&second, resources.resources());

    try std.testing.expect(pool.gpuMemoryBytes() > 64);
    try std.testing.expect(first.buffer_handle != old_handle);
    try std.testing.expectEqual(first.buffer_handle, second.buffer_handle);
    try std.testing.expectEqual(@as(u32, 0), resources.uploaded);
    try std.testing.expect(resources.updated >= 1);
    try std.testing.expectEqual(@as(u32, 0), resources.wait_idle);
    pool.destroyMesh(&first);
    pool.destroyMesh(&second);
}

test "LODVertexPool splits oversized staging updates" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, lod_mesh.MAX_STAGING_UPDATE_BYTES * 2);
    defer pool.deinit(resources.resources());

    var mesh = LODMesh.init(allocator, .lod1);
    const vertex_count = lod_mesh.MAX_STAGING_UPDATE_BYTES / @sizeOf(Vertex) + 1;
    try setPending(&mesh, allocator, vertex_count);
    try pool.uploadMesh(&mesh, resources.resources());

    try std.testing.expect(resources.updated >= 2);
    try std.testing.expect(resources.max_update_bytes <= lod_mesh.MAX_STAGING_UPDATE_BYTES);
    try std.testing.expectEqual(vertex_count * @sizeOf(Vertex), resources.total_updated_bytes);
    pool.destroyMesh(&mesh);
}

test "LODVertexPool compacts fragmented ranges" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());

    var a = LODMesh.init(allocator, .lod1);
    var b = LODMesh.init(allocator, .lod1);
    var c = LODMesh.init(allocator, .lod1);
    try setPending(&a, allocator, 4);
    try setPending(&b, allocator, 4);
    try setPending(&c, allocator, 4);
    try pool.uploadMesh(&a, resources.resources());
    try pool.uploadMesh(&b, resources.resources());
    try pool.uploadMesh(&c, resources.resources());

    pool.destroyMesh(&b);
    const old_c_offset = c.vertex_offset;
    try pool.compact(resources.resources());

    try std.testing.expect(c.vertex_offset < old_c_offset);
    try std.testing.expectEqual(pool.capacity_bytes - pool.allocatedBytes(), pool.freeBytes());
    pool.destroyMesh(&a);
    pool.destroyMesh(&c);
}

test "LODVertexPool upload failure keeps pending vertices retryable" {
    const allocator = std.testing.allocator;
    var resources = TestResources{ .fail_updates = true };
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());

    var mesh = LODMesh.init(allocator, .lod1);
    defer if (mesh.pending_vertices) |pending| allocator.free(pending);
    try setPending(&mesh, allocator, 4);
    try std.testing.expectError(error.GpuLost, pool.uploadMesh(&mesh, resources.resources()));

    try std.testing.expect(mesh.pending_vertices != null);
    try std.testing.expect(!mesh.ready);
    try std.testing.expectEqual(@as(u32, 0), mesh.vertex_count);
}

test "LODVertexPool upload failure preserves existing renderable allocation" {
    const allocator = std.testing.allocator;
    var resources = TestResources{};
    var pool = LODVertexPool.init(allocator, .lod1, 1024);
    defer pool.deinit(resources.resources());

    var mesh = LODMesh.init(allocator, .lod1);
    defer if (mesh.pending_vertices) |pending| allocator.free(pending);
    try setPending(&mesh, allocator, 4);
    try pool.uploadMesh(&mesh, resources.resources());

    const old_handle = mesh.buffer_handle;
    const old_offset = mesh.vertex_offset;
    const old_count = mesh.vertex_count;
    resources.fail_updates = true;
    try setPending(&mesh, allocator, 4);
    try std.testing.expectError(error.GpuLost, pool.uploadMesh(&mesh, resources.resources()));

    try std.testing.expect(mesh.pending_vertices != null);
    try std.testing.expect(mesh.ready);
    try std.testing.expect(mesh.pooled);
    try std.testing.expectEqual(old_handle, mesh.buffer_handle);
    try std.testing.expectEqual(old_offset, mesh.vertex_offset);
    try std.testing.expectEqual(old_count, mesh.vertex_count);
    try std.testing.expectEqual(@as(usize, old_count) * @sizeOf(Vertex), pool.allocatedBytes());
}

test "LODVertexPool exposes compaction threshold helper" {
    _ = shouldCompactAfterEviction;
}
