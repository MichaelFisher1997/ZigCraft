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
const ChunkKey = world_core.ChunkKey;
const ChunkStorage = @import("world-meshing").ChunkStorage;

/// Solves light for the connected loaded component containing a chunk.
/// Unloaded chunks are a frontier; their arrival triggers another reconciliation.
pub const WorldLightingEngine = struct {
    storage: *ChunkStorage,
    allocator: std.mem.Allocator,

    pub fn init(storage: *ChunkStorage, allocator: std.mem.Allocator) WorldLightingEngine {
        return .{ .storage = storage, .allocator = allocator };
    }

    pub fn reconcileChunkArrival(self: *WorldLightingEngine, cx: i32, cz: i32) !bool {
        return try self.relightLoadedComponent(cx, cz);
    }

    pub fn afterBlockMutation(self: *WorldLightingEngine, cx: i32, cz: i32) !void {
        _ = try self.relightLoadedComponent(cx, cz);
    }

    fn relightLoadedComponent(self: *WorldLightingEngine, center_cx: i32, center_cz: i32) !bool {
        var component = ComponentChunks.init(self.allocator);
        defer component.deinit();
        defer {
            var chunks = component.valueIterator();
            while (chunks.next()) |chunk| chunk.*.unpin();
        }

        // Pin the complete component while the storage map is stable, then do
        // the expensive solve without blocking unrelated storage operations.
        self.storage.chunks_mutex.lockShared();
        var storage_locked = true;
        defer {
            if (storage_locked) self.storage.chunks_mutex.unlockShared();
        }
        const center = self.storage.chunks.get(.{ .x = center_cx, .z = center_cz }) orelse return false;
        if (!center.chunk.generated) return false;
        try component.put(.{ .x = center_cx, .z = center_cz }, &center.chunk);
        center.chunk.pin();

        var discovery = std.ArrayListUnmanaged(ChunkCoords).empty;
        defer discovery.deinit(self.allocator);
        try discovery.append(self.allocator, .{ .cx = center_cx, .cz = center_cz });

        var index: usize = 0;
        while (index < discovery.items.len) : (index += 1) {
            const coords = discovery.items[index];
            for (CARDINAL_CHUNK_OFFSETS) |offset| {
                const key = ChunkKey{ .x = coords.cx + offset[0], .z = coords.cz + offset[1] };
                if (component.contains(key)) continue;
                const data = self.storage.chunks.get(key) orelse continue;
                if (!data.chunk.generated) continue;
                try component.put(key, &data.chunk);
                data.chunk.pin();
                try discovery.append(self.allocator, .{ .cx = key.x, .cz = key.z });
            }
        }
        self.storage.chunks_mutex.unlockShared();
        storage_locked = false;

        var sky_queue = std.ArrayListUnmanaged(SkyNode).empty;
        defer sky_queue.deinit(self.allocator);
        var rgb_queue = std.ArrayListUnmanaged(RgbNode).empty;
        defer rgb_queue.deinit(self.allocator);

        var chunks = component.valueIterator();
        while (chunks.next()) |chunk| {
            resetChunkLighting(chunk.*);
            try seedChunkSunlight(chunk.*, self.allocator, &sky_queue);
            try seedChunkBlockLight(chunk.*, self.allocator, &rgb_queue);
            chunk.*.dirty = true;
            chunk.*.modified = true;
            chunk.*.lighting_valid = true;
            chunk.*.markLightChanged();
        }

        try spreadSkylight(&component, self.allocator, &sky_queue);
        try spreadBlockLight(&component, self.allocator, &rgb_queue);
        return true;
    }
};

const ChunkCoords = struct { cx: i32, cz: i32 };
const ComponentChunks = std.AutoHashMap(ChunkKey, *Chunk);
const SkyNode = struct { cx: i32, cz: i32, x: u8, y: u16, z: u8, light: u4 };
const RgbNode = struct { cx: i32, cz: i32, x: u8, y: u16, z: u8, r: u4, g: u4, b: u4 };
const LoadedStep = struct { cx: i32, cz: i32, x: u32, y: u32, z: u32, chunk: *Chunk };
const CARDINAL_CHUNK_OFFSETS = [_][2]i32{ .{ 0, -1 }, .{ 0, 1 }, .{ 1, 0 }, .{ -1, 0 } };
const VOXEL_NEIGHBOR_OFFSETS = [_][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };

fn resetChunkLighting(chunk: *Chunk) void {
    for (&chunk.light) |*light| light.* = PackedLight.init(0, 0);
    for (&chunk.entrance_bounce) |*bounce| bounce.* = 0;
    for (&chunk.entrance_dir) |*dir| dir.* = world_core.packEntranceDir(0, 0);
}

