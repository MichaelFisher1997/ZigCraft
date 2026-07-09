//! Authoritative lighting propagation across the loaded chunk graph.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const PackedLight = world_core.PackedLight;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const MAX_LIGHT = world_core.MAX_LIGHT;
const block_registry = world_core.block_registry;
const ChunkStorage = @import("world-meshing").ChunkStorage;

/// Solves light for the connected loaded component containing a chunk.
/// Unloaded chunks are a frontier; their arrival triggers another reconciliation.
pub const WorldLightingEngine = struct {
    storage: *ChunkStorage,
    allocator: std.mem.Allocator,

    pub fn init(storage: *ChunkStorage, allocator: std.mem.Allocator) WorldLightingEngine {
        return .{ .storage = storage, .allocator = allocator };
    }

    pub fn reconcileChunkArrival(self: *WorldLightingEngine, cx: i32, cz: i32) !void {
        try self.relightLoadedComponent(cx, cz);
    }

    pub fn afterBlockMutation(self: *WorldLightingEngine, cx: i32, cz: i32) !void {
        try self.relightLoadedComponent(cx, cz);
    }

    fn relightLoadedComponent(self: *WorldLightingEngine, center_cx: i32, center_cz: i32) !void {
        self.storage.chunks_mutex.lock();
        defer self.storage.chunks_mutex.unlock();

        if (self.storage.chunks.get(.{ .x = center_cx, .z = center_cz }) == null) return;

        var component = std.ArrayListUnmanaged(ChunkCoords).empty;
        defer component.deinit(self.allocator);
        try component.append(self.allocator, .{ .cx = center_cx, .cz = center_cz });

        var sky_queue = std.ArrayListUnmanaged(SkyNode).empty;
        defer sky_queue.deinit(self.allocator);
        var rgb_queue = std.ArrayListUnmanaged(RgbNode).empty;
        defer rgb_queue.deinit(self.allocator);

        var index: usize = 0;
        while (index < component.items.len) : (index += 1) {
            const coords = component.items[index];
            const data = self.storage.chunks.get(.{ .x = coords.cx, .z = coords.cz }) orelse continue;
            resetChunkLighting(&data.chunk);
            try seedChunkSunlight(&data.chunk, self.allocator, &sky_queue);
            try seedChunkBlockLight(&data.chunk, self.allocator, &rgb_queue);
            data.chunk.dirty = true;
            data.chunk.markLightChanged();

            for (CARDINAL_CHUNK_OFFSETS) |offset| {
                const neighbor_cx = coords.cx + offset[0];
                const neighbor_cz = coords.cz + offset[1];
                if (self.storage.chunks.get(.{ .x = neighbor_cx, .z = neighbor_cz }) == null) continue;
                if (!containsCoords(component.items, neighbor_cx, neighbor_cz)) {
                    try component.append(self.allocator, .{ .cx = neighbor_cx, .cz = neighbor_cz });
                }
            }
        }

        try spreadSkylight(self.storage, self.allocator, &sky_queue);
        try spreadBlockLight(self.storage, self.allocator, &rgb_queue);
    }
};

const ChunkCoords = struct { cx: i32, cz: i32 };
const SkyNode = struct { cx: i32, cz: i32, x: u8, y: u16, z: u8, light: u4 };
const RgbNode = struct { cx: i32, cz: i32, x: u8, y: u16, z: u8, r: u4, g: u4, b: u4 };
const LoadedStep = struct { cx: i32, cz: i32, x: u32, y: u32, z: u32, chunk: *Chunk };
const CARDINAL_CHUNK_OFFSETS = [_][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 } };
const VOXEL_NEIGHBOR_OFFSETS = [_][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };

fn containsCoords(items: []const ChunkCoords, cx: i32, cz: i32) bool {
    for (items) |coords| if (coords.cx == cx and coords.cz == cz) return true;
    return false;
}

fn resetChunkLighting(chunk: *Chunk) void {
    for (&chunk.light) |*light| light.* = PackedLight.init(0, 0);
}

fn seedChunkSunlight(chunk: *Chunk, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(SkyNode)) !void {
    for (0..CHUNK_SIZE_Z) |z| {
        for (0..CHUNK_SIZE_X) |x| {
            var sunlit = true;
            var y: i32 = CHUNK_SIZE_Y - 1;
            while (y >= 0) : (y -= 1) {
                const uy: u32 = @intCast(y);
                const block = chunk.getBlock(@intCast(x), uy, @intCast(z));
                if (sunlit and block_registry.getBlockDefinition(block).isOpaque()) sunlit = false;
                if (!sunlit) continue;
                chunk.setSkyLight(@intCast(x), uy, @intCast(z), MAX_LIGHT);
                try queue.append(allocator, .{ .cx = chunk.chunk_x, .cz = chunk.chunk_z, .x = @intCast(x), .y = @intCast(uy), .z = @intCast(z), .light = MAX_LIGHT });
            }
        }
    }
}

