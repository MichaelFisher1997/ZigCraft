const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const MAX_LIGHT = world_core.MAX_LIGHT;
const packEntranceDir = world_core.packEntranceDir;
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

    const EntranceNode = struct {
        x: u8,
        y: u16,
        z: u8,
        light: u4,
        dir_x: i4,
        dir_z: i4,
    };

    const EntranceSource = struct {
        sky: u4,
        dir_x: i4,
        dir_z: i4,
    };

    const ENTRANCE_SOURCE_SKY_OFFSET: u32 = 0;
    const ENTRANCE_MAX_SEED: u32 = 15;
    const ENTRANCE_MIN_EDGE_CONTRAST: u4 = 1;
    const ENTRANCE_PORTAL_SEED_SKY: u4 = 15;
    const ENTRANCE_PORTAL_PROBE_STEPS = 3;

    pub fn interface() ILightingSystem {
        // LightingComputer is stateless; the interface pointer is a stable token
        // used only to satisfy the shared interface shape.
        return .{ .ptr = &interface_token, .vtable = &INTERFACE_VTABLE };
    }

    pub fn computeSkylight(chunk: *Chunk, allocator: std.mem.Allocator) !void {
        for (&chunk.light) |*light| {
            light.setSkyLight(0);
        }

        var queue = std.ArrayListUnmanaged(SkyNode).empty;
        defer queue.deinit(allocator);

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                var sky_light: u4 = MAX_LIGHT;
                var y: i32 = CHUNK_SIZE_Y - 1;
                while (y >= 0) : (y -= 1) {
                    const uy: u32 = @intCast(y);
                    const block = chunk.getBlock(local_x, uy, local_z);
                    if (block_registry.getBlockDefinition(block).isOpaque()) {
                        chunk.setSkyLight(local_x, uy, local_z, 0);
                        sky_light = 0;
                        continue;
                    }

                    chunk.setSkyLight(local_x, uy, local_z, sky_light);
                    if (sky_light > 0) {
                        try queue.append(allocator, .{
                            .x = @intCast(local_x),
                            .y = @intCast(uy),
                            .z = @intCast(local_z),
                            .light = sky_light,
                        });
                    }

                    const attenuation = block_registry.lightAttenuation(block);
                    if (attenuation > 1) {
                        sky_light = if (sky_light > attenuation) sky_light - attenuation else 0;
                    }
                }
            }
        }

        const propagation_neighbors = [5][3]i32{
            .{ 1, 0, 0 },
            .{ -1, 0, 0 },
            .{ 0, 0, 1 },
            .{ 0, 0, -1 },
            .{ 0, -1, 0 },
        };

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const node = queue.items[head];
            if (node.light <= 1) continue;

            for (propagation_neighbors) |offset| {
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
                try queue.append(allocator, .{
                    .x = @intCast(ux),
                    .y = @intCast(uy),
                    .z = @intCast(uz),
                    .light = next_light,
                });
            }
        }

        try computeEntranceBounce(chunk, allocator);
    }

    fn computeEntranceBounce(chunk: *Chunk, allocator: std.mem.Allocator) !void {
        for (&chunk.entrance_bounce) |*bounce| {
            bounce.* = 0;
        }
        for (&chunk.entrance_dir) |*dir| {
            dir.* = packEntranceDir(0, 0);
        }

        var queue = std.ArrayListUnmanaged(EntranceNode).empty;
        defer queue.deinit(allocator);

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                var covered = false;
                var y: i32 = CHUNK_SIZE_Y - 1;
                while (y >= 0) : (y -= 1) {
                    const uy: u32 = @intCast(y);
                    const block = chunk.getBlock(local_x, uy, local_z);
                    if (block_registry.getBlockDefinition(block).isOpaque()) {
                        covered = true;
                        continue;
                    }

                    if (!covered and !touchesOpaqueNeighbor(chunk, local_x, uy, local_z)) continue;

                    const sky = chunk.getSkyLight(local_x, uy, local_z);
                    if (sky >= MAX_LIGHT) continue;
                    const source = entranceSourceSky(chunk, local_x, uy, local_z, sky) orelse continue;

                    const seed: u4 = @intCast(@min(ENTRANCE_MAX_SEED, @max(@as(u32, sky), @as(u32, source.sky)) - ENTRANCE_SOURCE_SKY_OFFSET));
                    chunk.setEntranceBounce(local_x, uy, local_z, seed);
                    chunk.setEntranceDir(local_x, uy, local_z, packEntranceDir(source.dir_x, source.dir_z));
                    try queue.append(allocator, .{ .x = @intCast(local_x), .y = @intCast(uy), .z = @intCast(local_z), .light = seed, .dir_x = source.dir_x, .dir_z = source.dir_z });
                }
            }
        }

        const neighbors = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
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

                const offset_x = offset[0];
                const offset_z = offset[2];
                const away_from_aperture = offset[1] == 0 and offset_x == -@as(i32, node.dir_x) and offset_z == -@as(i32, node.dir_z);
                const toward_aperture = offset[1] == 0 and offset_x == @as(i32, node.dir_x) and offset_z == @as(i32, node.dir_z);
                const horizontal_turn = offset[1] == 0 and !away_from_aperture and !toward_aperture;
                const attenuation: u4 = if (away_from_aperture)
                    1
                else if (horizontal_turn)
                    2
                else if (toward_aperture)
                    4
                else
                    3;
                if (node.light <= attenuation) continue;

                const next_light: u4 = node.light - attenuation;
                if (next_light == 0) continue;
                if (next_light <= chunk.getEntranceBounce(ux, uy, uz)) continue;

                chunk.setEntranceBounce(ux, uy, uz, next_light);
                chunk.setEntranceDir(ux, uy, uz, packEntranceDir(node.dir_x, node.dir_z));
                try queue.append(allocator, .{ .x = @intCast(ux), .y = @intCast(uy), .z = @intCast(uz), .light = next_light, .dir_x = node.dir_x, .dir_z = node.dir_z });
            }
        }
    }

    fn touchesOpaqueNeighbor(chunk: *const Chunk, x: u32, y: u32, z: u32) bool {
        const neighbors = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
        for (neighbors) |offset| {
            const nx = @as(i32, @intCast(x)) + offset[0];
            const ny = @as(i32, @intCast(y)) + offset[1];
            const nz = @as(i32, @intCast(z)) + offset[2];
            if (nx < 0 or nx >= CHUNK_SIZE_X or ny < 0 or ny >= CHUNK_SIZE_Y or nz < 0 or nz >= CHUNK_SIZE_Z) continue;

            const block = chunk.getBlock(@intCast(nx), @intCast(ny), @intCast(nz));
            if (block_registry.getBlockDefinition(block).isOpaque()) return true;
        }
        return false;
    }

    fn entranceSourceSky(chunk: *const Chunk, x: u32, y: u32, z: u32, sky: u4) ?EntranceSource {
        const neighbors = [4][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
        var source_sky: u4 = 0;
        var source_dir_x: i4 = 0;
        var source_dir_z: i4 = 0;
        for (neighbors) |offset| {
            var step: i32 = 1;
            while (step <= ENTRANCE_PORTAL_PROBE_STEPS) : (step += 1) {
                const nx = @as(i32, @intCast(x)) + offset[0] * step;
                const ny = @as(i32, @intCast(y));
                const nz = @as(i32, @intCast(z)) + offset[2] * step;
                if (nx < 0 or nx >= CHUNK_SIZE_X or nz < 0 or nz >= CHUNK_SIZE_Z) {
                    if (sky >= 6) {
                        const candidate_sky = @max(sky, ENTRANCE_PORTAL_SEED_SKY);
                        if (candidate_sky > source_sky) {
                            source_sky = candidate_sky;
                            source_dir_x = @intCast(offset[0]);
                            source_dir_z = @intCast(offset[2]);
                        }
                    }
                    break;
                }
                if (ny < 0 or ny >= CHUNK_SIZE_Y) break;

                const neighbor_block = chunk.getBlock(@intCast(nx), @intCast(ny), @intCast(nz));
                if (block_registry.getBlockDefinition(neighbor_block).isOpaque()) break;

                const neighbor_sky = chunk.getSkyLight(@intCast(nx), @intCast(ny), @intCast(nz));
                if (neighbor_sky >= sky + ENTRANCE_MIN_EDGE_CONTRAST or !isCoveredByColumn(chunk, @intCast(nx), @intCast(ny), @intCast(nz))) {
                    const candidate_sky = @max(neighbor_sky, ENTRANCE_PORTAL_SEED_SKY);
                    if (candidate_sky > source_sky) {
                        source_sky = candidate_sky;
                        source_dir_x = @intCast(offset[0]);
                        source_dir_z = @intCast(offset[2]);
                    }
                    break;
                }
            }
        }
        return if (source_sky > sky) .{ .sky = source_sky, .dir_x = source_dir_x, .dir_z = source_dir_z } else null;
    }

    fn isCoveredByColumn(chunk: *const Chunk, x: u32, y: u32, z: u32) bool {
        var yy = y + 1;
        while (yy < CHUNK_SIZE_Y) : (yy += 1) {
            const block = chunk.getBlock(x, yy, z);
            if (block_registry.getBlockDefinition(block).isOpaque()) return true;
        }
        return false;
    }

    pub fn computeBlockLight(chunk: *Chunk, allocator: std.mem.Allocator) !void {
        for (&chunk.light) |*light| {
            light.setBlockLightRGB(0, 0, 0);
        }

        var queue = std.ArrayListUnmanaged(LightNode).empty;
        defer queue.deinit(allocator);
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var y: u32 = 0;
            while (y < CHUNK_SIZE_Y) : (y += 1) {
                var local_x: u32 = 0;
                while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                    const block = chunk.getBlock(local_x, y, local_z);
                    const emission = block_registry.getBlockDefinition(block).light_emission;
                    if (emission[0] > 0 or emission[1] > 0 or emission[2] > 0) {
                        chunk.setBlockLightRGB(local_x, y, local_z, emission[0], emission[1], emission[2]);
                        try queue.append(allocator, .{
                            .x = @intCast(local_x),
                            .y = @intCast(y),
                            .z = @intCast(local_z),
                            .r = emission[0],
                            .g = emission[1],
                            .b = emission[2],
                        });
                    }
                }
            }
        }
        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const node = queue.items[head];
            const neighbors = [6][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, -1, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 } };
            for (neighbors) |offset| {
                const nx = @as(i32, node.x) + offset[0];
                const ny = @as(i32, node.y) + offset[1];
                const nz = @as(i32, node.z) + offset[2];
                if (nx >= 0 and nx < CHUNK_SIZE_X and ny >= 0 and ny < CHUNK_SIZE_Y and nz >= 0 and nz < CHUNK_SIZE_Z) {
                    const ux: u32 = @intCast(nx);
                    const uy: u32 = @intCast(ny);
                    const uz: u32 = @intCast(nz);
                    const block = chunk.getBlock(ux, uy, uz);
                    if (!block_registry.getBlockDefinition(block).isOpaque()) {
                        const current_light = chunk.getLight(ux, uy, uz);
                        const current_r = current_light.getBlockLightR();
                        const current_g = current_light.getBlockLightG();
                        const current_b = current_light.getBlockLightB();

                        const next_r: u4 = if (node.r > 1) node.r - 1 else 0;
                        const next_g: u4 = if (node.g > 1) node.g - 1 else 0;
                        const next_b: u4 = if (node.b > 1) node.b - 1 else 0;

                        if (next_r > current_r or next_g > current_g or next_b > current_b) {
                            const new_r = @max(next_r, current_r);
                            const new_g = @max(next_g, current_g);
                            const new_b = @max(next_b, current_b);
                            chunk.setBlockLightRGB(ux, uy, uz, new_r, new_g, new_b);
                            try queue.append(allocator, .{
                                .x = @intCast(nx),
                                .y = @intCast(ny),
                                .z = @intCast(nz),
                                .r = new_r,
                                .g = new_g,
                                .b = new_b,
                            });
                        }
                    }
                }
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

    for (0..CHUNK_SIZE_Z) |z| {
        for (0..CHUNK_SIZE_X) |x| {
            chunk.setBlock(@intCast(x), 4, @intCast(z), .stone);
        }
    }
    chunk.setBlock(8, 4, 8, .air);

    try LightingComputer.computeSkylight(&chunk, std.testing.allocator);

    try std.testing.expectEqual(@as(u4, MAX_LIGHT), chunk.getSkyLight(8, 3, 8));
    try std.testing.expect(chunk.getSkyLight(9, 3, 8) > 0);
}

