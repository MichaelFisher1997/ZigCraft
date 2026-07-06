//! Chunk data structure - 16x256x16 block storage with lighting.

const std = @import("std");
const BlockType = @import("block.zig").BlockType;
const block_registry = @import("block_registry.zig");
const BiomeId = @import("block.zig").Biome;

pub const CHUNK_SIZE_X = @import("chunk_constants.zig").CHUNK_SIZE_X;
pub const CHUNK_SIZE_Y = @import("chunk_constants.zig").CHUNK_SIZE_Y;
pub const CHUNK_SIZE_Z = @import("chunk_constants.zig").CHUNK_SIZE_Z;
pub const MAX_BLOCK_TYPES = @import("chunk_constants.zig").MAX_BLOCK_TYPES;
pub const CHUNK_VOLUME = @import("chunk_constants.zig").CHUNK_VOLUME;
pub const CHUNK_UNLOAD_BUFFER = @import("chunk_constants.zig").CHUNK_UNLOAD_BUFFER;
pub const MAX_LIGHT = @import("chunk_constants.zig").MAX_LIGHT;

pub const PackedLight = @import("light.zig").PackedLight;

pub const packEntranceDir = @import("light.zig").packEntranceDir;
pub const unpackEntranceDirX = @import("light.zig").unpackEntranceDirX;
pub const unpackEntranceDirZ = @import("light.zig").unpackEntranceDirZ;

