//! Geometry, material selection, vegetation impostors, and color helpers for LOD mesh generation.

const std = @import("std");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const world_core = @import("world-core");
const BiomeId = world_core.BiomeId;
const biome_mod = @import("biome_color_provider.zig");
const BlockType = world_core.BlockType;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi_types = @import("engine-rhi");
const Vertex = rhi_types.Vertex;
const encodeColor = rhi_types.encodeColor;
const encodeNormal = rhi_types.encodeNormal;
const encodeMeta = rhi_types.encodeMeta;

pub const FullDetailMesh = struct {
    vertices: []Vertex,
    indices: []u32,
};

/// Build a full-detail indexed triangle mesh from LOD heightmap data.
/// Produces fine-grained quads with per-vertex heights suitable for QEM simplification.
/// The mesh uses 1-block resolution: each cell in the heightmap grid becomes a quad
/// subdivided into 2 triangles with separate indices for QEM edge collapse.
pub fn appendIndexedQuad(
    vertices: *std.ArrayListUnmanaged(Vertex),
    indices: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
    quad: *const [4]Vertex,
) !void {
    const base: u32 = @intCast(vertices.items.len);
    try vertices.appendSlice(allocator, quad);
    try indices.appendSlice(allocator, &.{
        base, base + 1, base + 2,
        base, base + 2, base + 3,
    });
}

pub const SkirtParams = struct {
    x: f32,
    z: f32,
    size: f32,
    avg_h: f32,
    avg_c: u32,
    brightness: f32,
    dir: SkirtDir,
};

pub const SkirtDir = enum { north, south, east, west };

/// Computes make skirt quad for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn makeSkirtQuad(params: SkirtParams, tile_id: u16, world_x: i32, world_z: i32) [4]Vertex {
    const p = params;
    const cr = unpackR(p.avg_c) * p.brightness;
    const cg = unpackG(p.avg_c) * p.brightness;
    const cb = unpackB(p.avg_c) * p.brightness;
    const skirt_bottom = p.avg_h - p.size * 4.0;
    const normal: [3]f32 = switch (p.dir) {
        .north => .{ 0, 0, -1 },
        .south => .{ 0, 0, 1 },
        .west => .{ -1, 0, 0 },
        .east => .{ 1, 0, 0 },
    };
    const col = [3]f32{ cr, cg, cb };
    const face_dir = skirtDirToFaceDir(p.dir);
    return switch (p.dir) {
        .north => .{
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z }, col, normal, sideFaceUV(.{ p.x + p.size, skirt_bottom, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, skirt_bottom, p.z }, col, normal, sideFaceUV(.{ p.x, skirt_bottom, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z }, col, normal, sideFaceUV(.{ p.x, p.avg_h, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z }, col, normal, sideFaceUV(.{ p.x + p.size, p.avg_h, p.z }, face_dir, world_x, world_z), tile_id),
        },
        .south => .{
            makeLODVertex(.{ p.x, skirt_bottom, p.z + p.size }, col, normal, sideFaceUV(.{ p.x, skirt_bottom, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z + p.size }, col, normal, sideFaceUV(.{ p.x + p.size, skirt_bottom, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z + p.size }, col, normal, sideFaceUV(.{ p.x + p.size, p.avg_h, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z + p.size }, col, normal, sideFaceUV(.{ p.x, p.avg_h, p.z + p.size }, face_dir, world_x, world_z), tile_id),
        },
        .west => .{
            makeLODVertex(.{ p.x, skirt_bottom, p.z }, col, normal, sideFaceUV(.{ p.x, skirt_bottom, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, skirt_bottom, p.z + p.size }, col, normal, sideFaceUV(.{ p.x, skirt_bottom, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z + p.size }, col, normal, sideFaceUV(.{ p.x, p.avg_h, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z }, col, normal, sideFaceUV(.{ p.x, p.avg_h, p.z }, face_dir, world_x, world_z), tile_id),
        },
        .east => .{
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z + p.size }, col, normal, sideFaceUV(.{ p.x + p.size, skirt_bottom, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z }, col, normal, sideFaceUV(.{ p.x + p.size, skirt_bottom, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z }, col, normal, sideFaceUV(.{ p.x + p.size, p.avg_h, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z + p.size }, col, normal, sideFaceUV(.{ p.x + p.size, p.avg_h, p.z + p.size }, face_dir, world_x, world_z), tile_id),
        },
    };
}

/// Computes build full detail heightmap mesh from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn buildFullDetailHeightmapMesh(
    allocator: std.mem.Allocator,
    lod_level: LODLevel,
    data: *const LODSimplifiedData,
    world_x: i32,
    world_z: i32,
    atlas: *const TextureAtlas,
) !FullDetailMesh {
    const w = data.width;
    const grid_total = w * w;
    if (grid_total == 0) return error.EmptyData;
    const grid_count: usize = @intCast(grid_total);
    std.debug.assert(grid_count <= data.heightmap.len and
        grid_count <= data.biomes.len and
        grid_count <= data.top_blocks.len and
        grid_count <= data.colors.len and
        grid_count <= data.material_layers.len and
        grid_count <= data.water.len and
        grid_count <= data.lighting.len and
        grid_count <= data.vegetation.len);

    if (w < 2) return error.EmptyData;
    const cell_size: f32 = @as(f32, @floatFromInt(lod_chunk.regionSizeBlocks(lod_level))) / @as(f32, @floatFromInt(w - 1));

    var vertices = std.ArrayListUnmanaged(Vertex).empty;
    errdefer vertices.deinit(allocator);
    var indices = std.ArrayListUnmanaged(u32).empty;
    errdefer indices.deinit(allocator);

    var gz: u32 = 0;
    while (gz + 1 < w) : (gz += 1) {
        var gx: u32 = 0;
        while (gx + 1 < w) : (gx += 1) {
            const h00 = data.heightmap[gx + gz * w];
            const h10 = data.heightmap[(gx + 1) + gz * w];
            const h01 = data.heightmap[gx + (gz + 1) * w];
            const h11 = data.heightmap[(gx + 1) + (gz + 1) * w];

            const c00 = data.colors[gx + gz * w];
            const c10 = data.colors[(gx + 1) + gz * w];
            const c01 = data.colors[gx + (gz + 1) * w];
            const c11 = data.colors[(gx + 1) + (gz + 1) * w];
            const wx = @as(f32, @floatFromInt(gx)) * cell_size;
            const wz = @as(f32, @floatFromInt(gz)) * cell_size;
            const size = cell_size;
            const material = selectCellMaterial(data, atlas, gx, gz);

            const top_block = blockForLODQuad(data, gx, gz);
            const top_tile_id = getLodTopTile(top_block, atlas);
            const tc00 = applyTextureLuminance(getLodTopColor(top_block, top_tile_id, applyColorBrightness(c00, data.lighting[gx + gz * w].ambient_occlusion)), top_block, .top, atlas);
            const tc10 = applyTextureLuminance(getLodTopColor(top_block, top_tile_id, applyColorBrightness(c10, data.lighting[(gx + 1) + gz * w].ambient_occlusion)), top_block, .top, atlas);
            const tc01 = applyTextureLuminance(getLodTopColor(top_block, top_tile_id, applyColorBrightness(c01, data.lighting[gx + (gz + 1) * w].ambient_occlusion)), top_block, .top, atlas);
            const tc11 = applyTextureLuminance(getLodTopColor(top_block, top_tile_id, applyColorBrightness(c11, data.lighting[(gx + 1) + (gz + 1) * w].ambient_occlusion)), top_block, .top, atlas);
            const top_quad = [4]Vertex{
                makeLODVertex(.{ wx, h00, wz }, .{ unpackR(tc00), unpackG(tc00), unpackB(tc00) }, .{ 0, 1, 0 }, topFaceUV(.{ wx, h00, wz }, world_x, world_z), top_tile_id),
                makeLODVertex(.{ wx + size, h10, wz }, .{ unpackR(tc10), unpackG(tc10), unpackB(tc10) }, .{ 0, 1, 0 }, topFaceUV(.{ wx + size, h10, wz }, world_x, world_z), top_tile_id),
                makeLODVertex(.{ wx + size, h11, wz + size }, .{ unpackR(tc11), unpackG(tc11), unpackB(tc11) }, .{ 0, 1, 0 }, topFaceUV(.{ wx + size, h11, wz + size }, world_x, world_z), top_tile_id),
                makeLODVertex(.{ wx, h01, wz + size }, .{ unpackR(tc01), unpackG(tc01), unpackB(tc01) }, .{ 0, 1, 0 }, topFaceUV(.{ wx, h01, wz + size }, world_x, world_z), top_tile_id),
            };
            try appendIndexedQuad(&vertices, &indices, allocator, &top_quad);

            if (gz == 0) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h00 + h10) * 0.5,
                .avg_c = averageColor(c00, c10, c00, c10),
                .brightness = 0.7,
                .dir = .north,
            }, material.side, world_x, world_z));
            if (gz == w - 2) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h01 + h11) * 0.5,
                .avg_c = averageColor(c01, c11, c01, c11),
                .brightness = 0.7,
                .dir = .south,
            }, material.side, world_x, world_z));
            if (gx == 0) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h00 + h01) * 0.5,
                .avg_c = averageColor(c00, c01, c00, c01),
                .brightness = 0.8,
                .dir = .west,
            }, material.side, world_x, world_z));
            if (gx == w - 2) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h10 + h11) * 0.5,
                .avg_c = averageColor(c10, c11, c10, c11),
                .brightness = 0.8,
                .dir = .east,
            }, material.side, world_x, world_z));
        }
    }

    return .{
        .vertices = try vertices.toOwnedSlice(allocator),
        .indices = try indices.toOwnedSlice(allocator),
    };
}

