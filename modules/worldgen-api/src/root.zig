const std = @import("std");
const world_core = @import("world-core");

const Chunk = world_core.Chunk;
const LODLevel = world_core.LODLevel;
const LODSimplifiedData = world_core.LODSimplifiedData;
const BiomeId = world_core.BiomeId;

pub const RegionMood = enum {
    calm,
    sparse,
    lush,
    wild,
};

pub const RegionRole = enum {
    transit,
    destination,
    boundary,
};

pub const FeatureFocus = enum {
    none,
    lake,
    forest,
    mountain,
};

pub const RegionInfo = struct {
    mood: RegionMood,
    role: RegionRole,
    focus: FeatureFocus,
    center_x: i32,
    center_z: i32,
};

pub const ColumnInfo = struct {
    height: i32,
    biome: BiomeId,
    is_ocean: bool,
    temperature: f32,
    humidity: f32,
    continentalness: f32,
};

pub const GenerationOptions = struct {
    lod_level: LODLevel = .lod0,
    enable_caves: bool = true,
    enable_worm_caves: bool = true,
    enable_decorations: bool = true,
    enable_ores: bool = true,
    enable_lighting: bool = true,
    octave_reduction: u8 = 0,
    skip_biome_blending: bool = false,

    pub fn fromLOD(lod: LODLevel) GenerationOptions {
        const level = @intFromEnum(lod);
        return .{
            .lod_level = lod,
            .enable_caves = level <= 1,
            .enable_worm_caves = level == 0,
            .enable_decorations = level <= 1,
            .enable_ores = level == 0,
            .enable_lighting = level == 0,
            .octave_reduction = @intCast(level),
            .skip_biome_blending = level > 0,
        };
    }
};

pub const GeneratorInfo = struct {
    name: []const u8,
    description: []const u8,
};

pub const Generator = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    info: GeneratorInfo,

    pub const VTable = struct {
        generate: *const fn (ptr: *anyopaque, chunk: *Chunk, stop_flag: ?*const bool) void,
        generateHeightmapOnly: *const fn (ptr: *anyopaque, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void,
        maybeRecenterCache: *const fn (ptr: *anyopaque, player_x: i32, player_z: i32) bool,
        getSeed: *const fn (ptr: *anyopaque) u64,
        getRegionInfo: *const fn (ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo,
        getColumnInfo: *const fn (ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn generate(self: Generator, chunk: *Chunk, stop_flag: ?*const bool) void {
        self.vtable.generate(self.ptr, chunk, stop_flag);
    }

    pub fn generateHeightmapOnly(self: Generator, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void {
        self.vtable.generateHeightmapOnly(self.ptr, data, region_x, region_z, lod_level);
    }

    pub fn maybeRecenterCache(self: Generator, player_x: i32, player_z: i32) bool {
        return self.vtable.maybeRecenterCache(self.ptr, player_x, player_z);
    }

    pub fn getSeed(self: Generator) u64 {
        return self.vtable.getSeed(self.ptr);
    }

    pub fn getRegionInfo(self: Generator, world_x: i32, world_z: i32) RegionInfo {
        return self.vtable.getRegionInfo(self.ptr, world_x, world_z);
    }

    pub fn getColumnInfo(self: Generator, wx: f32, wz: f32) ColumnInfo {
        return self.vtable.getColumnInfo(self.ptr, wx, wz);
    }

    pub fn deinit(self: Generator, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub const CreateContext = struct {
    seed: u64,
    allocator: std.mem.Allocator,
};

pub const RegistryError = error{
    InvalidGeneratorIndex,
    InvalidGeneratorId,
    OutOfMemory,
};

pub const GeneratorDescriptor = struct {
    id: []const u8,
    aliases: []const []const u8 = &.{},
    info: GeneratorInfo,
    create: *const fn (context: CreateContext) RegistryError!Generator,
};

pub const IChunkGenerator = struct {
    generator: Generator,

    pub fn generate(self: IChunkGenerator, chunk: *Chunk, stop_flag: ?*const bool) void {
        self.generator.generate(chunk, stop_flag);
    }
};

pub const ILODHeightmapGenerator = struct {
    generator: Generator,

    pub fn generateHeightmapOnly(self: ILODHeightmapGenerator, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void {
        self.generator.generateHeightmapOnly(data, region_x, region_z, lod_level);
    }
};

pub const IGeneratorInfoProvider = struct {
    generator: Generator,

    pub fn getSeed(self: IGeneratorInfoProvider) u64 {
        return self.generator.getSeed();
    }

    pub fn getRegionInfo(self: IGeneratorInfoProvider, world_x: i32, world_z: i32) RegionInfo {
        return self.generator.getRegionInfo(world_x, world_z);
    }

    pub fn getColumnInfo(self: IGeneratorInfoProvider, wx: f32, wz: f32) ColumnInfo {
        return self.generator.getColumnInfo(wx, wz);
    }
};

pub const ICacheRecenterable = struct {
    generator: Generator,

    pub fn maybeRecenterCache(self: ICacheRecenterable, player_x: i32, player_z: i32) bool {
        return self.generator.maybeRecenterCache(player_x, player_z);
    }
};
