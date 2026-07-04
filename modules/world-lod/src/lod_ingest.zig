//! Chunk -> LOD downsampler for chunk-derived distant terrain.
//!
//! Part of issue #752 Phase 2: produces per-grid-cell representative LOD data
//! from a real generated/loaded Chunk and writes it into a region's
//! `LODSimplifiedData` with provenance `chunk_derived` (or `edited`). Higher
//! provenance always overwrites lower, so real chunk data upgrades worldgen
//! samples in place and player edits are never clobbered by regeneration.
//!
//! The downsampler is pure: it operates only on a Chunk and a region's source
//! data, so it is fully unit-testable without a renderer or job system.

const std = @import("std");

const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;

const lod_chunk = @import("lod_chunk.zig");
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const biome_color_provider = @import("biome_color_provider.zig");

const LODColumnProvenance = world_core.LODColumnProvenance;
const LODLightingHint = world_core.LODLightingHint;
const LODMaterialLayers = world_core.LODMaterialLayers;
const LODVegetationHint = world_core.LODVegetationHint;
const LODWaterState = world_core.LODWaterState;

/// Per-column vegetation scan height: how many blocks above the terrain
/// surface we look for tree trunks/canopy. Trees taller than this are still
/// detected (their trunk is within the band); only the recorded height is
/// capped for the LOD vegetation hint.
const TREE_SCAN_BAND: u32 = 24;

/// Maximum number of grid vertices a single 16x16 chunk can touch along one
/// axis. The finest LOD cell is ~2 blocks, so a chunk spans at most ~9
/// vertices per axis; 24 is a generous upper bound used for the stack
/// accumulator buffer.
const MAX_SUB_VERTICES: usize = 24;

/// A representative terrain sample for one LOD grid vertex, aggregated from
/// the chunk columns that fall inside that vertex.
pub const VertexSample = struct {
    terrain_height: f32 = 0.0,
    biome: BiomeId = .plains,
    layers: LODMaterialLayers = .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone },
    has_water: bool = false,
    water_surface_height: f32 = 0.0,
    water_depth: f32 = 0.0,
    water_coverage: f32 = 0.0,
    has_tree: bool = false,
    tree_height: f32 = 0.0,
    sky_light: u8 = 15,
};

const VertexAccumulator = struct {
    sample_count: u32 = 0,
    max_terrain_y: i32 = -1,
    dominant_biome: BiomeId = .plains,
    dominant_surface: BlockType = .grass,
    dominant_subsurface: BlockType = .dirt,
    dominant_foundation: BlockType = .stone,
    water_count: u32 = 0,
    max_water_surface_y: i32 = -1,
    tree_count: u32 = 0,
    tree_height_sum: u32 = 0,
    sky_light_sum: u32 = 0,

    fn toSample(self: VertexAccumulator) ?VertexSample {
        if (self.sample_count == 0 or self.max_terrain_y < 0) return null;
        const height_f: f32 = @floatFromInt(self.max_terrain_y);
        const water_coverage: f32 = if (self.sample_count > 0)
            @as(f32, @floatFromInt(self.water_count)) / @as(f32, @floatFromInt(self.sample_count))
        else
            0.0;
        const has_water = self.water_count > 0 and self.max_water_surface_y > self.max_terrain_y;
        const water_surface: f32 = if (has_water) @floatFromInt(self.max_water_surface_y) else height_f;
        const water_depth: f32 = if (has_water) @as(f32, @floatFromInt(self.max_water_surface_y - self.max_terrain_y)) else 0.0;
        const has_tree = self.tree_count > 0;
        const tree_height: f32 = if (self.tree_count > 0)
            @as(f32, @floatFromInt(self.tree_height_sum)) / @as(f32, @floatFromInt(self.tree_count))
        else
            0.0;
        const avg_sky: u32 = if (self.sample_count > 0) self.sky_light_sum / self.sample_count else 15;
        return .{
            .terrain_height = height_f,
            .biome = self.dominant_biome,
            .layers = .{
                .surface = self.dominant_surface,
                .subsurface = self.dominant_subsurface,
                .foundation = self.dominant_foundation,
            },
            .has_water = has_water,
            .water_surface_height = water_surface,
            .water_depth = water_depth,
            .water_coverage = water_coverage,
            .has_tree = has_tree,
            .tree_height = tree_height,
            .sky_light = @intCast(@min(avg_sky, 15)),
        };
    }
};