pub const FaceDir = enum { north, south, east, west };
pub const WORLDGEN_SEA_LEVEL: f32 = 64.0;
pub const SEA_LEVEL_WATER_EPSILON: f32 = 2.0;
pub const SYNTHETIC_SEAFLOOR_SKIRT: f32 = 8.0;
pub const LOD_TREE_COVERAGE_THRESHOLD: f32 = 0.08;

/// Reports whether is l o d water cell for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn isLODWaterCell(data: *const LODSimplifiedData, gx: u32, gz: u32) bool {
    const stats = waterCoverageStats(data, gx, gz);
    const water_coverage = stats.average_coverage;
    if (water_coverage >= 0.35) return true;
    return stats.wet_samples >= 2 and water_coverage >= 0.25 and stats.representative_depth >= 1.5;
}

/// Reports whether is fine sample l o d for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn isFineSampleLOD(lod_level: LODLevel) bool {
    return @intFromEnum(lod_level) <= @intFromEnum(LODLevel.lod1);
}

/// Reads cell index from the clamped LOD sample grid.
/// Coordinates are clamped to the simplified data width.
pub fn cellIndex(data: *const LODSimplifiedData, gx: u32, gz: u32) u32 {
    return @min(gx, data.width - 1) + @min(gz, data.width - 1) * data.width;
}

/// Computes cell color for l o d for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn cellColorForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) u32 {
    if (isFineSampleLOD(lod_level)) return data.colors[cellIndex(data, gx, gz)];
    const c00 = data.colors[cellIndex(data, gx, gz)];
    const c10 = data.colors[cellIndex(data, gx + 1, gz)];
    const c01 = data.colors[cellIndex(data, gx, gz + 1)];
    const c11 = data.colors[cellIndex(data, gx + 1, gz + 1)];
    return averageColor(c00, c10, c01, c11);
}

/// Reads ambient occlusion for l o d from the clamped LOD sample grid.
/// Coordinates are clamped to the simplified data width.
pub fn ambientOcclusionForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) f32 {
    if (isFineSampleLOD(lod_level)) return data.lighting[cellIndex(data, gx, gz)].ambient_occlusion;
    return averageAmbientOcclusion(data, gx, gz);
}

/// Reports whether is l o d water cell for l o d for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn isLODWaterCellForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) bool {
    if (isFineSampleLOD(lod_level)) {
        const water = data.water[cellIndex(data, gx, gz)];
        return water.is_surface and water.coverage > 0.0 and water.depth >= 0.25;
    }
    return isLODWaterCell(data, gx, gz);
}

/// Computes quantized height from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn quantizedHeight(height: f32) f32 {
    return @round(height);
}

/// Computes terrain height for point from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn terrainHeightForPoint(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const clamped_x = @min(gx, data.width - 1);
    const clamped_z = @min(gz, data.width - 1);
    const idx = clamped_x + clamped_z * data.width;
    const height = terrainSurfaceHeightForPoint(data, clamped_x, clamped_z);
    const water = data.water[idx];
    if (!water.is_surface or water.coverage <= 0.0) return height;

    const floor_height = if (water.depth > 0.0)
        @max(0.0, water.surface_height - water.depth)
    else
        water.surface_height;
    return @min(height, floor_height);
}

/// Computes terrain surface height for point from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn terrainSurfaceHeightForPoint(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const clamped_x = @min(gx, data.width - 1);
    const clamped_z = @min(gz, data.width - 1);
    return stitchedHeight(data, clamped_x, clamped_z);
}

/// Computes quantized terrain height for point from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn quantizedTerrainHeightForPoint(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    return quantizedHeight(terrainHeightForPoint(data, gx, gz));
}

/// Computes quantized cell terrain height from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn quantizedCellTerrainHeight(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    return quantizedHeight(terrainHeightForPoint(data, gx, gz));
}

/// Computes quantized cell surface height from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn quantizedCellSurfaceHeight(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    return quantizedHeight(terrainSurfaceHeightForPoint(data, gx, gz));
}

/// Computes quantized cell terrain height for l o d from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn quantizedCellTerrainHeightForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) f32 {
    if (isFineSampleLOD(lod_level)) return quantizedTerrainHeightForPoint(data, gx, gz);
    return quantizedCellTerrainHeight(data, gx, gz);
}

/// Computes quantized cell visual terrain height for l o d from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn quantizedCellVisualTerrainHeightForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, is_water_cell: bool) f32 {
    if (is_water_cell) return quantizedCellTerrainHeightForLOD(data, gx, gz, lod_level);
    if (isFineSampleLOD(lod_level)) return quantizedHeight(terrainSurfaceHeightForPoint(data, gx, gz));
    return quantizedCellSurfaceHeight(data, gx, gz);
}

/// Computes max water surface height for cell from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn maxWaterSurfaceHeightForCell(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) ?f32 {
    return representativeWaterSurfaceHeightForCell(data, gx, gz, lod_level);
}

/// Computes representative water surface height for cell from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn representativeWaterSurfaceHeightForCell(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) ?f32 {
    if (isFineSampleLOD(lod_level)) {
        const idx = cellIndex(data, gx, gz);
        const water = data.water[idx];
        if (!water.is_surface or water.coverage <= 0.0) return null;
        return normalizedWaterSurfaceHeight(data, idx, water);
    }

    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    for (indices) |idx| {
        const water = data.water[idx];
        if (!water.is_surface or water.coverage <= 0.0) continue;
        return normalizedWaterSurfaceHeight(data, idx, water);
    }

    return null;
}

/// Computes normalized water surface height from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn normalizedWaterSurfaceHeight(data: *const LODSimplifiedData, idx: u32, water: world_core.LODWaterState) f32 {
    if (isOceanBiome(data.biomes[idx]) and @abs(water.surface_height - WORLDGEN_SEA_LEVEL) <= SEA_LEVEL_WATER_EPSILON) {
        return WORLDGEN_SEA_LEVEL;
    }
    return water.surface_height;
}

/// Reports whether is ocean biome for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn isOceanBiome(biome: BiomeId) bool {
    return switch (biome) {
        .deep_ocean, .ocean, .warm_ocean, .frozen_ocean, .cold_ocean => true,
        else => false,
    };
}

/// Computes quantized water surface height for cell from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn quantizedWaterSurfaceHeightForCell(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) f32 {
    if (maxWaterSurfaceHeightForCell(data, gx, gz, lod_level)) |height| return quantizedHeight(height);
    return quantizedCellTerrainHeightForLOD(data, gx, gz, lod_level);
}

/// Computes quantized water surface height for span from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn quantizedWaterSurfaceHeightForSpan(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, fallback_height: f32) f32 {
    if (maxWaterSurfaceHeightForCell(data, gx, gz, lod_level)) |height| return quantizedHeight(height);
    return quantizedHeight(fallback_height);
}

pub const FoldedCanopyColumn = struct {
    height: f32,
    block: BlockType,
    color: u32,
};

/// Reports whether should fold canopy into terrain for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn shouldFoldCanopyIntoTerrain(lod_level: LODLevel) bool {
    _ = lod_level;
    return false;
}

/// Reports whether should render l o d tree trunk for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn shouldRenderLODTreeTrunk(lod_level: LODLevel) bool {
    return @intFromEnum(lod_level) <= @intFromEnum(LODLevel.lod3);
}

