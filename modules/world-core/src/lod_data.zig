const std = @import("std");

const engine_core = @import("engine-core");
const world_core = @import("root.zig");

pub const LODLevel = engine_core.LODLevel;

pub const LODDataVersion = enum(u16) {
    simplified_v1 = 1,
    rich_v2 = 2,
};

pub const MAX_LOD_VERTICAL_SPANS: usize = 4;

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

pub const LODVerticalSpan = struct {
    min_height: f32,
    max_height: f32,
    biome: world_core.BiomeId,
    material_layers: LODMaterialLayers,
    color: u32,
    water: LODWaterState,
    lighting: LODLightingHint,
    vegetation: LODVegetationHint,

    pub fn fromColumn(
        height: f32,
        biome: world_core.BiomeId,
        layers: LODMaterialLayers,
        color: u32,
        water_state: LODWaterState,
        lighting_hint: LODLightingHint,
        vegetation_hint: LODVegetationHint,
    ) LODVerticalSpan {
        return .{
            .min_height = height,
            .max_height = height,
            .biome = biome,
            .material_layers = layers,
            .color = color,
            .water = water_state,
            .lighting = lighting_hint,
            .vegetation = vegetation_hint,
        };
    }
};

pub fn regionSizeBlocks(lod_level: LODLevel) u32 {
    return lod_level.regionSizeBlocks(world_core.CHUNK_SIZE_X);
}

