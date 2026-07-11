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

/// Reconciles legacy lighting in the local chunk window and propagates edits.
pub const WorldLightingEngine = struct {
    storage: *ChunkStorage,
    allocator: std.mem.Allocator,

    pub fn init(storage: *ChunkStorage, allocator: std.mem.Allocator) WorldLightingEngine {
        return .{ .storage = storage, .allocator = allocator };
    }

    pub fn reconcileChunkArrival(self: *WorldLightingEngine, cx: i32, cz: i32) !bool {
        self.storage.lighting_mutex.lock();
        defer self.storage.lighting_mutex.unlock();

        var component = ComponentChunks.init(self.allocator);
        defer component.deinit();
        defer {
            var chunks = component.valueIterator();
            while (chunks.next()) |chunk| chunk.*.unpin();
        }

        if (!try self.pinLoadedArea(&component, cx, cz, -1, 1, -1, 1)) return false;

        var sky_queue = std.ArrayListUnmanaged(SkyNode).empty;
        defer sky_queue.deinit(self.allocator);
        var rgb_queue = std.ArrayListUnmanaged(RgbNode).empty;
        defer rgb_queue.deinit(self.allocator);

        const center = component.get(.{ .x = cx, .z = cz }).?;
        if (component.get(.{ .x = cx - 1, .z = cz })) |west| {
            try seedChunkInterface(center, west, .west, self.allocator, &sky_queue, &rgb_queue);
        }
        if (component.get(.{ .x = cx + 1, .z = cz })) |east| {
            try seedChunkInterface(center, east, .east, self.allocator, &sky_queue, &rgb_queue);
        }
        if (component.get(.{ .x = cx, .z = cz - 1 })) |north| {
            try seedChunkInterface(center, north, .north, self.allocator, &sky_queue, &rgb_queue);
        }
        if (component.get(.{ .x = cx, .z = cz + 1 })) |south| {
            try seedChunkInterface(center, south, .south, self.allocator, &sky_queue, &rgb_queue);
        }

        try spreadSkylight(&component, self.allocator, &sky_queue);
        try spreadBlockLight(&component, self.allocator, &rgb_queue);
        markLightingChanged(&component);
        return true;
    }

    pub fn reconcileLegacyArea(self: *WorldLightingEngine, cx: i32, cz: i32) !bool {
        self.storage.lighting_mutex.lock();
        defer self.storage.lighting_mutex.unlock();
        return try self.relightArea(cx, cz, -1, 1, -1, 1);
    }

    pub fn recomputeArea(self: *WorldLightingEngine, center_cx: i32, center_cz: i32, local_x: u32, local_z: u32) !void {
        self.storage.lighting_mutex.lock();
        defer self.storage.lighting_mutex.unlock();

        _ = local_x;
        _ = local_z;
        // Light from a neighboring chunk can reach well into the edited chunk,
        // so reset and reseed the complete local window on every recompute.
        _ = try self.relightArea(center_cx, center_cz, -1, 1, -1, 1);
    }

    pub fn afterBlockRemoval(self: *WorldLightingEngine, center_cx: i32, center_cz: i32, local_x: u32, local_y: u32, local_z: u32) !void {
        self.storage.lighting_mutex.lock();
        defer self.storage.lighting_mutex.unlock();

        const min_dx: i32 = if (local_x == 0) -1 else 0;
        const max_dx: i32 = if (local_x == CHUNK_SIZE_X - 1) 1 else 0;
        const min_dz: i32 = if (local_z == 0) -1 else 0;
        const max_dz: i32 = if (local_z == CHUNK_SIZE_Z - 1) 1 else 0;

        var component = ComponentChunks.init(self.allocator);
        defer component.deinit();
        defer {
            var chunks = component.valueIterator();
            while (chunks.next()) |chunk| chunk.*.unpin();
        }

        if (!try self.pinLoadedArea(&component, center_cx, center_cz, min_dx, max_dx, min_dz, max_dz)) return;

        var sky_queue = std.ArrayListUnmanaged(SkyNode).empty;
        defer sky_queue.deinit(self.allocator);
        var rgb_queue = std.ArrayListUnmanaged(RgbNode).empty;
        defer rgb_queue.deinit(self.allocator);

        try seedSunlightColumn(&component, self.allocator, &sky_queue, center_cx, center_cz, local_x, local_z);
        try seedLightFromNeighbors(&component, self.allocator, &sky_queue, &rgb_queue, center_cx, center_cz, local_x, local_y, local_z);
        try spreadSkylight(&component, self.allocator, &sky_queue);
        try spreadBlockLight(&component, self.allocator, &rgb_queue);
        markLightingChanged(&component);
    }

    fn relightArea(self: *WorldLightingEngine, center_cx: i32, center_cz: i32, min_dx: i32, max_dx: i32, min_dz: i32, max_dz: i32) !bool {
        var component = ComponentChunks.init(self.allocator);
        defer component.deinit();
        defer {
            var chunks = component.valueIterator();
            while (chunks.next()) |chunk| chunk.*.unpin();
        }

        if (!try self.pinLoadedArea(&component, center_cx, center_cz, min_dx, max_dx, min_dz, max_dz)) return false;

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

    fn pinLoadedArea(self: *WorldLightingEngine, component: *ComponentChunks, center_cx: i32, center_cz: i32, min_dx: i32, max_dx: i32, min_dz: i32, max_dz: i32) !bool {
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        const center = self.storage.chunks.get(.{ .x = center_cx, .z = center_cz }) orelse return false;
        if (!center.chunk.generated) return false;

        var dz = min_dz;
        while (dz <= max_dz) : (dz += 1) {
            var dx = min_dx;
            while (dx <= max_dx) : (dx += 1) {
                const key = ChunkKey{ .x = center_cx + dx, .z = center_cz + dz };
                const data = self.storage.chunks.get(key) orelse continue;
                if (!data.chunk.generated) continue;
                try component.put(key, &data.chunk);
                data.chunk.pin();
            }
        }
        return true;
    }
};

const ComponentChunks = std.AutoHashMap(ChunkKey, *Chunk);
const SkyNode = struct { chunk: *Chunk, x: u8, y: u16, z: u8, light: u4 };
const RgbNode = struct { chunk: *Chunk, x: u8, y: u16, z: u8, r: u4, g: u4, b: u4 };
const LoadedStep = struct { cx: i32, cz: i32, x: u32, y: u32, z: u32, chunk: *Chunk };
const ChunkInterface = enum { west, east, north, south };
const VOXEL_NEIGHBOR_OFFSETS = [_][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };

fn resetChunkLighting(chunk: *Chunk) void {
    for (&chunk.light) |*light| light.* = PackedLight.init(0, 0);
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
                try queue.append(allocator, skyNode(chunk, @intCast(x), uy, @intCast(z), sky_light));
                sky_light = block_registry.attenuateVerticalSkylight(sky_light, block);
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
        try queue.append(allocator, rgbNode(chunk, @intCast(x), @intCast(y), @intCast(z), chunk.getLight(@intCast(x), @intCast(y), @intCast(z))));
    };
}

