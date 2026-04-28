const std = @import("std");

const engine_core = @import("engine-core");
const world_core = @import("root.zig");

pub const LODLevel = engine_core.LODLevel;

pub fn regionSizeBlocks(lod_level: LODLevel) u32 {
    return lod_level.regionSizeBlocks(world_core.CHUNK_SIZE_X);
}

/// Simplified world data for distant LOD generation.
pub const LODSimplifiedData = struct {
    width: u32,
    heightmap: []f32,
    biomes: []world_core.BiomeId,
    top_blocks: []world_core.BlockType,
    colors: []u32,
    allocator: std.mem.Allocator,

    pub fn getGridSize(lod_level: LODLevel) u32 {
        if (lod_level == .lod0) return 16;
        return 32;
    }

    pub fn getCellSizeBlocks(lod_level: LODLevel) u32 {
        const region_size = regionSizeBlocks(lod_level);
        const grid_size = getGridSize(lod_level);
        return region_size / grid_size;
    }

    pub fn init(allocator: std.mem.Allocator, lod_level: LODLevel) !LODSimplifiedData {
        const grid_size = getGridSize(lod_level);
        const count = grid_size * grid_size;

        return .{
            .width = grid_size,
            .heightmap = try allocator.alloc(f32, count),
            .biomes = try allocator.alloc(world_core.BiomeId, count),
            .top_blocks = try allocator.alloc(world_core.BlockType, count),
            .colors = try allocator.alloc(u32, count),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LODSimplifiedData) void {
        self.allocator.free(self.heightmap);
        self.allocator.free(self.biomes);
        self.allocator.free(self.top_blocks);
        self.allocator.free(self.colors);
        self.* = undefined;
    }

    pub fn getHeight(self: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
        if (gx >= self.width or gz >= self.width) return 0;
        return self.heightmap[gz * self.width + gx];
    }

    pub fn setHeight(self: *LODSimplifiedData, gx: u32, gz: u32, height: f32) void {
        if (gx >= self.width or gz >= self.width) return;
        self.heightmap[gz * self.width + gx] = height;
    }

    pub fn totalMemoryBytes(self: *const LODSimplifiedData) usize {
        const count = self.width * self.width;
        return count * (@sizeOf(f32) + @sizeOf(world_core.BiomeId) + @sizeOf(world_core.BlockType) + @sizeOf(u32));
    }
};