fn seedChunkSunlight(chunk: *Chunk, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(SkyNode)) !void {
    for (0..CHUNK_SIZE_Z) |z| {
        for (0..CHUNK_SIZE_X) |x| {
            var sunlit = true;
            var sky_light: u4 = MAX_LIGHT;
            var y: i32 = CHUNK_SIZE_Y - 1;
            while (y >= 0) : (y -= 1) {
                const uy: u32 = @intCast(y);
                const block = chunk.getBlock(@intCast(x), uy, @intCast(z));
                if (sunlit and block_registry.getBlockDefinition(block).isOpaque()) sunlit = false;
                if (!sunlit) continue;
                chunk.setSkyLight(@intCast(x), uy, @intCast(z), sky_light);
                try queue.append(allocator, .{ .cx = chunk.chunk_x, .cz = chunk.chunk_z, .x = @intCast(x), .y = @intCast(uy), .z = @intCast(z), .light = sky_light });
                const attenuation = block_registry.lightAttenuation(block);
                if (attenuation > 1) sky_light = if (sky_light > attenuation) sky_light - attenuation else 0;
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

fn spreadSkylight(component: *const ComponentChunks, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(SkyNode)) !void {
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];
        if (node.light <= 1) continue;
        for (VOXEL_NEIGHBOR_OFFSETS) |offset| {
            const pos = stepLoadedPos(component, node.cx, node.cz, node.x, node.y, node.z, offset) orelse continue;
            const block = pos.chunk.getBlock(pos.x, pos.y, pos.z);
            if (block_registry.getBlockDefinition(block).isOpaque()) continue;
            const attenuation = block_registry.lightAttenuation(block);
            const next_light: u4 = if (node.light > attenuation) node.light - attenuation else 0;
            if (next_light <= pos.chunk.getSkyLight(pos.x, pos.y, pos.z)) continue;
            pos.chunk.setSkyLight(pos.x, pos.y, pos.z, next_light);
            pos.chunk.dirty = true;
            try queue.append(allocator, .{ .cx = pos.cx, .cz = pos.cz, .x = @intCast(pos.x), .y = @intCast(pos.y), .z = @intCast(pos.z), .light = next_light });
        }
    }
}

fn spreadBlockLight(component: *const ComponentChunks, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(RgbNode)) !void {
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];
        for (VOXEL_NEIGHBOR_OFFSETS) |offset| {
            const pos = stepLoadedPos(component, node.cx, node.cz, node.x, node.y, node.z, offset) orelse continue;
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

fn stepLoadedPos(component: *const ComponentChunks, cx: i32, cz: i32, x: u8, y: u16, z: u8, offset: [3]i32) ?LoadedStep {
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
    const chunk = component.get(.{ .x = ncx, .z = ncz }) orelse return null;
    return .{ .cx = ncx, .cz = ncz, .x = @intCast(nx), .y = @intCast(ny), .z = @intCast(nz), .chunk = chunk };
}

test "WorldLightingEngine propagates RGB light through loaded chunk boundaries" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const center = try storage.getOrCreate(0, 0);
    const east = try storage.getOrCreate(1, 0);
    center.chunk.generated = true;
    east.chunk.generated = true;
    center.chunk.setBlock(CHUNK_SIZE_X - 1, 4, 1, .torch);
    var lighting = WorldLightingEngine.init(&storage, testing.allocator);
    _ = try lighting.reconcileChunkArrival(0, 0);
    try testing.expect(east.chunk.getLight(2, 4, 1).getBlockLightR() > 0);
}

test "WorldLightingEngine removes stale light across the loaded component" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const center = try storage.getOrCreate(0, 0);
    const east = try storage.getOrCreate(1, 0);
    center.chunk.generated = true;
    east.chunk.generated = true;
    center.chunk.setBlock(CHUNK_SIZE_X - 1, 4, 1, .torch);
    east.chunk.setEntranceBounce(2, 4, 1, 7);
    east.chunk.setEntranceDir(2, 4, 1, world_core.packEntranceDir(1, -1));
    var lighting = WorldLightingEngine.init(&storage, testing.allocator);
    try lighting.afterBlockMutation(0, 0);
    try testing.expectEqual(@as(u4, 0), east.chunk.getEntranceBounce(2, 4, 1));
    try testing.expectEqual(world_core.packEntranceDir(0, 0), east.chunk.getEntranceDir(2, 4, 1));
    center.chunk.setBlock(CHUNK_SIZE_X - 1, 4, 1, .air);
    try lighting.afterBlockMutation(0, 0);
    try testing.expectEqual(@as(u4, 0), east.chunk.getLight(2, 4, 1).getBlockLightR());
}
