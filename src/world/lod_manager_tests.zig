const std = @import("std");

const lod_manager = @import("lod_manager.zig");
const LODManager = lod_manager.LODManager;
const LODStats = lod_manager.LODStats;
const MAX_LOD_REGIONS = lod_manager.MAX_LOD_REGIONS;

const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODConfig = lod_chunk.LODConfig;
const ILODConfig = lod_chunk.ILODConfig;
const LODChunk = lod_chunk.LODChunk;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;

const Chunk = @import("chunk.zig").Chunk;
const Generator = @import("worldgen/generator_interface.zig").Generator;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const rhi_types = @import("../engine/graphics/rhi_types.zig");
const LODMesh = @import("lod_mesh.zig").LODMesh;

const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;

test "LODManager initialization" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = @import("chunk.zig").MAX_BLOCK_TYPES;

    const MockState = struct {
        buffer_created: bool = false,
        buffer_destroyed: bool = false,
    };

    const MockGenerator = struct {
        fn generate(_: *anyopaque, _: *Chunk, _: ?*const bool) void {}
        fn generateHeightmapOnly(_: *anyopaque, _: *LODSimplifiedData, _: i32, _: i32, _: LODLevel) void {}
        fn maybeRecenterCache(_: *anyopaque, _: i32, _: i32) bool {
            return false;
        }
        fn getSeed(_: *anyopaque) u64 {
            return 0;
        }
        fn getRegionInfo(_: *anyopaque, _: i32, _: i32) @import("worldgen/region.zig").RegionInfo {
            return undefined;
        }
        fn getColumnInfo(_: *anyopaque, _: f32, _: f32) @import("worldgen/generator_interface.zig").ColumnInfo {
            return undefined;
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        const vtable = Generator.VTable{
            .generate = generate,
            .generateHeightmapOnly = generateHeightmapOnly,
            .maybeRecenterCache = maybeRecenterCache,
            .getSeed = getSeed,
            .getRegionInfo = getRegionInfo,
            .getColumnInfo = getColumnInfo,
            .deinit = deinit,
        };
    };

    var mock_gen_impl = MockGenerator{};
    const mock_gen = Generator{
        .ptr = &mock_gen_impl,
        .vtable = &MockGenerator.vtable,
        .info = .{ .name = "Mock", .description = "Mock Generator" },
    };

    var config = LODConfig{
        .radii = .{ 8, 16, 32, 64 },
    };

    var mock_state = MockState{};
    const mock_bridge = LODGPUBridge{
        .on_upload = struct {
            fn f(_: *LODMesh, _: *anyopaque) rhi_types.RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *LODMesh, ctx: *anyopaque) void {
                const state: *MockState = @ptrCast(@alignCast(ctx));
                state.buffer_destroyed = true;
            }
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(&mock_state),
    };

    const mock_render = LODRenderInterface{
        .render_fn = struct {
            fn f(_: *anyopaque, _: *const [LODLevel.count]MeshMap, _: *const [LODLevel.count]RegionMap, _: ILODConfig, _: Mat4, _: Vec3, _: ?LODManager.ChunkChecker, _: ?*anyopaque, _: bool, _: ?i32) void {}
        }.f,
        .deinit_fn = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ptr = @ptrCast(&mock_state),
    };

    const mock_atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };

    var mgr = try LODManager.init(allocator, config.interface(), mock_bridge, mock_render, mock_gen, &mock_atlas);
    mgr.cleanup_covered_regions = false;

    const stats = mgr.getStats();
    try std.testing.expectEqual(@as(u32, 0), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 0), stats.totalGenerating());

    mgr.deinit();

    try std.testing.expectEqual(LODLevel.lod0, config.getLODForDistance(5));
    try std.testing.expectEqual(LODLevel.lod1, config.getLODForDistance(12));
    try std.testing.expectEqual(LODLevel.lod2, config.getLODForDistance(24));
    try std.testing.expectEqual(LODLevel.lod3, config.getLODForDistance(50));
}