test "entrance bounce carries around tunnel corners" {
    var chunk = Chunk.init(0, 0);

    for (0..CHUNK_SIZE_Z) |z| {
        for (0..CHUNK_SIZE_X) |x| {
            chunk.setBlock(@intCast(x), 4, @intCast(z), .stone);
        }
    }

    // Open shaft to the sky and a one-block-high tunnel that turns a corner.
    chunk.setBlock(4, 4, 4, .air);
    for (5..11) |x| {
        chunk.setBlock(@intCast(x), 3, 4, .air);
    }
    for (5..10) |z| {
        chunk.setBlock(10, 3, @intCast(z), .air);
    }

    try LightingComputer.computeSkylight(&chunk, std.testing.allocator);

    try std.testing.expect(chunk.getEntranceBounce(8, 3, 4) >= chunk.getEntranceBounce(10, 3, 8));
    try std.testing.expect(chunk.getEntranceBounce(10, 3, 8) > 0);
}

test "entrance bounce seeds side openings without vertical cover" {
    var chunk = Chunk.init(0, 0);

    // Build a vertical wall with a one-block recess at y=4. The recess column
    // itself has open sky above, so old covered-column-only seeding missed it.
    var y: u32 = 0;
    while (y <= 8) : (y += 1) {
        var z: u32 = 6;
        while (z <= 10) : (z += 1) {
            chunk.setBlock(8, y, z, .stone);
        }
    }
    chunk.setBlock(8, 4, 8, .air);

    try LightingComputer.computeSkylight(&chunk, std.testing.allocator);

    try std.testing.expect(chunk.getEntranceBounce(8, 4, 8) > 0);
}

test "entrance bounce fills a three-deep side tunnel" {
    var chunk = Chunk.init(0, 0);

    var z: u32 = 4;
    while (z <= 9) : (z += 1) {
        var y: u32 = 3;
        while (y <= 5) : (y += 1) {
            var x: u32 = 7;
            while (x <= 9) : (x += 1) {
                chunk.setBlock(x, y, z, .stone);
            }
        }
    }

    z = 4;
    while (z <= 8) : (z += 1) {
        chunk.setBlock(8, 4, z, .air);
    }

    try LightingComputer.computeSkylight(&chunk, std.testing.allocator);

    try std.testing.expect(chunk.getEntranceBounce(8, 4, 8) > 0);
}