fn seedChunkInterface(center: *Chunk, neighbor: *Chunk, interface: ChunkInterface, allocator: std.mem.Allocator, sky_queue: *std.ArrayListUnmanaged(SkyNode), rgb_queue: *std.ArrayListUnmanaged(RgbNode)) !void {
    for (0..CHUNK_SIZE_X) |horizontal| {
        const h: u32 = @intCast(horizontal);
        const positions = switch (interface) {
            .west => .{ .{ @as(u32, 0), h }, .{ @as(u32, CHUNK_SIZE_X - 1), h } },
            .east => .{ .{ @as(u32, CHUNK_SIZE_X - 1), h }, .{ @as(u32, 0), h } },
            .north => .{ .{ h, @as(u32, 0) }, .{ h, @as(u32, CHUNK_SIZE_Z - 1) } },
            .south => .{ .{ h, @as(u32, CHUNK_SIZE_Z - 1) }, .{ h, @as(u32, 0) } },
        };
        // Saved/player-placed emitters can sit above generated surface heights.
        for (0..CHUNK_SIZE_Y) |y| {
            try seedInterfacePair(center, positions[0][0], @intCast(y), positions[0][1], neighbor, positions[1][0], positions[1][1], allocator, sky_queue, rgb_queue);
        }
    }
}

fn seedInterfacePair(a: *Chunk, ax: u32, y: u32, az: u32, b: *Chunk, bx: u32, bz: u32, allocator: std.mem.Allocator, sky_queue: *std.ArrayListUnmanaged(SkyNode), rgb_queue: *std.ArrayListUnmanaged(RgbNode)) !void {
    const a_light = a.getLight(ax, y, az);
    const b_light = b.getLight(bx, y, bz);

    if (a_light.getSkyLight() > b_light.getSkyLight()) {
        try sky_queue.append(allocator, skyNode(a, ax, y, az, a_light.getSkyLight()));
    } else if (b_light.getSkyLight() > a_light.getSkyLight()) {
        try sky_queue.append(allocator, skyNode(b, bx, y, bz, b_light.getSkyLight()));
    }

    const a_brighter = a_light.getBlockLightR() > b_light.getBlockLightR() or a_light.getBlockLightG() > b_light.getBlockLightG() or a_light.getBlockLightB() > b_light.getBlockLightB();
    const b_brighter = b_light.getBlockLightR() > a_light.getBlockLightR() or b_light.getBlockLightG() > a_light.getBlockLightG() or b_light.getBlockLightB() > a_light.getBlockLightB();
    if (a_brighter) try rgb_queue.append(allocator, rgbNode(a, ax, y, az, a_light));
    if (b_brighter) try rgb_queue.append(allocator, rgbNode(b, bx, y, bz, b_light));
}