/// Computes folded canopy column for l o d for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn foldedCanopyColumnForLOD(
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    base_height: f32,
    terrain_block: BlockType,
    is_water_cell: bool,
) ?FoldedCanopyColumn {
    if (!shouldFoldCanopyIntoTerrain(lod_level) or is_water_cell or !shouldRenderLODTree(terrain_block)) return null;

    const vegetation = representativeVegetationForLOD(data, gx, gz, lod_level);
    if (vegetation.tree_coverage < LOD_TREE_COVERAGE_THRESHOLD or vegetation.avg_tree_height < 2.0) return null;

    const leaves = if (vegetation.leaves == .air) BlockType.leaves else vegetation.leaves;
    const coverage = std.math.clamp(vegetation.tree_coverage, 0.0, 1.0);
    const height_boost = @max(2.0, @max(3.0, vegetation.avg_tree_height) * std.math.clamp(coverage, 0.35, 1.0));
    return .{
        .height = quantizedHeight(base_height + height_boost),
        .block = leaves,
        .color = packBlockDefaultColor(leaves, 0x2F7D2A),
    };
}

/// Computes quantized visual column height for l o d from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn quantizedVisualColumnHeightForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) f32 {
    const is_water_cell = isLODWaterCellForLOD(data, gx, gz, lod_level);
    const terrain_block = terrainBlockForLODQuadForLOD(data, gx, gz, is_water_cell, lod_level);
    const base_height = quantizedCellVisualTerrainHeightForLOD(data, gx, gz, lod_level, is_water_cell);
    if (foldedCanopyColumnForLOD(data, gx, gz, lod_level, base_height, terrain_block, is_water_cell)) |folded| {
        return folded.height;
    }
    return base_height;
}

/// Selects terrain block for l o d quad for a representative LOD terrain cell.
/// The selection folds fine terrain samples into stable coarse LOD material output.
pub fn terrainBlockForLODQuad(data: *const LODSimplifiedData, gx: u32, gz: u32, is_water_cell: bool) BlockType {
    if (!is_water_cell) return blockForLODQuad(data, gx, gz);

    const side_block = sideBlockForLODQuad(data, gx, gz, .water);
    if (side_block != .air and side_block != .water) return side_block;

    const representative = representativeSurfaceBlock(data, gx, gz);
    if (representative != .air and representative != .water) return representative;

    const idx = @min(gx, data.width - 1) + @min(gz, data.width - 1) * data.width;
    return data.biomes[idx].getOceanFloorBlock(representativeWaterDepth(data, gx, gz));
}

/// Selects terrain block for l o d quad for l o d for a representative LOD terrain cell.
/// The selection folds fine terrain samples into stable coarse LOD material output.
pub fn terrainBlockForLODQuadForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, is_water_cell: bool, lod_level: LODLevel) BlockType {
    if (!isFineSampleLOD(lod_level)) return terrainBlockForLODQuad(data, gx, gz, is_water_cell);
    if (!is_water_cell) return blockForLODCell(data, gx, gz);

    const idx = cellIndex(data, gx, gz);
    const subsurface = data.material_layers[idx].subsurface;
    if (subsurface != .air and subsurface != .water) return subsurface;
    const surface = data.material_layers[idx].surface;
    if (surface != .air and surface != .water) return surface;
    return data.biomes[idx].getOceanFloorBlock(data.water[idx].depth);
}

/// Computes get lod side tile for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn getLodSideTile(block: BlockType, atlas: *const TextureAtlas) u16 {
    if (block == .air) return Vertex.LOD_TILE_ID;
    if (isLeafBlock(block)) return Vertex.LOD_TILE_ID;
    const tiles = atlas.getTilesForBlock(@intFromEnum(block));
    if (tiles.side == 0) return Vertex.LOD_TILE_ID;
    return tiles.side;
}

/// Computes boundary skirt depth for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn boundarySkirtDepth(size: f32) f32 {
    return std.math.clamp(size, 16.0, 32.0);
}

/// Computes heightfield side brightness from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn heightfieldSideBrightness(dir: FaceDir) f32 {
    return switch (dir) {
        .west, .east => 0.8,
        .north, .south => 0.7,
    };
}

/// Appends add stepped heightfield sides geometry to the provided mesh buffers.
/// The caller owns the vertex/index lists and receives allocation errors from growth operations.
pub fn addSteppedHeightfieldSides(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    wx: f32,
    wz: f32,
    size: f32,
    column_height: f32,
    color: u32,
    side_tile: u16,
    world_x: i32,
    world_z: i32,
) !void {
    try addHeightfieldSide(allocator, vertices, wx, wz, size, column_height, if (gx == 0) null else quantizedVisualColumnHeightForLOD(data, gx - 1, gz, lod_level), color, side_tile, .west, world_x, world_z);
    try addHeightfieldSide(allocator, vertices, wx, wz, size, column_height, if (gx + 1 >= data.width - 1) null else quantizedVisualColumnHeightForLOD(data, gx + 1, gz, lod_level), color, side_tile, .east, world_x, world_z);
    try addHeightfieldSide(allocator, vertices, wx, wz, size, column_height, if (gz == 0) null else quantizedVisualColumnHeightForLOD(data, gx, gz - 1, lod_level), color, side_tile, .north, world_x, world_z);
    try addHeightfieldSide(allocator, vertices, wx, wz, size, column_height, if (gz + 1 >= data.width - 1) null else quantizedVisualColumnHeightForLOD(data, gx, gz + 1, lod_level), color, side_tile, .south, world_x, world_z);
}

/// Appends add heightfield side geometry to the provided mesh buffers.
/// The caller owns the vertex/index lists and receives allocation errors from growth operations.
pub fn addHeightfieldSide(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    wx: f32,
    wz: f32,
    size: f32,
    column_height: f32,
    neighbor_height: ?f32,
    color: u32,
    side_tile: u16,
    dir: FaceDir,
    world_x: i32,
    world_z: i32,
) !void {
    const bottom = neighbor_height orelse (column_height - boundarySkirtDepth(size));
    if (column_height <= bottom + 0.01) return;
    const brightness = heightfieldSideBrightness(dir);
    try addSideFaceQuad(allocator, vertices, wx, column_height, wz, size, bottom, unpackR(color) * brightness, unpackG(color) * brightness, unpackB(color) * brightness, dir, side_tile, world_x, world_z);
}

pub const LODColumnSpan = struct {
    min_height: f32,
    max_height: f32,
    block: BlockType,
    color: u32,
    ambient_occlusion: f32,
};

pub const HeightInterval = struct {
    min_height: f32,
    max_height: f32,
};

/// Computes collect column spans for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn collectColumnSpans(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, out: *[world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan) usize {
    var count: usize = 0;
    var has_water_span = false;
    var has_solid_span = false;
    var has_canopy_span = false;
    var i: u8 = 0;
    while (i < data.verticalSpanCount(gx, gz)) : (i += 1) {
        const raw = data.getVerticalSpan(gx, gz, i) orelse continue;
        const block = representativeSpanBlock(raw.material_layers);
        if (block == .air) continue;
        const min_height = @min(raw.min_height, raw.max_height);
        const max_height = @max(raw.min_height, raw.max_height);
        if (max_height <= min_height + 0.01) continue;
        if (block == .water) {
            if (!shouldEmitWaterSpanForLOD(data, gx, gz, lod_level, raw.water)) continue;
            has_water_span = true;
        } else {
            has_solid_span = true;
            const terrain_height = data.getHeight(gx, gz);
            if (raw.vegetation.tree_coverage > 0.0 and max_height > terrain_height + 1.0) {
                has_canopy_span = true;
            }
        }
        insertColumnSpan(out, &count, .{
            .min_height = min_height,
            .max_height = max_height,
            .block = block,
            .color = raw.color,
            .ambient_occlusion = raw.lighting.ambient_occlusion,
        });
    }

    if (gx < data.width and gz < data.width) {
        const idx = gx + gz * data.width;
        const vegetation = data.vegetation[idx];
        if (!has_canopy_span and vegetation.tree_coverage >= LOD_TREE_COVERAGE_THRESHOLD and vegetation.avg_tree_height >= 2.0 and count < out.len) {
            const leaves = if (vegetation.leaves == .air) BlockType.leaves else vegetation.leaves;
            const canopy = treeCanopyInterval(quantizedTerrainHeightForPoint(data, gx, gz), vegetation);
            insertColumnSpan(out, &count, .{
                .min_height = canopy.min_height,
                .max_height = canopy.max_height,
                .block = leaves,
                .color = packBlockDefaultColor(leaves, data.colors[idx]),
                .ambient_occlusion = data.lighting[idx].ambient_occlusion,
            });
        }

        const water = data.water[idx];
        if (!has_water_span and shouldEmitWaterSpanForLOD(data, gx, gz, lod_level, water) and count < out.len) {
            has_water_span = true;
            insertColumnSpan(out, &count, .{
                .min_height = water.surface_height - water.depth,
                .max_height = water.surface_height,
                .block = .water,
                .color = data.colors[idx],
                .ambient_occlusion = data.lighting[idx].ambient_occlusion,
            });
        }

        if (has_water_span and !has_solid_span and count < out.len) {
            const terrain_height = quantizedTerrainHeightForPoint(data, gx, gz);
            if (terrain_height > 0.01) {
                const seafloor_block = terrainBlockForLODQuad(data, gx, gz, true);
                insertColumnSpan(out, &count, .{
                    .min_height = syntheticSeafloorMinHeight(data, gx, gz),
                    .max_height = terrain_height,
                    .block = seafloor_block,
                    .color = packBlockDefaultColor(seafloor_block, data.colors[idx]),
                    .ambient_occlusion = data.lighting[idx].ambient_occlusion,
                });
            }
        }
    }
    foldCanopyIntoSpansForLOD(data, gx, gz, lod_level, out, &count);
    return count;
}