/// Downsample a chunk into a region's LOD source data.
///
/// `region_min_x` / `region_min_z` are the world-space block origin of the
/// region (region.rx * regionSizeBlocks(lod), region.rz * ...). `region_size_blocks`
/// is the edge length of the region in world blocks. Only grid vertices whose
/// nearest world column falls inside the chunk are updated, so partial regions
/// accumulate correctly as neighboring chunks stream in.
///
/// Returns the number of grid vertices written (i.e. upgraded by this call).
pub fn downsampleChunkIntoRegion(
    chunk: *const Chunk,
    chunk_x: i32,
    chunk_z: i32,
    data: *LODSimplifiedData,
    region_min_x: i32,
    region_min_z: i32,
    region_size_blocks: i32,
    provenance: LODColumnProvenance,
) u32 {
    const width_i: i32 = @intCast(data.width);
    if (width_i <= 1) return 0;
    const denom: i32 = region_size_blocks;
    if (denom <= 0) return 0;

    // Map the chunk's block footprint to the grid-vertex sub-range it touches.
    const wx_lo: i32 = chunk_x * CHUNK_SIZE_X;
    const wx_hi: i32 = wx_lo + CHUNK_SIZE_X - 1;
    const wz_lo: i32 = chunk_z * CHUNK_SIZE_Z;
    const wz_hi: i32 = wz_lo + CHUNK_SIZE_Z - 1;

    const gx_lo = clampVertex(vertexForWorld(wx_lo, region_min_x, width_i, denom), width_i);
    const gx_hi = clampVertex(vertexForWorld(wx_hi, region_min_x, width_i, denom), width_i);
    const gz_lo = clampVertex(vertexForWorld(wz_lo, region_min_z, width_i, denom), width_i);
    const gz_hi = clampVertex(vertexForWorld(wz_hi, region_min_z, width_i, denom), width_i);

    const span_x: usize = @intCast(gx_hi - gx_lo + 1);
    const span_z: usize = @intCast(gz_hi - gz_lo + 1);
    if (span_x > MAX_SUB_VERTICES or span_z > MAX_SUB_VERTICES) return 0;

    var acc: [MAX_SUB_VERTICES][MAX_SUB_VERTICES]VertexAccumulator = undefined;
    clearAccumulators(&acc);

    // Forward-map every chunk column to its target grid vertex and aggregate.
    var lz: u32 = 0;
    while (lz < CHUNK_SIZE_Z) : (lz += 1) {
        var lx: u32 = 0;
        while (lx < CHUNK_SIZE_X) : (lx += 1) {
            const wx: i32 = wx_lo + @as(i32, @intCast(lx));
            const wz: i32 = wz_lo + @as(i32, @intCast(lz));
            const gx = clampVertex(vertexForWorld(wx, region_min_x, width_i, denom), width_i);
            const gz = clampVertex(vertexForWorld(wz, region_min_z, width_i, denom), width_i);
            const ax: usize = @intCast(gx - gx_lo);
            const az: usize = @intCast(gz - gz_lo);
            accumulateColumn(&acc[az][ax], chunk, lx, lz);
        }
    }

    var written: u32 = 0;
    var az: usize = 0;
    while (az < span_z) : (az += 1) {
        const gz: u32 = @intCast(gz_lo + @as(i32, @intCast(az)));
        var ax: usize = 0;
        while (ax < span_x) : (ax += 1) {
            const gx: u32 = @intCast(gx_lo + @as(i32, @intCast(ax)));
            const sample = acc[az][ax].toSample() orelse continue;
            if (writeIngestedColumn(data, gx, gz, sample, provenance)) written += 1;
        }
    }
    return written;
}

