const std = @import("std");
const world_core = @import("world-core");
const biomes = @import("biomes.zig");
const block_colors = @import("block_colors.zig");
const climate = @import("climate.zig");
const terrain_shape = @import("terrain_shape.zig");
const trees = @import("trees.zig");
const util = @import("util.zig");

const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const LODLevel = world_core.LODLevel;
const LODSimplifiedData = world_core.LODSimplifiedData;

const ColumnSample = struct {
    terrain_height: i32,
    base_height: i32,
    biome: BiomeId,
    is_river: bool,
    is_ocean: bool,
    temperature: f32,
    humidity: f32,
    continentalness: f32,
};

const ClassifiedLODSample = struct {
    world_x: i32,
    world_z: i32,
    terrain_height: f32,
    terrain_height_i: i32,
    biome: BiomeId,
    surface_block: BlockType,
    render_water_surface: bool,
};

const RepresentativeLODColumn = struct {
    height: f32,
    biome: BiomeId,
    layers: world_core.LODMaterialLayers,
    color: u32,
    water: world_core.LODWaterState,
    lighting: world_core.LODLightingHint,
    vegetation: world_core.LODVegetationHint,
};

pub fn generateHeightmapOnly(self: anytype, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel, stop_flag: ?*const std.atomic.Value(bool)) void {
    if (data.width < 2) return;
    const region_size_i: i32 = @intCast(world_core.regionSizeBlocks(lod_level));
    const region_size_f: f32 = @floatFromInt(region_size_i);
    const grid_max: f32 = @floatFromInt(data.width - 1);
    const cell_span = region_size_f / grid_max;
    const world_x = util.chunkWorldOffset(region_x, 0, region_size_i);
    const world_z = util.chunkWorldOffset(region_z, 0, region_size_i);

    var gz: u32 = 0;
    while (gz < data.width) : (gz += 1) {
        if (stop_flag) |sf| if (sf.load(.acquire)) return;
        var gx: u32 = 0;
        while (gx < data.width) : (gx += 1) {
            const wx_f = @as(f32, @floatFromInt(world_x)) + (@as(f32, @floatFromInt(gx)) / grid_max) * region_size_f;
            const wz_f = @as(f32, @floatFromInt(world_z)) + (@as(f32, @floatFromInt(gz)) / grid_max) * region_size_f;
            const sample = sampleRepresentativeLODColumn(self, wx_f, wz_f, cell_span);
            data.setGeneratedColumn(gx, gz, sample.height, sample.biome, sample.layers, sample.color, sample.water, sample.lighting, sample.vegetation);
        }
    }
}