pub const Chunk = struct {
    pub const State = enum {
        missing,
        queued_for_generation,
        generating,
        generated,
        queued_for_mesh,
        meshing,
        mesh_ready,
        uploading,
        renderable,
        unloading,
    };

    chunk_x: i32,
    chunk_z: i32,
    blocks: [CHUNK_VOLUME]BlockType,
    light: [CHUNK_VOLUME]PackedLight,
    entrance_bounce: [CHUNK_VOLUME]u4,
    entrance_dir: [CHUNK_VOLUME]u8,
    biomes: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
    heightmap: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i16,
    state: State = .missing,
    job_token: u32 = 0,
    dirty: bool = true,
    mesh_attempts: u8 = 0,
    generated: bool = false,
    modified: bool = false,
    pin_count: std.atomic.Value(u32),

    pub fn init(chunk_x: i32, chunk_z: i32) Chunk {
        return .{
            .chunk_x = chunk_x,
            .chunk_z = chunk_z,
            .blocks = [_]BlockType{.air} ** CHUNK_VOLUME,
            .light = [_]PackedLight{PackedLight.init(0, 0)} ** CHUNK_VOLUME,
            .entrance_bounce = [_]u4{0} ** CHUNK_VOLUME,
            .entrance_dir = [_]u8{packEntranceDir(0, 0)} ** CHUNK_VOLUME,
            .biomes = [_]BiomeId{.plains} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z),
            .heightmap = [_]i16{0} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z),
            .state = .missing,
            .pin_count = std.atomic.Value(u32).init(0),
        };
    }

    pub fn getIndex(x: u32, y: u32, z: u32) usize {
        std.debug.assert(x < CHUNK_SIZE_X);
        std.debug.assert(y < CHUNK_SIZE_Y);
        std.debug.assert(z < CHUNK_SIZE_Z);
        return @as(usize, x) + @as(usize, z) * CHUNK_SIZE_X + @as(usize, y) * CHUNK_SIZE_X * CHUNK_SIZE_Z;
    }

    pub fn getBlock(self: *const Chunk, x: u32, y: u32, z: u32) BlockType {
        return self.blocks[getIndex(x, y, z)];
    }

    pub fn setBlock(self: *Chunk, x: u32, y: u32, z: u32, block: BlockType) void {
        self.blocks[getIndex(x, y, z)] = block;
        self.dirty = true;
        self.modified = true;
    }

    pub fn getBlockSafe(self: *const Chunk, x: i32, y: i32, z: i32) BlockType {
        if (x < 0 or x >= CHUNK_SIZE_X or y < 0 or y >= CHUNK_SIZE_Y or z < 0 or z >= CHUNK_SIZE_Z) return .air;
        return self.getBlock(@intCast(x), @intCast(y), @intCast(z));
    }

    pub fn getBiome(self: *const Chunk, x: u32, z: u32) BiomeId {
        return self.biomes[x + z * CHUNK_SIZE_X];
    }

    pub fn setBiome(self: *Chunk, x: u32, z: u32, biome: BiomeId) void {
        self.biomes[x + z * CHUNK_SIZE_X] = biome;
        self.dirty = true;
    }

    pub fn getLight(self: *const Chunk, x: u32, y: u32, z: u32) PackedLight {
        return self.light[getIndex(x, y, z)];
    }

    pub fn setLight(self: *Chunk, x: u32, y: u32, z: u32, light_val: PackedLight) void {
        self.light[getIndex(x, y, z)] = light_val;
    }

    pub fn getSkyLight(self: *const Chunk, x: u32, y: u32, z: u32) u4 {
        return self.light[getIndex(x, y, z)].getSkyLight();
    }

    pub fn setSkyLight(self: *Chunk, x: u32, y: u32, z: u32, val: u4) void {
        self.light[getIndex(x, y, z)].setSkyLight(val);
    }

    pub fn getEntranceBounce(self: *const Chunk, x: u32, y: u32, z: u32) u4 {
        return self.entrance_bounce[getIndex(x, y, z)];
    }

    pub fn setEntranceBounce(self: *Chunk, x: u32, y: u32, z: u32, val: u4) void {
        self.entrance_bounce[getIndex(x, y, z)] = val;
    }

    pub fn getEntranceDir(self: *const Chunk, x: u32, y: u32, z: u32) u8 {
        return self.entrance_dir[getIndex(x, y, z)];
    }

    pub fn setEntranceDir(self: *Chunk, x: u32, y: u32, z: u32, val: u8) void {
        self.entrance_dir[getIndex(x, y, z)] = val;
    }

    pub fn getBlockLight(self: *const Chunk, x: u32, y: u32, z: u32) u4 {
        return self.light[getIndex(x, y, z)].getBlockLight();
    }

    pub fn getSurfaceHeight(self: *const Chunk, x: u32, z: u32) i16 {
        return self.heightmap[x + z * CHUNK_SIZE_X];
    }

    pub fn setSurfaceHeight(self: *Chunk, x: u32, z: u32, height: i16) void {
        self.heightmap[x + z * CHUNK_SIZE_X] = height;
    }

    pub fn setBlockLight(self: *Chunk, x: u32, y: u32, z: u32, val: u4) void {
        self.light[getIndex(x, y, z)].setBlockLight(val);
    }

    pub fn setBlockLightRGB(self: *Chunk, x: u32, y: u32, z: u32, r: u4, g: u4, b: u4) void {
        self.light[getIndex(x, y, z)].setBlockLightRGB(r, g, b);
    }

    pub fn getLightSafe(self: *const Chunk, x: i32, y: i32, z: i32) PackedLight {
        // Out-of-bounds X/Z returns zero light. Out-of-bounds Y returns:
        //   - MAX_LIGHT sky light for y >= CHUNK_SIZE_Y: the meshing system samples this
        //     position to light the TOP FACE of the highest block in each column (e.g. a
        //     mountain peak at y=255 queries y=256). The space above the world is open
        //     sky, so the face should be full daylight. Returning 0 here makes mountain
        //     tops render incorrectly dark.
        //   - 0 light for y < 0: nothing emits light from below the world.
        if (x < 0 or x >= CHUNK_SIZE_X or z < 0 or z >= CHUNK_SIZE_Z) return PackedLight.init(0, 0);
        if (y >= CHUNK_SIZE_Y) return PackedLight.init(MAX_LIGHT, 0);
        if (y < 0) return PackedLight.init(0, 0);
        return self.getLight(@intCast(x), @intCast(y), @intCast(z));
    }

    pub fn getEntranceBounceSafe(self: *const Chunk, x: i32, y: i32, z: i32) u4 {
        if (x < 0 or x >= CHUNK_SIZE_X or z < 0 or z >= CHUNK_SIZE_Z or y < 0 or y >= CHUNK_SIZE_Y) return 0;
        return self.getEntranceBounce(@intCast(x), @intCast(y), @intCast(z));
    }

    pub fn getEntranceDirSafe(self: *const Chunk, x: i32, y: i32, z: i32) u8 {
        if (x < 0 or x >= CHUNK_SIZE_X or z < 0 or z >= CHUNK_SIZE_Z or y < 0 or y >= CHUNK_SIZE_Y) return packEntranceDir(0, 0);
        return self.getEntranceDir(@intCast(x), @intCast(y), @intCast(z));
    }

    pub fn getWorldX(self: *const Chunk) i32 {
        return self.chunk_x * CHUNK_SIZE_X;
    }

    pub fn getWorldZ(self: *const Chunk) i32 {
        return self.chunk_z * CHUNK_SIZE_Z;
    }

    pub fn getHighestSolidY(self: *const Chunk, x: u32, z: u32) u32 {
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y >= 0) : (y -= 1) {
            const block = self.getBlock(x, @intCast(y), z);
            if (block != .air and block != .water) return @intCast(y);
        }
        return 0;
    }

    pub fn pin(self: *Chunk) void {
        _ = self.pin_count.fetchAdd(1, .monotonic);
    }

    pub fn unpin(self: *Chunk) void {
        _ = self.pin_count.fetchSub(1, .monotonic);
    }

    pub fn isPinned(self: *const Chunk) bool {
        return self.pin_count.load(.monotonic) > 0;
    }

    pub fn fill(self: *Chunk, block: BlockType) void {
        @memset(&self.blocks, block);
        self.dirty = true;
    }

    pub fn fillLayer(self: *Chunk, y: u32, block: BlockType) void {
        var x: u32 = 0;
        while (x < CHUNK_SIZE_X) : (x += 1) {
            var z: u32 = 0;
            while (z < CHUNK_SIZE_Z) : (z += 1) {
                self.setBlock(x, y, z, block);
            }
        }
    }

    pub fn generateFlat(self: *Chunk, ground_level: u32) void {
        var y: u32 = 0;
        while (y < CHUNK_SIZE_Y) : (y += 1) {
            const block: BlockType = if (y == 0)
                .bedrock
            else if (y < ground_level - 3)
                .stone
            else if (y < ground_level)
                .dirt
            else if (y == ground_level)
                .grass
            else
                .air;

            self.fillLayer(y, block);
        }
        self.generated = true;
        self.dirty = true;
    }

    pub fn updateSkylightColumn(self: *Chunk, x: u32, z: u32) void {
        var sky_light: u4 = MAX_LIGHT;
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y >= 0) : (y -= 1) {
            const uy: u32 = @intCast(y);
            const block = self.getBlock(x, uy, z);
            self.setSkyLight(x, uy, z, sky_light);
            if (block_registry.getBlockDefinition(block).isOpaque()) {
                sky_light = 0;
            } else if (block == .water and sky_light > 0) {
                sky_light -= 1;
            }
        }
    }
};

pub fn worldToChunkFromFloat(world_x: f32, world_z: f32) struct { chunk_x: i32, chunk_z: i32 } {
    const chunk = worldToChunk(@as(i32, @intFromFloat(@floor(world_x))), @as(i32, @intFromFloat(@floor(world_z))));
    return .{ .chunk_x = chunk.chunk_x, .chunk_z = chunk.chunk_z };
}

pub fn worldToChunk(world_x: i32, world_z: i32) struct { chunk_x: i32, chunk_z: i32 } {
    return .{
        .chunk_x = @divFloor(world_x, CHUNK_SIZE_X),
        .chunk_z = @divFloor(world_z, CHUNK_SIZE_Z),
    };
}

pub fn worldToLocal(world_x: i32, world_z: i32) struct { x: u32, z: u32 } {
    return .{
        .x = @intCast(@mod(world_x, CHUNK_SIZE_X)),
        .z = @intCast(@mod(world_z, CHUNK_SIZE_Z)),
    };
}
