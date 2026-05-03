const std = @import("std");
const worldgen_api = @import("worldgen-api");
const Generator = worldgen_api.Generator;
const GeneratorInfo = worldgen_api.GeneratorInfo;
const ColumnInfo = worldgen_api.ColumnInfo;
const RegionInfo = worldgen_api.RegionInfo;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const LODLevel = world_core.LODLevel;
const LODSimplifiedData = world_core.LODSimplifiedData;
const LightingComputer = @import("worldgen-common").LightingComputer;

pub const FlatWorldGenerator = struct {
    seed: u64,
    allocator: std.mem.Allocator,

    const FLAT_HEIGHT: i32 = 64;
    const GRASS_COLOR: u32 = 0xFF40A040;

    pub const INFO = GeneratorInfo{
        .name = "Flat World",
        .description = "A perfectly flat world, ideal for testing and building.",
        .version = 1,
    };

    pub fn init(seed: u64, allocator: std.mem.Allocator) FlatWorldGenerator {
        return .{ .seed = seed, .allocator = allocator };
    }

    pub fn generate(self: *FlatWorldGenerator, chunk: *Chunk, stop_flag: ?*const bool) void {
        chunk.generated = false;

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                chunk.setSurfaceHeight(local_x, local_z, @intCast(FLAT_HEIGHT));
                chunk.setBiome(local_x, local_z, .plains);

                var y: i32 = 0;
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    const block: BlockType = if (y == 0)
                        .bedrock
                    else if (y < FLAT_HEIGHT - 3)
                        .stone
                    else if (y < FLAT_HEIGHT)
                        .dirt
                    else if (y == FLAT_HEIGHT)
                        .grass
                    else
                        .air;
                    chunk.setBlock(local_x, @intCast(y), local_z, block);
                }
            }
        }

        LightingComputer.computeSkylight(chunk, self.allocator) catch unreachable;

        chunk.generated = true;
        chunk.dirty = true;
    }

    pub fn generateHeightmapOnly(self: *const FlatWorldGenerator, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void {
        _ = self;
        _ = region_x;
        _ = region_z;
        _ = lod_level;

        @memset(data.heightmap, @floatFromInt(FLAT_HEIGHT));
        @memset(data.biomes, .plains);
        @memset(data.top_blocks, .grass);
        @memset(data.colors, GRASS_COLOR);
        @memset(data.material_layers, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone });
        @memset(data.water, world_core.LODWaterState.empty);
        @memset(data.lighting, world_core.LODLightingHint.daylight);
        @memset(data.vegetation, world_core.LODVegetationHint.empty);
    }

    pub fn maybeRecenterCache(self: *FlatWorldGenerator, player_x: i32, player_z: i32) bool {
        _ = self;
        _ = player_x;
        _ = player_z;
        return false;
    }

    pub fn getSeed(self: *const FlatWorldGenerator) u64 {
        return self.seed;
    }

    pub fn getRegionInfo(self: *const FlatWorldGenerator, world_x: i32, world_z: i32) RegionInfo {
        _ = self;
        return .{ .mood = .calm, .role = .transit, .focus = .none, .center_x = world_x, .center_z = world_z };
    }

    pub fn getColumnInfo(self: *const FlatWorldGenerator, wx: f32, wz: f32) ColumnInfo {
        _ = self;
        _ = wx;
        _ = wz;
        return .{ .height = FLAT_HEIGHT, .biome = .plains, .is_ocean = false, .temperature = 0.5, .humidity = 0.5, .continentalness = 0.5 };
    }

    pub fn generator(self: *FlatWorldGenerator) Generator {
        return .{ .ptr = self, .vtable = &VTABLE, .info = INFO };
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
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        self.generate(chunk, stop_flag);
    }

    fn generateHeightmapOnlyWrapper(ptr: *anyopaque, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void {
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        self.generateHeightmapOnly(data, region_x, region_z, lod_level);
    }

    fn maybeRecenterCacheWrapper(ptr: *anyopaque, player_x: i32, player_z: i32) bool {
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.maybeRecenterCache(player_x, player_z);
    }

    fn getSeedWrapper(ptr: *anyopaque) u64 {
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getSeed();
    }

    fn getRegionInfoWrapper(ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo {
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn getColumnInfoWrapper(ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo {
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(wx, wz);
    }

    fn deinitWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *FlatWorldGenerator = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

pub fn create(context: worldgen_api.CreateContext) worldgen_api.RegistryError!Generator {
    const gen = context.allocator.create(FlatWorldGenerator) catch return error.OutOfMemory;
    gen.* = FlatWorldGenerator.init(context.seed, context.allocator);
    return gen.generator();
}

pub const descriptor = worldgen_api.GeneratorDescriptor{
    .id = "zigcraft:flat",
    .aliases = &.{"flat"},
    .info = FlatWorldGenerator.INFO,
    .create = create,
};