fn sampleRepresentativeLODColumn(self: anytype, wx: f32, wz: f32, cell_span: f32) RepresentativeLODColumn {
    // Sample the full cell footprint so shorelines retain fractional coverage
    // rather than snapping every coarse cell fully to land or water.
    const sample_offsets = [_]f32{ -1.0, 0.0, 1.0 };
    const sample_radius = @min(cell_span * 0.5, 48.0);
    var classified_samples: [sample_offsets.len * sample_offsets.len]ClassifiedLODSample = undefined;
    var classified_count: usize = 0;

    var block_counts = [_]u32{0} ** world_core.MAX_BLOCK_TYPES;
    var biome_counts = [_]u32{0} ** 256;
    var color_r: u32 = 0;
    var color_g: u32 = 0;
    var color_b: u32 = 0;
    var terrain_height_sum: f32 = 0.0;
    var terrain_min: f32 = std.math.floatMax(f32);
    var terrain_max: f32 = -std.math.floatMax(f32);
    var water_depth_sum: f32 = 0.0;
    var water_samples: u32 = 0;
    var total_samples: u32 = 0;

    for (sample_offsets) |oz| {
        for (sample_offsets) |ox| {
            const sample = classifyLODSample(self, wx + ox * sample_radius, wz + oz * sample_radius);
            classified_samples[classified_count] = sample;
            classified_count += 1;
            const block_index = @intFromEnum(sample.surface_block);
            if (block_index < block_counts.len) block_counts[block_index] += 1;
            biome_counts[@intFromEnum(sample.biome)] += 1;

            const color = block_colors.colorForBiome(sample.biome, sample.surface_block);
            color_r += (color >> 16) & 0xFF;
            color_g += (color >> 8) & 0xFF;
            color_b += color & 0xFF;
            terrain_height_sum += sample.terrain_height;
            terrain_min = @min(terrain_min, sample.terrain_height);
            terrain_max = @max(terrain_max, sample.terrain_height);
            total_samples += 1;

            if (sample.render_water_surface) {
                water_samples += 1;
                water_depth_sum += @floatFromInt(@max(self.params.sea_level - sample.terrain_height_i, 0));
            }
        }
    }

    const sample_count = @max(total_samples, 1);
    const water_coverage = @as(f32, @floatFromInt(water_samples)) / @as(f32, @floatFromInt(sample_count));
    const render_water_surface = water_coverage >= 0.45;
    const dominant_biome = dominantBiome(biome_counts);
    const dominant_block = dominantBlock(block_counts);
    const center_sample = classified_samples[classified_samples.len / 2];
    const surface_block: BlockType = if (render_water_surface) .water else if (center_sample.render_water_surface) dominant_block else center_sample.surface_block;
    const avg_height = terrain_height_sum / @as(f32, @floatFromInt(sample_count));
    const terrain_range = @max(terrain_max - terrain_min, 0.0);
    const center_height = center_sample.terrain_height;
    const height_blend: f32 = if (terrain_range > 24.0 and center_height > avg_height) 0.82 else 0.68;
    const land_height = center_height * height_blend + avg_height * (1.0 - height_blend);
    const vegetation = if (render_water_surface)
        world_core.LODVegetationHint.empty
    else
        lodVegetationHintFromSamples(self, classified_samples[0..classified_count], wx, wz);
    const avg_color = packAverageColor(color_r, color_g, color_b, sample_count);

    return .{
        .height = if (render_water_surface) @floatFromInt(self.params.sea_level) else land_height,
        .biome = dominant_biome,
        .layers = .{
            .surface = surface_block,
            .subsurface = block_colors.fillerBlock(dominant_biome, render_water_surface),
            .foundation = .stone,
        },
        .color = avg_color,
        .water = if (render_water_surface) .{
            .is_surface = true,
            .surface_height = @floatFromInt(self.params.sea_level),
            .depth = if (water_samples == 0) 0.0 else water_depth_sum / @as(f32, @floatFromInt(water_samples)),
            .coverage = water_coverage,
        } else world_core.LODWaterState.empty,
        .lighting = .{
            .sky_light = 15,
            .block_light = 0,
            .ambient_occlusion = if (render_water_surface) 0.92 else 1.0,
        },
        .vegetation = vegetation,
    };
}

fn classifyLODSample(self: anytype, wx: f32, wz: f32) ClassifiedLODSample {
    const wx_i = util.floorToI32(wx);
    const wz_i = util.floorToI32(wz);
    const sample = sampleLODColumn(self, wx_i, wz_i);
    const render_water_surface = sample.terrain_height < self.params.sea_level;
    const surface_block: BlockType = if (render_water_surface) .water else block_colors.surfaceBlock(sample.biome, sample.terrain_height, self.params.sea_level, false);

    return .{
        .world_x = wx_i,
        .world_z = wz_i,
        .terrain_height = @floatFromInt(sample.terrain_height),
        .terrain_height_i = sample.terrain_height,
        .biome = sample.biome,
        .surface_block = surface_block,
        .render_water_surface = render_water_surface,
    };
}

