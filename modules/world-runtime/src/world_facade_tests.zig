const std = @import("std");
const testing = std.testing;

const world_mod = @import("world.zig");
const world_core = @import("world-core");
const worldgen = @import("world-worldgen");
const math = @import("engine-math");

const MockWorld = struct {
    update_count: u32 = 0,
    render_count: u32 = 0,
    render_opaque_count: u32 = 0,
    render_fluid_count: u32 = 0,
    deinit_count: u32 = 0,
    save_count: u32 = 0,
    pause_count: u32 = 0,
    set_block_count: u32 = 0,
    render_distance: i32 = 12,
    horizon_distance: i32 = 512,
    paused: bool = false,
    lod_rendering_enabled: bool = true,
    last_block: world_core.BlockType = .air,

    fn iface(self: *@This()) world_mod.IWorld {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable = world_mod.IWorld.VTable{
        .update = update,
        .render = render,
        .renderOpaque = renderOpaque,
        .renderFluid = renderFluid,
        .deinit = deinit,
        .getRenderStats = getRenderStats,
        .getStats = getStats,
        .getLODStats = getLODStats,
        .isLODEnabled = isLODEnabled,
        .shadowScene = shadowScene,
        .enableSaveManager = enableSaveManager,
        .takeSaveFailureWarningCount = takeSaveFailureWarningCount,
        .pauseGeneration = pauseGeneration,
        .isPaused = isPaused,
        .collisionWorld = collisionWorld,
        .getBlock = getBlock,
        .setBlock = setBlock,
        .getColumnInfo = getColumnInfo,
        .getDebugLightInfo = getDebugLightInfo,
        .getRegionInfo = getRegionInfo,
        .getGenerator = getGenerator,
        .getGeneratorName = getGeneratorName,
        .getRenderDistance = getRenderDistance,
        .setRenderDistance = setRenderDistance,
        .getHorizonDistance = getHorizonDistance,
        .setHorizonDistance = setHorizonDistance,
        .isLODRenderingEnabled = isLODRenderingEnabled,
        .toggleLODRendering = toggleLODRendering,
        .getChunkStateCounts = getChunkStateCounts,
        .isStartupBusy = isStartupBusy,
        .getWorldStateData = getWorldStateData,
        .lpvWorld = lpvWorld,
        .graphicsRenderView = graphicsRenderView,
        .getGpuMeshDispatch = getGpuMeshDispatch,
    };

    fn cast(ptr: *anyopaque) *@This() {
        return @ptrCast(@alignCast(ptr));
    }

    fn update(ptr: *anyopaque, player_pos: math.Vec3, dt: f32) anyerror!void {
        _ = player_pos;
        _ = dt;
        cast(ptr).update_count += 1;
    }

    fn render(ptr: *anyopaque, view_proj: math.Mat4, camera_pos: math.Vec3, render_lod: bool) void {
        _ = view_proj;
        _ = camera_pos;
        _ = render_lod;
        cast(ptr).render_count += 1;
    }

    fn renderOpaque(ptr: *anyopaque, view_proj: math.Mat4, camera_pos: math.Vec3, render_lod: bool) void {
        _ = view_proj;
        _ = camera_pos;
        _ = render_lod;
        cast(ptr).render_opaque_count += 1;
    }

    fn renderFluid(ptr: *anyopaque, view_proj: math.Mat4, camera_pos: math.Vec3, render_lod: bool) void {
        _ = view_proj;
        _ = camera_pos;
        _ = render_lod;
        cast(ptr).render_fluid_count += 1;
    }

    fn deinit(ptr: *anyopaque) void {
        cast(ptr).deinit_count += 1;
    }

    fn getRenderStats(ptr: *anyopaque) world_mod.RenderStats {
        _ = ptr;
        return .{ .chunks_total = 3, .chunks_rendered = 2, .chunks_culled = 1, .vertices_rendered = 144 };
    }

    fn getStats(ptr: *anyopaque) world_mod.WorldStatsData {
        _ = ptr;
        return .{ .chunks_loaded = 4, .total_vertices = 200, .gen_queue = 1, .mesh_queue = 2, .upload_queue = 3 };
    }

    fn getLODStats(ptr: *anyopaque) ?@import("world-lod").LODStats {
        _ = ptr;
        return null;
    }

    fn isLODEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return true;
    }

    fn shadowScene(ptr: *anyopaque) @import("engine-rhi").IShadowScene {
        _ = ptr;
        return undefined;
    }

    fn enableSaveManager(ptr: *anyopaque, save_dir_path: []const u8, world_name: []const u8) anyerror!void {
        _ = save_dir_path;
        _ = world_name;
        cast(ptr).save_count += 1;
    }

    fn takeSaveFailureWarningCount(ptr: *anyopaque) usize {
        _ = ptr;
        return 2;
    }

    fn pauseGeneration(ptr: *anyopaque) void {
        const self = cast(ptr);
        self.paused = true;
        self.pause_count += 1;
    }

    fn isPaused(ptr: *anyopaque) bool {
        return cast(ptr).paused;
    }

    fn collisionWorld(ptr: *anyopaque) @import("engine-physics").VoxelCollisionWorld {
        _ = ptr;
        return undefined;
    }

    fn getBlock(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) world_core.BlockType {
        _ = world_x;
        _ = world_y;
        _ = world_z;
        return cast(ptr).last_block;
    }

    fn setBlock(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32, block: world_core.BlockType) anyerror!void {
        _ = world_x;
        _ = world_y;
        _ = world_z;
        const self = cast(ptr);
        self.last_block = block;
        self.set_block_count += 1;
    }

    fn getColumnInfo(ptr: *anyopaque, world_x: i32, world_z: i32) worldgen.ColumnInfo {
        _ = ptr;
        _ = world_x;
        _ = world_z;
        return undefined;
    }

    fn getDebugLightInfo(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) ?world_mod.DebugLightInfo {
        _ = ptr;
        _ = world_x;
        _ = world_y;
        _ = world_z;
        return .{ .sky = 15, .block = 3, .entrance_bounce = 1 };
    }

    fn getRegionInfo(ptr: *anyopaque, world_x: i32, world_z: i32) worldgen.RegionInfo {
        _ = ptr;
        _ = world_x;
        _ = world_z;
        return undefined;
    }

    fn getGenerator(ptr: *anyopaque) worldgen.Generator {
        _ = ptr;
        return undefined;
    }

    fn getGeneratorName(ptr: *anyopaque) []const u8 {
        _ = ptr;
        return "mock-generator";
    }

    fn getRenderDistance(ptr: *anyopaque) i32 {
        return cast(ptr).render_distance;
    }

    fn setRenderDistance(ptr: *anyopaque, distance: i32) void {
        cast(ptr).render_distance = distance;
    }

    fn getHorizonDistance(ptr: *anyopaque) i32 {
        return cast(ptr).horizon_distance;
    }

    fn setHorizonDistance(ptr: *anyopaque, distance: i32) void {
        cast(ptr).horizon_distance = distance;
    }

    fn isLODRenderingEnabled(ptr: *anyopaque) bool {
        return cast(ptr).lod_rendering_enabled;
    }

    fn toggleLODRendering(ptr: *anyopaque) bool {
        const self = cast(ptr);
        self.lod_rendering_enabled = !self.lod_rendering_enabled;
        return self.lod_rendering_enabled;
    }

    fn getChunkStateCounts(ptr: *anyopaque) world_core.ChunkStateCounts {
        _ = ptr;
        return .{ .total = 5, .renderable = 4, .dirty = 1 };
    }

    fn isStartupBusy(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }

    fn getWorldStateData(ptr: *anyopaque) world_core.WorldStateData {
        _ = ptr;
        return .{ .generator_name = "mock-generator", .seed = 99, .gen_queue = 1, .mesh_queue = 2, .upload_queue = 3 };
    }

    fn lpvWorld(ptr: *anyopaque) @import("engine-rhi").ILPVWorld {
        _ = ptr;
        return undefined;
    }

    fn graphicsRenderView(ptr: *anyopaque) @import("engine-rhi").IWorldRenderView {
        _ = ptr;
        return undefined;
    }

    fn getGpuMeshDispatch(ptr: *anyopaque) world_mod.GpuMeshDispatch {
        _ = ptr;
        return .{ .dispatch_fn = null, .dispatch_ctx = null };
    }
};

