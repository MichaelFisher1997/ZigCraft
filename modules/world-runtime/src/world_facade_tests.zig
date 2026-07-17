const std = @import("std");
const testing = std.testing;

const world_mod = @import("world.zig");
const world_core = @import("world-core");
const world_meshing = @import("world-meshing");
const worldgen = @import("world-worldgen");
const math = @import("engine-math");
const LpvGridBuilder = @import("lpv_grid_builder.zig").LpvGridBuilder;
const RenderLayer = @import("world_renderer.zig").RenderLayer;
const WorldMutationCoordinator = @import("world_mutation.zig").WorldMutationCoordinator;
const SaveManager = @import("world-persistence").SaveManager;
const World = world_mod.World;

test "full-detail radius follows active preset cap" {
    try testing.expectEqual(@as(i32, 12), World.effectiveChunkRenderRadius(16, 12, true));
    try testing.expectEqual(@as(i32, 16), World.effectiveChunkRenderRadius(16, 16, true));
    try testing.expectEqual(@as(i32, 22), World.effectiveChunkRenderRadius(22, 10, false));
}

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
        .isGpuCullingEnabled = isGpuCullingEnabled,
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

    fn prepareLODCulling(_: *anyopaque, _: math.Mat4, _: math.Vec3) void {}

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
        return .{ .sky = 15, .block = 3 };
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

    fn isGpuCullingEnabled(ptr: *anyopaque) bool {
        _ = ptr;
        return false;
    }
};

fn makeStorageOnlyWorld(allocator: std.mem.Allocator) world_mod.World {
    // Storage-only fixture for real World methods that do not touch renderer,
    // streamer, RHI, generator, save manager, or LOD. Tests must tear it down
    // with deinitStorageOnlyWorld(), not World.deinit().
    var world = world_mod.World{
        .storage = world_meshing.ChunkStorage.init(allocator),
        .streamer = undefined,
        .renderer = undefined,
        .allocator = allocator,
        .generator = undefined,
        .render_distance = 8,
        .horizon_distance = 512,
        .rhi = undefined,
        .paused = false,
        .safe_mode = false,
        .safe_render_distance = 8,
        .lod = null,
        .lod_enabled = false,
        .save_manager = null,
        .gpu_block_buffer = null,
        .mutation = undefined,
        .lpv_grid_builder = undefined,
    };
    world.mutation = WorldMutationCoordinator.init(&world.storage, allocator, null, false);
    world.lpv_grid_builder = LpvGridBuilder.init(&world.storage);
    return world;
}

fn deinitStorageOnlyWorld(world: *world_mod.World) void {
    if (world.save_manager) |sm| {
        sm.deinit();
        world.save_manager = null;
    }
    // Mutation and LPV grid builder currently borrow storage/allocator only.
    // If either starts owning resources, this fixture teardown should grow with it.
    world.storage.deinitWithoutRHI();
}

const OrchestrationRecorder = struct {
    next_order: u32 = 0,
    begin_order: u32 = 999,
    update_order: u32 = 999,
    autosave_order: u32 = 999,
};

const MockRendererSubsystem = struct {
    recorder: ?*OrchestrationRecorder = null,
    begin_count: u32 = 0,
    render_count: u32 = 0,
    last_render_distance: i32 = 0,
    last_render_lod: bool = false,
    last_layer: RenderLayer = .all,

    pub fn beginFrame(self: *@This()) void {
        self.begin_count += 1;
        if (self.recorder) |recorder| {
            recorder.begin_order = recorder.next_order;
            recorder.next_order += 1;
        }
    }

    pub fn render(self: *@This(), view_proj: math.Mat4, camera_pos: math.Vec3, render_distance: i32, lod_manager: ?*@import("world-lod").LODManager, render_lod: bool, layer: RenderLayer) void {
        _ = view_proj;
        _ = camera_pos;
        _ = lod_manager;
        self.render_count += 1;
        self.last_render_distance = render_distance;
        self.last_render_lod = render_lod;
        self.last_layer = layer;
    }
};