/// Simplified world data for distant LOD generation.
pub const LODSimplifiedData = struct {
    version: LODDataVersion,
    width: u32,
    heightmap: []f32,
    biomes: []world_core.BiomeId,
    top_blocks: []world_core.BlockType,
    colors: []u32,
    material_layers: []LODMaterialLayers,
    water: []LODWaterState,
    lighting: []LODLightingHint,
    vegetation: []LODVegetationHint,
    vertical_span_counts: ?[]u8,
    vertical_spans: ?[]LODVerticalSpan,
    allocator: std.mem.Allocator,

    pub fn getGridSize(lod_level: LODLevel) u32 {
        return switch (lod_level) {
            .lod0 => 16,
            .lod1 => 32,
            .lod2, .lod3 => 48,
        };
    }

    pub fn getCellSizeBlocks(lod_level: LODLevel) u32 {
        const region_size = regionSizeBlocks(lod_level);
        const grid_size = getGridSize(lod_level);
        return region_size / @max(grid_size - 1, 1);
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
            .version = .rich_v2,
            .width = grid_size,
            .heightmap = heightmap,
            .biomes = biomes,
            .top_blocks = top_blocks,
            .colors = colors,
            .material_layers = material_layers,
            .water = water,
            .lighting = lighting,
            .vegetation = vegetation,
            .vertical_span_counts = null,
            .vertical_spans = null,
            .allocator = allocator,
        };
    }

    pub fn initWithVerticalSpans(allocator: std.mem.Allocator, lod_level: LODLevel) !LODSimplifiedData {
        var data = try init(allocator, lod_level);
        errdefer data.deinit();
        try data.enableVerticalSpans();
        return data;
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
        if (self.vertical_span_counts) |counts| self.allocator.free(counts);
        if (self.vertical_spans) |spans| self.allocator.free(spans);
        self.* = undefined;
    }

    pub fn enableVerticalSpans(self: *LODSimplifiedData) !void {
        if (self.vertical_spans != null) return;

        const count = self.width * self.width;
        const span_count = @as(usize, @intCast(count)) * MAX_LOD_VERTICAL_SPANS;
        const counts = try self.allocator.alloc(u8, count);
        errdefer self.allocator.free(counts);
        const spans = try self.allocator.alloc(LODVerticalSpan, span_count);
        errdefer self.allocator.free(spans);

        @memset(counts, 0);
        @memset(spans, LODVerticalSpan.fromColumn(0.0, .plains, LODMaterialLayers.default(.air), 0, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty));

        self.vertical_span_counts = counts;
        self.vertical_spans = spans;
    }

    pub fn hasVerticalSpans(self: *const LODSimplifiedData) bool {
        return self.vertical_span_counts != null and self.vertical_spans != null;
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
        if (self.hasVerticalSpans()) {
            _ = self.setVerticalSpan(gx, gz, 0, LODVerticalSpan.fromColumn(height, biome, layers, color, water_state, lighting_hint, vegetation_hint));
        }
    }

    pub fn verticalSpanCount(self: *const LODSimplifiedData, gx: u32, gz: u32) u8 {
        if (gx >= self.width or gz >= self.width) return 0;
        const counts = self.vertical_span_counts orelse return 0;
        return counts[gz * self.width + gx];
    }

    pub fn getVerticalSpan(self: *const LODSimplifiedData, gx: u32, gz: u32, span_index: u8) ?LODVerticalSpan {
        if (gx >= self.width or gz >= self.width) return null;
        if (span_index >= self.verticalSpanCount(gx, gz)) return null;
        const spans = self.vertical_spans orelse return null;
        const column_idx = @as(usize, @intCast(gz * self.width + gx));
        const idx = column_idx * MAX_LOD_VERTICAL_SPANS + span_index;
        return spans[idx];
    }

    pub fn setVerticalSpan(self: *LODSimplifiedData, gx: u32, gz: u32, span_index: u8, span: LODVerticalSpan) bool {
        if (gx >= self.width or gz >= self.width) return false;
        if (@as(usize, span_index) >= MAX_LOD_VERTICAL_SPANS) return false;
        const counts = self.vertical_span_counts orelse return false;
        const spans = self.vertical_spans orelse return false;
        const column_idx = gz * self.width + gx;
        spans[@as(usize, @intCast(column_idx)) * MAX_LOD_VERTICAL_SPANS + span_index] = span;
        counts[column_idx] = @max(counts[column_idx], span_index + 1);
        return true;
    }

    pub fn clearVerticalSpans(self: *LODSimplifiedData, gx: u32, gz: u32) void {
        if (gx >= self.width or gz >= self.width) return;
        const counts = self.vertical_span_counts orelse return;
        counts[gz * self.width + gx] = 0;
    }

    pub fn totalMemoryBytes(self: *const LODSimplifiedData) usize {
        const count = self.width * self.width;
        const count_usize = @as(usize, @intCast(count));
        var total: usize = count_usize * (@sizeOf(f32) + @sizeOf(world_core.BiomeId) + @sizeOf(world_core.BlockType) + @sizeOf(u32) + @sizeOf(LODMaterialLayers) + @sizeOf(LODWaterState) + @sizeOf(LODLightingHint) + @sizeOf(LODVegetationHint));
        if (self.vertical_span_counts != null) total += count_usize * @sizeOf(u8);
        if (self.vertical_spans != null) total += @as(usize, @intCast(count)) * MAX_LOD_VERTICAL_SPANS * @sizeOf(LODVerticalSpan);
        return total;
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

test "LODSimplifiedData tracks bounded vertical spans when enabled" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();

    try std.testing.expectEqual(LODDataVersion.rich_v2, data.version);
    try std.testing.expect(data.hasVerticalSpans());
    try std.testing.expectEqual(@as(u8, 0), data.verticalSpanCount(3, 4));

    try std.testing.expect(data.setVerticalSpan(3, 4, 0, .{
        .min_height = 72.0,
        .max_height = 76.0,
        .biome = .plains,
        .material_layers = .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone },
        .color = 0x66AA44,
        .water = LODWaterState.empty,
        .lighting = LODLightingHint.daylight,
        .vegetation = LODVegetationHint.empty,
    }));
    try std.testing.expect(data.setVerticalSpan(3, 4, 1, .{
        .min_height = 44.0,
        .max_height = 48.0,
        .biome = .plains,
        .material_layers = .{ .surface = .stone, .subsurface = .stone, .foundation = .stone },
        .color = 0x777777,
        .water = LODWaterState.empty,
        .lighting = .{ .sky_light = 8, .block_light = 0, .ambient_occlusion = 0.6 },
        .vegetation = LODVegetationHint.empty,
    }));

    try std.testing.expectEqual(@as(u8, 2), data.verticalSpanCount(3, 4));
    const lower = data.getVerticalSpan(3, 4, 1) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 44.0), lower.min_height);
    try std.testing.expectEqual(world_core.BlockType.stone, lower.material_layers.surface);
    try std.testing.expect(!data.setVerticalSpan(3, 4, @intCast(MAX_LOD_VERTICAL_SPANS), lower));
}

test "LODSimplifiedData memory accounting includes optional vertical spans" {
    const allocator = std.testing.allocator;
    var baseline = try LODSimplifiedData.init(allocator, .lod1);
    defer baseline.deinit();
    var rich = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod1);
    defer rich.deinit();

    const count = @as(usize, @intCast(baseline.width * baseline.width));
    const span_bytes = count * (@sizeOf(u8) + MAX_LOD_VERTICAL_SPANS * @sizeOf(LODVerticalSpan));
    try std.testing.expectEqual(baseline.totalMemoryBytes() + span_bytes, rich.totalMemoryBytes());
}

test "LODSimplifiedData setColumn seeds representative span when enabled" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod1);
    defer data.deinit();

    data.setColumn(2, 2, 80.0, .forest, .{
        .surface = .grass,
        .subsurface = .dirt,
        .foundation = .stone,
    }, 0x22AA44, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty);

    try std.testing.expectEqual(@as(u8, 1), data.verticalSpanCount(2, 2));
    const span = data.getVerticalSpan(2, 2, 0) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(f32, 80.0), span.max_height);
    try std.testing.expectEqual(world_core.BlockType.grass, span.material_layers.surface);
}