/// Computes synthetic seafloor min height from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn syntheticSeafloorMinHeight(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const x_min = if (gx == 0) gx else gx - 1;
    const z_min = if (gz == 0) gz else gz - 1;
    const x_max = @min(gx + 1, data.width - 1);
    const z_max = @min(gz + 1, data.width - 1);

    var min_height: f32 = std.math.floatMax(f32);
    var z = z_min;
    while (z <= z_max) : (z += 1) {
        var x = x_min;
        while (x <= x_max) : (x += 1) {
            min_height = @min(min_height, quantizedTerrainHeightForPoint(data, x, z));
        }
    }
    if (min_height == std.math.floatMax(f32)) return 0.0;
    return @max(0.0, min_height - SYNTHETIC_SEAFLOOR_SKIRT);
}

/// Computes fold canopy into spans for l o d for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn foldCanopyIntoSpansForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, spans: *[world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan, count: *usize) void {
    if (!shouldFoldCanopyIntoTerrain(lod_level) or count.* == 0) return;

    const is_water_cell = isLODWaterCellForLOD(data, gx, gz, lod_level);
    const terrain_block = terrainBlockForLODQuadForLOD(data, gx, gz, is_water_cell, lod_level);
    const base_height = quantizedCellVisualTerrainHeightForLOD(data, gx, gz, lod_level, is_water_cell);
    const folded = foldedCanopyColumnForLOD(data, gx, gz, lod_level, base_height, terrain_block, is_water_cell) orelse return;

    var i: usize = 0;
    while (i < count.*) {
        if (isDetachedCanopySpan(spans[i], base_height)) {
            var j = i;
            while (j + 1 < count.*) : (j += 1) spans[j] = spans[j + 1];
            count.* -= 1;
            continue;
        }
        i += 1;
    }

    var terrain_idx: ?usize = null;
    i = 0;
    while (i < count.*) : (i += 1) {
        if (spans[i].block == .water) continue;
        if (spans[i].min_height <= base_height + 0.01) terrain_idx = i;
    }

    if (terrain_idx) |idx| {
        spans[idx].max_height = @max(spans[idx].max_height, folded.height);
        spans[idx].block = folded.block;
        spans[idx].color = folded.color;
        return;
    }

    insertColumnSpan(spans, count, .{
        .min_height = 0.0,
        .max_height = folded.height,
        .block = folded.block,
        .color = folded.color,
        .ambient_occlusion = ambientOcclusionForLOD(data, gx, gz, lod_level),
    });
}

/// Reports whether is detached canopy span for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn isDetachedCanopySpan(span: LODColumnSpan, base_height: f32) bool {
    return isLeafBlock(span.block) and span.min_height > base_height + 0.5;
}

/// Selects representative span block for a representative LOD terrain cell.
/// The selection folds fine terrain samples into stable coarse LOD material output.
pub fn representativeSpanBlock(layers: world_core.LODMaterialLayers) BlockType {
    if (layers.surface != .air) return layers.surface;
    if (layers.subsurface != .air) return layers.subsurface;
    return layers.foundation;
}

/// Appends insert column span geometry to the provided mesh buffers.
/// The caller owns the vertex/index lists and receives allocation errors from growth operations.
pub fn insertColumnSpan(out: *[world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan, count: *usize, span: LODColumnSpan) void {
    if (count.* >= out.len) return;
    var dst = count.*;
    count.* += 1;
    while (dst > 0 and out[dst - 1].min_height > span.min_height) : (dst -= 1) {
        out[dst] = out[dst - 1];
    }
    out[dst] = span;
}

/// Computes highest solid span index for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn highestSolidSpanIndex(spans: []const LODColumnSpan) ?usize {
    var i = spans.len;
    while (i > 0) {
        i -= 1;
        if (spans[i].block != .water) return i;
    }
    return null;
}

/// Appends add exposed span faces geometry to the provided mesh buffers.
/// The caller owns the vertex/index lists and receives allocation errors from growth operations.
pub fn addExposedSpanFaces(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    span: LODColumnSpan,
    wx: f32,
    wz: f32,
    size: f32,
    color: u32,
    tile_id: u16,
    world_x: i32,
    world_z: i32,
) !void {
    try addExposedSpanFace(allocator, vertices, data, gx, gz, if (gx == 0) null else gx - 1, gz, lod_level, span, wx, wz, size, color, tile_id, .west, world_x, world_z);
    try addExposedSpanFace(allocator, vertices, data, gx, gz, if (gx + 1 >= data.width - 1) null else gx + 1, gz, lod_level, span, wx, wz, size, color, tile_id, .east, world_x, world_z);
    try addExposedSpanFace(allocator, vertices, data, gx, gz, gx, if (gz == 0) null else gz - 1, lod_level, span, wx, wz, size, color, tile_id, .north, world_x, world_z);
    try addExposedSpanFace(allocator, vertices, data, gx, gz, gx, if (gz + 1 >= data.width - 1) null else gz + 1, lod_level, span, wx, wz, size, color, tile_id, .south, world_x, world_z);
}

/// Appends add exposed span face geometry to the provided mesh buffers.
/// The caller owns the vertex/index lists and receives allocation errors from growth operations.
pub fn addExposedSpanFace(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    neighbor_gx: ?u32,
    neighbor_gz: ?u32,
    lod_level: LODLevel,
    span: LODColumnSpan,
    wx: f32,
    wz: f32,
    size: f32,
    color: u32,
    tile_id: u16,
    dir: FaceDir,
    world_x: i32,
    world_z: i32,
) !void {
    _ = gx;
    _ = gz;
    var exposed: [world_core.MAX_LOD_VERTICAL_SPANS + 1]HeightInterval = undefined;
    var exposed_count: usize = 1;
    exposed[0] = .{ .min_height = span.min_height, .max_height = span.max_height };

    if (neighbor_gx == null or neighbor_gz == null) {
        // Without a border apron we do not know the adjacent region column.
        // Treat it as matching this span so region borders do not emit walls.
        subtractCoveredInterval(&exposed, &exposed_count, span.min_height, span.max_height);
    } else {
        const nx = neighbor_gx.?;
        const nz = neighbor_gz.?;
        var neighbor_spans: [world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan = undefined;
        const neighbor_count = collectColumnSpans(data, nx, nz, lod_level, &neighbor_spans);
        var ni: usize = 0;
        while (ni < neighbor_count) : (ni += 1) {
            subtractCoveredInterval(&exposed, &exposed_count, neighbor_spans[ni].min_height, neighbor_spans[ni].max_height);
        }
    }

    var i: usize = 0;
    while (i < exposed_count) : (i += 1) {
        const interval = exposed[i];
        if (interval.max_height <= interval.min_height + 0.01) continue;
        const brightness: f32 = switch (dir) {
            .west, .east => 0.8,
            .north, .south => 0.7,
        };
        try addSideFaceQuad(allocator, vertices, wx, interval.max_height, wz, size, interval.min_height, unpackR(color) * brightness, unpackG(color) * brightness, unpackB(color) * brightness, dir, tile_id, world_x, world_z);
    }
}

/// Computes subtract covered interval for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn subtractCoveredInterval(intervals: *[world_core.MAX_LOD_VERTICAL_SPANS + 1]HeightInterval, count: *usize, cover_min: f32, cover_max: f32) void {
    var i: usize = 0;
    while (i < count.*) {
        const current = intervals[i];
        const overlap_min = @max(current.min_height, cover_min);
        const overlap_max = @min(current.max_height, cover_max);
        if (overlap_max <= overlap_min + 0.01) {
            i += 1;
            continue;
        }

        if (overlap_min <= current.min_height + 0.01 and overlap_max >= current.max_height - 0.01) {
            intervals[i] = intervals[count.* - 1];
            count.* -= 1;
            continue;
        }

        if (overlap_min <= current.min_height + 0.01) {
            intervals[i].min_height = overlap_max;
            i += 1;
            continue;
        }

        if (overlap_max >= current.max_height - 0.01) {
            intervals[i].max_height = overlap_min;
            i += 1;
            continue;
        }

        if (count.* < intervals.len) {
            intervals[i].max_height = overlap_min;
            intervals[count.*] = .{ .min_height = overlap_max, .max_height = current.max_height };
            count.* += 1;
        }
        i += 1;
    }
}