fn sampleLODColumn(self: anytype, wx: i32, wz: i32) ColumnSample {
    const base_height = util.floorToI32(terrain_shape.baseTerrainLevelAtPoint(self, wx, wz));
    const terrain_height = terrain_shape.estimateGroundedTerrainHeight(self, wx, wz, base_height);
    const climate_sample = climate.sampleClimate(self, wx, wz);
    const river = terrain_shape.isRiverColumn(self, wx, wz) and terrain_height >= self.params.sea_level - 18 and terrain_height <= self.params.sea_level + 1;
    const biome = biomes.selectBiome(self, wx, wz, terrain_height, river, climate_sample.temperature, climate_sample.humidity);
    const continentalness = std.math.clamp((@as(f32, @floatFromInt(terrain_height - self.params.sea_level)) + 56.0) / 150.0, 0.0, 1.0);
    return .{
        .terrain_height = terrain_height,
        .base_height = base_height,
        .biome = biome,
        .is_river = river,
        .is_ocean = terrain_height < self.params.sea_level - 2,
        .temperature = climate_sample.temperature,
        .humidity = climate_sample.humidity,
        .continentalness = continentalness,
    };
}

fn lodVegetationHintFromSamples(self: anytype, samples: []const ClassifiedLODSample, center_wx: f32, center_wz: f32) world_core.LODVegetationHint {
    var tree_count: u32 = 0;
    var total_columns: u32 = 0;
    var height_sum: f32 = 0.0;
    var offset_x_sum: f32 = 0.0;
    var offset_z_sum: f32 = 0.0;
    var best_shape: ?trees.TreeShape = null;

    for (samples) |sample| {
        total_columns += 1;
        if (sample.terrain_height_i <= self.params.sea_level) continue;
        if (sample.surface_block != .grass and sample.surface_block != .dirt and sample.surface_block != .snow_block and sample.surface_block != .sand) continue;

        const shape = trees.treeForColumn(self, sample.biome, sample.world_x, sample.world_z) orelse continue;
        tree_count += 1;
        height_sum += trees.treeHeightForShape(shape);
        offset_x_sum += @as(f32, @floatFromInt(sample.world_x)) - center_wx;
        offset_z_sum += @as(f32, @floatFromInt(sample.world_z)) - center_wz;
        if (best_shape == null) best_shape = shape;
    }

    if (tree_count == 0) return world_core.LODVegetationHint.empty;

    const area = @as(f32, @floatFromInt(@max(total_columns, 1)));
    const sampled_coverage = std.math.clamp(@as(f32, @floatFromInt(tree_count)) / area, 0.0, 1.0);
    const blocks = trees.treeBlocksForShape(best_shape orelse .oak);

    return .{
        .tree_coverage = sampled_coverage,
        .avg_tree_height = height_sum / @as(f32, @floatFromInt(tree_count)),
        .offset_x = offset_x_sum / @as(f32, @floatFromInt(tree_count)),
        .offset_z = offset_z_sum / @as(f32, @floatFromInt(tree_count)),
        .trunk = blocks.trunk,
        .leaves = blocks.leaves,
    };
}

fn dominantBlock(counts: [world_core.MAX_BLOCK_TYPES]u32) BlockType {
    var best_index: usize = @intFromEnum(BlockType.grass);
    var best_count: u32 = 0;
    for (counts, 0..) |count, i| {
        if (count > best_count) {
            best_index = i;
            best_count = count;
        }
    }
    return @enumFromInt(best_index);
}

fn dominantBiome(counts: [256]u32) BiomeId {
    var best_index: usize = @intFromEnum(BiomeId.plains);
    var best_count: u32 = 0;
    for (counts, 0..) |count, i| {
        if (count > best_count) {
            best_index = i;
            best_count = count;
        }
    }
    return @enumFromInt(best_index);
}

fn packAverageColor(r_sum: u32, g_sum: u32, b_sum: u32, count: u32) u32 {
    const r = r_sum / count;
    const g = g_sum / count;
    const b = b_sum / count;
    return (r << 16) | (g << 8) | b;
}