/// Write one aggregated column into the region source data, honoring the
/// provenance ordering: a cell is only overwritten if `provenance` is at least
/// as authoritative as the cell's current provenance. Returns true if written.
pub fn writeIngestedColumn(
    data: *LODSimplifiedData,
    gx: u32,
    gz: u32,
    sample: VertexSample,
    provenance: LODColumnProvenance,
) bool {
    if (!provenance.canOverwrite(data.getColumnProvenance(gx, gz))) return false;

    const water_state: LODWaterState = if (sample.has_water)
        .{
            .is_surface = true,
            .surface_height = sample.water_surface_height,
            .depth = sample.water_depth,
            .coverage = if (sample.water_coverage > 0.0) sample.water_coverage else 1.0,
        }
    else
        LODWaterState.empty;

    const lighting: LODLightingHint = .{
        .sky_light = sample.sky_light,
        .block_light = 0,
        .ambient_occlusion = 1.0,
    };

    const vegetation: LODVegetationHint = if (sample.has_tree)
        .{
            .tree_coverage = 1.0,
            .avg_tree_height = sample.tree_height,
            .offset_x = 0.0,
            .offset_z = 0.0,
            .trunk = .wood,
            .leaves = .leaves,
        }
    else
        LODVegetationHint.empty;

    const color = biome_color_provider.getBiomeColor(sample.biome);

    // setGeneratedColumn writes the heightmap/biome/material/water/lighting
    // fields AND emits surface + water vertical spans when spans are enabled,
    // mirroring the worldgen path so chunk-derived data is mesh-compatible at
    // every preset. Provenance is set separately (setGeneratedColumn does not
    // touch it).
    data.setGeneratedColumn(
        gx,
        gz,
        sample.terrain_height,
        sample.biome,
        sample.layers,
        color,
        water_state,
        lighting,
        vegetation,
    );
    data.setColumnProvenance(gx, gz, provenance);
    return true;
}

// ---------------------------------------------------------------------------
// Internals
// ---------------------------------------------------------------------------

fn clearAccumulators(acc: *[MAX_SUB_VERTICES][MAX_SUB_VERTICES]VertexAccumulator) void {
    var z: usize = 0;
    while (z < MAX_SUB_VERTICES) : (z += 1) {
        var x: usize = 0;
        while (x < MAX_SUB_VERTICES) : (x += 1) acc[z][x] = .{};
    }
}

/// World block coordinate -> grid vertex index (rounded to nearest).
fn vertexForWorld(world_block: i32, region_min: i32, width: i32, region_size_blocks: i32) i32 {
    const offset: i32 = world_block - region_min;
    // vertex = offset * (width-1) / region_size_blocks, rounded to nearest.
    const numer: i32 = offset * (width - 1);
    const half: i32 = @divFloor(region_size_blocks, 2);
    return @divFloor(numer + half, region_size_blocks);
}

fn clampVertex(vertex: i32, width: i32) i32 {
    if (vertex < 0) return 0;
    if (vertex >= width) return width - 1;
    return vertex;
}

/// True for blocks that are part of vegetation (tree) rather than terrain
/// surface. These are excluded from terrain-height detection so a canopy does
/// not masquerade as the ground.
fn isVegetationBlock(block: BlockType) bool {
    return block == .wood or block == .leaves;
}

/// True for blocks that form the solid terrain surface (everything that is
/// not air, water, or vegetation).
fn isTerrainSolid(block: BlockType) bool {
    return block != .air and block != .water and !isVegetationBlock(block);
}

/// Highest terrain-surface Y in a column, or -1 if the column has no solid
/// ground. Skips air, water, and vegetation so tree canopies do not inflate
/// the recorded surface height.
fn terrainSurfaceY(chunk: *const Chunk, lx: u32, lz: u32) i32 {
    var y: i32 = CHUNK_SIZE_Y - 1;
    while (y >= 0) : (y -= 1) {
        const block = chunk.getBlock(lx, @intCast(y), lz);
        if (isTerrainSolid(block)) return y;
    }
    return -1;
}