test "IWorld forwards simulation lifecycle calls" {
    var mock = MockWorld{};
    const world = mock.iface();

    try world.update(math.Vec3.zero, 0.016);
    world.deinit();

    try testing.expectEqual(@as(u32, 1), mock.update_count);
    try testing.expectEqual(@as(u32, 1), mock.deinit_count);
}

test "IWorld forwards render passes" {
    var mock = MockWorld{};
    const world = mock.iface();
    const mat = math.Mat4.identity();

    world.render(mat, math.Vec3.zero, true);
    world.renderOpaque(mat, math.Vec3.zero, true);
    world.renderFluid(mat, math.Vec3.zero, false);

    try testing.expectEqual(@as(u32, 1), mock.render_count);
    try testing.expectEqual(@as(u32, 1), mock.render_opaque_count);
    try testing.expectEqual(@as(u32, 1), mock.render_fluid_count);
}

test "IWorld forwards block reads and writes" {
    var mock = MockWorld{};
    const world = mock.iface();

    try world.setBlock(1, 2, 3, .stone);

    try testing.expectEqual(@as(u32, 1), mock.set_block_count);
    try testing.expectEqual(world_core.BlockType.stone, world.getBlock(1, 2, 3));
}

test "IWorld forwards save and pause state" {
    var mock = MockWorld{};
    const world = mock.iface();

    try world.enableSaveManager("/tmp/save", "world");
    world.pauseGeneration();

    try testing.expectEqual(@as(u32, 1), mock.save_count);
    try testing.expectEqual(@as(u32, 1), mock.pause_count);
    try testing.expect(world.isPaused());
    try testing.expectEqual(@as(usize, 2), world.takeSaveFailureWarningCount());
}

