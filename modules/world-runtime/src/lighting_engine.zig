//! Loaded-chunk lighting propagation for runtime block mutations.

const std = @import("std");
const world_core = @import("world-core");
const BlockType = world_core.BlockType;
const Chunk = world_core.Chunk;
const PackedLight = world_core.PackedLight;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const MAX_LIGHT = world_core.MAX_LIGHT;
const block_registry = world_core.block_registry;
const ChunkStorage = @import("world-meshing").ChunkStorage;

pub const LightingEngine = struct {
    storage: *ChunkStorage,
    allocator: std.mem.Allocator,

    pub fn init(storage: *ChunkStorage, allocator: std.mem.Allocator) LightingEngine {
        return .{ .storage = storage, .allocator = allocator };
    }

    pub fn recomputeArea(self: *LightingEngine, center_cx: i32, center_cz: i32, local_x: u32, local_z: u32) !void {
        var skylight_queue = std.ArrayListUnmanaged(LightPos).empty;
        defer skylight_queue.deinit(self.allocator);

        var blocklight_queue = std.ArrayListUnmanaged(RgbLightPos).empty;
        defer blocklight_queue.deinit(self.allocator);

        const min_dx: i32 = if (local_x == 0) -1 else 0;
        const max_dx: i32 = if (local_x == CHUNK_SIZE_X - 1) 1 else 0;
        const min_dz: i32 = if (local_z == 0) -1 else 0;
        const max_dz: i32 = if (local_z == CHUNK_SIZE_Z - 1) 1 else 0;

        var dz: i32 = min_dz;
        while (dz <= max_dz) : (dz += 1) {
            var dx: i32 = min_dx;
            while (dx <= max_dx) : (dx += 1) {
                if (self.storage.get(center_cx + dx, center_cz + dz)) |data| {
                    resetChunkLighting(&data.chunk);
                    try seedChunkSunlight(&data.chunk, self.allocator, &skylight_queue);
                    try seedChunkBlockLight(&data.chunk, self.allocator, &blocklight_queue);
                    data.chunk.dirty = true;
                }
            }
        }

        try spreadSkylight(self.storage, self.allocator, center_cx, center_cz, min_dx, max_dx, min_dz, max_dz, &skylight_queue);
        try spreadBlockLight(self.storage, self.allocator, center_cx, center_cz, min_dx, max_dx, min_dz, max_dz, &blocklight_queue);
    }

    pub fn afterBlockRemoval(self: *LightingEngine, center_cx: i32, center_cz: i32, local_x: u32, local_y: u32, local_z: u32) !void {
        const data = self.storage.get(center_cx, center_cz) orelse return;

        var skylight_queue = std.ArrayListUnmanaged(LightPos).empty;
        defer skylight_queue.deinit(self.allocator);

        var blocklight_queue = std.ArrayListUnmanaged(RgbLightPos).empty;
        defer blocklight_queue.deinit(self.allocator);

        try seedSunlightColumn(&data.chunk, self.allocator, &skylight_queue, local_x, local_z);
        try seedLightFromNeighbors(self.storage, self.allocator, &skylight_queue, &blocklight_queue, center_cx, center_cz, local_x, local_y, local_z);

        const min_dx: i32 = if (local_x == 0) -1 else 0;
        const max_dx: i32 = if (local_x == CHUNK_SIZE_X - 1) 1 else 0;
        const min_dz: i32 = if (local_z == 0) -1 else 0;
        const max_dz: i32 = if (local_z == CHUNK_SIZE_Z - 1) 1 else 0;

        try spreadSkylight(self.storage, self.allocator, center_cx, center_cz, min_dx, max_dx, min_dz, max_dz, &skylight_queue);
        try spreadBlockLight(self.storage, self.allocator, center_cx, center_cz, min_dx, max_dx, min_dz, max_dz, &blocklight_queue);
    }
};

const LightPos = struct {
    cx: i32,
    cz: i32,
    x: u8,
    y: u16,
    z: u8,
    light: u4,
};

const RgbLightPos = struct {
    cx: i32,
    cz: i32,
    x: u8,
    y: u16,
    z: u8,
    r: u4,
    g: u4,
    b: u4,
};

fn resetChunkLighting(chunk: *Chunk) void {
    for (&chunk.light) |*light| {
        light.* = PackedLight.init(0, 0);
    }
    for (&chunk.entrance_bounce) |*bounce| {
        bounce.* = 0;
    }
    for (&chunk.entrance_dir) |*dir| {
        dir.* = world_core.packEntranceDir(0, 0);
    }
}

fn seedChunkSunlight(chunk: *Chunk, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(LightPos)) !void {
    var z: u32 = 0;
    while (z < CHUNK_SIZE_Z) : (z += 1) {
        var x: u32 = 0;
        while (x < CHUNK_SIZE_X) : (x += 1) {
            var sunlit = true;
            var y: i32 = CHUNK_SIZE_Y - 1;
            while (y >= 0) : (y -= 1) {
                const uy: u32 = @intCast(y);
                const block = chunk.getBlock(x, uy, z);
                const def = block_registry.getBlockDefinition(block);
                if (sunlit and def.isOpaque()) sunlit = false;

                if (sunlit) {
                    chunk.setSkyLight(x, uy, z, MAX_LIGHT);
                    try queue.append(allocator, .{ .cx = chunk.chunk_x, .cz = chunk.chunk_z, .x = @intCast(x), .y = @intCast(uy), .z = @intCast(z), .light = MAX_LIGHT });
                }
            }
        }
    }
}

