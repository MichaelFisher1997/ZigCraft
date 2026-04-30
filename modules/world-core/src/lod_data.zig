const std = @import("std");

const engine_core = @import("engine-core");
const world_core = @import("root.zig");

pub const LODLevel = engine_core.LODLevel;

pub const LODMaterialLayers = struct {
    surface: world_core.BlockType,
    subsurface: world_core.BlockType,
    foundation: world_core.BlockType,

    pub fn default(surface: world_core.BlockType) LODMaterialLayers {
        return .{
            .surface = surface,
            .subsurface = surface,
            .foundation = surface,
        };
    }
};

pub const LODWaterState = struct {
    is_surface: bool,
    surface_height: f32,
    depth: f32,
    coverage: f32,

    pub const empty: LODWaterState = .{
        .is_surface = false,
        .surface_height = 0.0,
        .depth = 0.0,
        .coverage = 0.0,
    };
};

pub const LODLightingHint = struct {
    sky_light: u8,
    block_light: u8,
    ambient_occlusion: f32,

    pub const daylight: LODLightingHint = .{
        .sky_light = 15,
        .block_light = 0,
        .ambient_occlusion = 1.0,
    };
};

pub const LODVegetationHint = struct {
    tree_coverage: f32,
    avg_tree_height: f32,
    offset_x: f32,
    offset_z: f32,
    trunk: world_core.BlockType,
    leaves: world_core.BlockType,

    pub const empty: LODVegetationHint = .{
        .tree_coverage = 0.0,
        .avg_tree_height = 0.0,
        .offset_x = 0.0,
        .offset_z = 0.0,
        .trunk = .air,
        .leaves = .air,
    };
};

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
    material_layers: []LODMaterialLayers,
    water: []LODWaterState,
    lighting: []LODLightingHint,
    vegetation: []LODVegetationHint,
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

        const heightmap = try allocator.alloc(f32, count);
        errdefer allocator.free(heightmap);
        const biomes = try allocator.alloc(world_core.BiomeId, count);
        errdefer allocator.free(biomes);
        const top_blocks = try allocator.alloc(world_core.BlockType, count);
        errdefer allocator.free(top_blocks);
        const colors = try allocator.alloc(u32, count);
        errdefer allocator.free(colors);
        const material_layers = try allocator.alloc(LODMaterialLayers, count);
        errdefer allocator.free(material_layers);
        const water = try allocator.alloc(LODWaterState, count);
        errdefer allocator.free(water);
        const lighting = try allocator.alloc(LODLightingHint, count);
        errdefer allocator.free(lighting);
        const vegetation = try allocator.alloc(LODVegetationHint, count);
        errdefer allocator.free(vegetation);

        @memset(heightmap, 0.0);
        @memset(biomes, .plains);
        @memset(top_blocks, .air);
        @memset(colors, 0);
        @memset(material_layers, LODMaterialLayers.default(.air));
        @memset(water, LODWaterState.empty);
        @memset(lighting, LODLightingHint.daylight);
        @memset(vegetation, LODVegetationHint.empty);

        return .{
            .width = grid_size,
            .heightmap = heightmap,
            .biomes = biomes,
            .top_blocks = top_blocks,
            .colors = colors,
            .material_layers = material_layers,
            .water = water,
            .lighting = lighting,
            .vegetation = vegetation,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *LODSimplifiedData) void {
        self.allocator.free(self.heightmap);
        self.allocator.free(self.biomes);
        self.allocator.free(self.top_blocks);
        self.allocator.free(self.colors);
        self.allocator.free(self.material_layers);
        self.allocator.free(self.water);
        self.allocator.free(self.lighting);
        self.allocator.free(self.vegetation);
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

    pub fn setColumn(
        self: *LODSimplifiedData,
        gx: u32,
        gz: u32,
        height: f32,
        biome: world_core.BiomeId,
        layers: LODMaterialLayers,
        color: u32,
        water_state: LODWaterState,
        lighting_hint: LODLightingHint,
        vegetation_hint: LODVegetationHint,
    ) void {
        if (gx >= self.width or gz >= self.width) return;
        const idx = gz * self.width + gx;
        self.heightmap[idx] = height;
        self.biomes[idx] = biome;
        self.top_blocks[idx] = layers.surface;
        self.colors[idx] = color;
        self.material_layers[idx] = layers;
        self.water[idx] = water_state;
        self.lighting[idx] = lighting_hint;
        self.vegetation[idx] = vegetation_hint;
    }

    pub fn totalMemoryBytes(self: *const LODSimplifiedData) usize {
        const count = self.width * self.width;
        return count * (@sizeOf(f32) + @sizeOf(world_core.BiomeId) + @sizeOf(world_core.BlockType) + @sizeOf(u32) + @sizeOf(LODMaterialLayers) + @sizeOf(LODWaterState) + @sizeOf(LODLightingHint) + @sizeOf(LODVegetationHint));
    }
};

test "LODSimplifiedData initializes rich column defaults" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();

    try std.testing.expectEqual(@as(f32, 0.0), data.getHeight(0, 0));
    try std.testing.expectEqual(world_core.BlockType.air, data.top_blocks[0]);
    try std.testing.expectEqual(world_core.BlockType.air, data.material_layers[0].surface);
    try std.testing.expect(!data.water[0].is_surface);
    try std.testing.expectEqual(@as(u8, 15), data.lighting[0].sky_light);
    try std.testing.expectEqual(@as(f32, 0.0), data.vegetation[0].tree_coverage);
}

test "LODSimplifiedData setColumn stores rich representative data" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    data.setColumn(1, 2, 63.0, .ocean, .{
        .surface = .water,
        .subsurface = .sand,
        .foundation = .stone,
    }, 0x3355AA, .{
        .is_surface = true,
        .surface_height = 63.0,
        .depth = 12.0,
        .coverage = 1.0,
    }, .{
        .sky_light = 15,
        .block_light = 0,
        .ambient_occlusion = 0.9,
    }, .{
        .tree_coverage = 0.5,
        .avg_tree_height = 7.0,
        .offset_x = 0.25,
        .offset_z = -0.25,
        .trunk = .wood,
        .leaves = .leaves,
    });

    const idx = 1 + 2 * data.width;
    try std.testing.expectEqual(@as(f32, 63.0), data.heightmap[idx]);
    try std.testing.expectEqual(world_core.BlockType.water, data.top_blocks[idx]);
    try std.testing.expectEqual(world_core.BlockType.sand, data.material_layers[idx].subsurface);
    try std.testing.expect(data.water[idx].is_surface);
    try std.testing.expectEqual(@as(f32, 12.0), data.water[idx].depth);
    try std.testing.expectEqual(@as(f32, 0.9), data.lighting[idx].ambient_occlusion);
    try std.testing.expectEqual(world_core.BlockType.leaves, data.vegetation[idx].leaves);
}