test "IWorld telemetry forwards stats and distances" {
    var mock = MockWorld{};
    const world = mock.iface();

    world.setRenderDistance(24);
    world.setHorizonDistance(1024);
    const render_stats = world.getRenderStats();
    const stats = world.getStats();

    try testing.expectEqual(@as(i32, 24), world.getRenderDistance());
    try testing.expectEqual(@as(i32, 1024), world.getHorizonDistance());
    try testing.expectEqual(@as(u32, 2), render_stats.chunks_rendered);
    try testing.expectEqual(@as(u64, 200), stats.total_vertices);
}

test "IWorld forwards LOD rendering toggle" {
    var mock = MockWorld{};
    const world = mock.iface();

    try testing.expect(world.isLODRenderingEnabled());
    try testing.expect(!world.toggleLODRendering());
    try testing.expect(!world.isLODRenderingEnabled());
}

test "IWorld exposes role interface views" {
    var mock = MockWorld{};
    const world = mock.iface();

    try world.simulation().setBlock(0, 0, 0, .dirt);
    world.telemetry().setRenderDistance(18);
    world.renderView().render(math.Mat4.identity(), math.Vec3.zero, false);

    try testing.expectEqual(world_core.BlockType.dirt, world.simulation().getBlock(0, 0, 0));
    try testing.expectEqual(@as(i32, 18), world.telemetry().getRenderDistance());
    try testing.expectEqual(@as(u32, 1), mock.render_count);
}

test "IWorld telemetry view forwards debug and state data" {
    var mock = MockWorld{};
    const telemetry = mock.iface().telemetry();

    const chunk_counts = telemetry.getChunkStateCounts();
    const state = telemetry.getWorldStateData();
    const light = telemetry.getDebugLightInfo(1, 2, 3).?;

    try testing.expectEqualStrings("mock-generator", telemetry.getGeneratorName());
    try testing.expectEqual(@as(u32, 5), chunk_counts.total);
    try testing.expectEqual(@as(u32, 4), chunk_counts.renderable);
    try testing.expectEqual(@as(u64, 99), state.seed);
    try testing.expectEqual(@as(u4, 15), light.sky);
}
