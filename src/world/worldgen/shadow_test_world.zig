const std = @import("std");
const gen_interface = @import("generator_interface.zig");
const Generator = gen_interface.Generator;
const GeneratorInfo = gen_interface.GeneratorInfo;
const ColumnInfo = gen_interface.ColumnInfo;
const Chunk = @import("../chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("../chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../chunk.zig").CHUNK_SIZE_Z;
const BlockType = @import("../block.zig").BlockType;
const BiomeId = @import("biome.zig").BiomeId;
const LightingComputer = @import("lighting_computer.zig").LightingComputer;
const build_options = @import("build_options");
const lod_chunk = @import("../lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const region_pkg = @import("region.zig");
const RegionInfo = region_pkg.RegionInfo;

pub const ShadowTestWorldGenerator = struct {
    seed: u64,
    allocator: std.mem.Allocator,

    const GROUND_Y: i32 = 63;
    const CAVE_MIN_X: i32 = -8;
    const CAVE_MAX_X: i32 = 8;
    const CAVE_MIN_Z: i32 = -22;
    const CAVE_MAX_Z: i32 = 14;
    const CAVE_MIN_Y: i32 = GROUND_Y + 1;
    const CAVE_MAX_Y: i32 = GROUND_Y + 11;
    const GRASS_COLOR: u32 = 0xFF40A040;

    pub const INFO = GeneratorInfo{
        .name = "Shadow Test Scene",
        .description = "Deterministic low-block scene for shadow and cave entrance lighting captures.",
    };

    pub fn init(seed: u64, allocator: std.mem.Allocator) ShadowTestWorldGenerator {
        return .{ .seed = seed, .allocator = allocator };
    }

    pub fn generate(self: *ShadowTestWorldGenerator, chunk: *Chunk, stop_flag: ?*const bool) void {
        chunk.generated = false;

        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            if (stop_flag) |sf| if (sf.*) return;
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                const wx = chunk.chunk_x * CHUNK_SIZE_X + @as(i32, @intCast(local_x));
                const wz = chunk.chunk_z * CHUNK_SIZE_Z + @as(i32, @intCast(local_z));
                var y: i32 = 0;
                while (y < CHUNK_SIZE_Y) : (y += 1) {
                    chunk.setBlock(local_x, @intCast(y), local_z, blockAt(wx, y, wz));
                }
            }
        }

        updateColumnMetadata(chunk);
        LightingComputer.computeSkylight(chunk, self.allocator) catch unreachable;
        LightingComputer.computeBlockLight(chunk, self.allocator) catch unreachable;

        chunk.generated = true;
        chunk.dirty = true;
    }

    fn blockAt(wx: i32, y: i32, wz: i32) BlockType {
        if (isDugCaveVariant()) return dugCaveBlockAt(wx, y, wz);

        if (y == 0) return .bedrock;
        if (y < GROUND_Y) return .stone;
        if (y == GROUND_Y) return if (insideCaveFootprint(wx, wz)) .stone else .grass;
        if (isCaveShell(wx, y, wz)) return .stone;
        if (isBendOccluder(wx, y, wz)) return .stone;
        if (isStonePillar(wx, y, wz)) return .stone;
        if (isTreeTrunk(wx, y, wz)) return .wood;
        if (isTreeCanopy(wx, y, wz)) return .leaves;
        return .air;
    }

    fn dugCaveBlockAt(wx: i32, y: i32, wz: i32) BlockType {
        if (y == 0) return .bedrock;
        if (y < GROUND_Y) return .stone;
        if (y == GROUND_Y) return if (insideDugCaveFootprint(wx, wz)) .stone else .grass;
        if (isDugTunnelAir(wx, y, wz)) return .air;
        if (isDugCaveMass(wx, y, wz)) return if (y == GROUND_Y + 11) .grass else .dirt;
        if (isTreeTrunk(wx, y, wz)) return .wood;
        if (isTreeCanopy(wx, y, wz)) return .leaves;
        return .air;
    }

    fn isDugCaveVariant() bool {
        return std.ascii.eqlIgnoreCase(build_options.shadow_test_variant, "dug-cave") or std.ascii.eqlIgnoreCase(build_options.shadow_test_variant, "dug");
    }

    fn insideDugCaveFootprint(wx: i32, wz: i32) bool {
        return wx >= -7 and wx <= 7 and wz >= -22 and wz <= 14;
    }

    fn isDugCaveMass(wx: i32, y: i32, wz: i32) bool {
        return insideDugCaveFootprint(wx, wz) and y >= GROUND_Y + 1 and y <= GROUND_Y + 11;
    }

    fn isDugTunnelAir(wx: i32, y: i32, wz: i32) bool {
        if (y < GROUND_Y + 1 or y > GROUND_Y + 6) return false;
        if (wz < -22 or wz > 14) return false;
        return wx >= -4 and wx <= 4;
    }

    fn insideCaveFootprint(wx: i32, wz: i32) bool {
        return wx >= CAVE_MIN_X and wx <= CAVE_MAX_X and wz >= CAVE_MIN_Z and wz <= CAVE_MAX_Z;
    }

    fn isCaveShell(wx: i32, y: i32, wz: i32) bool {
        if (!insideCaveFootprint(wx, wz) or y < CAVE_MIN_Y or y > CAVE_MAX_Y) return false;
        return y == CAVE_MAX_Y or wx == CAVE_MIN_X or wx == CAVE_MAX_X or wz == CAVE_MIN_Z;
    }

    fn isBendOccluder(wx: i32, y: i32, wz: i32) bool {
        if (y < CAVE_MIN_Y or y >= CAVE_MAX_Y) return false;
        return rect(wx, wz, CAVE_MIN_X + 1, 3, -5, -3);
    }

    fn isStonePillar(wx: i32, y: i32, wz: i32) bool {
        if (y < GROUND_Y + 1 or y > GROUND_Y + 13) return false;
        if (rect(wx, wz, -4, -3, -6, -5)) return y <= GROUND_Y + 9;
        if (rect(wx, wz, 3, 4, 2, 3)) return y <= GROUND_Y + 9;
        if (rect(wx, wz, -6, -5, 18, 19)) return true;
        if (rect(wx, wz, 5, 6, 18, 19)) return true;
        return y == GROUND_Y + 13 and wx >= -6 and wx <= 6 and wz >= 18 and wz <= 19;
    }

    fn isTreeTrunk(wx: i32, y: i32, wz: i32) bool {
        return wx == 12 and wz == 20 and y >= GROUND_Y + 1 and y <= GROUND_Y + 7;
    }

    fn isTreeCanopy(wx: i32, y: i32, wz: i32) bool {
        if (y < GROUND_Y + 6 or y > GROUND_Y + 10) return false;
        const dx: u32 = @abs(wx - 12);
        const dz: u32 = @abs(wz - 20);
        const radius: u32 = if (y == GROUND_Y + 10) 1 else 3;
        return dx <= radius and dz <= radius and !(dx == 3 and dz == 3);
    }

    fn rect(wx: i32, wz: i32, min_x: i32, max_x: i32, min_z: i32, max_z: i32) bool {
        return wx >= min_x and wx <= max_x and wz >= min_z and wz <= max_z;
    }

    fn updateColumnMetadata(chunk: *Chunk) void {
        var local_z: u32 = 0;
        while (local_z < CHUNK_SIZE_Z) : (local_z += 1) {
            var local_x: u32 = 0;
            while (local_x < CHUNK_SIZE_X) : (local_x += 1) {
                chunk.setBiome(local_x, local_z, .plains);
                var y: i32 = CHUNK_SIZE_Y - 1;
                while (y >= 0) : (y -= 1) {
                    const block = chunk.getBlock(local_x, @intCast(y), local_z);
                    if (block != .air and block != .water) {
                        chunk.setSurfaceHeight(local_x, local_z, @intCast(y));
                        break;
                    }
                }
            }
        }
    }

    pub fn generateHeightmapOnly(self: *const ShadowTestWorldGenerator, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void {
        _ = self;
        _ = region_x;
        _ = region_z;
        _ = lod_level;
        @memset(data.heightmap, @floatFromInt(GROUND_Y));
        @memset(data.biomes, .plains);
        @memset(data.top_blocks, .grass);
        @memset(data.colors, GRASS_COLOR);
    }

    pub fn maybeRecenterCache(self: *ShadowTestWorldGenerator, player_x: i32, player_z: i32) bool {
        _ = self;
        _ = player_x;
        _ = player_z;
        return false;
    }

    pub fn getSeed(self: *const ShadowTestWorldGenerator) u64 {
        return self.seed;
    }

    pub fn getColumnInfo(self: *const ShadowTestWorldGenerator, wx: f32, wz: f32) ColumnInfo {
        _ = self;
        _ = wx;
        _ = wz;
        return .{
            .height = GROUND_Y,
            .biome = .plains,
            .is_ocean = false,
            .temperature = 0.5,
            .humidity = 0.5,
            .continentalness = 0.5,
        };
    }

    pub fn generator(self: *ShadowTestWorldGenerator) Generator {
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
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        self.generate(chunk, stop_flag);
    }

    fn generateHeightmapOnlyWrapper(ptr: *anyopaque, data: *LODSimplifiedData, region_x: i32, region_z: i32, lod_level: LODLevel) void {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        self.generateHeightmapOnly(data, region_x, region_z, lod_level);
    }

    fn maybeRecenterCacheWrapper(ptr: *anyopaque, player_x: i32, player_z: i32) bool {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.maybeRecenterCache(player_x, player_z);
    }

    fn getSeedWrapper(ptr: *anyopaque) u64 {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getSeed();
    }

    fn getRegionInfoWrapper(ptr: *anyopaque, world_x: i32, world_z: i32) RegionInfo {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        return region_pkg.getRegion(self.seed, world_x, world_z);
    }

    fn getColumnInfoWrapper(ptr: *anyopaque, wx: f32, wz: f32) ColumnInfo {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(wx, wz);
    }

    fn deinitWrapper(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ShadowTestWorldGenerator = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};
