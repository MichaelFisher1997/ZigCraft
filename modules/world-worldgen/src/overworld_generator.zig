//! Terrain generator orchestrator for Luanti-style phased worldgen.
//! Phase responsibilities are delegated to dedicated subsystems.

const std = @import("std");
const sync = @import("sync");
const biome_mod = @import("biome.zig");
const BiomeId = biome_mod.BiomeId;
const region_pkg = @import("region.zig");
const RegionInfo = region_pkg.RegionInfo;
const RegionMood = region_pkg.RegionMood;
const world_class = @import("world_class.zig");
const ContinentalZone = world_class.ContinentalZone;
const SurfaceType = world_class.SurfaceType;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const block_registry = world_core.block_registry;
const LODLevel = world_core.LODLevel;
const LODSimplifiedData = world_core.LODSimplifiedData;
const regionSizeBlocks = world_core.regionSizeBlocks;
const DecorationProvider = @import("decoration_provider.zig").DecorationProvider;
const decoration_registry = @import("decoration_registry.zig");
const gen_region = @import("gen_region.zig");
const ClassificationCache = gen_region.ClassificationCache;
const gen_interface = @import("generator_interface.zig");
const Generator = gen_interface.Generator;
const GeneratorInfo = gen_interface.GeneratorInfo;
const ColumnInfo = gen_interface.ColumnInfo;
const log = @import("engine-core").log;

const terrain_shape_mod = @import("terrain_shape_generator.zig");
const TerrainShapeGenerator = terrain_shape_mod.TerrainShapeGenerator;
const NoiseSampler = terrain_shape_mod.NoiseSampler;
const HeightSampler = terrain_shape_mod.HeightSampler;
const SurfaceBuilder = terrain_shape_mod.SurfaceBuilder;
const CoastalSurfaceType = terrain_shape_mod.CoastalSurfaceType;
const BiomeSource = @import("biome.zig").BiomeSource;
const BiomeDecorator = @import("biome_decorator.zig").BiomeDecorator;
const tree_registry = @import("tree_registry.zig");
const LightingComputer = @import("lighting_computer.zig").LightingComputer;
const Mutex = sync.Mutex;