pub const LOD_UV_BLOCK_SCALE: f32 = 1.0;
pub const LOD_UV_WRAP_BLOCKS: i32 = 256;

/// Computes lod u v offset for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn lodUVOffset(coord: i32) f32 {
    return @floatFromInt(@mod(coord, LOD_UV_WRAP_BLOCKS));
}

/// Computes top face u v for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn topFaceUV(pos: [3]f32, world_x: i32, world_z: i32) [2]f32 {
    return .{
        (lodUVOffset(world_x) + pos[0]) * LOD_UV_BLOCK_SCALE,
        (lodUVOffset(world_z) + pos[2]) * LOD_UV_BLOCK_SCALE,
    };
}

/// Computes side face u v for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn sideFaceUV(pos: [3]f32, dir: FaceDir, world_x: i32, world_z: i32) [2]f32 {
    const horizontal = switch (dir) {
        .north, .south => lodUVOffset(world_x) + pos[0],
        .east, .west => lodUVOffset(world_z) + pos[2],
    };
    return .{ horizontal * LOD_UV_BLOCK_SCALE, pos[1] * LOD_UV_BLOCK_SCALE };
}

/// Computes skirt dir to face dir for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn skirtDirToFaceDir(dir: SkirtDir) FaceDir {
    return switch (dir) {
        .north => .north,
        .south => .south,
        .east => .east,
        .west => .west,
    };
}

/// Selects block for l o d cell for a representative LOD terrain cell.
/// The selection folds fine terrain samples into stable coarse LOD material output.
pub fn blockForLODCell(data: *const LODSimplifiedData, gx: u32, gz: u32) BlockType {
    const clamped_x = @min(gx, data.width - 1);
    const clamped_z = @min(gz, data.width - 1);
    const idx = clamped_x + clamped_z * data.width;
    const block = data.material_layers[idx].surface;
    if (block != .air) return block;
    if (data.top_blocks[idx] != .air) return data.top_blocks[idx];
    return data.biomes[idx].getSurfaceBlock();
}

/// Selects block for l o d quad for a representative LOD terrain cell.
/// The selection folds fine terrain samples into stable coarse LOD material output.
pub fn blockForLODQuad(data: *const LODSimplifiedData, gx: u32, gz: u32) BlockType {
    if (isLODWaterCell(data, gx, gz)) return .water;
    return representativeSurfaceBlock(data, gx, gz);
}

/// Selects representative surface block for a representative LOD terrain cell.
/// The selection folds fine terrain samples into stable coarse LOD material output.
pub fn representativeSurfaceBlock(data: *const LODSimplifiedData, gx: u32, gz: u32) BlockType {
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    var best_block: BlockType = .air;
    var best_count: u32 = 0;
    for (indices) |idx| {
        const block = if (data.material_layers[idx].surface != .air) data.material_layers[idx].surface else if (data.top_blocks[idx] != .air) data.top_blocks[idx] else data.biomes[idx].getSurfaceBlock();
        if (block == .air or block == .water) continue;

        var count: u32 = 0;
        for (indices) |other_idx| {
            const other = if (data.material_layers[other_idx].surface != .air) data.material_layers[other_idx].surface else if (data.top_blocks[other_idx] != .air) data.top_blocks[other_idx] else data.biomes[other_idx].getSurfaceBlock();
            if (other == block) count += 1;
        }
        if (count > best_count) {
            best_block = block;
            best_count = count;
        }
    }

    if (best_block != .air) return best_block;
    return blockForLODCell(data, gx, gz);
}

/// Computes representative water depth from water coverage samples.
/// The function treats missing or dry samples as non-water and does not mutate source data.
pub fn representativeWaterDepth(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    var weighted_depth: f32 = 0.0;
    var coverage: f32 = 0.0;
    for (indices) |idx| {
        const water = data.water[idx];
        if (!water.is_surface) continue;
        weighted_depth += water.depth * water.coverage;
        coverage += water.coverage;
    }
    if (coverage <= 0.001) return 0.0;
    return weighted_depth / coverage;
}

/// Selects select cell material for a representative LOD terrain cell.
/// The selection folds fine terrain samples into stable coarse LOD material output.
pub fn selectCellMaterial(data: *const LODSimplifiedData, atlas: *const TextureAtlas, gx: u32, gz: u32) TextureAtlas.BlockTiles {
    const top_block = blockForLODQuad(data, gx, gz);
    const side_block = sideBlockForLODQuad(data, gx, gz, top_block);
    const top_tiles = atlas.getTilesForBlock(@intFromEnum(top_block));
    const side_tiles = atlas.getTilesForBlock(@intFromEnum(side_block));
    return .{
        .top = getLodTopTile(top_block, atlas),
        .bottom = if (top_tiles.bottom == 0) Vertex.LOD_TILE_ID else top_tiles.bottom,
        .side = if (side_tiles.side == 0) Vertex.LOD_TILE_ID else side_tiles.side,
    };
}

/// Selects side block for l o d quad for a representative LOD terrain cell.
/// The selection folds fine terrain samples into stable coarse LOD material output.
pub fn sideBlockForLODQuad(data: *const LODSimplifiedData, gx: u32, gz: u32, top_block: BlockType) BlockType {
    if (top_block != .water) return top_block;

    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    for (indices) |idx| {
        if (data.water[idx].is_surface and data.material_layers[idx].subsurface != .air and data.material_layers[idx].subsurface != .water) {
            return data.material_layers[idx].subsurface;
        }
    }

    return blockForLODCell(data, gx, gz);
}

/// Reports whether should render l o d tree for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn shouldRenderLODTree(top_block: BlockType) bool {
    return top_block != .water and top_block != .air;
}

/// Reports whether is leaf block for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn isLeafBlock(block: BlockType) bool {
    return switch (block) {
        .leaves,
        .mangrove_leaves,
        .jungle_leaves,
        .acacia_leaves,
        .birch_leaves,
        .spruce_leaves,
        => true,
        else => false,
    };
}

/// Derives representative vegetation for l o d for distant vegetation representation.
/// The result is based on simplified vegetation hints and LOD level.
pub fn representativeVegetationForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) world_core.LODVegetationHint {
    if (isFineSampleLOD(lod_level)) return data.vegetation[cellIndex(data, gx, gz)];
    return representativeVegetation(data, gx, gz);
}

/// Derives representative vegetation for distant vegetation representation.
/// The result is based on simplified vegetation hints and LOD level.
pub fn representativeVegetation(data: *const LODSimplifiedData, gx: u32, gz: u32) world_core.LODVegetationHint {
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    var height_sum: f32 = 0.0;
    var height_count: u32 = 0;
    var best = world_core.LODVegetationHint.empty;
    for (indices) |idx| {
        const hint = data.vegetation[idx];
        if (hint.avg_tree_height > 0.0) {
            height_sum += hint.avg_tree_height;
            height_count += 1;
        }
        if (hint.tree_coverage > best.tree_coverage) best = hint;
    }

    best.avg_tree_height = if (height_count == 0) 0.0 else height_sum / @as(f32, @floatFromInt(height_count));
    return best;
}

/// Computes average water coverage from water coverage samples.
/// The function treats missing or dry samples as non-water and does not mutate source data.
pub fn averageWaterCoverage(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    return waterCoverageStats(data, gx, gz).average_coverage;
}

pub const WaterCoverageStats = struct {
    average_coverage: f32,
    wet_samples: u32,
    representative_depth: f32,
};

/// Computes water coverage stats from water coverage samples.
/// The function treats missing or dry samples as non-water and does not mutate source data.
pub fn waterCoverageStats(data: *const LODSimplifiedData, gx: u32, gz: u32) WaterCoverageStats {
    if (data.width == 0) return .{ .average_coverage = 0.0, .wet_samples = 0, .representative_depth = 0.0 };
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    var coverage_sum: f32 = 0.0;
    var weighted_depth: f32 = 0.0;
    var coverage_weight: f32 = 0.0;
    var wet_samples: u32 = 0;
    for (indices) |idx| {
        const water = data.water[idx];
        if (!water.is_surface or water.coverage <= 0.0 or water.depth <= 0.01) continue;
        coverage_sum += water.coverage;
        weighted_depth += water.depth * water.coverage;
        coverage_weight += water.coverage;
        wet_samples += 1;
    }

    return .{
        .average_coverage = coverage_sum * 0.25,
        .wet_samples = wet_samples,
        .representative_depth = if (coverage_weight <= 0.001) 0.0 else weighted_depth / coverage_weight,
    };
}

