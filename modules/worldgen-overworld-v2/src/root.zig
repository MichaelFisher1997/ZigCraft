//! Overworld V2 terrain generator.
//!
//! Terrain equations, default noise parameters, river channel shaping, mountain
//! density, and noise-intersection caves are ported from Luanti mapgen v7:
//! https://github.com/luanti-org/luanti/blob/master/src/mapgen/mapgen_v7.cpp
//! Luanti source is LGPL-2.1-or-later; its noise helpers are BSD-style licensed.

const std = @import("std");
const worldgen_api = @import("worldgen-api");
const world_core = @import("world-core");
const LightingComputer = @import("worldgen-common").LightingComputer;

const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const LODLevel = world_core.LODLevel;
const LODSimplifiedData = world_core.LODSimplifiedData;
const Generator = worldgen_api.Generator;
const GeneratorInfo = worldgen_api.GeneratorInfo;
const ColumnInfo = worldgen_api.ColumnInfo;
const RegionInfo = worldgen_api.RegionInfo;

const LUANTI_WATER_LEVEL: i32 = 1;
const MGV7_MOUNTAINS: u32 = 0x01;
const MGV7_RIDGES: u32 = 0x02;
const MGV7_CAVERNS: u32 = 0x08;
const DEFAULT_SPFLAGS: u32 = MGV7_MOUNTAINS | MGV7_RIDGES | MGV7_CAVERNS;

const NOISE_FLAG_DEFAULTS: u32 = 0x01;
const NOISE_FLAG_EASED: u32 = 0x02;
const NOISE_FLAG_ABSVALUE: u32 = 0x04;

const Vec3f = struct {
    x: f32,
    y: f32,
    z: f32,

    fn uniform(v: f32) Vec3f {
        return .{ .x = v, .y = v, .z = v };
    }
};

const LuantiNoiseParams = struct {
    offset: f32,
    scale: f32,
    spread: Vec3f,
    seed: i32,
    octaves: u16,
    persist: f32,
    lacunarity: f32,
    flags: u32 = NOISE_FLAG_DEFAULTS,
};

const ClimateSample = struct {
    temperature: f32,
    humidity: f32,
};

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

const TreeBlocks = struct {
    trunk: BlockType,
    leaves: BlockType,
};

const TreeShape = enum {
    oak,
    birch,
    spruce,
    jungle,
    acacia,
};

const GroundDecoration = enum {
    tall_grass,
    flower_red,
    flower_yellow,
    dead_bush,
    cactus,
    bamboo,
    snow_layer,
};