fn skyNode(chunk: *Chunk, x: u32, y: u32, z: u32, light: u4) SkyNode {
    return .{ .chunk = chunk, .x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .light = light };
}

fn rgbNode(chunk: *Chunk, x: u32, y: u32, z: u32, light: PackedLight) RgbNode {
    return .{ .chunk = chunk, .x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .r = light.getBlockLightR(), .g = light.getBlockLightG(), .b = light.getBlockLightB() };
}

fn seedSunlightColumn(component: *const ComponentChunks, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(SkyNode), cx: i32, cz: i32, x: u32, z: u32) !void {
    const chunk = component.get(.{ .x = cx, .z = cz }) orelse return;
    var sunlit = true;
    var sky_light: u4 = MAX_LIGHT;
    var y: i32 = CHUNK_SIZE_Y - 1;
    while (y >= 0) : (y -= 1) {
        const uy: u32 = @intCast(y);
        const block = chunk.getBlock(x, uy, z);
        if (sunlit and block_registry.getBlockDefinition(block).isOpaque()) sunlit = false;
        if (!sunlit) continue;
        if (chunk.getSkyLight(x, uy, z) < sky_light) {
            chunk.setSkyLight(x, uy, z, sky_light);
            chunk.dirty = true;
            try queue.append(allocator, skyNode(chunk, x, uy, z, sky_light));
        }
        sky_light = block_registry.attenuateVerticalSkylight(sky_light, block);
    }
}

fn seedLightFromNeighbors(component: *const ComponentChunks, allocator: std.mem.Allocator, sky_queue: *std.ArrayListUnmanaged(SkyNode), block_queue: *std.ArrayListUnmanaged(RgbNode), cx: i32, cz: i32, x: u32, y: u32, z: u32) !void {
    const chunk = component.get(.{ .x = cx, .z = cz }) orelse return;
    if (block_registry.getBlockDefinition(chunk.getBlock(x, y, z)).isOpaque()) return;

    var best_sky = chunk.getSkyLight(x, y, z);
    var best_r = chunk.getLight(x, y, z).getBlockLightR();
    var best_g = chunk.getLight(x, y, z).getBlockLightG();
    var best_b = chunk.getLight(x, y, z).getBlockLightB();

    for (VOXEL_NEIGHBOR_OFFSETS) |offset| {
        const pos = stepLoadedPos(component, chunk, @intCast(x), @intCast(y), @intCast(z), offset) orelse continue;
        const light = pos.chunk.getLight(pos.x, pos.y, pos.z);
        best_sky = @max(best_sky, if (light.getSkyLight() > 1) light.getSkyLight() - 1 else 0);
        best_r = @max(best_r, if (light.getBlockLightR() > 1) light.getBlockLightR() - 1 else 0);
        best_g = @max(best_g, if (light.getBlockLightG() > 1) light.getBlockLightG() - 1 else 0);
        best_b = @max(best_b, if (light.getBlockLightB() > 1) light.getBlockLightB() - 1 else 0);
    }

    if (best_sky > chunk.getSkyLight(x, y, z)) {
        chunk.setSkyLight(x, y, z, best_sky);
        chunk.dirty = true;
        try sky_queue.append(allocator, skyNode(chunk, x, y, z, best_sky));
    }

    const current = chunk.getLight(x, y, z);
    if (best_r > current.getBlockLightR() or best_g > current.getBlockLightG() or best_b > current.getBlockLightB()) {
        chunk.setBlockLightRGB(x, y, z, best_r, best_g, best_b);
        chunk.dirty = true;
        try block_queue.append(allocator, rgbNode(chunk, x, y, z, chunk.getLight(x, y, z)));
    }
}

fn markLightingChanged(component: *ComponentChunks) void {
    var chunks = component.valueIterator();
    while (chunks.next()) |chunk| {
        if (chunk.*.dirty) chunk.*.markLightChanged();
    }
}