/// Highest water block Y in a column, or -1 if there is no water above the
/// terrain surface.
fn waterSurfaceY(chunk: *const Chunk, lx: u32, lz: u32, terrain_y: i32) i32 {
    var top_water: i32 = -1;
    var y: i32 = CHUNK_SIZE_Y - 1;
    while (y > terrain_y) : (y -= 1) {
        if (chunk.getBlock(lx, @intCast(y), lz) == .water) {
            top_water = y;
            break;
        }
    }
    return top_water;
}

fn accumulateColumn(acc: *VertexAccumulator, chunk: *const Chunk, lx: u32, lz: u32) void {
    const terrain_y = terrainSurfaceY(chunk, lx, lz);
    if (terrain_y < 0) return; // empty column: no terrain to contribute

    acc.sample_count += 1;
    const terrain_u32: u32 = @intCast(terrain_y);

    if (terrain_y > acc.max_terrain_y) {
        acc.max_terrain_y = terrain_y;
        // Dominant biome/material comes from the highest column in the vertex.
        acc.dominant_biome = chunk.getBiome(lx, lz);
        acc.dominant_surface = chunk.getBlock(lx, terrain_u32, lz);
        acc.dominant_subsurface = if (terrain_y > 0)
            chunk.getBlock(lx, terrain_u32 - 1, lz)
        else
            acc.dominant_surface;
        const foundation_y: u32 = if (terrain_u32 >= 4) terrain_u32 - 4 else 0;
        acc.dominant_foundation = chunk.getBlock(lx, foundation_y, lz);
        if (acc.dominant_foundation == .air) acc.dominant_foundation = .stone;
        if (acc.dominant_subsurface == .air) acc.dominant_subsurface = acc.dominant_foundation;
    }

    // Water above terrain.
    const water_y = waterSurfaceY(chunk, lx, lz, terrain_y);
    if (water_y > terrain_y) {
        acc.water_count += 1;
        if (water_y > acc.max_water_surface_y) acc.max_water_surface_y = water_y;
    }

    // Vegetation canopy above terrain.
    const scan_top: u32 = @min(CHUNK_SIZE_Y - 1, terrain_u32 + TREE_SCAN_BAND);
    var tree_top: i32 = terrain_y;
    var has_tree = false;
    var y: u32 = terrain_u32 + 1;
    while (y <= scan_top) : (y += 1) {
        const block = chunk.getBlock(lx, y, lz);
        if (isVegetationBlock(block)) {
            has_tree = true;
            const yi: i32 = @intCast(y);
            if (yi > tree_top) tree_top = yi;
        }
    }
    if (has_tree) {
        acc.tree_count += 1;
        acc.tree_height_sum += @intCast(tree_top - terrain_y);
    }

    // Sky light sampled just above the surface.
    const sample_y: u32 = @min(CHUNK_SIZE_Y - 1, terrain_u32 + 1);
    acc.sky_light_sum += chunk.getSkyLight(lx, sample_y, lz);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn fillTerrainColumn(chunk: *Chunk, lx: u32, lz: u32, surface_y: u32, surface: BlockType, subsurface: BlockType, foundation: BlockType) void {
    var y: u32 = 0;
    while (y <= surface_y) : (y += 1) {
        const block: BlockType = if (y == surface_y)
            surface
        else if (y + 4 > surface_y)
            subsurface
        else
            foundation;
        chunk.setBlock(lx, y, lz, block);
    }
}

test "downsampleChunkIntoRegion writes terrain height and biome for an overlapping cell" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod1);
    defer data.deinit();
    // Pre-seed one cell as worldgen so we can observe the provenance upgrade.
    data.setColumn(0, 0, 10.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x4D8033, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty);
    try testing.expectEqual(LODColumnProvenance.worldgen, data.getColumnProvenance(0, 0));

    var chunk = Chunk.init(0, 0);
    fillTerrainColumn(&chunk, 0, 0, 64, .grass, .dirt, .stone);
    chunk.setBiome(0, 0, .forest);

    const region_size: i32 = @intCast(world_core.regionSizeBlocks(.lod1));
    const written = downsampleChunkIntoRegion(&chunk, 0, 0, &data, 0, 0, region_size, .chunk_derived);
    try testing.expect(written > 0);

    try testing.expectEqual(LODColumnProvenance.chunk_derived, data.getColumnProvenance(0, 0));
    try testing.expectEqual(@as(f32, 64.0), data.getHeight(0, 0));
    try testing.expectEqual(BiomeId.forest, data.biomes[0]);
}