const MockStreamerSubsystem = struct {
    recorder: ?*OrchestrationRecorder = null,
    update_count: u32 = 0,
    active_render_distance: i32 = 18,
    last_dt: f32 = 0.0,
    last_player_pos: math.Vec3 = math.Vec3.zero,

    pub fn updateFrame(self: *@This(), player_pos: math.Vec3, dt: f32) !void {
        self.update_count += 1;
        self.last_player_pos = player_pos;
        self.last_dt = dt;
        if (self.recorder) |recorder| {
            recorder.update_order = recorder.next_order;
            recorder.next_order += 1;
        }
    }

    pub fn getActiveRenderDistance(self: *@This()) i32 {
        return self.active_render_distance;
    }
};

const MockAutoSaveWorld = struct {
    recorder: *OrchestrationRecorder,
    autosave_count: u32 = 0,

    pub fn checkAutoSave(self: *@This()) void {
        self.autosave_count += 1;
        self.recorder.autosave_order = self.recorder.next_order;
        self.recorder.next_order += 1;
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

test "WorldOrchestration update orders renderer streamer and autosave" {
    var recorder = OrchestrationRecorder{};
    var renderer = MockRendererSubsystem{ .recorder = &recorder };
    var streamer = MockStreamerSubsystem{ .recorder = &recorder };
    var save_owner = MockAutoSaveWorld{ .recorder = &recorder };
    const player_pos = math.Vec3.init(1.0, 2.0, 3.0);

    try world_mod.WorldOrchestration.update(&renderer, &streamer, &save_owner, player_pos, 0.25);

    try testing.expectEqual(@as(u32, 1), renderer.begin_count);
    try testing.expectEqual(@as(u32, 1), streamer.update_count);
    try testing.expectEqual(@as(u32, 1), save_owner.autosave_count);
    try testing.expectEqual(@as(u32, 0), recorder.begin_order);
    try testing.expectEqual(@as(u32, 1), recorder.update_order);
    try testing.expectEqual(@as(u32, 2), recorder.autosave_order);
    try testing.expectEqual(@as(f32, 0.25), streamer.last_dt);
    try testing.expectEqual(player_pos.x, streamer.last_player_pos.x);
}

test "WorldOrchestration render delegates active distance layer and LOD flag" {
    var renderer = MockRendererSubsystem{};
    var streamer = MockStreamerSubsystem{ .active_render_distance = 24 };

    world_mod.WorldOrchestration.render(&renderer, &streamer, null, true, math.Mat4.identity(), math.Vec3.zero, true, .terrain);

    try testing.expectEqual(@as(u32, 1), renderer.render_count);
    try testing.expectEqual(@as(i32, 24), renderer.last_render_distance);
    try testing.expect(renderer.last_render_lod);
    try testing.expectEqual(RenderLayer.terrain, renderer.last_layer);

    world_mod.WorldOrchestration.render(&renderer, &streamer, null, true, math.Mat4.identity(), math.Vec3.zero, false, .fluid);

    try testing.expectEqual(@as(u32, 2), renderer.render_count);
    try testing.expect(!renderer.last_render_lod);
    try testing.expectEqual(RenderLayer.fluid, renderer.last_layer);
}

test "World storage facade returns air for unloaded and out-of-bounds blocks" {
    var world = makeStorageOnlyWorld(testing.allocator);
    defer deinitStorageOnlyWorld(&world);

    try testing.expectEqual(world_core.BlockType.air, world.getBlock(0, 64, 0));
    try testing.expectEqual(world_core.BlockType.air, world.getBlock(0, -1, 0));
    try testing.expectEqual(world_core.BlockType.air, world.getBlock(0, 256, 0));
}

test "World setBlock ignores unloaded chunks" {
    var world = makeStorageOnlyWorld(testing.allocator);
    defer deinitStorageOnlyWorld(&world);

    try world.setBlock(17, 42, -1, .stone);

    try testing.expectEqual(world_core.BlockType.air, world.getBlock(17, 42, -1));
    try testing.expectEqual(@as(usize, 0), world.storage.count());
}

test "World setBlock ignores out-of-bounds y without creating chunks" {
    var world = makeStorageOnlyWorld(testing.allocator);
    defer deinitStorageOnlyWorld(&world);

    try world.setBlock(0, -1, 0, .dirt);
    try world.setBlock(0, 256, 0, .dirt);

    try testing.expectEqual(@as(usize, 0), world.storage.count());
}

test "World getChunkStateCounts reports storage telemetry" {
    var world = makeStorageOnlyWorld(testing.allocator);
    defer deinitStorageOnlyWorld(&world);

    const missing = try world.storage.getOrCreate(0, 0);
    missing.chunk.state = .missing;
    missing.chunk.dirty = false;
    const renderable = try world.storage.getOrCreate(1, 0);
    renderable.chunk.state = .renderable;
    renderable.chunk.dirty = true;

    const counts = world.getChunkStateCounts();

    try testing.expectEqual(@as(u32, 2), counts.total);
    try testing.expectEqual(@as(u32, 1), counts.missing);
    try testing.expectEqual(@as(u32, 1), counts.renderable);
    try testing.expectEqual(@as(u32, 1), counts.dirty);
}

test "World saveAllModifiedChunks and loadChunkFromSave round-trip chunk data" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const base_path = try tmp_dir.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(base_path);
    const save_path = try std.fmt.allocPrint(testing.allocator, "{s}/world_save_roundtrip", .{base_path});
    defer testing.allocator.free(save_path);

    var world = makeStorageOnlyWorld(testing.allocator);
    defer deinitStorageOnlyWorld(&world);
    world.save_manager = try SaveManager.init(testing.allocator, save_path, "world_save_roundtrip", 1234, "test-generator");

    const data = try world.storage.getOrCreate(2, -1);
    data.chunk.generated = true;
    data.chunk.setBlock(4, 64, 5, .stone);
    data.chunk.setBiome(4, 5, .forest);

    world.saveAllModifiedChunks();

    try testing.expect(!data.chunk.modified);
    var loaded = world_core.Chunk.init(2, -1);
    try testing.expectEqual(@import("world-persistence").LoadResult.success, world.loadChunkFromSave(2, -1, &loaded));
    try testing.expectEqual(world_core.BlockType.stone, loaded.getBlock(4, 64, 5));
    try testing.expectEqual(world_core.BiomeId.forest, loaded.getBiome(4, 5));
}

test "World loaded map capture reflects foliage placement and removal" {
    var world = makeStorageOnlyWorld(testing.allocator);
    defer deinitStorageOnlyWorld(&world);
    const data = try world.storage.getOrCreate(0, 0);
    data.chunk.generated = true;
    data.chunk.setBlock(3, 64, 5, .grass);
    data.chunk.setBlock(3, 72, 5, .leaves);

    var map = try worldgen.WorldMap.init(testing.allocator, 16, 16);
    defer map.deinit();
    const first = try map.createLoadedSurfaceOverlay();
    defer first.deinit();
    try world.captureLoadedMapSurface(first, 8, 8, 1, 16, 16);
    const canopy = first.sample(3, 5).?;
    try testing.expectEqual(world_core.BlockType.leaves, canopy.block);
    try testing.expectEqual(@as(i16, 72), canopy.height);

    data.chunk.setBlock(3, 72, 5, .air);
    const second = try map.createLoadedSurfaceOverlay();
    defer second.deinit();
    try world.captureLoadedMapSurface(second, 8, 8, 1, 16, 16);
    const exposed = second.sample(3, 5).?;
    try testing.expectEqual(world_core.BlockType.grass, exposed.block);
    try testing.expectEqual(@as(i16, 64), exposed.height);
}