pub const OverworldV2Generator = struct {
    pub const INFO = GeneratorInfo{
        .name = "Overworld V2",
        .description = "Luanti v7-style terrain with ridges, mountains, rivers, and cave noise.",
        .version = 1,
    };

    pub const Params = struct {
        sea_level: i32 = 64,
        spflags: u32 = DEFAULT_SPFLAGS,
        mount_zero_level: i32 = 0,
        cave_width: f32 = 0.09,
        enable_lighting: bool = true,
    };

    seed: u64,
    seed32: i32,
    allocator: std.mem.Allocator,
    params: Params,

    noise_terrain_base: LuantiNoiseParams,
    noise_terrain_alt: LuantiNoiseParams,
    noise_terrain_persist: LuantiNoiseParams,
    noise_height_select: LuantiNoiseParams,
    noise_filler_depth: LuantiNoiseParams,
    noise_mount_height: LuantiNoiseParams,
    noise_ridge_uwater: LuantiNoiseParams,
    noise_mountain: LuantiNoiseParams,
    noise_ridge: LuantiNoiseParams,
    noise_cave1: LuantiNoiseParams,
    noise_cave2: LuantiNoiseParams,
    noise_temperature: LuantiNoiseParams,
    noise_humidity: LuantiNoiseParams,

    pub fn init(seed: u64, allocator: std.mem.Allocator) OverworldV2Generator {
        return initWithParams(seed, allocator, .{});
    }

    pub fn initWithParams(seed: u64, allocator: std.mem.Allocator, params: Params) OverworldV2Generator {
        const seed32_u: u32 = @truncate(seed);
        const seed32: i32 = @bitCast(seed32_u);
        return .{
            .seed = seed,
            .seed32 = seed32,
            .allocator = allocator,
            .params = params,
            .noise_terrain_base = np(4.0, 70.0, Vec3f.uniform(600), 82341, 5, 0.6, 2.0),
            .noise_terrain_alt = np(4.0, 25.0, Vec3f.uniform(600), 5934, 5, 0.6, 2.0),
            .noise_terrain_persist = np(0.6, 0.1, Vec3f.uniform(2000), 539, 3, 0.6, 2.0),
            .noise_height_select = np(-8.0, 16.0, Vec3f.uniform(500), 4213, 6, 0.7, 2.0),
            .noise_filler_depth = np(0.0, 1.2, Vec3f.uniform(150), 261, 3, 0.7, 2.0),
            .noise_mount_height = np(256.0, 112.0, Vec3f.uniform(1000), 72449, 3, 0.6, 2.0),
            .noise_ridge_uwater = np(0.0, 1.0, Vec3f.uniform(1000), 85039, 5, 0.6, 2.0),
            .noise_mountain = np(-0.6, 1.0, .{ .x = 250, .y = 350, .z = 250 }, 5333, 5, 0.63, 2.0),
            .noise_ridge = np(0.0, 1.0, Vec3f.uniform(100), 6467, 4, 0.75, 2.0),
            .noise_cave1 = np(0.0, 12.0, Vec3f.uniform(61), 52534, 3, 0.5, 2.0),
            .noise_cave2 = np(0.0, 12.0, Vec3f.uniform(67), 10325, 3, 0.5, 2.0),
            .noise_temperature = np(0.0, 1.0, Vec3f.uniform(1400), 9130, 3, 0.55, 2.0),
            .noise_humidity = np(0.0, 1.0, Vec3f.uniform(1200), 9171, 3, 0.55, 2.0),
        };
    }

    pub fn deinit(self: *OverworldV2Generator) void {
        // No owned heap allocations; allocator is stored only for per-call lighting work.
        _ = self;
    }

    pub fn generate(self: *OverworldV2Generator, chunk: *Chunk, stop_flag: ?*const bool) void {
        chunk.generated = false;
        @memset(&chunk.blocks, .air);
        @memset(&chunk.biomes, .plains);
        @memset(&chunk.heightmap, 0);

        const world_x0 = chunk.getWorldX();
        const world_z0 = chunk.getWorldZ();

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const wx = world_x0 + @as(i32, @intCast(local_x));
                const wz = world_z0 + @as(i32, @intCast(local_z));
                const sample = self.sampleColumn(wx, wz);
                self.fillRawTerrainColumn(chunk, local_x, local_z, wx, wz, sample.base_height);
                self.applyBiomeSurfaceColumn(chunk, local_x, local_z, wx, wz, sample);
                if (self.params.spflags & MGV7_CAVERNS != 0) {
                    self.carveNoiseCavesColumn(chunk, local_x, local_z, wx, wz, sample.terrain_height);
                }
                const actual_height = highestSolidY(chunk, local_x, local_z, sample.terrain_height);
                chunk.setSurfaceHeight(local_x, local_z, @intCast(actual_height));
                chunk.biomes[local_x + local_z * CHUNK_SIZE_X] = sample.biome;
            }
        }

        self.placeTrees(chunk, stop_flag);
        self.placeVegetation(chunk, stop_flag);

        if (self.params.enable_lighting) {
            LightingComputer.computeSkylight(chunk, self.allocator) catch return;
        }

        chunk.generated = true;
        chunk.dirty = true;
        chunk.modified = false;
    }

    fn placeTrees(self: *const OverworldV2Generator, chunk: *Chunk, stop_flag: ?*const bool) void {
        const world_x0 = chunk.getWorldX();
        const world_z0 = chunk.getWorldZ();

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const surface_y = chunk.getSurfaceHeight(local_x, local_z);
                if (surface_y <= self.params.sea_level or surface_y >= CHUNK_SIZE_Y - 8) continue;

                const surface = chunk.getBlock(local_x, @intCast(surface_y), local_z);
                if (surface != .grass and surface != .dirt and surface != .snow_block and surface != .sand) continue;

                const biome = chunk.biomes[local_x + local_z * CHUNK_SIZE_X];
                const wx = world_x0 + @as(i32, @intCast(local_x));
                const wz = world_z0 + @as(i32, @intCast(local_z));
                const tree = self.treeForColumn(biome, wx, wz) orelse continue;
                placeTreeShape(chunk, local_x, @intCast(surface_y + 1), local_z, tree);
            }
        }
    }

    fn treeForColumn(self: *const OverworldV2Generator, biome: BiomeId, wx: i32, wz: i32) ?TreeShape {
        const density = treeDensityForBiome(biome);
        if (density <= 0.0) return null;

        const spacing: i32 = switch (biome) {
            .jungle => 4,
            .forest, .taiga, .snowy_taiga => 5,
            .savanna => 7,
            else => 6,
        };
        if (@mod(wx, spacing) != @mod(hash2i(wx, wz, self.seed32 +% 4101), spacing)) return null;
        if (@mod(wz, spacing) != @mod(hash2i(wx, wz, self.seed32 +% 4109), spacing)) return null;

        const roll = hashUnit(wx, wz, self.seed32 +% 4127);
        if (roll > density) return null;

        return switch (biome) {
            .taiga, .snowy_taiga, .snow_tundra, .old_growth_taiga, .grove => .spruce,
            .jungle, .bamboo_jungle, .sparse_jungle => .jungle,
            .savanna, .savanna_plateau, .windswept_savanna => .acacia,
            .birch_forest => .birch,
            .forest, .flower_forest => if (hashUnit(wx, wz, self.seed32 +% 4133) < 0.25) .birch else .oak,
            else => .oak,
        };
    }

    fn placeVegetation(self: *const OverworldV2Generator, chunk: *Chunk, stop_flag: ?*const bool) void {
        const world_x0 = chunk.getWorldX();
        const world_z0 = chunk.getWorldZ();

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const surface_y = chunk.getSurfaceHeight(local_x, local_z);
                if (surface_y <= 0 or surface_y >= CHUNK_SIZE_Y - 2) continue;

                const biome = chunk.biomes[local_x + local_z * CHUNK_SIZE_X];
                const surface = chunk.getBlock(local_x, @intCast(surface_y), local_z);
                const wx = world_x0 + @as(i32, @intCast(local_x));
                const wz = world_z0 + @as(i32, @intCast(local_z));

                if (surface_y < self.params.sea_level and chunk.getBlockSafe(@intCast(local_x), surface_y + 1, @intCast(local_z)) == .water) {
                    self.placeAquaticVegetation(chunk, local_x, @intCast(surface_y), local_z, biome, surface, wx, wz);
                } else {
                    self.placeGroundVegetation(chunk, local_x, @intCast(surface_y), local_z, biome, surface, wx, wz);
                }
            }
        }
    }

    fn placeGroundVegetation(self: *const OverworldV2Generator, chunk: *Chunk, x: u32, surface_y: u32, z: u32, biome: BiomeId, surface: BlockType, wx: i32, wz: i32) void {
        const place_y = surface_y + 1;
        if (place_y >= CHUNK_SIZE_Y or chunk.getBlock(x, place_y, z) != .air) return;

        const variant = hashUnit(wx, wz, self.seed32 +% 5101);
        const scatter = hashUnit(wx, wz, self.seed32 +% 5107);
        const deco = groundDecorationForBiome(biome, surface, variant, scatter) orelse return;

        switch (deco) {
            .cactus => placeCactus(chunk, x, place_y, z, 2 + @as(u32, @intFromFloat(hashUnit(wx, wz, self.seed32 +% 5113) * 3.0))),
            .bamboo => placeColumnDecoration(chunk, x, place_y, z, .bamboo, 2 + @as(u32, @intFromFloat(hashUnit(wx, wz, self.seed32 +% 5119) * 5.0))),
            .snow_layer => if (surface == .snow_block or biome == .snow_tundra or biome == .snowy_taiga or biome == .snowy_slopes) setDecorationBlock(chunk, x, place_y, z, .snow_layer),
            else => setDecorationBlock(chunk, x, place_y, z, groundDecorationBlock(deco)),
        }
    }

    fn placeAquaticVegetation(self: *const OverworldV2Generator, chunk: *Chunk, x: u32, surface_y: u32, z: u32, biome: BiomeId, surface: BlockType, wx: i32, wz: i32) void {
        if (!isOceanBiome(biome)) return;
        if (surface != .sand and surface != .gravel and surface != .clay and surface != .coral_block) return;

        const water_depth = columnWaterDepth(chunk, x, z, @intCast(surface_y));
        if (water_depth < 2) return;

        const variant = hashUnit(wx, wz, self.seed32 +% 5201);
        const scatter = hashUnit(wx, wz, self.seed32 +% 5207);
        const place_y = surface_y + 1;
        if (chunk.getBlock(x, place_y, z) != .water) return;

        if ((biome == .warm_ocean or biome == .tropical) and scatter < 0.04 and water_depth <= 10) {
            if (variant < 0.35) {
                setDecorationBlock(chunk, x, surface_y, z, .coral_block);
            } else {
                setDecorationBlock(chunk, x, place_y, z, .coral_fan);
            }
            return;
        }

        if (water_depth >= 6 and scatter < 0.06) {
            placeKelp(chunk, x, place_y, z, @min(water_depth - 1, 2 + @as(u8, @intFromFloat(variant * 7.0))));
        } else if (water_depth >= 4 and scatter < 0.13) {
            setDecorationBlock(chunk, x, place_y, z, .tall_seagrass);
        } else if (scatter < 0.24) {
            setDecorationBlock(chunk, x, place_y, z, if (variant < 0.75) .seagrass else .seaweed);
        }
    }

    fn fillRawTerrainColumn(self: *const OverworldV2Generator, chunk: *Chunk, local_x: u32, local_z: u32, wx: i32, wz: i32, base_surface_y: i32) void {
        var y: u32 = 0;
        while (y < CHUNK_SIZE_Y) : (y += 1) {
            const yi: i32 = @intCast(y);
            const block: BlockType = if (yi == 0)
                .bedrock
            else if (self.isTerrainStone(wx, yi, wz, base_surface_y))
                .stone
            else if (yi <= self.params.sea_level)
                .water
            else
                .air;
            chunk.blocks[Chunk.getIndex(local_x, y, local_z)] = block;
        }
    }

    fn applyBiomeSurfaceColumn(self: *const OverworldV2Generator, chunk: *Chunk, local_x: u32, local_z: u32, wx: i32, wz: i32, sample: ColumnSample) void {
        const filler_depth = self.fillerDepth(wx, wz);
        var layer_depth: i32 = -1;
        var above: BlockType = .air;
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y >= 1) : (y -= 1) {
            const uy: u32 = @intCast(y);
            const idx = Chunk.getIndex(local_x, uy, local_z);
            const block = chunk.blocks[idx];

            if (block != .stone) {
                layer_depth = -1;
                above = block;
                continue;
            }

            if (above == .air or above == .water) {
                layer_depth = 0;
            }

            if (layer_depth >= 0) {
                const underwater = above == .water;
                chunk.blocks[idx] = if (layer_depth == 0)
                    surfaceBlock(sample.biome, sample.terrain_height, self.params.sea_level, underwater)
                else if (layer_depth <= filler_depth)
                    fillerBlock(sample.biome, underwater)
                else
                    .stone;
                layer_depth += 1;
            }

            above = chunk.blocks[idx];
        }
    }

    fn carveNoiseCavesColumn(self: *const OverworldV2Generator, chunk: *Chunk, local_x: u32, local_z: u32, wx: i32, wz: i32, terrain_height: i32) void {
        if (terrain_height <= 2) return;

        var y: u32 = 1;
        while (y < CHUNK_SIZE_Y) : (y += 1) {
            const yi: i32 = @intCast(y);
            if (yi > terrain_height + 8) break;

            const idx = Chunk.getIndex(local_x, y, local_z);
            if (!isCaveCarvable(chunk.blocks[idx])) continue;

            const ly = self.toLuantiY(yi);
            const d1 = contour(noiseFractal3D(&self.noise_cave1, @floatFromInt(wx), ly, @floatFromInt(wz), self.seed32));
            const d2 = contour(noiseFractal3D(&self.noise_cave2, @floatFromInt(wx), ly, @floatFromInt(wz), self.seed32));
            if (d1 * d2 > self.params.cave_width) {
                chunk.blocks[idx] = .air;
            }
        }
    }

    fn isTerrainStone(self: *const OverworldV2Generator, wx: i32, y: i32, wz: i32, base_surface_y: i32) bool {
        const river_channel = (self.params.spflags & MGV7_RIDGES != 0) and self.getRiverChannelAt(wx, y, wz);
        if (y <= base_surface_y and !river_channel) return true;
        if ((self.params.spflags & MGV7_MOUNTAINS != 0) and !river_channel and self.getMountainTerrainAt(wx, y, wz)) return true;
        return false;
    }

    fn sampleColumn(self: *const OverworldV2Generator, wx: i32, wz: i32) ColumnSample {
        const base_height = floorToI32(self.baseTerrainLevelAtPoint(wx, wz));
        const terrain_height = self.estimateTerrainHeight(wx, wz, base_height);
        const climate = self.sampleClimate(wx, wz);
        const river = self.isRiverColumn(wx, wz) and terrain_height >= self.params.sea_level - 18 and terrain_height <= self.params.sea_level + 1;
        const biome = self.selectBiome(wx, wz, terrain_height, river, climate.temperature, climate.humidity);
        const continentalness = std.math.clamp((@as(f32, @floatFromInt(terrain_height - self.params.sea_level)) + 56.0) / 150.0, 0.0, 1.0);
        return .{
            .terrain_height = terrain_height,
            .base_height = base_height,
            .biome = biome,
            .is_river = river,
            .is_ocean = terrain_height < self.params.sea_level - 2,
            .temperature = climate.temperature,
            .humidity = climate.humidity,
            .continentalness = continentalness,
        };
    }

    fn estimateTerrainHeight(self: *const OverworldV2Generator, wx: i32, wz: i32, base_surface_y: i32) i32 {
        var y: i32 = CHUNK_SIZE_Y - 1;
        while (y >= 1) : (y -= 1) {
            if (self.isTerrainStone(wx, y, wz, base_surface_y)) return y;
        }
        return 0;
    }

    fn baseTerrainLevelAtPoint(self: *const OverworldV2Generator, wx: i32, wz: i32) f32 {
        const x: f32 = @floatFromInt(wx);
        const z: f32 = @floatFromInt(wz);
        const hselect = std.math.clamp(noiseFractal2D(&self.noise_height_select, x, z, self.seed32), 0.0, 1.0);
        const persist = noiseFractal2D(&self.noise_terrain_persist, x, z, self.seed32);

        const height_base = noiseFractal2DWithPersist(&self.noise_terrain_base, x, z, self.seed32, persist);
        const height_alt = noiseFractal2DWithPersist(&self.noise_terrain_alt, x, z, self.seed32, persist);
        const luanti_height = if (height_alt > height_base)
            height_alt
        else
            height_base * hselect + height_alt * (1.0 - hselect);

        return luanti_height + @as(f32, @floatFromInt(self.verticalShift()));
    }

    fn getMountainTerrainAt(self: *const OverworldV2Generator, wx: i32, y: i32, wz: i32) bool {
        const x: f32 = @floatFromInt(wx);
        const z: f32 = @floatFromInt(wz);
        const luanti_y = self.toLuantiY(y);
        const mount_height = @max(noiseFractal2D(&self.noise_mount_height, x, z, self.seed32), 1.0);
        const density_gradient = -((luanti_y - @as(f32, @floatFromInt(self.params.mount_zero_level))) / mount_height);
        const mountain = noiseFractal3D(&self.noise_mountain, x, luanti_y, z, self.seed32);
        return mountain + density_gradient >= 0.0;
    }

    fn getRiverChannelAt(self: *const OverworldV2Generator, wx: i32, y: i32, wz: i32) bool {
        const width: f32 = 0.2;
        const x: f32 = @floatFromInt(wx);
        const z: f32 = @floatFromInt(wz);
        const absuwater = @abs(noiseFractal2D(&self.noise_ridge_uwater, x, z, self.seed32)) * 2.0;
        if (absuwater > width) return false;

        const altitude = @as(f32, @floatFromInt(y - self.params.sea_level));
        const height_mod = (altitude + 17.0) / 2.5;
        const width_mod = width - absuwater;
        const ridge = noiseFractal3D(&self.noise_ridge, x, self.toLuantiY(y), z, self.seed32) * @max(altitude, 0.0) / 7.0;
        return ridge + width_mod * height_mod >= 0.6;
    }

    fn isRiverColumn(self: *const OverworldV2Generator, wx: i32, wz: i32) bool {
        if (self.params.spflags & MGV7_RIDGES == 0) return false;
        const x: f32 = @floatFromInt(wx);
        const z: f32 = @floatFromInt(wz);
        return @abs(noiseFractal2D(&self.noise_ridge_uwater, x, z, self.seed32)) * 2.0 <= 0.2;
    }

    fn fillerDepth(self: *const OverworldV2Generator, wx: i32, wz: i32) i32 {
        const depth = 4.0 + noiseFractal2D(&self.noise_filler_depth, @floatFromInt(wx), @floatFromInt(wz), self.seed32);
        return @max(2, floorToI32(depth));
    }

    fn sampleClimate(self: *const OverworldV2Generator, wx: i32, wz: i32) ClimateSample {
        const x: f32 = @floatFromInt(wx);
        const z: f32 = @floatFromInt(wz);
        const temp_raw = noiseFractal2D(&self.noise_temperature, x, z, self.seed32);
        const humid_raw = noiseFractal2D(&self.noise_humidity, x + 913.0, z - 719.0, self.seed32);
        return .{
            .temperature = std.math.clamp((temp_raw + 1.0) * 0.5, 0.0, 1.0),
            .humidity = std.math.clamp((humid_raw + 1.0) * 0.5, 0.0, 1.0),
        };
    }

    fn selectBiome(self: *const OverworldV2Generator, wx: i32, wz: i32, height: i32, river: bool, temperature: f32, humidity: f32) BiomeId {
        if (river) return if (temperature < 0.22) .frozen_river else .river;
        if (height < self.params.sea_level - 24) return if (temperature < 0.2) .frozen_ocean else .deep_ocean;
        if (height < self.params.sea_level - 2) return if (temperature < 0.2) .cold_ocean else .ocean;
        if (self.isBeachColumn(wx, wz, height)) return if (temperature < 0.18) .snowy_beach else .beach;
        if (height > self.params.sea_level + 95) return if (temperature < 0.35) .frozen_peaks else .jagged_peaks;
        if (height > self.params.sea_level + 62) return if (temperature < 0.28) .snowy_slopes else .mountains;
        if (temperature < 0.18) return .snow_tundra;
        if (temperature < 0.30) return if (humidity > 0.55) .taiga else .snowy_taiga;
        if (temperature > 0.78 and humidity < 0.30) return .desert;
        if (temperature > 0.70 and humidity > 0.68) return .jungle;
        if (temperature > 0.66 and humidity < 0.45) return .savanna;
        if (humidity > 0.70) return .forest;
        return .plains;
    }

    fn isBeachColumn(self: *const OverworldV2Generator, wx: i32, wz: i32, height: i32) bool {
        if (height < self.params.sea_level - 1 or height > self.params.sea_level + 1) return false;

        const offsets = [_][2]i32{
            .{ -6, 0 },
            .{ 6, 0 },
            .{ 0, -6 },
            .{ 0, 6 },
            .{ -8, -8 },
            .{ 8, -8 },
            .{ -8, 8 },
            .{ 8, 8 },
        };

        for (offsets) |offset| {
            const neighbor_base = floorToI32(self.baseTerrainLevelAtPoint(wx + offset[0], wz + offset[1]));
            if (neighbor_base < self.params.sea_level - 1) return true;
        }

        return false;
    }

    pub fn generateHeightmapOnly(self: *const OverworldV2Generator, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel, stop_flag: ?*const std.atomic.Value(bool)) void {
        if (data.width < 2) return;
        const region_size_i: i32 = @intCast(world_core.regionSizeBlocks(lod_level));
        const region_size_f: f32 = @floatFromInt(region_size_i);
        const grid_max: f32 = @floatFromInt(data.width - 1);
        const cell_span = region_size_f / grid_max;
        const world_x = region_x * region_size_i;
        const world_z = region_z * region_size_i;

        var gz: u32 = 0;
        while (gz < data.width) : (gz += 1) {
            if (stop_flag) |sf| if (sf.load(.acquire)) return;
            var gx: u32 = 0;
            while (gx < data.width) : (gx += 1) {
                const wx_f = @as(f32, @floatFromInt(world_x)) + (@as(f32, @floatFromInt(gx)) / grid_max) * region_size_f;
                const wz_f = @as(f32, @floatFromInt(world_z)) + (@as(f32, @floatFromInt(gz)) / grid_max) * region_size_f;
                const sample = self.sampleRepresentativeLODColumn(wx_f, wz_f, cell_span);
                data.setGeneratedColumn(gx, gz, sample.height, sample.biome, sample.layers, sample.color, sample.water, sample.lighting, sample.vegetation);
            }
        }
    }

    fn sampleRepresentativeLODColumn(self: *const OverworldV2Generator, wx: f32, wz: f32, cell_span: f32) RepresentativeLODColumn {
        // Single center sample (see overworld v1 rationale): the 3x3 grid
        // sampled a sub-block neighborhood, so 8 of 9 samples were nearly
        // identical — ~9x cost for negligible benefit.
        const sample_offsets = [_]f32{0.0};
        const sample_radius = @min(cell_span * 0.5, 48.0);
        const center_sample = self.classifyLODSample(wx, wz);

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
                const sample = self.classifyLODSample(wx + ox * sample_radius, wz + oz * sample_radius);
                const block_index = @intFromEnum(sample.surface_block);
                if (block_index < block_counts.len) block_counts[block_index] += 1;
                biome_counts[@intFromEnum(sample.biome)] += 1;

                const color = colorForBiome(sample.biome, sample.surface_block);
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
        const surface_block: BlockType = if (render_water_surface) .water else if (center_sample.render_water_surface) dominant_block else center_sample.surface_block;
        const avg_height = terrain_height_sum / @as(f32, @floatFromInt(sample_count));
        const terrain_range = @max(terrain_max - terrain_min, 0.0);
        const center_height = center_sample.terrain_height;
        const height_blend: f32 = if (terrain_range > 24.0 and center_height > avg_height) 0.82 else 0.68;
        const land_height = center_height * height_blend + avg_height * (1.0 - height_blend);
        const vegetation = if (render_water_surface)
            world_core.LODVegetationHint.empty
        else
            self.lodVegetationHintInArea(wx, wz, sample_radius, dominant_biome);
        const avg_color = packAverageColor(color_r, color_g, color_b, sample_count);

        return .{
            .height = if (render_water_surface) @floatFromInt(self.params.sea_level) else land_height,
            .biome = dominant_biome,
            .layers = .{
                .surface = surface_block,
                .subsurface = fillerBlock(dominant_biome, render_water_surface),
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

    fn classifyLODSample(self: *const OverworldV2Generator, wx: f32, wz: f32) ClassifiedLODSample {
        const wx_i: i32 = @intFromFloat(@floor(wx));
        const wz_i: i32 = @intFromFloat(@floor(wz));
        const sample = self.sampleLODColumn(wx_i, wz_i);
        const render_water_surface = sample.terrain_height < self.params.sea_level;
        const surface_block: BlockType = if (render_water_surface) .water else surfaceBlock(sample.biome, sample.terrain_height, self.params.sea_level, false);

        return .{
            .terrain_height = @floatFromInt(sample.terrain_height),
            .terrain_height_i = sample.terrain_height,
            .biome = sample.biome,
            .surface_block = surface_block,
            .render_water_surface = render_water_surface,
        };
    }

    fn sampleLODColumn(self: *const OverworldV2Generator, wx: i32, wz: i32) ColumnSample {
        const base_height = floorToI32(self.baseTerrainLevelAtPoint(wx, wz));
        const terrain_height = self.estimateGroundedTerrainHeight(wx, wz, base_height);
        const climate = self.sampleClimate(wx, wz);
        const river = self.isRiverColumn(wx, wz) and terrain_height >= self.params.sea_level - 18 and terrain_height <= self.params.sea_level + 1;
        const biome = self.selectBiome(wx, wz, terrain_height, river, climate.temperature, climate.humidity);
        const continentalness = std.math.clamp((@as(f32, @floatFromInt(terrain_height - self.params.sea_level)) + 56.0) / 150.0, 0.0, 1.0);
        return .{
            .terrain_height = terrain_height,
            .base_height = base_height,
            .biome = biome,
            .is_river = river,
            .is_ocean = terrain_height < self.params.sea_level - 2,
            .temperature = climate.temperature,
            .humidity = climate.humidity,
            .continentalness = continentalness,
        };
    }

    fn estimateGroundedTerrainHeight(self: *const OverworldV2Generator, wx: i32, wz: i32, base_surface_y: i32) i32 {
        var top: i32 = 0;
        var connected_to_base = true;

        var y: i32 = 1;
        while (y < CHUNK_SIZE_Y) : (y += 1) {
            const stone = self.isTerrainStone(wx, y, wz, base_surface_y);
            if (stone and connected_to_base) top = y;
            if (!stone and y > base_surface_y) connected_to_base = false;
        }

        return top;
    }

    fn lodVegetationHintInArea(self: *const OverworldV2Generator, center_wx: f32, center_wz: f32, radius: f32, dominant_biome: BiomeId) world_core.LODVegetationHint {
        const sample_offsets = [_]f32{ -0.5, 0.0, 0.5 };

        var tree_count: u32 = 0;
        var total_columns: u32 = 0;
        var height_sum: f32 = 0.0;
        var offset_x_sum: f32 = 0.0;
        var offset_z_sum: f32 = 0.0;
        var best_shape: ?TreeShape = null;

        for (sample_offsets) |oz| {
            for (sample_offsets) |ox| {
                const wx: i32 = @intFromFloat(@floor(center_wx + ox * radius));
                const wz: i32 = @intFromFloat(@floor(center_wz + oz * radius));
                total_columns += 1;
                const shape = self.treeForColumn(dominant_biome, wx, wz) orelse continue;
                tree_count += 1;
                height_sum += treeHeightForShape(shape);
                offset_x_sum += @as(f32, @floatFromInt(wx)) - center_wx;
                offset_z_sum += @as(f32, @floatFromInt(wz)) - center_wz;
                if (best_shape == null) best_shape = shape;
            }
        }

        if (tree_count == 0) return world_core.LODVegetationHint.empty;

        const area = @as(f32, @floatFromInt(@max(total_columns, 1)));
        const sampled_coverage = std.math.clamp(@as(f32, @floatFromInt(tree_count)) / area, 0.0, 1.0);
        const blocks = treeBlocksForShape(best_shape orelse defaultTreeShapeForBiome(dominant_biome));

        return .{
            .tree_coverage = sampled_coverage,
            .avg_tree_height = height_sum / @as(f32, @floatFromInt(tree_count)),
            .offset_x = offset_x_sum / @as(f32, @floatFromInt(tree_count)),
            .offset_z = offset_z_sum / @as(f32, @floatFromInt(tree_count)),
            .trunk = blocks.trunk,
            .leaves = blocks.leaves,
        };
    }

    fn estimatedLODVegetationHint(self: *const OverworldV2Generator, biome: BiomeId, wx: i32, wz: i32) world_core.LODVegetationHint {
        const density = treeDensityForBiome(biome);
        if (density <= 0.0) return world_core.LODVegetationHint.empty;
        const shape = defaultTreeShapeForBiome(biome);
        const blocks = treeBlocksForShape(shape);
        const jitter = hashUnit(wx, wz, self.seed32 +% 6131);
        return .{
            .tree_coverage = std.math.clamp(density * (0.75 + jitter * 0.3), 0.0, 1.0),
            .avg_tree_height = treeHeightForShape(shape),
            .offset_x = (hashUnit(wx, wz, self.seed32 +% 6133) - 0.5) * 2.0,
            .offset_z = (hashUnit(wx, wz, self.seed32 +% 6137) - 0.5) * 2.0,
            .trunk = blocks.trunk,
            .leaves = blocks.leaves,
        };
    }

    pub fn maybeRecenterCache(self: *OverworldV2Generator, player_x: i32, player_z: i32) bool {
        _ = self;
        _ = player_x;
        _ = player_z;
        return false;
    }

    pub fn getSeed(self: *const OverworldV2Generator) u64 {
        return self.seed;
    }

    pub fn getRegionInfo(self: *const OverworldV2Generator, world_x: i32, world_z: i32) RegionInfo {
        const sample = self.sampleColumn(world_x, world_z);
        const focus: worldgen_api.FeatureFocus = if (sample.is_river)
            .lake
        else if (sample.terrain_height > self.params.sea_level + 60)
            .mountain
        else
            .none;
        const mood: worldgen_api.RegionMood = if (sample.is_ocean)
            .sparse
        else if (sample.humidity > 0.7)
            .lush
        else if (sample.terrain_height > self.params.sea_level + 70)
            .wild
        else
            .calm;
        return .{ .mood = mood, .role = .destination, .focus = focus, .center_x = world_x, .center_z = world_z };
    }

    pub fn getColumnInfo(self: *const OverworldV2Generator, wx: f32, wz: f32) ColumnInfo {
        const sample = self.sampleColumn(@intFromFloat(@floor(wx)), @intFromFloat(@floor(wz)));
        return .{
            .height = sample.terrain_height,
            .biome = sample.biome,
            .is_ocean = sample.is_ocean,
            .temperature = sample.temperature,
            .humidity = sample.humidity,
            .continentalness = sample.continentalness,
        };
    }

    pub fn generator(self: *OverworldV2Generator) Generator {
        return .{ .ptr = self, .vtable = &VTABLE, .info = INFO };
    }

    fn verticalShift(self: *const OverworldV2Generator) i32 {
        return self.params.sea_level - LUANTI_WATER_LEVEL;
    }

    fn toLuantiY(self: *const OverworldV2Generator, y: i32) f32 {
        return @floatFromInt(y - self.verticalShift());
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
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        self.generate(chunk, stop_flag);
    }

    fn generateHeightmapOnlyWrapper(ptr: *anyopaque, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel, stop_flag: ?*const std.atomic.Value(bool)) void {
        const self: *const OverworldV2Generator = @ptrCast(@alignCast(ptr));
        self.generateHeightmapOnly(data, region_x, region_z, lod_level, stop_flag);
    }

    fn maybeRecenterCacheWrapper(ptr: *anyopaque, player_x: i32, player_z: i32) bool {
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        return self.maybeRecenterCache(player_x, player_z);
    }

    fn getSeedWrapper(ptr: *anyopaque) u64 {
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        return self.getSeed();
    }

    fn getRegionInfoWrapper(ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo {
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn getColumnInfoWrapper(ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo {
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(wx, wz);
    }

    fn deinitWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *OverworldV2Generator = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

fn np(offset: f32, scale: f32, spread: Vec3f, seed: i32, octaves: u16, persist: f32, lacunarity: f32) LuantiNoiseParams {
    return .{ .offset = offset, .scale = scale, .spread = spread, .seed = seed, .octaves = octaves, .persist = persist, .lacunarity = lacunarity };
}

fn highestSolidY(chunk: *const Chunk, local_x: u32, local_z: u32, max_y: i32) i32 {
    var y: i32 = @min(max_y, CHUNK_SIZE_Y - 1);
    while (y >= 0) : (y -= 1) {
        const block = chunk.getBlock(local_x, @intCast(y), local_z);
        if (block != .air and block != .water) return y;
    }
    return 0;
}

fn surfaceBlock(biome: BiomeId, height: i32, sea_level: i32, underwater: bool) BlockType {
    if (underwater) {
        return switch (biome) {
            .deep_ocean, .cold_ocean, .frozen_ocean => .gravel,
            .river, .frozen_river, .ocean, .warm_ocean => .sand,
            else => .sand,
        };
    }

    return switch (biome) {
        .beach => .sand,
        .snowy_beach, .snow_tundra, .snowy_taiga, .snowy_slopes => .snow_block,
        .desert => .sand,
        .river => .sand,
        .frozen_river => .gravel,
        .jagged_peaks, .stony_peaks, .mountains => if (height > sea_level + 82) .stone else .grass,
        .frozen_peaks => .packed_ice,
        .taiga, .forest, .jungle, .savanna, .plains => .grass,
        else => biome.getSurfaceBlock(),
    };
}

fn fillerBlock(biome: BiomeId, underwater: bool) BlockType {
    if (underwater) return switch (biome) {
        .deep_ocean, .cold_ocean, .frozen_ocean, .frozen_river => .gravel,
        else => .sand,
    };

    return switch (biome) {
        .beach, .snowy_beach, .desert, .river => .sand,
        .frozen_river => .gravel,
        .jagged_peaks, .frozen_peaks, .stony_peaks, .mountains => .stone,
        else => biome.getFillerBlock(),
    };
}

const BiomeColors = struct {
    grass: [3]f32 = .{ 0.22, 0.72, 0.16 },
    foliage: [3]f32 = .{ 0.14, 0.58, 0.12 },
    water: [3]f32 = .{ 0.12, 0.38, 0.78 },
};

fn colorForBiome(biome: BiomeId, block: BlockType) u32 {
    const colors = biomeTintColors(biome);
    if (block == .water) return packRgb(colors.water);
    if (block == .grass) return packRgb(colors.grass);
    if (isLeafBlock(block)) return leafTintColor(block, colors.foliage);
    return packRgb(world_core.block_registry.getBlockDefinition(block).default_color);
}

fn biomeTintColors(biome: BiomeId) BiomeColors {
    return switch (biome) {
        .deep_ocean => .{ .water = .{ 0.1, 0.2, 0.5 } },
        .frozen_ocean => .{ .grass = .{ 0.78, 0.88, 0.92 }, .foliage = .{ 0.66, 0.78, 0.82 }, .water = .{ 0.32, 0.54, 0.74 } },
        .cold_ocean => .{ .water = .{ 0.10, 0.32, 0.62 } },
        .warm_ocean => .{ .water = .{ 0.08, 0.50, 0.82 } },
        .tropical => .{ .grass = .{ 0.18, 0.74, 0.18 }, .foliage = .{ 0.10, 0.62, 0.10 }, .water = .{ 0.05, 0.55, 0.85 } },
        .plains => .{},
        .forest => .{ .grass = .{ 0.18, 0.64, 0.16 }, .foliage = .{ 0.12, 0.52, 0.12 } },
        .birch_forest => .{ .grass = .{ 0.24, 0.68, 0.18 }, .foliage = .{ 0.18, 0.58, 0.14 } },
        .dark_forest => .{ .grass = .{ 0.12, 0.46, 0.12 }, .foliage = .{ 0.08, 0.36, 0.08 } },
        .flower_forest => .{ .grass = .{ 0.30, 0.72, 0.18 }, .foliage = .{ 0.20, 0.58, 0.12 } },
        .taiga => .{ .grass = .{ 0.24, 0.56, 0.24 }, .foliage = .{ 0.18, 0.46, 0.18 } },
        .snowy_taiga => .{ .grass = .{ 0.62, 0.74, 0.70 }, .foliage = .{ 0.16, 0.40, 0.24 } },
        .old_growth_taiga => .{ .grass = .{ 0.20, 0.48, 0.28 }, .foliage = .{ 0.12, 0.34, 0.20 } },
        .desert => .{ .grass = .{ 0.75, 0.70, 0.35 } },
        .snow_tundra => .{ .grass = .{ 0.7, 0.75, 0.8 } },
        .snowy_mountains => .{ .grass = .{ 0.85, 0.90, 0.95 } },
        .stony_shore => .{ .grass = .{ 0.48, 0.52, 0.50 }, .foliage = .{ 0.34, 0.42, 0.36 }, .water = .{ 0.10, 0.34, 0.62 } },
        .snowy_beach => .{ .grass = .{ 0.82, 0.90, 0.94 }, .foliage = .{ 0.68, 0.78, 0.82 }, .water = .{ 0.22, 0.46, 0.70 } },
        .meadow => .{ .grass = .{ 0.32, 0.74, 0.24 }, .foliage = .{ 0.20, 0.58, 0.18 } },
        .grove => .{ .grass = .{ 0.20, 0.48, 0.24 }, .foliage = .{ 0.16, 0.38, 0.18 } },
        .snowy_slopes => .{ .grass = .{ 0.82, 0.88, 0.94 }, .foliage = .{ 0.64, 0.72, 0.70 } },
        .jagged_peaks => .{ .grass = .{ 0.56, 0.56, 0.54 }, .foliage = .{ 0.44, 0.46, 0.42 } },
        .frozen_peaks => .{ .grass = .{ 0.76, 0.88, 0.96 }, .foliage = .{ 0.68, 0.78, 0.82 } },
        .stony_peaks => .{ .grass = .{ 0.62, 0.58, 0.48 }, .foliage = .{ 0.46, 0.44, 0.34 } },
        .swamp => .{ .grass = .{ 0.26, 0.58, 0.18 }, .foliage = .{ 0.22, 0.52, 0.16 }, .water = .{ 0.16, 0.38, 0.30 } },
        .frozen_river => .{ .grass = .{ 0.78, 0.88, 0.92 }, .foliage = .{ 0.66, 0.78, 0.82 }, .water = .{ 0.36, 0.58, 0.78 } },
        .jungle => .{ .grass = .{ 0.10, 0.76, 0.08 }, .foliage = .{ 0.08, 0.62, 0.08 } },
        .savanna => .{ .grass = .{ 0.55, 0.55, 0.30 }, .foliage = .{ 0.50, 0.50, 0.28 } },
        .badlands => .{ .grass = .{ 0.5, 0.4, 0.3 } },
        .mushroom_fields => .{ .grass = .{ 0.4, 0.8, 0.4 } },
        .foothills => .{ .grass = .{ 0.24, 0.62, 0.22 }, .foliage = .{ 0.18, 0.50, 0.16 } },
        .dry_plains => .{ .grass = .{ 0.55, 0.50, 0.28 } },
        .coastal_plains => .{ .grass = .{ 0.24, 0.66, 0.24 }, .foliage = .{ 0.18, 0.52, 0.16 } },
        else => .{},
    };
}

fn leafTintColor(block: BlockType, biome_foliage: [3]f32) u32 {
    if (block == .leaves) return packRgb(biome_foliage);
    const base = world_core.block_registry.getBlockDefinition(block).default_color;
    return packRgb(.{
        base[0] * 0.70 + biome_foliage[0] * 0.30,
        base[1] * 0.70 + biome_foliage[1] * 0.30,
        base[2] * 0.70 + biome_foliage[2] * 0.30,
    });
}

fn packRgb(color: [3]f32) u32 {
    const r: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0));
    return (r << 16) | (g << 8) | b;
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

fn treeBlocksForShape(shape: TreeShape) TreeBlocks {
    return switch (shape) {
        .birch => .{ .trunk = .birch_log, .leaves = .birch_leaves },
        .spruce => .{ .trunk = .spruce_log, .leaves = .spruce_leaves },
        .jungle => .{ .trunk = .jungle_log, .leaves = .jungle_leaves },
        .acacia => .{ .trunk = .acacia_log, .leaves = .acacia_leaves },
        .oak => .{ .trunk = .wood, .leaves = .leaves },
    };
}

fn treeHeightForShape(shape: TreeShape) f32 {
    return switch (shape) {
        .spruce => 7.0,
        .jungle => 8.0,
        .acacia => 5.0,
        .birch, .oak => 6.0,
    };
}

fn defaultTreeShapeForBiome(biome: BiomeId) TreeShape {
    return switch (biome) {
        .taiga, .snowy_taiga, .snow_tundra, .old_growth_taiga, .grove => .spruce,
        .jungle, .bamboo_jungle, .sparse_jungle => .jungle,
        .savanna, .savanna_plateau, .windswept_savanna => .acacia,
        .birch_forest => .birch,
        else => .oak,
    };
}

fn isCaveCarvable(block: BlockType) bool {
    return switch (block) {
        .stone, .dirt, .grass, .sand, .gravel, .snow_block, .clay, .mud, .terracotta, .red_sand, .packed_ice => true,
        else => false,
    };
}

fn isTreeBlock(block: BlockType) bool {
    return switch (block) {
        .wood, .leaves, .birch_log, .birch_leaves, .spruce_log, .spruce_leaves, .jungle_log, .jungle_leaves, .acacia_log, .acacia_leaves => true,
        else => false,
    };
}

fn isVegetationBlock(block: BlockType) bool {
    return switch (block) {
        .tall_grass, .flower_red, .flower_yellow, .dead_bush, .cactus, .bamboo, .snow_layer, .seagrass, .tall_seagrass, .kelp, .seaweed, .coral_block, .coral_fan => true,
        else => false,
    };
}

fn treeDensityForBiome(biome: BiomeId) f32 {
    return switch (biome) {
        .forest => 0.72,
        .birch_forest => 0.68,
        .dark_forest => 0.92,
        .flower_forest => 0.42,
        .taiga, .snowy_taiga => 0.58,
        .old_growth_taiga => 0.82,
        .grove => 0.46,
        .jungle, .bamboo_jungle => 0.86,
        .sparse_jungle => 0.48,
        .swamp, .mangrove_swamp => 0.42,
        .savanna, .savanna_plateau, .windswept_savanna => 0.30,
        .plains, .coastal_plains, .foothills => 0.14,
        .mountains => 0.08,
        else => 0.0,
    };
}

fn groundDecorationForBiome(biome: BiomeId, surface: BlockType, variant: f32, scatter: f32) ?GroundDecoration {
    return switch (biome) {
        .plains => if (surface == .grass and scatter < 0.58) flowerOrGrass(variant, 0.10) else null,
        .forest => if (surface == .grass and scatter < 0.44) flowerOrGrass(variant, 0.06) else null,
        .taiga => if (surface == .grass and scatter < 0.24) .tall_grass else null,
        .snowy_taiga, .snow_tundra, .snowy_slopes => if (surface == .snow_block and scatter < 0.18) .snow_layer else null,
        .jungle => if (surface == .grass and scatter < 0.72) if (variant < 0.22) .bamboo else .tall_grass else null,
        .savanna => if (surface == .grass and scatter < 0.34) .tall_grass else null,
        .desert => if (surface == .sand) desertDecoration(variant, scatter) else null,
        .beach => if (surface == .sand and scatter < 0.02) .dead_bush else null,
        .mountains => if (surface == .grass and scatter < 0.10) .tall_grass else null,
        else => null,
    };
}

fn groundDecorationBlock(decoration: GroundDecoration) BlockType {
    return switch (decoration) {
        .tall_grass => .tall_grass,
        .flower_red => .flower_red,
        .flower_yellow => .flower_yellow,
        .dead_bush => .dead_bush,
        .cactus => .cactus,
        .bamboo => .bamboo,
        .snow_layer => .snow_layer,
    };
}

fn flowerOrGrass(variant: f32, flower_chance: f32) GroundDecoration {
    if (variant < flower_chance * 0.5) return .flower_red;
    if (variant < flower_chance) return .flower_yellow;
    return .tall_grass;
}

fn desertDecoration(variant: f32, scatter: f32) ?GroundDecoration {
    if (scatter < 0.025) return .cactus;
    if (variant < 0.10 and scatter < 0.12) return .dead_bush;
    return null;
}

fn isOceanBiome(biome: BiomeId) bool {
    return switch (biome) {
        .ocean, .deep_ocean, .warm_ocean, .cold_ocean, .frozen_ocean, .tropical => true,
        else => false,
    };
}

fn columnWaterDepth(chunk: *const Chunk, x: u32, z: u32, surface_y: i32) u8 {
    var depth: u8 = 0;
    var y = surface_y + 1;
    while (y < CHUNK_SIZE_Y and depth < 30) : (y += 1) {
        if (chunk.getBlock(x, @intCast(y), z) != .water) break;
        depth += 1;
    }
    return depth;
}

fn placeCactus(chunk: *Chunk, x: u32, y: u32, z: u32, height: u32) void {
    placeColumnDecoration(chunk, x, y, z, .cactus, height);
}

fn placeKelp(chunk: *Chunk, x: u32, y: u32, z: u32, height: u8) void {
    var dy: u32 = 0;
    while (dy < height and y + dy < CHUNK_SIZE_Y) : (dy += 1) {
        if (chunk.getBlock(x, y + dy, z) != .water) break;
        chunk.blocks[Chunk.getIndex(x, y + dy, z)] = .kelp;
    }
}

fn placeColumnDecoration(chunk: *Chunk, x: u32, y: u32, z: u32, block: BlockType, height: u32) void {
    var dy: u32 = 0;
    while (dy < height and y + dy < CHUNK_SIZE_Y) : (dy += 1) {
        if (chunk.getBlock(x, y + dy, z) != .air) break;
        chunk.blocks[Chunk.getIndex(x, y + dy, z)] = block;
    }
}

fn setDecorationBlock(chunk: *Chunk, x: u32, y: u32, z: u32, block: BlockType) void {
    if (y >= CHUNK_SIZE_Y) return;
    const existing = chunk.getBlock(x, y, z);
    const can_replace = existing == .air or (existing == .water and isAquaticDecoration(block));
    if (!can_replace) return;
    chunk.blocks[Chunk.getIndex(x, y, z)] = block;
}

fn isAquaticDecoration(block: BlockType) bool {
    return switch (block) {
        .seagrass, .tall_seagrass, .kelp, .seaweed, .coral_fan => true,
        else => false,
    };
}

fn placeTreeShape(chunk: *Chunk, x: u32, y: u32, z: u32, shape: TreeShape) void {
    const trunk: BlockType = switch (shape) {
        .birch => .birch_log,
        .spruce => .spruce_log,
        .jungle => .jungle_log,
        .acacia => .acacia_log,
        .oak => .wood,
    };
    const leaves: BlockType = switch (shape) {
        .birch => .birch_leaves,
        .spruce => .spruce_leaves,
        .jungle => .jungle_leaves,
        .acacia => .acacia_leaves,
        .oak => .leaves,
    };
    const height: u32 = switch (shape) {
        .spruce => 7,
        .jungle => 8,
        .acacia => 5,
        else => 6,
    };

    if (y + height + 1 >= CHUNK_SIZE_Y) return;

    var dy: u32 = 0;
    while (dy < height) : (dy += 1) {
        setTreeBlock(chunk, x, y + dy, z, trunk, false);
    }

    switch (shape) {
        .spruce => placeConeLeaves(chunk, x, y + 2, z, height, leaves),
        .acacia => placeFlatCanopy(chunk, x, y + height - 1, z, leaves),
        else => placeRoundCanopy(chunk, x, y + height - 2, z, leaves),
    }
}

fn placeRoundCanopy(chunk: *Chunk, cx: u32, cy: u32, cz: u32, leaves: BlockType) void {
    var oy: i32 = -1;
    while (oy <= 2) : (oy += 1) {
        const radius: i32 = if (oy == 2) 1 else 2;
        var oz: i32 = -radius;
        while (oz <= radius) : (oz += 1) {
            var ox: i32 = -radius;
            while (ox <= radius) : (ox += 1) {
                if (@abs(ox) == radius and @abs(oz) == radius and oy >= 1) continue;
                setTreeBlockOffset(chunk, cx, cy, cz, ox, oy, oz, leaves, true);
            }
        }
    }
}

fn placeConeLeaves(chunk: *Chunk, cx: u32, base_y: u32, cz: u32, height: u32, leaves: BlockType) void {
    var layer: u32 = 0;
    while (layer < height) : (layer += 1) {
        const cy = base_y + layer;
        const remaining = height - layer;
        const radius: i32 = if (remaining > 4) 2 else if (remaining > 1) 1 else 0;
        var oz: i32 = -radius;
        while (oz <= radius) : (oz += 1) {
            var ox: i32 = -radius;
            while (ox <= radius) : (ox += 1) {
                if (@abs(ox) + @abs(oz) > radius + 1) continue;
                setTreeBlockOffset(chunk, cx, cy, cz, ox, 0, oz, leaves, true);
            }
        }
    }
}

fn placeFlatCanopy(chunk: *Chunk, cx: u32, cy: u32, cz: u32, leaves: BlockType) void {
    var oz: i32 = -2;
    while (oz <= 2) : (oz += 1) {
        var ox: i32 = -2;
        while (ox <= 2) : (ox += 1) {
            if (@abs(ox) == 2 and @abs(oz) == 2) continue;
            setTreeBlockOffset(chunk, cx, cy, cz, ox, 0, oz, leaves, true);
        }
    }
    setTreeBlock(chunk, cx, cy + 1, cz, leaves, true);
}

fn setTreeBlockOffset(chunk: *Chunk, cx: u32, base_y: u32, cz: u32, ox: i32, oy: i32, oz: i32, block: BlockType, leaves_only: bool) void {
    const x = @as(i32, @intCast(cx)) + ox;
    const y = @as(i32, @intCast(base_y)) + oy;
    const z = @as(i32, @intCast(cz)) + oz;
    if (x < 0 or x >= CHUNK_SIZE_X or y < 0 or y >= CHUNK_SIZE_Y or z < 0 or z >= CHUNK_SIZE_Z) return;
    setTreeBlock(chunk, @intCast(x), @intCast(y), @intCast(z), block, leaves_only);
}

fn setTreeBlock(chunk: *Chunk, x: u32, y: u32, z: u32, block: BlockType, leaves_only: bool) void {
    const idx = Chunk.getIndex(x, y, z);
    const existing = chunk.blocks[idx];
    if (leaves_only and existing != .air and !isLeafBlock(existing)) return;
    if (!leaves_only and existing != .air and !isLeafBlock(existing) and !isReplaceableTreeBase(existing)) return;
    chunk.blocks[idx] = block;
}

fn isLeafBlock(block: BlockType) bool {
    return switch (block) {
        .leaves, .birch_leaves, .spruce_leaves, .jungle_leaves, .acacia_leaves => true,
        else => false,
    };
}

fn isReplaceableTreeBase(block: BlockType) bool {
    return switch (block) {
        .tall_grass, .flower_red, .flower_yellow, .dead_bush, .snow_layer, .seagrass, .tall_seagrass, .kelp, .seaweed => true,
        else => false,
    };
}

fn hashUnit(x: i32, z: i32, seed: i32) f32 {
    const h: u32 = @bitCast(hash2i(x, z, seed));
    return @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

fn hash2i(x: i32, z: i32, seed: i32) i32 {
    var n = @as(u32, @bitCast(x)) *% 374761393 +% @as(u32, @bitCast(z)) *% 668265263 +% @as(u32, @bitCast(seed)) *% 2246822519;
    n = (n ^ (n >> 13)) *% 1274126177;
    n ^= n >> 16;
    return @bitCast(n);
}

fn contour(v_in: f32) f32 {
    const v = @abs(v_in);
    if (v >= 1.0) return 0.0;
    return 1.0 - v;
}

fn floorToI32(v: f32) i32 {
    return @intFromFloat(@floor(v));
}

fn noiseFractal2D(params: *const LuantiNoiseParams, x_in: f32, y_in: f32, seed: i32) f32 {
    return noiseFractal2DWithPersist(params, x_in, y_in, seed, params.persist);
}

fn noiseFractal2DWithPersist(params: *const LuantiNoiseParams, x_in: f32, y_in: f32, seed: i32, persist: f32) f32 {
    const x = x_in / params.spread.x;
    const y = y_in / params.spread.y;
    var frequency: f32 = 1.0;
    var amplitude: f32 = 1.0;
    var value: f32 = 0.0;
    const eased = params.flags & (NOISE_FLAG_DEFAULTS | NOISE_FLAG_EASED) != 0;
    const noise_seed = seed +% params.seed;

    var octave: u16 = 0;
    while (octave < params.octaves) : (octave += 1) {
        var noise_val = noise2dValue(x * frequency, y * frequency, noise_seed +% @as(i32, @intCast(octave)), eased);
        if (params.flags & NOISE_FLAG_ABSVALUE != 0) noise_val = @abs(noise_val);
        value += amplitude * noise_val;
        frequency *= params.lacunarity;
        amplitude *= persist;
    }

    return params.offset + value * params.scale;
}

fn noiseFractal3D(params: *const LuantiNoiseParams, x_in: f32, y_in: f32, z_in: f32, seed: i32) f32 {
    const x = x_in / params.spread.x;
    const y = y_in / params.spread.y;
    const z = z_in / params.spread.z;
    var frequency: f32 = 1.0;
    var amplitude: f32 = 1.0;
    var value: f32 = 0.0;
    const eased = params.flags & NOISE_FLAG_EASED != 0;
    const noise_seed = seed +% params.seed;

    var octave: u16 = 0;
    while (octave < params.octaves) : (octave += 1) {
        var noise_val = noise3dValue(x * frequency, y * frequency, z * frequency, noise_seed +% @as(i32, @intCast(octave)), eased);
        if (params.flags & NOISE_FLAG_ABSVALUE != 0) noise_val = @abs(noise_val);
        value += amplitude * noise_val;
        frequency *= params.lacunarity;
        amplitude *= params.persist;
    }

    return params.offset + value * params.scale;
}

fn noise2dValue(x: f32, y: f32, seed: i32, eased: bool) f32 {
    const x0 = myFloor(x);
    const y0 = myFloor(y);
    var xl = x - @as(f32, @floatFromInt(x0));
    var yl = y - @as(f32, @floatFromInt(y0));
    const v00 = noise2d(x0, y0, seed);
    const v10 = noise2d(x0 + 1, y0, seed);
    const v01 = noise2d(x0, y0 + 1, seed);
    const v11 = noise2d(x0 + 1, y0 + 1, seed);
    if (eased) {
        xl = easeCurve(xl);
        yl = easeCurve(yl);
    }
    const u = lerp(v00, v10, xl);
    const v = lerp(v01, v11, xl);
    return lerp(u, v, yl);
}

fn noise3dValue(x: f32, y: f32, z: f32, seed: i32, eased: bool) f32 {
    const x0 = myFloor(x);
    const y0 = myFloor(y);
    const z0 = myFloor(z);
    var xl = x - @as(f32, @floatFromInt(x0));
    var yl = y - @as(f32, @floatFromInt(y0));
    var zl = z - @as(f32, @floatFromInt(z0));
    if (eased) {
        xl = easeCurve(xl);
        yl = easeCurve(yl);
        zl = easeCurve(zl);
    }

    const v000 = noise3d(x0, y0, z0, seed);
    const v100 = noise3d(x0 + 1, y0, z0, seed);
    const v010 = noise3d(x0, y0 + 1, z0, seed);
    const v110 = noise3d(x0 + 1, y0 + 1, z0, seed);
    const v001 = noise3d(x0, y0, z0 + 1, seed);
    const v101 = noise3d(x0 + 1, y0, z0 + 1, seed);
    const v011 = noise3d(x0, y0 + 1, z0 + 1, seed);
    const v111 = noise3d(x0 + 1, y0 + 1, z0 + 1, seed);

    const x00 = lerp(v000, v100, xl);
    const x10 = lerp(v010, v110, xl);
    const x01 = lerp(v001, v101, xl);
    const x11 = lerp(v011, v111, xl);
    const v0 = lerp(x00, x10, yl);
    const v1 = lerp(x01, x11, yl);
    return lerp(v0, v1, zl);
}

fn noise2d(x: i32, y: i32, seed: i32) f32 {
    var n = @as(u32, @bitCast(x)) *% 1619 +% @as(u32, @bitCast(y)) *% 31337 +% @as(u32, @bitCast(seed)) *% 1013;
    n &= 0x7fffffff;
    n = (n >> 13) ^ n;
    n = (n *% (n *% n *% 60493 +% 19990303) +% 1376312589) & 0x7fffffff;
    return 1.0 - @as(f32, @floatFromInt(n)) / 0x40000000;
}

fn noise3d(x: i32, y: i32, z: i32, seed: i32) f32 {
    var n = @as(u32, @bitCast(x)) *% 1619 +% @as(u32, @bitCast(y)) *% 31337 +% @as(u32, @bitCast(z)) *% 52591 +% @as(u32, @bitCast(seed)) *% 1013;
    n &= 0x7fffffff;
    n = (n >> 13) ^ n;
    n = (n *% (n *% n *% 60493 +% 19990303) +% 1376312589) & 0x7fffffff;
    return 1.0 - @as(f32, @floatFromInt(n)) / 0x40000000;
}

fn myFloor(v: f32) i32 {
    const truncated: i32 = @intFromFloat(v);
    return if (v < 0.0) truncated - 1 else truncated;
}

fn easeCurve(t: f32) f32 {
    return t * t * t * (t * (6.0 * t - 15.0) + 10.0);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

pub fn create(context: worldgen_api.CreateContext) worldgen_api.RegistryError!Generator {
    const gen = context.allocator.create(OverworldV2Generator) catch return error.OutOfMemory;
    gen.* = OverworldV2Generator.init(context.seed, context.allocator);
    return gen.generator();
}

pub const descriptor = worldgen_api.GeneratorDescriptor{
    .id = "zigcraft:overworld-v2",
    .aliases = &.{ "overworld-v2", "v2", "v7" },
    .info = OverworldV2Generator.INFO,
    .create = create,
};

test "overworld-v2 deterministic terrain columns" {
    var gen = OverworldV2Generator.init(42, std.testing.allocator);
    const a = gen.getColumnInfo(128.0, -96.0);
    const b = gen.getColumnInfo(128.0, -96.0);
    try std.testing.expectEqual(a.height, b.height);
    try std.testing.expectEqual(a.biome, b.biome);
}

test "overworld-v2 generates a chunk" {
    var gen = OverworldV2Generator.init(12345, std.testing.allocator);
    var chunk = Chunk.init(0, 0);
    gen.generate(&chunk, null);
    try std.testing.expect(chunk.generated);
    try std.testing.expect(chunk.getBlock(0, 0, 0) == .bedrock);
    try std.testing.expect(chunk.getSurfaceHeight(8, 8) > 0);
}

test "overworld-v2 places trees in forested chunks" {
    var gen = OverworldV2Generator.init(12345, std.testing.allocator);

    var tree_blocks: u32 = 0;
    const positions = [_][2]i32{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, 1 },
        .{ 4, -3 },
        .{ -6, 5 },
        .{ 9, 2 },
    };

    for (positions) |pos| {
        var chunk = Chunk.init(pos[0], pos[1]);
        gen.generate(&chunk, null);
        for (chunk.blocks) |block| {
            if (isTreeBlock(block)) tree_blocks += 1;
        }
    }

    try std.testing.expect(tree_blocks > 0);
}

test "overworld-v2 places ground vegetation" {
    var gen = OverworldV2Generator.init(12345, std.testing.allocator);

    var vegetation_blocks: u32 = 0;
    const positions = [_][2]i32{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 0, 1 },
        .{ 4, -3 },
        .{ -6, 5 },
        .{ 9, 2 },
    };

    for (positions) |pos| {
        var chunk = Chunk.init(pos[0], pos[1]);
        gen.generate(&chunk, null);
        for (chunk.blocks) |block| {
            if (isVegetationBlock(block)) vegetation_blocks += 1;
        }
    }

    try std.testing.expect(vegetation_blocks > 0);
}

test "overworld-v2 generates representative LOD data" {
    var gen = OverworldV2Generator.init(12345, std.testing.allocator);
    var data = try LODSimplifiedData.init(std.testing.allocator, .lod3);
    defer data.deinit();

    gen.generateHeightmapOnly(&data, 0, 0, .lod3, null);

    var filled_columns: u32 = 0;
    var material_columns: u32 = 0;
    for (data.heightmap, 0..) |height, i| {
        if (height > 0.0) filled_columns += 1;
        if (data.top_blocks[i] != .air and data.colors[i] != 0) material_columns += 1;
        try std.testing.expect(height <= @as(f32, @floatFromInt(CHUNK_SIZE_Y - 1)));
    }

    try std.testing.expect(filled_columns > 0);
    try std.testing.expect(material_columns > 0);
}

test "overworld-v2 LOD tree density covers forest variants" {
    try std.testing.expect(treeDensityForBiome(.forest) > 0.5);
    try std.testing.expect(treeDensityForBiome(.birch_forest) > 0.5);
    try std.testing.expect(treeDensityForBiome(.dark_forest) > treeDensityForBiome(.forest));
    try std.testing.expect(treeDensityForBiome(.old_growth_taiga) > treeDensityForBiome(.taiga));
    try std.testing.expect(treeDensityForBiome(.bamboo_jungle) > 0.5);
    try std.testing.expect(treeDensityForBiome(.plains) >= 0.1);
    try std.testing.expectEqual(TreeShape.birch, defaultTreeShapeForBiome(.birch_forest));
    try std.testing.expectEqual(TreeShape.spruce, defaultTreeShapeForBiome(.old_growth_taiga));
    try std.testing.expectEqual(TreeShape.jungle, defaultTreeShapeForBiome(.bamboo_jungle));
}
