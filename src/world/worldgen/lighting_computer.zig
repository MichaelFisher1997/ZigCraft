const std = @import("std");
const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const MAX_LIGHT = @import("../chunk.zig").MAX_LIGHT;
const block_registry = @import("../block_registry.zig");

pub const LightingComputer = struct {
    const LightNode = struct {
        x: u8,
        y: u16,
        z: u8,
        r: u4,
        g: u4,
        b: u4,
    };

    pub fn computeSkylight(chunk: *Chunk) void {
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                var sky_light: u4 = MAX_LIGHT;
                var y: i32 = CHUNK_SIZE_Y - 1;
                while (y >= 0) : (y -= 1) {
                    const uy: u32 = @intCast(y);
                    const block = chunk.getBlock(local_x, uy, local_z);
                    chunk.setSkyLight(local_x, uy, local_z, sky_light);
                    if (block_registry.getBlockDefinition(block).isOpaque()) {
                        sky_light = 0;
                    } else if (block == .water and sky_light > 0) {
                        sky_light -= 1;
                    }
                }
            }
        }
    }

    pub fn computeBlockLight(chunk: *Chunk, allocator: std.mem.Allocator) !void {
        var queue = std.ArrayListUnmanaged(LightNode){};
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
