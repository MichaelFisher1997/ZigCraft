const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const MAX_LIGHT = world_core.MAX_LIGHT;
const block_registry = world_core.block_registry;
const ILightingSystem = @import("lighting_interface.zig").ILightingSystem;

const interface_token: u8 = 0;

pub const LightingComputer = struct {
    const LightNode = struct {
        x: u8,
        y: u16,
        z: u8,
        r: u4,
        g: u4,
        b: u4,
    };

    const SkyNode = struct {
        x: u8,
        y: u16,
        z: u8,
        light: u4,
    };

    pub fn interface() ILightingSystem {
        return .{ .ptr = &interface_token, .vtable = &INTERFACE_VTABLE };
    }

    pub fn computeSkylight(chunk: *Chunk, allocator: std.mem.Allocator) !void {
        for (&chunk.light) |*light| light.setSkyLight(0);

        var queue = std.ArrayListUnmanaged(SkyNode).empty;
        defer queue.deinit(allocator);

        for (0..CHUNK_SIZE_Z) |z| {
            for (0..CHUNK_SIZE_X) |x| {
                var sky_light: u4 = MAX_LIGHT;
                var y: i32 = CHUNK_SIZE_Y - 1;
                while (y >= 0) : (y -= 1) {
                    const uy: u32 = @intCast(y);
                    const block = chunk.getBlock(@intCast(x), uy, @intCast(z));
                    if (block_registry.getBlockDefinition(block).isOpaque()) {
                        chunk.setSkyLight(@intCast(x), uy, @intCast(z), 0);
                        sky_light = 0;
                        continue;
                    }
                    chunk.setSkyLight(@intCast(x), uy, @intCast(z), sky_light);
                    if (sky_light > 0) try queue.append(allocator, .{ .x = @intCast(x), .y = @intCast(uy), .z = @intCast(z), .light = sky_light });
                    sky_light = block_registry.attenuateVerticalSkylight(sky_light, block);
                }
            }
        }

        const neighbors = [5][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 }, .{ 0, -1, 0 } };
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const node = queue.items[head];
            if (node.light <= 1) continue;
            for (neighbors) |offset| {
                const nx = @as(i32, node.x) + offset[0];
                const ny = @as(i32, node.y) + offset[1];
                const nz = @as(i32, node.z) + offset[2];
                if (nx < 0 or nx >= CHUNK_SIZE_X or ny < 0 or ny >= CHUNK_SIZE_Y or nz < 0 or nz >= CHUNK_SIZE_Z) continue;
                const ux: u32 = @intCast(nx);
                const uy: u32 = @intCast(ny);
                const uz: u32 = @intCast(nz);
                const block = chunk.getBlock(ux, uy, uz);
                if (block_registry.getBlockDefinition(block).isOpaque()) continue;
                const attenuation = block_registry.lightAttenuation(block);
                const next_light: u4 = if (node.light > attenuation) node.light - attenuation else 0;
                if (next_light <= chunk.getSkyLight(ux, uy, uz)) continue;
                chunk.setSkyLight(ux, uy, uz, next_light);
                try queue.append(allocator, .{ .x = @intCast(ux), .y = @intCast(uy), .z = @intCast(uz), .light = next_light });
            }
        }
    }

    pub fn computeBlockLight(chunk: *Chunk, allocator: std.mem.Allocator) !void {
        for (&chunk.light) |*light| light.setBlockLightRGB(0, 0, 0);

        var queue = std.ArrayListUnmanaged(LightNode).empty;
        defer queue.deinit(allocator);
        for (0..CHUNK_SIZE_Z) |z| for (0..CHUNK_SIZE_Y) |y| for (0..CHUNK_SIZE_X) |x| {
            const block = chunk.getBlock(@intCast(x), @intCast(y), @intCast(z));
            const emission = block_registry.getBlockDefinition(block).light_emission;
            if (emission[0] == 0 and emission[1] == 0 and emission[2] == 0) continue;
            chunk.setBlockLightRGB(@intCast(x), @intCast(y), @intCast(z), emission[0], emission[1], emission[2]);
            try queue.append(allocator, .{ .x = @intCast(x), .y = @intCast(y), .z = @intCast(z), .r = emission[0], .g = emission[1], .b = emission[2] });
        };

        const neighbors = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const node = queue.items[head];
            for (neighbors) |offset| {
                const nx = @as(i32, node.x) + offset[0];
                const ny = @as(i32, node.y) + offset[1];
                const nz = @as(i32, node.z) + offset[2];
                if (nx < 0 or nx >= CHUNK_SIZE_X or ny < 0 or ny >= CHUNK_SIZE_Y or nz < 0 or nz >= CHUNK_SIZE_Z) continue;
                const ux: u32 = @intCast(nx);
                const uy: u32 = @intCast(ny);
                const uz: u32 = @intCast(nz);
                if (block_registry.getBlockDefinition(chunk.getBlock(ux, uy, uz)).isOpaque()) continue;
                const current = chunk.getLight(ux, uy, uz);
                const r: u4 = @max(if (node.r > 1) node.r - 1 else 0, current.getBlockLightR());
                const g: u4 = @max(if (node.g > 1) node.g - 1 else 0, current.getBlockLightG());
                const b: u4 = @max(if (node.b > 1) node.b - 1 else 0, current.getBlockLightB());
                if (r == current.getBlockLightR() and g == current.getBlockLightG() and b == current.getBlockLightB()) continue;
                chunk.setBlockLightRGB(ux, uy, uz, r, g, b);
                try queue.append(allocator, .{ .x = @intCast(ux), .y = @intCast(uy), .z = @intCast(uz), .r = r, .g = g, .b = b });
            }
        }
    }
};

const INTERFACE_VTABLE = ILightingSystem.VTable{
    .computeSkylight = interfaceComputeSkylight,
    .computeBlockLight = interfaceComputeBlockLight,
};

fn interfaceComputeSkylight(ptr: *anyopaque, chunk: *Chunk, allocator: std.mem.Allocator) !void {
    _ = ptr;
    try LightingComputer.computeSkylight(chunk, allocator);
}

fn interfaceComputeBlockLight(ptr: *anyopaque, chunk: *Chunk, allocator: std.mem.Allocator) !void {
    _ = ptr;
    try LightingComputer.computeBlockLight(chunk, allocator);
}

test "computeSkylight preserves full light in open columns" {
    var chunk = Chunk.init(0, 0);
    try LightingComputer.computeSkylight(&chunk, std.testing.allocator);
    try std.testing.expectEqual(@as(u4, MAX_LIGHT), chunk.getSkyLight(8, 255, 8));
    try std.testing.expectEqual(@as(u4, MAX_LIGHT), chunk.getSkyLight(8, 64, 8));
}

test "computeSkylight propagates sideways from an open shaft" {
    var chunk = Chunk.init(0, 0);
    for (0..CHUNK_SIZE_Z) |z| for (0..CHUNK_SIZE_X) |x| chunk.setBlock(@intCast(x), 4, @intCast(z), .stone);
    chunk.setBlock(8, 4, 8, .air);
    try LightingComputer.computeSkylight(&chunk, std.testing.allocator);
    try std.testing.expectEqual(@as(u4, MAX_LIGHT), chunk.getSkyLight(8, 3, 8));
    try std.testing.expect(chunk.getSkyLight(9, 3, 8) > 0);
}