fn seedChunkBlockLight(chunk: *Chunk, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(RgbNode)) !void {
    for (0..CHUNK_SIZE_Z) |z| for (0..CHUNK_SIZE_Y) |y| for (0..CHUNK_SIZE_X) |x| {
        const block = chunk.getBlock(@intCast(x), @intCast(y), @intCast(z));
        const emission = block_registry.getBlockDefinition(block).light_emission;
        if (emission[0] == 0 and emission[1] == 0 and emission[2] == 0) continue;
        chunk.setBlockLightRGB(@intCast(x), @intCast(y), @intCast(z), emission[0], emission[1], emission[2]);
        try queue.append(allocator, .{ .cx = chunk.chunk_x, .cz = chunk.chunk_z, .x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .r = emission[0], .g = emission[1], .b = emission[2] });
    };
}

fn spreadSkylight(storage: *ChunkStorage, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(SkyNode)) !void {
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];
        if (node.light <= 1) continue;
        for (VOXEL_NEIGHBOR_OFFSETS) |offset| {
            const pos = stepLoadedPosUnlocked(storage, node.cx, node.cz, node.x, node.y, node.z, offset) orelse continue;
            const block = pos.chunk.getBlock(pos.x, pos.y, pos.z);
            if (block_registry.getBlockDefinition(block).isOpaque()) continue;
            const attenuation: u4 = if (block == .water) 2 else 1;
            const next_light: u4 = if (node.light > attenuation) node.light - attenuation else 0;
            if (next_light <= pos.chunk.getSkyLight(pos.x, pos.y, pos.z)) continue;
            pos.chunk.setSkyLight(pos.x, pos.y, pos.z, next_light);
            pos.chunk.dirty = true;
            try queue.append(allocator, .{ .cx = pos.cx, .cz = pos.cz, .x = @intCast(pos.x), .y = @intCast(pos.y), .z = @intCast(pos.z), .light = next_light });
        }
    }
}

fn spreadBlockLight(storage: *ChunkStorage, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(RgbNode)) !void {
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];
        for (VOXEL_NEIGHBOR_OFFSETS) |offset| {
            const pos = stepLoadedPosUnlocked(storage, node.cx, node.cz, node.x, node.y, node.z, offset) orelse continue;
            if (block_registry.getBlockDefinition(pos.chunk.getBlock(pos.x, pos.y, pos.z)).isOpaque()) continue;
            const current = pos.chunk.getLight(pos.x, pos.y, pos.z);
            const next_r: u4 = if (node.r > 1) node.r - 1 else 0;
            const next_g: u4 = if (node.g > 1) node.g - 1 else 0;
            const next_b: u4 = if (node.b > 1) node.b - 1 else 0;
            if (next_r <= current.getBlockLightR() and next_g <= current.getBlockLightG() and next_b <= current.getBlockLightB()) continue;
            const r = @max(next_r, current.getBlockLightR());
            const g = @max(next_g, current.getBlockLightG());
            const b = @max(next_b, current.getBlockLightB());
            pos.chunk.setBlockLightRGB(pos.x, pos.y, pos.z, r, g, b);
            pos.chunk.dirty = true;
            try queue.append(allocator, .{ .cx = pos.cx, .cz = pos.cz, .x = @intCast(pos.x), .y = @intCast(pos.y), .z = @intCast(pos.z), .r = r, .g = g, .b = b });
        }
    }
}

fn stepLoadedPosUnlocked(storage: *ChunkStorage, cx: i32, cz: i32, x: u8, y: u16, z: u8, offset: [3]i32) ?LoadedStep {
    var ncx = cx;
    var ncz = cz;
    var nx = @as(i32, x) + offset[0];
    const ny = @as(i32, y) + offset[1];
    var nz = @as(i32, z) + offset[2];
    if (ny < 0 or ny >= CHUNK_SIZE_Y) return null;
    if (nx < 0) {
        ncx -= 1;
        nx = CHUNK_SIZE_X - 1;
    } else if (nx >= CHUNK_SIZE_X) {
        ncx += 1;
        nx = 0;
    }
    if (nz < 0) {
        ncz -= 1;
        nz = CHUNK_SIZE_Z - 1;
    } else if (nz >= CHUNK_SIZE_Z) {
        ncz += 1;
        nz = 0;
    }
    const data = storage.chunks.get(.{ .x = ncx, .z = ncz }) orelse return null;
    return .{ .cx = ncx, .cz = ncz, .x = @intCast(nx), .y = @intCast(ny), .z = @intCast(nz), .chunk = &data.chunk };
}

test "WorldLightingEngine propagates RGB light through loaded chunk boundaries" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const center = try storage.getOrCreate(0, 0);
    const east = try storage.getOrCreate(1, 0);
    center.chunk.setBlock(CHUNK_SIZE_X - 1, 4, 1, .torch);
    var lighting = WorldLightingEngine.init(&storage, testing.allocator);
    try lighting.reconcileChunkArrival(0, 0);
    try testing.expect(east.chunk.getLight(2, 4, 1).getBlockLightR() > 0);
}

test "WorldLightingEngine removes stale light across the loaded component" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const center = try storage.getOrCreate(0, 0);
    const east = try storage.getOrCreate(1, 0);
    center.chunk.setBlock(CHUNK_SIZE_X - 1, 4, 1, .torch);
    var lighting = WorldLightingEngine.init(&storage, testing.allocator);
    try lighting.afterBlockMutation(0, 0);
    center.chunk.setBlock(CHUNK_SIZE_X - 1, 4, 1, .air);
    try lighting.afterBlockMutation(0, 0);
    try testing.expectEqual(@as(u4, 0), east.chunk.getLight(2, 4, 1).getBlockLightR());
}