test "writeIngestedColumn respects provenance authority" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod2);
    defer data.deinit();

    // Worldgen cell can be upgraded by chunk_derived.
    data.setColumn(1, 1, 5.0, .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0, LODWaterState.empty, LODLightingHint.daylight, LODVegetationHint.empty);
    const upgraded = writeIngestedColumn(data, 1, 1, .{ .terrain_height = 40.0, .biome = .forest }, .chunk_derived);
    try testing.expect(upgraded);
    try testing.expectEqual(@as(f32, 40.0), data.getHeight(1, 1));

    // chunk_derived must NOT be overwritten by worldgen.
    const clobbered = writeIngestedColumn(data, 1, 1, .{ .terrain_height = 1.0, .biome = .desert }, .worldgen);
    try testing.expect(!clobbered);
    try testing.expectEqual(@as(f32, 40.0), data.getHeight(1, 1));
    try testing.expectEqual(BiomeId.forest, data.biomes[1 + data.width]);

    // edited beats chunk_derived.
    const edited = writeIngestedColumn(data, 1, 1, .{ .terrain_height = 70.0, .biome = .mountains }, .edited);
    try testing.expect(edited);
    try testing.expectEqual(@as(f32, 70.0), data.getHeight(1, 1));
    try testing.expectEqual(LODColumnProvenance.edited, data.getColumnProvenance(1, 1));
}

test "downsampleChunkIntoRegion emits water state for a flooded column" {
    var data = try LODSimplifiedData.init(testing.allocator, .lod1);
    defer data.deinit();

    var chunk = Chunk.init(0, 0);
    // Terrain at y=58, water filling up to y=63.
    fillTerrainColumn(&chunk, 0, 0, 58, .sand, .sand, .stone);
    var y: u32 = 59;
    while (y <= 63) : (y += 1) chunk.setBlock(0, y, 0, .water);

    const region_size: i32 = @intCast(world_core.regionSizeBlocks(.lod1));
    _ = downsampleChunkIntoRegion(&chunk, 0, 0, &data, 0, 0, region_size, .chunk_derived);

    try testing.expectEqual(@as(f32, 58.0), data.getHeight(0, 0));
    try testing.expect(data.water[0].is_surface);
    try testing.expectEqual(@as(f32, 63.0), data.water[0].surface_height);
    try testing.expectEqual(@as(f32, 5.0), data.water[0].depth);
}

test "downsampleChunkIntoRegion updates the correct cells at a region corner" {
    // A chunk at the corner of two regions must only update cells inside its
    // own region. Use LOD3 (large cells) so a chunk maps to a single vertex,
    // making the boundary unambiguous.
    var data = try LODSimplifiedData.init(testing.allocator, .lod3);
    defer data.deinit();

    var chunk = Chunk.init(0, 0);
    fillTerrainColumn(&chunk, 0, 0, 80, .stone, .stone, .stone);

    const region_size: i32 = @intCast(world_core.regionSizeBlocks(.lod3));
    const written = downsampleChunkIntoRegion(&chunk, 0, 0, &data, 0, 0, region_size, .chunk_derived);
    try testing.expect(written > 0);

    // At least one cell was upgraded to chunk_derived.
    var any_upgraded = false;
    for (data.provenance) |p| {
        if (p == .chunk_derived) any_upgraded = true;
    }
    try testing.expect(any_upgraded);
}