/// Reports whether should emit water span for l o d for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn shouldEmitWaterSpanForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, water: world_core.LODWaterState) bool {
    if (!water.is_surface or water.coverage <= 0.0 or water.depth <= 0.01) return false;
    if (isFineSampleLOD(lod_level)) return true;
    if (water.coverage >= 0.35) return true;

    const stats = waterCoverageStats(data, gx, gz);
    return stats.wet_samples >= 2 and stats.average_coverage >= 0.25 and stats.representative_depth >= 1.5;
}

/// Computes stitched height from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn stitchedHeight(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const height = data.getHeight(gx, gz);
    if (data.width < 5) return height;

    const blend_cells: u32 = 2;
    const max_idx = data.width - 1;
    const edge_dist = @min(@min(gx, gz), @min(max_idx - gx, max_idx - gz));
    if (edge_dist >= blend_cells) return height;

    const coarse_x = @min(((gx + 1) / 2) * 2, max_idx);
    const coarse_z = @min(((gz + 1) / 2) * 2, max_idx);
    const coarse_height = data.getHeight(coarse_x, coarse_z);
    const edge_weight = 1.0 - (@as(f32, @floatFromInt(edge_dist)) / @as(f32, @floatFromInt(blend_cells)));
    const blend = edge_weight * 0.35;
    return height * (1.0 - blend) + coarse_height * blend;
}

/// Computes max stitched height adjustment from LOD terrain and water samples.
/// Returned heights are in world/block units and may be quantized for seam stability.
pub fn maxStitchedHeightAdjustment(data: *const LODSimplifiedData) f32 {
    if (data.width < 5) return 0.0;

    var max_adjust: f32 = 0.0;
    var i: u32 = 0;
    while (i < data.width) : (i += 1) {
        max_adjust = @max(max_adjust, @abs(data.getHeight(i, 0) - stitchedHeight(data, i, 0)));
        max_adjust = @max(max_adjust, @abs(data.getHeight(i, data.width - 1) - stitchedHeight(data, i, data.width - 1)));
        max_adjust = @max(max_adjust, @abs(data.getHeight(0, i) - stitchedHeight(data, 0, i)));
        max_adjust = @max(max_adjust, @abs(data.getHeight(data.width - 1, i) - stitchedHeight(data, data.width - 1, i)));
    }
    return max_adjust;
}

// Helper functions for unpacking colors
/// Computes unpack r for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn unpackR(color: u32) f32 {
    return @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
}

/// Computes unpack g for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn unpackG(color: u32) f32 {
    return @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
}

/// Computes unpack b for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn unpackB(color: u32) f32 {
    return @as(f32, @floatFromInt(color & 0xFF)) / 255.0;
}

/// Computes average color for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn averageColor(c00: u32, c10: u32, c01: u32, c11: u32) u32 {
    const r = ((c00 >> 16) & 0xFF) + ((c10 >> 16) & 0xFF) + ((c01 >> 16) & 0xFF) + ((c11 >> 16) & 0xFF);
    const g = ((c00 >> 8) & 0xFF) + ((c10 >> 8) & 0xFF) + ((c01 >> 8) & 0xFF) + ((c11 >> 8) & 0xFF);
    const b = (c00 & 0xFF) + (c10 & 0xFF) + (c01 & 0xFF) + (c11 & 0xFF);
    const r_avg: u32 = r / 4;
    const g_avg: u32 = g / 4;
    const b_avg: u32 = b / 4;
    return (r_avg << 16) | (g_avg << 8) | b_avg;
}

/// Computes average ambient occlusion for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn averageAmbientOcclusion(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const a00 = data.lighting[x0 + z0 * data.width].ambient_occlusion;
    const a10 = data.lighting[x1 + z0 * data.width].ambient_occlusion;
    const a01 = data.lighting[x0 + z1 * data.width].ambient_occlusion;
    const a11 = data.lighting[x1 + z1 * data.width].ambient_occlusion;
    return (a00 + a10 + a01 + a11) * 0.25;
}

/// Computes apply color brightness for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn applyColorBrightness(color: u32, brightness: f32) u32 {
    const clamped = std.math.clamp(brightness, 0.0, 1.0);
    const r: u32 = @intFromFloat(@round(@as(f32, @floatFromInt((color >> 16) & 0xFF)) * clamped));
    const g: u32 = @intFromFloat(@round(@as(f32, @floatFromInt((color >> 8) & 0xFF)) * clamped));
    const b: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(color & 0xFF)) * clamped));
    return (r << 16) | (g << 8) | b;
}

pub const LODTextureFace = enum { top, side, bottom };

/// Computes tint color for lod face for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn tintColorForLodFace(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, block: BlockType, face: LODTextureFace, fallback: u32) u32 {
    if (block == .grass and face == .top) return averageBiomeBlockTint(data, gx, gz, lod_level, block);
    if (block == .water) return averageBiomeBlockTint(data, gx, gz, lod_level, block);
    if (isLeafBlock(block)) return averageBiomeBlockTint(data, gx, gz, lod_level, block);
    return fallback;
}

/// Computes average biome block tint for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn averageBiomeBlockTint(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, block: BlockType) u32 {
    if (isFineSampleLOD(lod_level)) {
        return biome_mod.getBlockTintColor(data.biomes[cellIndex(data, gx, gz)], block);
    }

    const c00 = biome_mod.getBlockTintColor(data.biomes[cellIndex(data, gx, gz)], block);
    const c10 = biome_mod.getBlockTintColor(data.biomes[cellIndex(data, gx + 1, gz)], block);
    const c01 = biome_mod.getBlockTintColor(data.biomes[cellIndex(data, gx, gz + 1)], block);
    const c11 = biome_mod.getBlockTintColor(data.biomes[cellIndex(data, gx + 1, gz + 1)], block);
    return averageColor(c00, c10, c01, c11);
}

/// Computes apply texture luminance for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn applyTextureLuminance(color: u32, block: BlockType, face: LODTextureFace, atlas: *const TextureAtlas) u32 {
    if (block == .air or block == .water) return color;
    const texture_color = averageTextureColorForFace(block, face, atlas) orelse {
        const luminance = atlas.getLuminanceForBlock(@intFromEnum(block));
        const factor = switch (face) {
            .top => luminance.top,
            .side => luminance.side,
            .bottom => luminance.bottom,
        };
        return scaleColor(color, std.math.clamp(factor, 0.18, 1.0));
    };

    if (!shouldTintLodFace(block, face)) return texture_color;
    return multiplyColors(texture_color, shaderLikeTintColor(color));
}

/// Computes average texture color for face for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn averageTextureColorForFace(block: BlockType, face: LODTextureFace, atlas: *const TextureAtlas) ?u32 {
    const tiles = atlas.getTilesForBlock(@intFromEnum(block));
    const tile_id = switch (face) {
        .top => tiles.top,
        .bottom => tiles.bottom,
        .side => tiles.side,
    };
    if (tile_id == 0) return null;

    const colors = atlas.getAverageColorForBlock(@intFromEnum(block));
    return switch (face) {
        .top => colors.top,
        .bottom => colors.bottom,
        .side => colors.side,
    };
}

/// Reports whether should tint lod face for a sampled LOD cell or span.
/// The query is deterministic and does not mutate the supplied simplified data.
pub fn shouldTintLodFace(block: BlockType, face: LODTextureFace) bool {
    if (block == .grass) return face == .top;
    if (block == .water) return true;
    return isLeafBlock(block);
}

/// Computes multiply colors for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn multiplyColors(base: u32, tint: u32) u32 {
    const r: u32 = @intFromFloat(@round(unpackR(base) * unpackR(tint) * 255.0));
    const g: u32 = @intFromFloat(@round(unpackG(base) * unpackG(tint) * 255.0));
    const b: u32 = @intFromFloat(@round(unpackB(base) * unpackB(tint) * 255.0));
    const rr: u32 = @min(r, 255);
    const gg: u32 = @min(g, 255);
    const bb: u32 = @min(b, 255);
    return (rr << 16) | (gg << 8) | bb;
}