pub const OverworldGenerator = struct {
    pub const INFO = GeneratorInfo{
        .name = "Overworld",
        .description = "Standard terrain with diverse biomes and caves.",
    };

    allocator: std.mem.Allocator,
    classification_cache: ClassificationCache,
    cache_center_x: i32,
    cache_center_z: i32,
    cache_mutex: Mutex,
    terrain_shape: TerrainShapeGenerator,
    biome_decorator: BiomeDecorator,
    basic_chunks_only: bool,

    /// Distance threshold for cache recentering (blocks).
    pub const CACHE_RECENTER_THRESHOLD: i32 = 512;

    pub const InitParams = struct {
        terrain_shape: terrain_shape_mod.Params = .{},
        basic_chunks_only: bool = false,
    };

    pub fn init(seed: u64, allocator: std.mem.Allocator, decoration_provider: DecorationProvider) OverworldGenerator {
        return initWithParams(seed, allocator, decoration_provider, .{});
    }

    pub fn initWithParams(seed: u64, allocator: std.mem.Allocator, decoration_provider: DecorationProvider, params: InitParams) OverworldGenerator {
        return .{
            .allocator = allocator,
            .classification_cache = ClassificationCache.init(),
            .cache_center_x = 0,
            .cache_center_z = 0,
            .cache_mutex = .{},
            .terrain_shape = TerrainShapeGenerator.initWithParams(seed, params.terrain_shape),
            .biome_decorator = BiomeDecorator.init(seed, decoration_provider),
            .basic_chunks_only = params.basic_chunks_only,
        };
    }

    pub fn deinit(self: *OverworldGenerator) void {
        _ = self;
    }

    pub fn getNoiseSampler(self: *const OverworldGenerator) *const NoiseSampler {
        return self.terrain_shape.getNoiseSampler();
    }

    pub fn getHeightSampler(self: *const OverworldGenerator) *const HeightSampler {
        return self.terrain_shape.getHeightSampler();
    }

    pub fn getSurfaceBuilder(self: *const OverworldGenerator) *const SurfaceBuilder {
        return self.terrain_shape.getSurfaceBuilder();
    }

    pub fn getBiomeSource(self: *const OverworldGenerator) *const BiomeSource {
        return self.terrain_shape.getBiomeSource();
    }

    pub fn getSeed(self: *const OverworldGenerator) u64 {
        return self.terrain_shape.getSeed();
    }

    pub fn getRegionInfo(self: *const OverworldGenerator, world_x: i32, world_z: i32) RegionInfo {
        return self.terrain_shape.getRegionInfo(world_x, world_z);
    }

    pub fn getMood(self: *const OverworldGenerator, world_x: i32, world_z: i32) RegionMood {
        return self.getRegionInfo(world_x, world_z).mood;
    }

    pub fn getColumnInfo(self: *const OverworldGenerator, wx: f32, wz: f32) ColumnInfo {
        const column = self.terrain_shape.sampleColumnData(wx, wz, 0);
        const climate = self.terrain_shape.biome_source.computeClimate(
            column.temperature,
            column.humidity,
            column.terrain_height_i,
            column.continentalness,
            column.erosion,
            CHUNK_SIZE_Y,
        );

        const structural = biome_mod.StructuralParams{
            .height = column.terrain_height_i,
            .slope = 1,
            .continentalness = column.continentalness,
            .ridge_mask = column.ridge_mask,
        };

        const biome_id = self.terrain_shape.biome_source.selectBiome(climate, structural, column.river_mask);
        return .{
            .height = column.terrain_height_i,
            .biome = biome_id,
            .is_ocean = column.continentalness < self.terrain_shape.getOceanThreshold(),
            .temperature = column.temperature,
            .humidity = column.humidity,
            .continentalness = column.continentalness,
        };
    }

    pub fn maybeRecenterCache(self: *OverworldGenerator, player_x: i32, player_z: i32) bool {
        self.cache_mutex.lock();
        defer self.cache_mutex.unlock();

        const dx = player_x - self.cache_center_x;
        const dz = player_z - self.cache_center_z;
        if (dx * dx + dz * dz > CACHE_RECENTER_THRESHOLD * CACHE_RECENTER_THRESHOLD) {
            self.classification_cache.recenter(player_x, player_z);
            self.cache_center_x = player_x;
            self.cache_center_z = player_z;
            return true;
        }
        return false;
    }

    pub fn generate(self: *OverworldGenerator, chunk: *Chunk, stop_flag: ?*const bool) void {
        chunk.generated = false;
        const world_x = chunk.getWorldX();
        const world_z = chunk.getWorldZ();
        const cache_center = blk: {
            self.cache_mutex.lock();
            defer self.cache_mutex.unlock();

            if (!self.classification_cache.contains(world_x, world_z)) {
                self.classification_cache.recenter(world_x, world_z);
                self.cache_center_x = world_x;
                self.cache_center_z = world_z;
            }

            break :blk .{ .x = self.cache_center_x, .z = self.cache_center_z };
        };

        const phase_data = self.allocator.create(terrain_shape_mod.ChunkPhaseData) catch return;
        defer self.allocator.destroy(phase_data);
        if (!self.terrain_shape.prepareChunkPhaseData(
            phase_data,
            world_x,
            world_z,
            cache_center.x,
            cache_center.z,
            stop_flag,
        )) return;

        self.cache_mutex.lock();
        self.populateClassificationCache(
            world_x,
            world_z,
            &phase_data.surface_heights,
            &phase_data.biome_ids,
            &phase_data.continentalness_values,
            &phase_data.is_ocean_water_flags,
            &phase_data.coastal_types,
        );
        self.cache_mutex.unlock();

        var worm_map_opt = if (self.terrain_shape.params.disable_caves)
            null
        else
            self.terrain_shape.generateWormCaves(
                chunk,
                &phase_data.surface_heights,
                self.allocator,
            ) catch null;
        defer if (worm_map_opt) |*map| map.deinit();
        const worm_map_ptr: ?*const terrain_shape_mod.CaveCarveMap = if (worm_map_opt) |*map| map else null;

        if (!self.terrain_shape.fillChunkBlocks(chunk, phase_data, worm_map_ptr, stop_flag)) return;
        if (stop_flag) |sf| if (sf.*) return;
        if (!self.basic_chunks_only) {
            self.biome_decorator.generateOres(chunk);
            if (stop_flag) |sf| if (sf.*) return;
            self.biome_decorator.generateFeatures(chunk, self.terrain_shape.getNoiseSampler());
            if (stop_flag) |sf| if (sf.*) return;
        }
        LightingComputer.computeSkylight(chunk, self.allocator) catch |err| {
            log.log.errWithTrace("Failed to compute skylight for chunk ({}, {}): {}", .{ chunk.chunk_x, chunk.chunk_z, err });
            return;
        };
        if (stop_flag) |sf| if (sf.*) return;
        if (!self.basic_chunks_only) {
            LightingComputer.computeBlockLight(chunk, self.allocator) catch |err| {
                log.log.errWithTrace("Failed to compute block light for chunk ({}, {}): {}", .{ chunk.chunk_x, chunk.chunk_z, err });
                return;
            };
        }

        chunk.generated = true;
        chunk.dirty = true;
    }

    pub fn generateFeatures(self: *const OverworldGenerator, chunk: *Chunk) void {
        if (self.basic_chunks_only) return;
        self.biome_decorator.generateFeatures(chunk, self.terrain_shape.getNoiseSampler());
    }

    pub fn isOceanWater(self: *const OverworldGenerator, wx: f32, wz: f32) bool {
        return self.terrain_shape.isOceanWater(wx, wz);
    }

    pub fn isInlandWater(self: *const OverworldGenerator, wx: f32, wz: f32, height: i32) bool {
        return self.terrain_shape.isInlandWater(wx, wz, height);
    }

    pub fn getContinentalZone(self: *const OverworldGenerator, c: f32) ContinentalZone {
        return self.terrain_shape.getContinentalZone(c);
    }

    /// Generate heightmap data only (for LODSimplifiedData)
    /// Uses classification cache when available to ensure LOD matches LOD0.
    pub fn generateHeightmapOnly(self: *const OverworldGenerator, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void {
        if (data.width < 2) return;

        const region_size_i: i32 = @intCast(regionSizeBlocks(lod_level));
        const region_size_f: f32 = @floatFromInt(region_size_i);
        const grid_max: f32 = @floatFromInt(data.width - 1);
        const world_x = region_x * region_size_i;
        const world_z = region_z * region_size_i;
        const sea_level = self.terrain_shape.getSeaLevel();
        const controls = region_pkg.RegionControlCorners.init(
            self.terrain_shape.getRegionSeed(),
            world_x,
            world_z,
            world_x + region_size_i,
            world_z + region_size_i,
        );
        var tree_hint_cache = TreeHintCache.init(self.allocator);
        defer tree_hint_cache.deinit();

        var gz: u32 = 0;
        while (gz < data.width) : (gz += 1) {
            var gx: u32 = 0;
            while (gx < data.width) : (gx += 1) {
                const wx = @as(f32, @floatFromInt(world_x)) + (@as(f32, @floatFromInt(gx)) / grid_max) * region_size_f;
                const wz = @as(f32, @floatFromInt(world_z)) + (@as(f32, @floatFromInt(gz)) / grid_max) * region_size_f;
                const sample = self.sampleRepresentativeLODColumn(wx, wz, region_size_f / grid_max, sea_level, controls, &tree_hint_cache);
                data.setColumn(gx, gz, sample.height, sample.biome, sample.layers, sample.color, sample.water, sample.lighting, sample.vegetation);
            }
        }
    }

    const RepresentativeLODColumn = struct {
        height: f32,
        biome: BiomeId,
        layers: world_core.LODMaterialLayers,
        color: u32,
        water: world_core.LODWaterState,
        lighting: world_core.LODLightingHint,
        vegetation: world_core.LODVegetationHint,
    };

    const ClassifiedLODSample = struct {
        wx_i: i32,
        wz_i: i32,
        terrain_height: f32,
        terrain_height_i: i32,
        biome: BiomeId,
        surface_block: BlockType,
        render_water_surface: bool,
    };

    const TreeHintChunk = [CHUNK_SIZE_X * CHUNK_SIZE_Z]world_core.LODVegetationHint;
    const TreeHintCache = std.AutoHashMap(u64, TreeHintChunk);

    fn sampleRepresentativeLODColumn(self: *const OverworldGenerator, wx: f32, wz: f32, cell_span: f32, sea_level: i32, controls: region_pkg.RegionControlCorners, tree_hint_cache: *TreeHintCache) RepresentativeLODColumn {
        const sample_offsets = [_]f32{ -0.35, 0.0, 0.35 };
        const sample_radius = @min(cell_span * 0.5, 48.0);

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
                const sample = self.classifyLODSample(wx + ox * sample_radius, wz + oz * sample_radius, sea_level, controls);
                const block_index = @intFromEnum(sample.surface_block);
                if (block_index < block_counts.len) block_counts[block_index] += 1;
                biome_counts[@intFromEnum(sample.biome)] += 1;

                const color = lodColorForSample(sample.biome, sample.surface_block);
                color_r += (color >> 16) & 0xFF;
                color_g += (color >> 8) & 0xFF;
                color_b += color & 0xFF;
                terrain_height_sum += sample.terrain_height;
                terrain_min = @min(terrain_min, sample.terrain_height);
                terrain_max = @max(terrain_max, sample.terrain_height);
                total_samples += 1;

                if (sample.render_water_surface) {
                    water_samples += 1;
                    water_depth_sum += @floatFromInt(@max(sea_level - sample.terrain_height_i, 0));
                }
            }
        }

        const water_coverage = if (total_samples == 0) 0.0 else @as(f32, @floatFromInt(water_samples)) / @as(f32, @floatFromInt(total_samples));
        const dominant_block = dominantBlock(block_counts);
        const dominant_biome = dominantBiome(biome_counts);
        const render_water_surface = water_coverage >= 0.25;
        const surface_block: BlockType = if (render_water_surface) .water else dominant_block;
        const avg_height = terrain_height_sum / @as(f32, @floatFromInt(@max(total_samples, 1)));
        const terrain_range = @max(terrain_max - terrain_min, 0.0);
        const land_height = if (terrain_range > 12.0)
            avg_height + terrain_range * 0.35
        else
            avg_height;
        const height = if (render_water_surface)
            @as(f32, @floatFromInt(sea_level))
        else
            land_height;
        const avg_color = packAverageColor(color_r, color_g, color_b, @max(total_samples, 1));
        const vegetation_hint = if (render_water_surface) world_core.LODVegetationHint.empty else self.actualTreeHintInArea(wx, wz, sample_radius, dominant_biome, tree_hint_cache);
        const representative_color = if (vegetation_hint.tree_coverage > 0.0)
            blendColor(avg_color, foliageColorForBiome(dominant_biome, vegetation_hint.leaves), vegetation_hint.tree_coverage * 0.45)
        else
            avg_color;

        return .{
            .height = height,
            .biome = dominant_biome,
            .layers = makeMaterialLayers(surface_block, dominant_biome, render_water_surface),
            .color = representative_color,
            .water = .{
                .is_surface = render_water_surface,
                .surface_height = if (render_water_surface) @floatFromInt(sea_level) else 0.0,
                .depth = if (water_samples == 0) 0.0 else water_depth_sum / @as(f32, @floatFromInt(water_samples)),
                .coverage = water_coverage,
            },
            .lighting = makeLightingHint(render_water_surface),
            .vegetation = vegetation_hint,
        };
    }

    const TreeBlocks = struct {
        trunk: BlockType,
        leaves: BlockType,
    };

    fn actualTreeHintAtColumn(self: *const OverworldGenerator, target_wx: i32, target_wz: i32, cache: *TreeHintCache) world_core.LODVegetationHint {
        const chunk_x = @divFloor(target_wx, @as(i32, @intCast(CHUNK_SIZE_X)));
        const chunk_z = @divFloor(target_wz, @as(i32, @intCast(CHUNK_SIZE_Z)));
        const local_x: u32 = @intCast(@mod(target_wx, @as(i32, @intCast(CHUNK_SIZE_X))));
        const local_z: u32 = @intCast(@mod(target_wz, @as(i32, @intCast(CHUNK_SIZE_Z))));
        const idx = local_x + local_z * CHUNK_SIZE_X;
        const key = treeHintCacheKey(chunk_x, chunk_z);

        if (cache.get(key)) |hints| return hints[idx];

        const hints = self.computeChunkTreeHints(chunk_x, chunk_z);
        const result = hints[idx];
        cache.put(key, hints) catch {};
        return result;
    }

    fn actualTreeHintInArea(self: *const OverworldGenerator, center_wx: f32, center_wz: f32, radius: f32, dominant_biome: BiomeId, cache: *TreeHintCache) world_core.LODVegetationHint {
        const min_x: i32 = @intFromFloat(@floor(center_wx - radius));
        const max_x: i32 = @intFromFloat(@ceil(center_wx + radius));
        const min_z: i32 = @intFromFloat(@floor(center_wz - radius));
        const max_z: i32 = @intFromFloat(@ceil(center_wz + radius));
        const min_chunk_x = @divFloor(min_x, @as(i32, @intCast(CHUNK_SIZE_X)));
        const max_chunk_x = @divFloor(max_x, @as(i32, @intCast(CHUNK_SIZE_X)));
        const min_chunk_z = @divFloor(min_z, @as(i32, @intCast(CHUNK_SIZE_Z)));
        const max_chunk_z = @divFloor(max_z, @as(i32, @intCast(CHUNK_SIZE_Z)));

        var tree_count: u32 = 0;
        var height_sum: f32 = 0.0;
        var offset_x_sum: f32 = 0.0;
        var offset_z_sum: f32 = 0.0;
        var best = world_core.LODVegetationHint.empty;

        var chunk_z = min_chunk_z;
        while (chunk_z <= max_chunk_z) : (chunk_z += 1) {
            var chunk_x = min_chunk_x;
            while (chunk_x <= max_chunk_x) : (chunk_x += 1) {
                const key = treeHintCacheKey(chunk_x, chunk_z);
                if (!cache.contains(key)) {
                    cache.put(key, self.computeChunkTreeHints(chunk_x, chunk_z)) catch {};
                }
                const hints = cache.get(key) orelse continue;
                const chunk_world_x = chunk_x * @as(i32, @intCast(CHUNK_SIZE_X));
                const chunk_world_z = chunk_z * @as(i32, @intCast(CHUNK_SIZE_Z));

                var lz: u32 = 0;
                while (lz < CHUNK_SIZE_Z) : (lz += 1) {
                    const wz = chunk_world_z + @as(i32, @intCast(lz));
                    if (wz < min_z or wz > max_z) continue;
                    var lx: u32 = 0;
                    while (lx < CHUNK_SIZE_X) : (lx += 1) {
                        const wx = chunk_world_x + @as(i32, @intCast(lx));
                        if (wx < min_x or wx > max_x) continue;
                        const hint = hints[lx + lz * CHUNK_SIZE_X];
                        if (hint.tree_coverage <= 0.0) continue;
                        tree_count += 1;
                        height_sum += hint.avg_tree_height;
                        offset_x_sum += @as(f32, @floatFromInt(wx)) - center_wx;
                        offset_z_sum += @as(f32, @floatFromInt(wz)) - center_wz;
                        if (best.tree_coverage <= 0.0) best = hint;
                    }
                }
            }
        }

        if (tree_count == 0) return world_core.LODVegetationHint.empty;

        const blocks = if (best.leaves == .air) treeBlocksForBiome(dominant_biome) else TreeBlocks{ .trunk = best.trunk, .leaves = best.leaves };
        const area = @max(1.0, (radius * 2.0 + 1.0) * (radius * 2.0 + 1.0));
        return .{
            .tree_coverage = std.math.clamp(@as(f32, @floatFromInt(tree_count)) / area * 24.0, 0.0, 1.0),
            .avg_tree_height = height_sum / @as(f32, @floatFromInt(tree_count)),
            .offset_x = offset_x_sum / @as(f32, @floatFromInt(tree_count)),
            .offset_z = offset_z_sum / @as(f32, @floatFromInt(tree_count)),
            .trunk = blocks.trunk,
            .leaves = blocks.leaves,
        };
    }

    fn computeChunkTreeHints(self: *const OverworldGenerator, chunk_x: i32, chunk_z: i32) TreeHintChunk {
        const world_x = chunk_x * @as(i32, @intCast(CHUNK_SIZE_X));
        const world_z = chunk_z * @as(i32, @intCast(CHUNK_SIZE_Z));
        const sea_level = self.terrain_shape.getSeaLevel();
        const controls = region_pkg.RegionControlCorners.init(
            self.terrain_shape.getRegionSeed(),
            world_x,
            world_z,
            world_x + @as(i32, @intCast(CHUNK_SIZE_X)) - 1,
            world_z + @as(i32, @intCast(CHUNK_SIZE_Z)) - 1,
        );
        var prng = std.Random.DefaultPrng.init(self.biome_decorator.region_seed ^ @as(u64, @bitCast(@as(i64, chunk_x))) ^ (@as(u64, @bitCast(@as(i64, chunk_z))) << 32));
        const random = prng.random();
        var tree_occupancy = [_]bool{false} ** world_core.CHUNK_VOLUME;
        var hints = [_]world_core.LODVegetationHint{world_core.LODVegetationHint.empty} ** (CHUNK_SIZE_X * CHUNK_SIZE_Z);

        var lz: u32 = 0;
        while (lz < CHUNK_SIZE_Z) : (lz += 1) {
            var lx: u32 = 0;
            while (lx < CHUNK_SIZE_X) : (lx += 1) {
                const wx_i = world_x + @as(i32, @intCast(lx));
                const wz_i = world_z + @as(i32, @intCast(lz));
                const sample = self.classifyLODSample(@floatFromInt(wx_i), @floatFromInt(wz_i), sea_level, controls);
                const column_controls = controls.sample(wx_i, wz_i);
                const variant = self.terrain_shape.getNoiseSampler().variant_noise.get2D(@floatFromInt(wx_i), @floatFromInt(wz_i));
                consumeStaticDecorationRandom(sample.biome, sample.surface_block, variant, column_controls.subbiome_mask > 0.5, column_controls.vegetation_mult, random);

                const placed_tree = choosePlacedTree(sample.biome, sample.surface_block, variant, column_controls.subbiome_mask > 0.5, column_controls.vegetation_mult, lx, lz, sample.terrain_height_i, &tree_occupancy, random);
                if (placed_tree) |tree| {
                    placeTreeOccupancy(tree.schematic, lx, @intCast(sample.terrain_height_i + 1), lz, &tree_occupancy, random);
                    hints[lx + lz * CHUNK_SIZE_X] = treeHintForType(tree.tree_type);
                }
            }
        }
        return hints;
    }

    fn treeHintCacheKey(chunk_x: i32, chunk_z: i32) u64 {
        const x: u64 = @bitCast(@as(i64, chunk_x));
        const z: u64 = @bitCast(@as(i64, chunk_z));
        return (x *% 0x9E3779B97F4A7C15) ^ (z *% 0xC2B2AE3D27D4EB4F);
    }

    const PlacedTree = struct {
        tree_type: tree_registry.TreeType,
        schematic: @import("schematics.zig").Schematic,
    };

    fn choosePlacedTree(
        biome_id: BiomeId,
        surface_block: BlockType,
        variant: f32,
        allow_subbiomes: bool,
        veg_mult: f32,
        local_x: u32,
        local_z: u32,
        surface_y: i32,
        tree_occupancy: *const [world_core.CHUNK_VOLUME]bool,
        random: std.Random,
    ) ?PlacedTree {
        const vegetation = biome_mod.getBiomeDefinition(biome_id).vegetation;
        if (vegetation.tree_types.len == 0) return null;

        for (vegetation.tree_types) |tree_type| {
            const tree_def = tree_registry.getTreeDefinition(tree_type) orelse continue;
            if (!treeSurfaceAllowed(tree_def.place_on, surface_block)) continue;
            if (!variantAllowed(variant, allow_subbiomes, tree_def.variant_min, tree_def.variant_max)) continue;
            const prob = @min(1.0, tree_def.probability * veg_mult);
            if (random.float(f32) >= prob) continue;
            if (tree_def.spacing_radius > 0 and !isTreeAreaClear(tree_occupancy, @intCast(local_x), surface_y, @intCast(local_z), tree_def.spacing_radius)) continue;
            return .{
                .tree_type = tree_type,
                .schematic = tree_def.schematic,
            };
        }
        return null;
    }

    fn consumeStaticDecorationRandom(biome_id: BiomeId, surface_block: BlockType, variant: f32, allow_subbiomes: bool, veg_mult: f32, random: std.Random) void {
        for (decoration_registry.DECORATIONS) |deco| {
            switch (deco) {
                .simple => |simple| {
                    if (!simple.isAllowed(biome_id, surface_block)) continue;
                    if (!variantAllowed(variant, allow_subbiomes, simple.variant_min, simple.variant_max)) continue;
                    const prob = @min(1.0, simple.probability * veg_mult);
                    if (random.float(f32) < prob) break;
                },
                .schematic => {},
            }
        }
    }

    fn variantAllowed(variant: f32, allow_subbiomes: bool, min: f32, max: f32) bool {
        if (allow_subbiomes) return variant >= min and variant <= max;
        return min == -1.0 and max == 1.0;
    }

    fn treeSurfaceAllowed(place_on: []const BlockType, surface_block: BlockType) bool {
        for (place_on) |valid| {
            if (surface_block == valid) return true;
        }
        return false;
    }

    fn isTreeAreaClear(tree_occupancy: *const [world_core.CHUNK_VOLUME]bool, x: i32, y: i32, z: i32, radius: i32) bool {
        var dz: i32 = -radius;
        while (dz <= radius) : (dz += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                if (dx == 0 and dz == 0) continue;
                const check_x = x + dx;
                const check_z = z + dz;
                if (check_x >= 0 and check_x < CHUNK_SIZE_X and check_z >= 0 and check_z < CHUNK_SIZE_Z) {
                    var dy: i32 = 1;
                    while (dy <= 3) : (dy += 1) {
                        const check_y = y + dy;
                        if (check_y >= 0 and check_y < CHUNK_SIZE_Y) {
                            const idx: usize = @intCast(@as(u32, @intCast(check_x)) + @as(u32, @intCast(check_z)) * CHUNK_SIZE_X + @as(u32, @intCast(check_y)) * CHUNK_SIZE_X * CHUNK_SIZE_Z);
                            if (tree_occupancy[idx]) return false;
                        }
                    }
                }
            }
        }
        return true;
    }

    fn placeTreeOccupancy(schematic: @import("schematics.zig").Schematic, x: u32, y: u32, z: u32, tree_occupancy: *[world_core.CHUNK_VOLUME]bool, random: std.Random) void {
        const center_x = @as(i32, @intCast(x));
        const center_y = @as(i32, @intCast(y));
        const center_z = @as(i32, @intCast(z));
        for (schematic.blocks) |block| {
            if (block.probability < 1.0) {
                if (random.float(f32) >= block.probability) continue;
            }
            const bx = center_x + block.offset[0] - schematic.center_x;
            const by = center_y + block.offset[1];
            const bz = center_z + block.offset[2] - schematic.center_z;
            if (bx >= 0 and bx < CHUNK_SIZE_X and bz >= 0 and bz < CHUNK_SIZE_Z and by >= 0 and by < CHUNK_SIZE_Y and isTreeBlock(block.block)) {
                const idx: usize = @intCast(@as(u32, @intCast(bx)) + @as(u32, @intCast(bz)) * CHUNK_SIZE_X + @as(u32, @intCast(by)) * CHUNK_SIZE_X * CHUNK_SIZE_Z);
                tree_occupancy[idx] = true;
            }
        }
    }

    fn isTreeBlock(block: BlockType) bool {
        return switch (block) {
            .wood,
            .leaves,
            .birch_log,
            .birch_leaves,
            .spruce_log,
            .spruce_leaves,
            .jungle_log,
            .jungle_leaves,
            .acacia_log,
            .acacia_leaves,
            .mangrove_log,
            .mangrove_leaves,
            => true,
            else => false,
        };
    }

    fn treeHintForType(tree_type: tree_registry.TreeType) world_core.LODVegetationHint {
        const blocks = treeBlocksForType(tree_type);
        return .{
            .tree_coverage = 1.0,
            .avg_tree_height = treeHeightForType(tree_type),
            .offset_x = 0.0,
            .offset_z = 0.0,
            .trunk = blocks.trunk,
            .leaves = blocks.leaves,
        };
    }

    fn makeRepresentativeVegetationHint(biome_id: BiomeId, tree_coverage_sum: f32, tree_height_sum: f32, tree_offset_x_sum: f32, tree_offset_z_sum: f32, tree_samples: u32, total_samples: u32) world_core.LODVegetationHint {
        const blocks = treeBlocksForBiome(biome_id);
        return .{
            .tree_coverage = std.math.clamp(tree_coverage_sum / @as(f32, @floatFromInt(@max(total_samples, 1))), 0.0, 1.0),
            .avg_tree_height = if (tree_samples == 0) 0.0 else tree_height_sum / @as(f32, @floatFromInt(tree_samples)),
            .offset_x = if (tree_samples == 0) 0.0 else tree_offset_x_sum / @as(f32, @floatFromInt(tree_samples)),
            .offset_z = if (tree_samples == 0) 0.0 else tree_offset_z_sum / @as(f32, @floatFromInt(tree_samples)),
            .trunk = blocks.trunk,
            .leaves = blocks.leaves,
        };
    }

    fn foliageColorForBiome(biome_id: BiomeId, block: BlockType) u32 {
        return switch (block) {
            .leaves => packFloatColor(biomeFoliageTint(biome_id)),
            .spruce_leaves, .jungle_leaves, .acacia_leaves, .mangrove_leaves, .birch_leaves => packBlockColor(block),
            else => packFloatColor(biomeFoliageTint(biome_id)),
        };
    }

    fn biomeGrassTint(biome_id: BiomeId) [3]f32 {
        return switch (biome_id) {
            .forest => .{ 0.18, 0.64, 0.16 },
            .taiga => .{ 0.24, 0.56, 0.24 },
            .desert => .{ 0.75, 0.70, 0.35 },
            .snow_tundra => .{ 0.7, 0.75, 0.8 },
            .snowy_mountains => .{ 0.85, 0.90, 0.95 },
            .swamp => .{ 0.26, 0.58, 0.18 },
            .jungle => .{ 0.10, 0.76, 0.08 },
            .savanna => .{ 0.55, 0.55, 0.30 },
            .badlands => .{ 0.5, 0.4, 0.3 },
            .mushroom_fields => .{ 0.4, 0.8, 0.4 },
            .foothills => .{ 0.24, 0.62, 0.22 },
            .dry_plains => .{ 0.55, 0.50, 0.28 },
            .coastal_plains => .{ 0.24, 0.66, 0.24 },
            else => .{ 0.22, 0.72, 0.16 },
        };
    }

    fn biomeFoliageTint(biome_id: BiomeId) [3]f32 {
        return switch (biome_id) {
            .forest => .{ 0.12, 0.52, 0.12 },
            .taiga => .{ 0.18, 0.46, 0.18 },
            .swamp => .{ 0.22, 0.52, 0.16 },
            .jungle => .{ 0.08, 0.62, 0.08 },
            .savanna => .{ 0.50, 0.50, 0.28 },
            .foothills => .{ 0.18, 0.50, 0.16 },
            .coastal_plains => .{ 0.18, 0.52, 0.16 },
            else => .{ 0.14, 0.58, 0.12 },
        };
    }

    fn biomeWaterTint(biome_id: BiomeId) [3]f32 {
        return switch (biome_id) {
            .deep_ocean => .{ 0.1, 0.2, 0.5 },
            .swamp => .{ 0.16, 0.38, 0.30 },
            else => .{ 0.12, 0.38, 0.78 },
        };
    }

    fn blendColor(a: u32, b: u32, t: f32) u32 {
        const clamped = std.math.clamp(t, 0.0, 1.0);
        const ar: f32 = @floatFromInt((a >> 16) & 0xFF);
        const ag: f32 = @floatFromInt((a >> 8) & 0xFF);
        const ab: f32 = @floatFromInt(a & 0xFF);
        const br: f32 = @floatFromInt((b >> 16) & 0xFF);
        const bg: f32 = @floatFromInt((b >> 8) & 0xFF);
        const bb: f32 = @floatFromInt(b & 0xFF);
        const r: u32 = @intFromFloat(@round(ar + (br - ar) * clamped));
        const g: u32 = @intFromFloat(@round(ag + (bg - ag) * clamped));
        const blue: u32 = @intFromFloat(@round(ab + (bb - ab) * clamped));
        return (r << 16) | (g << 8) | blue;
    }

    fn treeBlocksForBiome(biome_id: BiomeId) TreeBlocks {
        return switch (biome_id) {
            .taiga, .snow_tundra, .snowy_mountains => .{ .trunk = .spruce_log, .leaves = .spruce_leaves },
            .jungle => .{ .trunk = .jungle_log, .leaves = .jungle_leaves },
            .savanna => .{ .trunk = .acacia_log, .leaves = .acacia_leaves },
            .swamp, .mangrove_swamp, .marsh => .{ .trunk = .mangrove_log, .leaves = .mangrove_leaves },
            else => .{ .trunk = .wood, .leaves = .leaves },
        };
    }

    fn treeBlocksForType(tree_type: tree_registry.TreeType) TreeBlocks {
        return switch (tree_type) {
            .spruce => .{ .trunk = .spruce_log, .leaves = .spruce_leaves },
            .jungle => .{ .trunk = .jungle_log, .leaves = .jungle_leaves },
            .acacia => .{ .trunk = .acacia_log, .leaves = .acacia_leaves },
            .mangrove => .{ .trunk = .mangrove_log, .leaves = .mangrove_leaves },
            .huge_red_mushroom => .{ .trunk = .mushroom_stem, .leaves = .red_mushroom_block },
            .huge_brown_mushroom => .{ .trunk = .mushroom_stem, .leaves = .brown_mushroom_block },
            else => .{ .trunk = .wood, .leaves = .leaves },
        };
    }

    fn treeHeightForBiome(biome_id: BiomeId) f32 {
        return switch (biome_id) {
            .jungle => 13.0,
            .taiga, .snow_tundra, .snowy_mountains => 10.0,
            .savanna => 8.0,
            .swamp, .mangrove_swamp, .marsh => 7.0,
            else => 6.0,
        };
    }

    fn treeHeightForType(tree_type: tree_registry.TreeType) f32 {
        return switch (tree_type) {
            .jungle => 13.0,
            .spruce => 10.0,
            .acacia => 8.0,
            .swamp_oak, .mangrove => 7.0,
            .huge_red_mushroom, .huge_brown_mushroom => 6.0,
            else => 6.0,
        };
    }

    fn classifyLODSample(self: *const OverworldGenerator, wx: f32, wz: f32, sea_level: i32, controls: region_pkg.RegionControlCorners) ClassifiedLODSample {
        const wx_i: i32 = @intFromFloat(@floor(wx));
        const wz_i: i32 = @intFromFloat(@floor(wz));
        const column = self.terrain_shape.sampleColumnDataWithControls(wx, wz, 0, controls.sample(wx_i, wz_i));
        const render_water_surface = column.terrain_height_i < sea_level and (column.is_ocean or self.isInlandWater(wx, wz, column.terrain_height_i));

        if (self.getCachedClassification(wx_i, wz_i)) |cached| {
            return .{
                .wx_i = wx_i,
                .wz_i = wz_i,
                .terrain_height = column.terrain_height,
                .terrain_height_i = column.terrain_height_i,
                .biome = cached.biome_id,
                .surface_block = if (render_water_surface) .water else self.surfaceTypeToBlock(cached.surface_type),
                .render_water_surface = render_water_surface,
            };
        }

        const climate = biome_mod.computeClimateParams(
            column.temperature,
            column.humidity,
            column.terrain_height_i,
            column.continentalness,
            column.erosion,
            sea_level,
            CHUNK_SIZE_Y,
        );

        const structural = biome_mod.StructuralParams{
            .height = column.terrain_height_i,
            .slope = 0,
            .continentalness = column.continentalness,
            .ridge_mask = column.ridge_mask,
        };

        const biome_id = biome_mod.selectBiomeWithConstraintsAndRiver(climate, structural, column.river_mask);
        return .{
            .wx_i = wx_i,
            .wz_i = wz_i,
            .terrain_height = column.terrain_height,
            .terrain_height_i = column.terrain_height_i,
            .biome = biome_id,
            .surface_block = self.getSurfaceBlock(biome_id, column.terrain_height_i, sea_level, render_water_surface),
            .render_water_surface = render_water_surface,
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

    fn lodColorForSample(biome_id: BiomeId, surface_block: BlockType) u32 {
        return switch (surface_block) {
            .air => 0,
            .grass => packFloatColor(biomeGrassTint(biome_id)),
            .water => packFloatColor(biomeWaterTint(biome_id)),
            .leaves, .mangrove_leaves, .jungle_leaves, .acacia_leaves, .birch_leaves, .spruce_leaves => packFloatColor(biomeFoliageTint(biome_id)),
            else => packBlockColor(surface_block),
        };
    }

    fn packFloatColor(color: [3]f32) u32 {
        const r: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0));
        const g: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0));
        const b: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0));
        return (r << 16) | (g << 8) | b;
    }

    fn makeMaterialLayers(surface_block: BlockType, biome_id: BiomeId, render_water_surface: bool) world_core.LODMaterialLayers {
        if (render_water_surface) {
            const floor_block: BlockType = switch (biome_id) {
                .deep_ocean => .gravel,
                .ocean, .river, .beach => .sand,
                else => .dirt,
            };
            return .{
                .surface = .water,
                .subsurface = floor_block,
                .foundation = .stone,
            };
        }

        return .{
            .surface = surface_block,
            .subsurface = biome_id.getFillerBlock(),
            .foundation = .stone,
        };
    }

    fn makeLightingHint(render_water_surface: bool) world_core.LODLightingHint {
        return .{
            .sky_light = 15,
            .block_light = 0,
            .ambient_occlusion = if (render_water_surface) 0.92 else 1.0,
        };
    }

    fn packBlockColor(block_type: BlockType) u32 {
        const color = block_registry.getBlockDefinition(block_type).default_color;
        const r: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0));
        const g: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0));
        const b: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0));
        return (r << 16) | (g << 8) | b;
    }

    fn surfaceTypeToBlock(_: *const OverworldGenerator, surface_type: SurfaceType) BlockType {
        return switch (surface_type) {
            .grass => .grass,
            .sand => .sand,
            .rock => .gravel,
            .snow => .snow_block,
            .water_deep, .water_shallow => .water,
            .dirt => .dirt,
            .stone => .stone,
        };
    }

    fn getSurfaceBlock(_: *const OverworldGenerator, biome_id: BiomeId, height: i32, sea_level: i32, render_water_surface: bool) BlockType {
        if (render_water_surface or height < sea_level) return .water;
        return switch (biome_id) {
            .desert, .badlands => .sand,
            .snow_tundra, .snowy_mountains => .snow_block,
            .beach => .sand,
            else => .grass,
        };
    }

    fn populateClassificationCache(
        self: *OverworldGenerator,
        world_x: i32,
        world_z: i32,
        surface_heights: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]i32,
        biome_ids: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
        continentalness_values: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]f32,
        is_ocean_water_flags: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]bool,
        coastal_types: *const [CHUNK_SIZE_X * CHUNK_SIZE_Z]CoastalSurfaceType,
    ) void {
        const sea_level = self.terrain_shape.getSeaLevel();
        const region_seed = self.terrain_shape.getRegionSeed();

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const idx = local_x + local_z * CHUNK_SIZE_X;
                const wx = world_x + @as(i32, @intCast(local_x));
                const wz = world_z + @as(i32, @intCast(local_z));
                if (self.classification_cache.has(wx, wz)) continue;

                const biome_id = biome_ids[idx];
                const height = surface_heights[idx];
                const continentalness = continentalness_values[idx];
                const is_ocean = is_ocean_water_flags[idx];
                const coastal_type = coastal_types[idx];

                const surface_type = self.deriveSurfaceTypeInternal(
                    biome_id,
                    height,
                    sea_level,
                    is_ocean,
                    coastal_type,
                );

                const continental_zone = self.terrain_shape.getContinentalZone(continentalness);
                const region_info = region_pkg.getRegion(region_seed, wx, wz);
                const path_info = region_pkg.getPathInfo(region_seed, wx, wz, region_info);

                self.classification_cache.put(wx, wz, .{
                    .biome_id = biome_id,
                    .surface_type = surface_type,
                    .is_water = height < sea_level,
                    .continental_zone = continental_zone,
                    .region_role = region_info.role,
                    .path_type = path_info.path_type,
                });
            }
        }
    }

    fn getCachedClassification(self: *const OverworldGenerator, world_x: i32, world_z: i32) ?gen_region.ClassCell {
        const mutable_self: *OverworldGenerator = @constCast(self);
        mutable_self.cache_mutex.lock();
        defer mutable_self.cache_mutex.unlock();
        return mutable_self.classification_cache.get(world_x, world_z);
    }

    fn deriveSurfaceTypeInternal(
        _: *const OverworldGenerator,
        biome_id: BiomeId,
        height: i32,
        sea_level: i32,
        is_ocean: bool,
        coastal_type: CoastalSurfaceType,
    ) SurfaceType {
        if (is_ocean and height < sea_level - 30) return .water_deep;
        if (is_ocean and height < sea_level) return .water_shallow;

        switch (coastal_type) {
            .sand_beach => return .sand,
            .gravel_beach => return .rock,
            .cliff => return .stone,
            .none => {},
        }

        return switch (biome_id) {
            .desert, .badlands, .beach => .sand,
            .snow_tundra, .snowy_mountains => .snow,
            .mountains => if (height > 120) .rock else .stone,
            .deep_ocean, .ocean => .sand,
            else => .grass,
        };
    }

    pub fn generator(self: *OverworldGenerator) Generator {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
            .info = INFO,
        };
    }

    const VTABLE = Generator.VTable{
        .generate = generateWrapper,
        .generateHeightmapOnly = generateHeightmapOnlyWrapper,
        .maybeRecenterCache = maybeRecenterCacheWrapper,
        .getSeed = getSeedWrapper,
        .getRegionInfo = getRegionInfoWrapper,
        .getColumnInfo = getColumnInfoWrapper,
        .deinit = deinitWrapper,
    };

    fn generateWrapper(ptr: *anyopaque, chunk: *Chunk, stop_flag: ?*const bool) void {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        self.generate(chunk, stop_flag);
    }

    fn generateHeightmapOnlyWrapper(ptr: *anyopaque, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        self.generateHeightmapOnly(data, region_x, region_z, lod_level);
    }

    fn maybeRecenterCacheWrapper(ptr: *anyopaque, player_x: i32, player_z: i32) bool {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.maybeRecenterCache(player_x, player_z);
    }

    fn getSeedWrapper(ptr: *anyopaque) u64 {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getSeed();
    }

    fn getRegionInfoWrapper(ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn getColumnInfoWrapper(ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(wx, wz);
    }

    fn deinitWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *OverworldGenerator = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

test "LOD cached water surfaces resolve to seabed block" {
    try std.testing.expectEqual(BlockType.water, OverworldGenerator.surfaceTypeToBlock(undefined, .water_shallow));
    try std.testing.expectEqual(BlockType.water, OverworldGenerator.surfaceTypeToBlock(undefined, .water_deep));
}