fn spreadSkylight(component: *const ComponentChunks, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(SkyNode)) !void {
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];
        if (node.light <= 1) continue;
        for (VOXEL_NEIGHBOR_OFFSETS) |offset| {
            const pos = stepLoadedPos(component, node.chunk, node.x, node.y, node.z, offset) orelse continue;
            const block = pos.chunk.getBlock(pos.x, pos.y, pos.z);
            if (block_registry.getBlockDefinition(block).isOpaque()) continue;
            const attenuation = block_registry.lightAttenuation(block);
            const next_light: u4 = if (node.light > attenuation) node.light - attenuation else 0;
            if (next_light <= pos.chunk.getSkyLight(pos.x, pos.y, pos.z)) continue;
            pos.chunk.setSkyLight(pos.x, pos.y, pos.z, next_light);
            pos.chunk.dirty = true;
            try queue.append(allocator, skyNode(pos.chunk, pos.x, pos.y, pos.z, next_light));
        }
    }
}

fn spreadBlockLight(component: *const ComponentChunks, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(RgbNode)) !void {
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];
        for (VOXEL_NEIGHBOR_OFFSETS) |offset| {
            const pos = stepLoadedPos(component, node.chunk, node.x, node.y, node.z, offset) orelse continue;
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
            try queue.append(allocator, rgbNode(pos.chunk, pos.x, pos.y, pos.z, pos.chunk.getLight(pos.x, pos.y, pos.z)));
        }
    }
}

fn stepLoadedPos(component: *const ComponentChunks, current_chunk: *Chunk, x: u8, y: u16, z: u8, offset: [3]i32) ?LoadedStep {
    var ncx = current_chunk.chunk_x;
    var ncz = current_chunk.chunk_z;
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
    const chunk = if (ncx == current_chunk.chunk_x and ncz == current_chunk.chunk_z)
        current_chunk
    else
        component.get(.{ .x = ncx, .z = ncz }) orelse return null;
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
    center.chunk.setBlock(CHUNK_SIZE_X - 1, 200, 1, .torch);
    center.chunk.setBlockLightRGB(CHUNK_SIZE_X - 1, 200, 1, 15, 11, 6);
    var lighting = WorldLightingEngine.init(&storage, testing.allocator);
    _ = try lighting.reconcileChunkArrival(0, 0);
    try testing.expect(east.chunk.getLight(2, 200, 1).getBlockLightR() > 0);
}

test "WorldLightingEngine removes stale light across an affected chunk boundary" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();
    const center = try storage.getOrCreate(0, 0);
    const east = try storage.getOrCreate(1, 0);
    center.chunk.generated = true;
    east.chunk.generated = true;
    center.chunk.setBlock(CHUNK_SIZE_X - 1, 4, 1, .torch);
    var lighting = WorldLightingEngine.init(&storage, testing.allocator);
    try lighting.recomputeArea(0, 0, CHUNK_SIZE_X - 1, 1);
    try testing.expect(east.chunk.getLight(2, 4, 1).getBlockLightR() > 0);
    center.chunk.setBlock(CHUNK_SIZE_X - 1, 4, 1, .air);
    try lighting.recomputeArea(0, 0, CHUNK_SIZE_X - 1, 1);
    try testing.expectEqual(@as(u4, 0), east.chunk.getLight(2, 4, 1).getBlockLightR());
}

test "WorldLightingEngine keeps unaffected chunks out of local recomputes" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const center = try storage.getOrCreate(0, 0);
    const distant = try storage.getOrCreate(2, 0);
    center.chunk.generated = true;
    distant.chunk.generated = true;
    distant.chunk.setLight(1, 1, 1, PackedLight.init(0, 13));

    var lighting = WorldLightingEngine.init(&storage, testing.allocator);
    try lighting.recomputeArea(0, 0, 4, 4);

    try testing.expect(!distant.chunk.lighting_valid);
    try testing.expectEqual(@as(u4, 13), distant.chunk.getLight(1, 1, 1).getBlockLightR());
}

test "WorldLightingEngine preserves neighbor light during interior recompute" {
    const testing = std.testing;
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const center = try storage.getOrCreate(0, 0);
    const east = try storage.getOrCreate(1, 0);
    center.chunk.generated = true;
    east.chunk.generated = true;
    east.chunk.setBlock(0, 4, 1, .torch);

    var lighting = WorldLightingEngine.init(&storage, testing.allocator);
    try lighting.recomputeArea(0, 0, 4, 4);

    try testing.expect(center.chunk.getLight(CHUNK_SIZE_X - 2, 4, 1).getBlockLightR() > 0);
}