/// Computes shader like tint color for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn shaderLikeTintColor(color: u32) u32 {
    const r: u32 = (color >> 16) & 0xFF;
    const g: u32 = (color >> 8) & 0xFF;
    const b: u32 = color & 0xFF;
    const max_channel = @max(r, @max(g, b));
    if (max_channel == 0) return 0xFFFFFF;

    const min_channel = @min(r, @min(g, b));
    const chroma = @as(f32, @floatFromInt(max_channel - min_channel)) / @as(f32, @floatFromInt(max_channel));
    const tint_strength = smoothstep(0.05, 0.2, chroma);

    const max_f = @as(f32, @floatFromInt(max_channel));
    const nr = @as(f32, @floatFromInt(r)) / max_f;
    const ng = @as(f32, @floatFromInt(g)) / max_f;
    const nb = @as(f32, @floatFromInt(b)) / max_f;
    const out_r: u32 = @intFromFloat(@round((1.0 + (nr - 1.0) * tint_strength) * 255.0));
    const out_g: u32 = @intFromFloat(@round((1.0 + (ng - 1.0) * tint_strength) * 255.0));
    const out_b: u32 = @intFromFloat(@round((1.0 + (nb - 1.0) * tint_strength) * 255.0));
    const rr: u32 = @min(out_r, 255);
    const gg: u32 = @min(out_g, 255);
    const bb: u32 = @min(out_b, 255);
    return (rr << 16) | (gg << 8) | bb;
}

/// Computes smoothstep for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// Computes scale color for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn scaleColor(color: u32, factor: f32) u32 {
    const clamped = std.math.clamp(factor, 0.0, 2.0);
    const r: u32 = @intFromFloat(@round(std.math.clamp(@as(f32, @floatFromInt((color >> 16) & 0xFF)) * clamped, 0.0, 255.0)));
    const g: u32 = @intFromFloat(@round(std.math.clamp(@as(f32, @floatFromInt((color >> 8) & 0xFF)) * clamped, 0.0, 255.0)));
    const b: u32 = @intFromFloat(@round(std.math.clamp(@as(f32, @floatFromInt(color & 0xFF)) * clamped, 0.0, 255.0)));
    return (r << 16) | (g << 8) | b;
}

/// Computes pack block default color for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn packBlockDefaultColor(block: BlockType, fallback: u32) u32 {
    if (block == .air) return fallback;
    const color = world_core.block_registry.getBlockDefinition(block).default_color;
    const r: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0));
    return (r << 16) | (g << 8) | b;
}

/// Computes get lod top tile for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn getLodTopTile(block: BlockType, atlas: *const TextureAtlas) u16 {
    if (block == .air) return Vertex.LOD_TILE_ID;
    if (isLeafBlock(block)) return Vertex.LOD_TILE_ID;

    const tiles = atlas.getTilesForBlock(@intFromEnum(block));
    if (tiles.top == 0) return Vertex.LOD_TILE_ID;
    return tiles.top;
}

/// Computes get lod top color for LOD material shading.
/// Inputs are packed RGB or biome/material samples; the result is safe to store in mesh vertices.
pub fn getLodTopColor(block: BlockType, tile_id: u16, fallback_color: u32) u32 {
    _ = block;
    if (tile_id == Vertex.LOD_TILE_ID) return fallback_color;
    return fallback_color;
}

/// Computes make l o d vertex for LOD mesh generation.
/// The function is pure with respect to caller-owned world data unless output buffers are explicit parameters.
pub fn makeLODVertex(pos: [3]f32, col: [3]f32, norm: [3]f32, uv: [2]f32, tile_id: u16) Vertex {
    return Vertex{
        .pos = pos,
        .color = encodeColor(col),
        .normal = encodeNormal(norm),
        .uv = .{ @floatCast(uv[0]), @floatCast(uv[1]) },
        .packed_meta = encodeMeta(tile_id, 1.0, 1.0),
        .blocklight = 0,
        .entrance_dir = 0,
    };
}

/// Add a top-facing quad (two triangles)
pub fn addTopFaceQuad(allocator: std.mem.Allocator, vertices: *std.ArrayListUnmanaged(Vertex), x: f32, y: f32, z: f32, size: f32, r: f32, g: f32, b: f32, tile_id: u16, world_x: i32, world_z: i32) !void {
    const normal = [3]f32{ 0, 1, 0 };
    const color = [3]f32{ r, g, b };

    try vertices.append(allocator, makeLODVertex(.{ x, y, z }, color, normal, topFaceUV(.{ x, y, z }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z + size }, color, normal, topFaceUV(.{ x + size, y, z + size }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x, y, z + size }, color, normal, topFaceUV(.{ x, y, z + size }, world_x, world_z), tile_id));

    try vertices.append(allocator, makeLODVertex(.{ x, y, z }, color, normal, topFaceUV(.{ x, y, z }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z + size }, color, normal, topFaceUV(.{ x + size, y, z + size }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z }, color, normal, topFaceUV(.{ x + size, y, z }, world_x, world_z), tile_id));
}

/// Add a downward-facing bottom quad for floating spans (overhangs) so
/// caves/arches read correctly from below (issue #752 Phase 3.3).
pub fn addBottomFaceQuad(allocator: std.mem.Allocator, vertices: *std.ArrayListUnmanaged(Vertex), x: f32, y: f32, z: f32, size: f32, r: f32, g: f32, b: f32, tile_id: u16, world_x: i32, world_z: i32) !void {
    const normal = [3]f32{ 0, -1, 0 };
    const color = [3]f32{ r, g, b };

    try vertices.append(allocator, makeLODVertex(.{ x, y, z }, color, normal, topFaceUV(.{ x, y, z }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x, y, z + size }, color, normal, topFaceUV(.{ x, y, z + size }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z + size }, color, normal, topFaceUV(.{ x + size, y, z + size }, world_x, world_z), tile_id));

    try vertices.append(allocator, makeLODVertex(.{ x, y, z }, color, normal, topFaceUV(.{ x, y, z }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z + size }, color, normal, topFaceUV(.{ x + size, y, z + size }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z }, color, normal, topFaceUV(.{ x + size, y, z }, world_x, world_z), tile_id));
}

