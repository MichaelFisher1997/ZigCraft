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
const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const BlockType = @import("../block.zig").BlockType;
const block_registry = @import("../block_registry.zig");
const lod_chunk = @import("../lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const DecorationProvider = @import("decoration_provider.zig").DecorationProvider;
const gen_region = @import("gen_region.zig");
const ClassificationCache = gen_region.ClassificationCache;
const gen_interface = @import("generator_interface.zig");
const Generator = gen_interface.Generator;
const GeneratorInfo = gen_interface.GeneratorInfo;
const ColumnInfo = gen_interface.ColumnInfo;
const log = @import("../../engine/core/log.zig");

const terrain_shape_mod = @import("terrain_shape_generator.zig");
const TerrainShapeGenerator = terrain_shape_mod.TerrainShapeGenerator;
const NoiseSampler = terrain_shape_mod.NoiseSampler;
const HeightSampler = terrain_shape_mod.HeightSampler;
const SurfaceBuilder = terrain_shape_mod.SurfaceBuilder;
const CoastalSurfaceType = terrain_shape_mod.CoastalSurfaceType;
const BiomeSource = @import("biome.zig").BiomeSource;
const BiomeDecorator = @import("biome_decorator.zig").BiomeDecorator;
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

        const region_size_i: i32 = @intCast(lod_level.regionSizeBlocks());
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

        var gz: u32 = 0;
        while (gz < data.width) : (gz += 1) {
            var gx: u32 = 0;
            while (gx < data.width) : (gx += 1) {
                const idx = gx + gz * data.width;
                const wx = @as(f32, @floatFromInt(world_x)) + (@as(f32, @floatFromInt(gx)) / grid_max) * region_size_f;
                const wz = @as(f32, @floatFromInt(world_z)) + (@as(f32, @floatFromInt(gz)) / grid_max) * region_size_f;
                const wx_i: i32 = @intFromFloat(@floor(wx));
                const wz_i: i32 = @intFromFloat(@floor(wz));
                const column = self.terrain_shape.sampleColumnDataWithControls(wx, wz, 0, controls.sample(wx_i, wz_i));
                const render_water_surface = column.terrain_height_i < sea_level and (column.is_ocean or self.isInlandWater(wx, wz, column.terrain_height_i));
                data.heightmap[idx] = if (render_water_surface)
                    @as(f32, @floatFromInt(sea_level))
                else
                    column.terrain_height;

                if (self.getCachedClassification(wx_i, wz_i)) |cached| {
                    data.biomes[idx] = cached.biome_id;
                    data.top_blocks[idx] = if (render_water_surface)
                        .water
                    else
                        self.surfaceTypeToBlock(cached.surface_type);
                    data.colors[idx] = packBlockColor(data.top_blocks[idx]);
                    continue;
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
                data.biomes[idx] = biome_id;
                data.top_blocks[idx] = self.getSurfaceBlock(biome_id, column.terrain_height_i, sea_level, render_water_surface);
                data.colors[idx] = packBlockColor(data.top_blocks[idx]);
            }
        }
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