fn seedChunkBlockLight(chunk: *Chunk, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(RgbLightPos)) !void {
    var z: u32 = 0;
    while (z < CHUNK_SIZE_Z) : (z += 1) {
        var y: u32 = 0;
        while (y < CHUNK_SIZE_Y) : (y += 1) {
            var x: u32 = 0;
            while (x < CHUNK_SIZE_X) : (x += 1) {
                const block = chunk.getBlock(x, y, z);
                const emission = block_registry.getBlockDefinition(block).light_emission;
                if (emission[0] == 0 and emission[1] == 0 and emission[2] == 0) continue;

                chunk.setBlockLightRGB(x, y, z, emission[0], emission[1], emission[2]);
                try queue.append(allocator, .{ .cx = chunk.chunk_x, .cz = chunk.chunk_z, .x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .r = emission[0], .g = emission[1], .b = emission[2] });
            }
        }
    }
}

fn seedSunlightColumn(chunk: *Chunk, allocator: std.mem.Allocator, queue: *std.ArrayListUnmanaged(LightPos), x: u32, z: u32) !void {
    var sunlit = true;
    var y: i32 = CHUNK_SIZE_Y - 1;
    while (y >= 0) : (y -= 1) {
        const uy: u32 = @intCast(y);
        const block = chunk.getBlock(x, uy, z);
        if (sunlit and block_registry.getBlockDefinition(block).isOpaque()) sunlit = false;
        if (!sunlit) continue;
        if (chunk.getSkyLight(x, uy, z) >= MAX_LIGHT) continue;

        chunk.setSkyLight(x, uy, z, MAX_LIGHT);
        chunk.dirty = true;
        try queue.append(allocator, .{ .cx = chunk.chunk_x, .cz = chunk.chunk_z, .x = @intCast(x), .y = @intCast(uy), .z = @intCast(z), .light = MAX_LIGHT });
    }
}

fn seedLightFromNeighbors(storage: *ChunkStorage, allocator: std.mem.Allocator, sky_queue: *std.ArrayListUnmanaged(LightPos), block_queue: *std.ArrayListUnmanaged(RgbLightPos), cx: i32, cz: i32, x: u32, y: u32, z: u32) !void {
    const data = storage.get(cx, cz) orelse return;
    if (block_registry.getBlockDefinition(data.chunk.getBlock(x, y, z)).isOpaque()) return;

    const neighbors = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
    var best_sky: u4 = data.chunk.getSkyLight(x, y, z);
    var best_r: u4 = data.chunk.getLight(x, y, z).getBlockLightR();
    var best_g: u4 = data.chunk.getLight(x, y, z).getBlockLightG();
    var best_b: u4 = data.chunk.getLight(x, y, z).getBlockLightB();

    for (neighbors) |offset| {
        const pos = stepLoadedPos(storage, cx, cz, @intCast(x), @intCast(y), @intCast(z), offset) orelse continue;
        const light = pos.chunk.getLight(pos.x, pos.y, pos.z);
        best_sky = @max(best_sky, if (light.getSkyLight() > 1) light.getSkyLight() - 1 else 0);
        best_r = @max(best_r, if (light.getBlockLightR() > 1) light.getBlockLightR() - 1 else 0);
        best_g = @max(best_g, if (light.getBlockLightG() > 1) light.getBlockLightG() - 1 else 0);
        best_b = @max(best_b, if (light.getBlockLightB() > 1) light.getBlockLightB() - 1 else 0);
    }

    if (best_sky > data.chunk.getSkyLight(x, y, z)) {
        data.chunk.setSkyLight(x, y, z, best_sky);
        data.chunk.dirty = true;
        try sky_queue.append(allocator, .{ .cx = cx, .cz = cz, .x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .light = best_sky });
    }

    const current = data.chunk.getLight(x, y, z);
    if (best_r > current.getBlockLightR() or best_g > current.getBlockLightG() or best_b > current.getBlockLightB()) {
        data.chunk.setBlockLightRGB(x, y, z, best_r, best_g, best_b);
        data.chunk.dirty = true;
        try block_queue.append(allocator, .{ .cx = cx, .cz = cz, .x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .r = best_r, .g = best_g, .b = best_b });
    }
}