/// Add a side-facing quad for cliff faces
pub fn addSideFaceQuad(allocator: std.mem.Allocator, vertices: *std.ArrayListUnmanaged(Vertex), x: f32, y_top: f32, z: f32, size: f32, y_bottom: f32, r: f32, g: f32, b: f32, dir: FaceDir, tile_id: u16, world_x: i32, world_z: i32) !void {
    const color = [3]f32{ r, g, b };

    const normal: [3]f32 = switch (dir) {
        .north => .{ 0, 0, -1 },
        .south => .{ 0, 0, 1 },
        .east => .{ 1, 0, 0 },
        .west => .{ -1, 0, 0 },
    };

    // Calculate quad corners based on direction
    const corners: [4][3]f32 = switch (dir) {
        .west => .{
            .{ x, y_bottom, z },
            .{ x, y_bottom, z + size },
            .{ x, y_top, z + size },
            .{ x, y_top, z },
        },
        .east => .{
            .{ x + size, y_bottom, z + size },
            .{ x + size, y_bottom, z },
            .{ x + size, y_top, z },
            .{ x + size, y_top, z + size },
        },
        .north => .{
            .{ x + size, y_bottom, z },
            .{ x, y_bottom, z },
            .{ x, y_top, z },
            .{ x + size, y_top, z },
        },
        .south => .{
            .{ x, y_bottom, z + size },
            .{ x + size, y_bottom, z + size },
            .{ x + size, y_top, z + size },
            .{ x, y_top, z + size },
        },
    };

    try vertices.append(allocator, makeLODVertex(corners[0], color, normal, sideFaceUV(corners[0], dir, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(corners[1], color, normal, sideFaceUV(corners[1], dir, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(corners[2], color, normal, sideFaceUV(corners[2], dir, world_x, world_z), tile_id));

    try vertices.append(allocator, makeLODVertex(corners[0], color, normal, sideFaceUV(corners[0], dir, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(corners[2], color, normal, sideFaceUV(corners[2], dir, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(corners[3], color, normal, sideFaceUV(corners[3], dir, world_x, world_z), tile_id));
}

/// Appends add tree column geometry to the provided mesh buffers.
/// The caller owns the vertex/index lists and receives allocation errors from growth operations.
pub fn addTreeColumn(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    wx: f32,
    wz: f32,
    cell_size: f32,
    base_height: f32,
    vegetation: world_core.LODVegetationHint,
    atlas: *const TextureAtlas,
    world_x: i32,
    world_z: i32,
) !void {
    if (vegetation.leaves == .air) return;

    const canopy = treeCanopyInterval(base_height, vegetation);
    try addTreeCanopyColumn(allocator, vertices, data, gx, gz, lod_level, wx, wz, cell_size, base_height, canopy.min_height, canopy.max_height, vegetation, atlas, world_x, world_z);
}

/// Appends add tree canopy column geometry to the provided mesh buffers.
/// The caller owns the vertex/index lists and receives allocation errors from growth operations.
pub fn addTreeCanopyColumn(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    wx: f32,
    wz: f32,
    cell_size: f32,
    base_height: f32,
    canopy_min_height: f32,
    canopy_max_height: f32,
    vegetation: world_core.LODVegetationHint,
    atlas: *const TextureAtlas,
    world_x: i32,
    world_z: i32,
) !void {
    if (vegetation.leaves == .air) return;
    if (canopy_max_height <= canopy_min_height + 0.01) return;

    const leaf_tile = Vertex.LOD_TILE_ID;
    const leaf_base_color = tintColorForLodFace(data, gx, gz, lod_level, vegetation.leaves, .top, packBlockDefaultColor(vegetation.leaves, 0x2F7D2A));
    const leaf_top_color = applyTextureLuminance(leaf_base_color, vegetation.leaves, .top, atlas);
    const footprint = treeCanopyFootprint(cell_size, vegetation);
    const origin = treeFootprintOrigin(wx, wz, cell_size, footprint, vegetation);
    try addBoxColumn(allocator, vertices, origin.x, origin.z, footprint, canopy_min_height, canopy_max_height, leaf_top_color, leaf_tile, world_x, world_z);

    if (shouldRenderLODTreeTrunk(lod_level) and vegetation.trunk != .air and canopy_min_height > base_height + 1.0) {
        const trunk_tiles = atlas.getTilesForBlock(@intFromEnum(vegetation.trunk));
        const trunk_tile = if (trunk_tiles.side == 0) Vertex.LOD_TILE_ID else trunk_tiles.side;
        const trunk_color = applyTextureLuminance(0xFFFFFF, vegetation.trunk, .side, atlas);
        const trunk_size = @min(footprint * 0.35, @max(0.65, cell_size * 0.18));
        const trunk_inset = (footprint - trunk_size) * 0.5;
        try addBoxColumn(allocator, vertices, origin.x + trunk_inset, origin.z + trunk_inset, trunk_size, base_height, canopy_min_height, trunk_color, trunk_tile, world_x, world_z);
    }
}

/// Derives tree canopy footprint for distant vegetation representation.
/// The result is based on simplified vegetation hints and LOD level.
pub fn treeCanopyFootprint(cell_size: f32, vegetation: world_core.LODVegetationHint) f32 {
    const coverage = std.math.clamp(vegetation.tree_coverage, LOD_TREE_COVERAGE_THRESHOLD, 1.0);
    const desired = @max(1.0, vegetation.avg_tree_height * (0.30 + coverage * 0.18));
    const min_size = @min(cell_size, 1.35);
    const max_size = @max(min_size, cell_size * 0.72);
    return std.math.clamp(desired, min_size, max_size);
}

pub const TreeFootprintOrigin = struct { x: f32, z: f32 };

/// Derives tree footprint origin for distant vegetation representation.
/// The result is based on simplified vegetation hints and LOD level.
pub fn treeFootprintOrigin(wx: f32, wz: f32, cell_size: f32, footprint: f32, vegetation: world_core.LODVegetationHint) TreeFootprintOrigin {
    const max_offset = @max(0.0, (cell_size - footprint) * 0.5 - 0.01);
    const offset_x = std.math.clamp(vegetation.offset_x, -max_offset, max_offset);
    const offset_z = std.math.clamp(vegetation.offset_z, -max_offset, max_offset);
    return .{
        .x = wx + (cell_size - footprint) * 0.5 + offset_x,
        .z = wz + (cell_size - footprint) * 0.5 + offset_z,
    };
}

/// Derives tree canopy interval for distant vegetation representation.
/// The result is based on simplified vegetation hints and LOD level.
pub fn treeCanopyInterval(base_height: f32, vegetation: world_core.LODVegetationHint) HeightInterval {
    const canopy_height = @max(3.0, vegetation.avg_tree_height);
    const top = base_height + canopy_height;
    const depth = @max(2.0, canopy_height * 0.45);
    return .{
        .min_height = @max(base_height + 1.0, top - depth),
        .max_height = top,
    };
}

/// Appends add tree column sides geometry to the provided mesh buffers.
/// The caller owns the vertex/index lists and receives allocation errors from growth operations.
pub fn addTreeColumnSides(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    wx: f32,
    wz: f32,
    size: f32,
    canopy: HeightInterval,
    color: u32,
    tile_id: u16,
    world_x: i32,
    world_z: i32,
) !void {
    try addTreeColumnSide(allocator, vertices, data, if (gx == 0) null else gx - 1, gz, lod_level, wx, wz, size, canopy, color, tile_id, .west, world_x, world_z);
    try addTreeColumnSide(allocator, vertices, data, if (gx + 1 >= data.width - 1) null else gx + 1, gz, lod_level, wx, wz, size, canopy, color, tile_id, .east, world_x, world_z);
    try addTreeColumnSide(allocator, vertices, data, gx, if (gz == 0) null else gz - 1, lod_level, wx, wz, size, canopy, color, tile_id, .north, world_x, world_z);
    try addTreeColumnSide(allocator, vertices, data, gx, if (gz + 1 >= data.width - 1) null else gz + 1, lod_level, wx, wz, size, canopy, color, tile_id, .south, world_x, world_z);
}

/// Appends add tree column side geometry to the provided mesh buffers.
/// The caller owns the vertex/index lists and receives allocation errors from growth operations.
pub fn addTreeColumnSide(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    neighbor_gx: ?u32,
    neighbor_gz: ?u32,
    lod_level: LODLevel,
    wx: f32,
    wz: f32,
    size: f32,
    canopy: HeightInterval,
    color: u32,
    tile_id: u16,
    dir: FaceDir,
    world_x: i32,
    world_z: i32,
) !void {
    var exposed: [world_core.MAX_LOD_VERTICAL_SPANS + 1]HeightInterval = undefined;
    var exposed_count: usize = 1;
    exposed[0] = canopy;

    if (neighbor_gx) |nx| {
        if (neighbor_gz) |nz| {
            const neighbor_veg = representativeVegetationForLOD(data, nx, nz, lod_level);
            if (neighbor_veg.tree_coverage >= LOD_TREE_COVERAGE_THRESHOLD) {
                const neighbor_is_water_cell = isLODWaterCellForLOD(data, nx, nz, lod_level);
                const neighbor_base = quantizedCellVisualTerrainHeightForLOD(data, nx, nz, lod_level, neighbor_is_water_cell);
                const neighbor_canopy = treeCanopyInterval(neighbor_base, neighbor_veg);
                subtractCoveredInterval(&exposed, &exposed_count, neighbor_canopy.min_height, neighbor_canopy.max_height);
            }
        }
    }

    var i: usize = 0;
    while (i < exposed_count) : (i += 1) {
        const interval = exposed[i];
        if (interval.max_height <= interval.min_height + 0.01) continue;
        const brightness = heightfieldSideBrightness(dir);
        try addSideFaceQuad(allocator, vertices, wx, interval.max_height, wz, size, interval.min_height, unpackR(color) * brightness, unpackG(color) * brightness, unpackB(color) * brightness, dir, tile_id, world_x, world_z);
    }
}

/// Appends add box column geometry to the provided mesh buffers.
/// The caller owns the vertex/index lists and receives allocation errors from growth operations.
pub fn addBoxColumn(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    x: f32,
    z: f32,
    size: f32,
    min_height: f32,
    max_height: f32,
    color: u32,
    tile_id: u16,
    world_x: i32,
    world_z: i32,
) !void {
    if (max_height <= min_height + 0.01) return;
    try addTopFaceQuad(allocator, vertices, x, max_height, z, size, unpackR(color), unpackG(color), unpackB(color), tile_id, world_x, world_z);
    try addSideFaceQuad(allocator, vertices, x, max_height, z, size, min_height, unpackR(color) * 0.8, unpackG(color) * 0.8, unpackB(color) * 0.8, .west, tile_id, world_x, world_z);
    try addSideFaceQuad(allocator, vertices, x, max_height, z, size, min_height, unpackR(color) * 0.8, unpackG(color) * 0.8, unpackB(color) * 0.8, .east, tile_id, world_x, world_z);
    try addSideFaceQuad(allocator, vertices, x, max_height, z, size, min_height, unpackR(color) * 0.7, unpackG(color) * 0.7, unpackB(color) * 0.7, .north, tile_id, world_x, world_z);
    try addSideFaceQuad(allocator, vertices, x, max_height, z, size, min_height, unpackR(color) * 0.7, unpackG(color) * 0.7, unpackB(color) * 0.7, .south, tile_id, world_x, world_z);
}