test "LODManager end-to-end covered cleanup" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = @import("chunk.zig").MAX_BLOCK_TYPES;

    const MockGenerator = struct {
        fn generate(_: *anyopaque, _: *Chunk, _: ?*const bool) void {}
        fn generateHeightmapOnly(_: *anyopaque, _: *LODSimplifiedData, _: i32, _: i32, _: LODLevel) void {}
        fn maybeRecenterCache(_: *anyopaque, _: i32, _: i32) bool {
            return false;
        }
        fn getSeed(_: *anyopaque) u64 {
            return 0;
        }
        fn getRegionInfo(_: *anyopaque, _: i32, _: i32) @import("worldgen/region.zig").RegionInfo {
            return undefined;
        }
        fn getColumnInfo(_: *anyopaque, _: f32, _: f32) @import("worldgen/generator_interface.zig").ColumnInfo {
            return .{ .height = 0, .biome = .plains, .is_ocean = false, .temperature = 0, .humidity = 0, .continentalness = 0 };
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

        const vtable = Generator.VTable{
            .generate = generate,
            .generateHeightmapOnly = generateHeightmapOnly,
            .maybeRecenterCache = maybeRecenterCache,
            .getSeed = getSeed,
            .getRegionInfo = getRegionInfo,
            .getColumnInfo = getColumnInfo,
            .deinit = deinit,
        };
    };

    var mock_gen_impl = MockGenerator{};
    const mock_gen = Generator{
        .ptr = &mock_gen_impl,
        .vtable = &MockGenerator.vtable,
        .info = .{ .name = "Mock", .description = "Mock Generator" },
    };

    var config = LODConfig{
        .radii = .{ 2, 4, 8, 16 },
    };

    var noop_ctx: u8 = 0;
    const mock_bridge = LODGPUBridge{
        .on_upload = struct {
            fn f(_: *LODMesh, _: *anyopaque) rhi_types.RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *LODMesh, _: *anyopaque) void {}
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(&noop_ctx),
    };

    const mock_render = LODRenderInterface{
        .render_fn = struct {
            fn f(_: *anyopaque, _: *const [LODLevel.count]MeshMap, _: *const [LODLevel.count]RegionMap, _: ILODConfig, _: Mat4, _: Vec3, _: ?LODManager.ChunkChecker, _: ?*anyopaque, _: bool, _: ?i32) void {}
        }.f,
        .deinit_fn = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ptr = @ptrCast(&noop_ctx),
    };

    const mock_atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };

    var mgr = try LODManager.init(allocator, config.interface(), mock_bridge, mock_render, mock_gen, &mock_atlas);
    mgr.cleanup_covered_regions = false;
    defer mgr.deinit();

    try mgr.update(Vec3.zero, Vec3.zero, null, null);

    const Checker = struct {
        pub fn isLoaded(_: i32, _: i32, _: *anyopaque) bool {
            return false;
        }
    };

    const key = lod_chunk.LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod1 };
    const chunk = try allocator.create(LODChunk);
    chunk.* = LODChunk.init(1, 0, .lod1);
    chunk.state = .renderable;
    try mgr.regions[1].put(key, chunk);

    const mesh = try allocator.create(LODMesh);
    mesh.* = LODMesh.init(allocator, .lod1);
    mesh.ready = true;
    mesh.vertex_count = 100;
    try mgr.meshes[1].put(key, mesh);

    var dummy: u8 = 0;
    try mgr.update(Vec3.zero, Vec3.zero, Checker.isLoaded, &dummy);
    try std.testing.expect(mgr.regions[1].contains(key));

    const FullChecker = struct {
        pub fn isLoaded(_: i32, _: i32, _: *anyopaque) bool {
            return true;
        }
    };

    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);
    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);
    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);
    try mgr.update(Vec3.zero, Vec3.zero, FullChecker.isLoaded, &dummy);

    try std.testing.expect(mgr.regions[1].contains(key));
}

test "LODStats aggregation" {
    var stats = LODStats{};
    stats.recordState(1, .renderable);
    stats.recordState(1, .renderable);
    stats.recordState(2, .generating);

    try std.testing.expectEqual(@as(u32, 2), stats.loaded[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.generating[2]);
    try std.testing.expectEqual(@as(u32, 2), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 1), stats.totalGenerating());

    stats.addMemory(2 * 1024 * 1024);
    try std.testing.expectEqual(@as(u32, 2), stats.memory_used_mb);

    stats.reset();
    try std.testing.expectEqual(@as(u32, 0), stats.totalLoaded());
    try std.testing.expectEqual(@as(u32, 0), stats.memory_used_mb);
}

test "LODManager constants" {
    try std.testing.expect(MAX_LOD_REGIONS > 0);
    try std.testing.expect(LODLevel.count >= 2);
}