fn spreadSkylight(storage: *ChunkStorage, allocator: std.mem.Allocator, center_cx: i32, center_cz: i32, min_dx: i32, max_dx: i32, min_dz: i32, max_dz: i32, queue: *std.ArrayListUnmanaged(LightPos)) !void {
    const neighbors = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];
        if (node.light <= 1) continue;

        for (neighbors) |offset| {
            const pos = stepLoadedPos(storage, node.cx, node.cz, node.x, node.y, node.z, offset) orelse continue;
            if (!isInRecomputeArea(center_cx, center_cz, min_dx, max_dx, min_dz, max_dz, pos.cx, pos.cz)) continue;
            const chunk = pos.chunk;
            const block = chunk.getBlock(pos.x, pos.y, pos.z);
            if (block_registry.getBlockDefinition(block).isOpaque()) continue;

            const attenuation: u4 = if (block == .water) 2 else 1;
            const next_light: u4 = if (node.light > attenuation) node.light - attenuation else 0;
            if (next_light <= chunk.getSkyLight(pos.x, pos.y, pos.z)) continue;

            chunk.setSkyLight(pos.x, pos.y, pos.z, next_light);
            chunk.dirty = true;
            try queue.append(allocator, .{ .cx = pos.cx, .cz = pos.cz, .x = @intCast(pos.x), .y = @intCast(pos.y), .z = @intCast(pos.z), .light = next_light });
        }
    }
}

fn spreadBlockLight(storage: *ChunkStorage, allocator: std.mem.Allocator, center_cx: i32, center_cz: i32, min_dx: i32, max_dx: i32, min_dz: i32, max_dz: i32, queue: *std.ArrayListUnmanaged(RgbLightPos)) !void {
    const neighbors = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];

        for (neighbors) |offset| {
            const pos = stepLoadedPos(storage, node.cx, node.cz, node.x, node.y, node.z, offset) orelse continue;
            if (!isInRecomputeArea(center_cx, center_cz, min_dx, max_dx, min_dz, max_dz, pos.cx, pos.cz)) continue;
            const chunk = pos.chunk;
            const block = chunk.getBlock(pos.x, pos.y, pos.z);
            if (block_registry.getBlockDefinition(block).isOpaque()) continue;

            const current = chunk.getLight(pos.x, pos.y, pos.z);
            const next_r: u4 = if (node.r > 1) node.r - 1 else 0;
            const next_g: u4 = if (node.g > 1) node.g - 1 else 0;
            const next_b: u4 = if (node.b > 1) node.b - 1 else 0;

            if (next_r <= current.getBlockLightR() and next_g <= current.getBlockLightG() and next_b <= current.getBlockLightB()) continue;

            const new_r = @max(next_r, current.getBlockLightR());
            const new_g = @max(next_g, current.getBlockLightG());
            const new_b = @max(next_b, current.getBlockLightB());
            chunk.setBlockLightRGB(pos.x, pos.y, pos.z, new_r, new_g, new_b);
            chunk.dirty = true;
            try queue.append(allocator, .{ .cx = pos.cx, .cz = pos.cz, .x = @intCast(pos.x), .y = @intCast(pos.y), .z = @intCast(pos.z), .r = new_r, .g = new_g, .b = new_b });
        }
    }
}

const LoadedStep = struct {
    cx: i32,
    cz: i32,
    x: u32,
    y: u32,
    z: u32,
    chunk: *Chunk,
};

fn stepLoadedPos(storage: *ChunkStorage, cx: i32, cz: i32, x: u8, y: u16, z: u8, offset: [3]i32) ?LoadedStep {
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

    const data = storage.get(ncx, ncz) orelse return null;
    return .{ .cx = ncx, .cz = ncz, .x = @intCast(nx), .y = @intCast(ny), .z = @intCast(nz), .chunk = &data.chunk };
}

fn isInRecomputeArea(center_cx: i32, center_cz: i32, min_dx: i32, max_dx: i32, min_dz: i32, max_dz: i32, cx: i32, cz: i32) bool {
    const dx = cx - center_cx;
    const dz = cz - center_cz;
    return dx >= min_dx and dx <= max_dx and dz >= min_dz and dz <= max_dz;
}

test "LightingEngine recomputeArea seeds skylight and block light" {
    const testing = std.testing;

    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data = try storage.getOrCreate(0, 0);
    for (0..CHUNK_SIZE_Z) |z| {
        for (0..CHUNK_SIZE_X) |x| {
            data.chunk.setBlock(@intCast(x), 5, @intCast(z), .stone);
        }
    }
    data.chunk.setBlock(4, 4, 4, .torch);

    var lighting = LightingEngine.init(&storage, testing.allocator);
    try lighting.recomputeArea(0, 0, 4, 4);

    try testing.expectEqual(@as(u4, MAX_LIGHT), data.chunk.getSkyLight(4, 6, 4));
    try testing.expectEqual(@as(u4, 0), data.chunk.getSkyLight(4, 4, 4));
    try testing.expect(data.chunk.getLight(5, 4, 4).getBlockLightR() > 0);
}

test "LightingEngine afterBlockRemoval seeds from lit neighbors" {
    const testing = std.testing;

    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const data = try storage.getOrCreate(0, 0);
    data.chunk.setSkyLight(4, 4, 1, MAX_LIGHT);

    var lighting = LightingEngine.init(&storage, testing.allocator);
    try lighting.afterBlockRemoval(0, 0, 5, 4, 1);

    try testing.expectEqual(@as(u4, MAX_LIGHT - 1), data.chunk.getSkyLight(5, 4, 1));
}
