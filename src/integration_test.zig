//! Integration smoke test for ZigCraft.
//!
//! Tests the full application lifecycle: launch, generate terrain, render a frame, and exit.
//! Requires a display server (use xvfb-run in CI).
//!
//! Run with: zig build test-integration
//! CI: xvfb-run -a zig build test-integration

const std = @import("std");
const testing = std.testing;
const fs = @import("fs");

const App = @import("game/app.zig").App;
const build_options = @import("build_options");

const WorldScreen = @import("game-ui").WorldScreen;
const Screen = @import("game-ui").screen;
const rhi = @import("engine-rhi");
const UISystem = @import("engine-ui").UISystem;
const c = @import("c").c;
const engine_math = @import("engine-math");
const world_core = @import("world-core");
const world_lod = @import("world-lod");
const world_meshing = @import("world-meshing");
const world_runtime = @import("world-runtime");
const SaveManager = @import("world-persistence").SaveManager;

const EngineContext = Screen.EngineContext;
const IScreen = Screen.IScreen;

fn initEditPersistenceLODManager(
    allocator: std.mem.Allocator,
    config: *world_lod.lod_chunk.LODConfig,
    atlas: *const @import("engine-assets").TextureAtlas,
    context: *u8,
) !*world_lod.LODManager {
    const LODLevel = world_lod.LODLevel;
    const LODSimplifiedData = world_lod.lod_chunk.LODSimplifiedData;
    const uploads = world_lod.lod_upload_queue;

    const bridge = world_lod.LODGPUBridge{
        .on_upload = struct {
            fn f(_: *world_lod.LODMesh, _: *anyopaque) rhi.RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *world_lod.LODMesh, _: *anyopaque) void {}
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(context),
    };
    const render_interface = world_lod.LODRenderInterface{
        .render_fn = struct {
            fn f(
                _: *anyopaque,
                _: *const [LODLevel.count]uploads.MeshMap,
                _: *const [LODLevel.count]uploads.RegionMap,
                _: world_lod.lod_chunk.ILODConfig,
                _: engine_math.Mat4,
                _: engine_math.Vec3,
                _: ?world_lod.LODManager.ChunkChecker,
                _: ?*anyopaque,
                _: bool,
                _: ?i32,
                _: uploads.LODRenderLayer,
                _: ?*world_lod.LODStats,
                _: ?*world_lod.lod_stats.LODProfilingCollector,
            ) void {}
        }.f,
        .deinit_fn = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ptr = @ptrCast(context),
    };
    const generator = world_lod.LODGenerator{
        .ptr = @ptrCast(context),
        .generate_heightmap_only = struct {
            fn f(_: *anyopaque, _: *LODSimplifiedData, _: i32, _: i32, _: LODLevel, _: ?*const std.atomic.Value(bool)) void {}
        }.f,
        .maybe_recenter_cache = struct {
            fn f(_: *anyopaque, _: i32, _: i32) bool {
                return false;
            }
        }.f,
        .seed = 923,
        .identity_hash = 923,
        .version = 1,
    };

    const manager = try world_lod.LODManager.init(allocator, config.interface(), bridge, render_interface, generator, atlas);
    manager.cleanup_covered_regions = false;
    return manager;
}

/// CPU-only world fixture for save/reload integration evidence. Its undefined
/// graphics/streaming members are intentionally never reached: this test uses
/// only the production storage and persistence facade methods.
fn initStorageOnlyPersistenceWorld(allocator: std.mem.Allocator) world_runtime.World {
    return .{
        .storage = world_meshing.ChunkStorage.init(allocator),
        .streamer = undefined,
        .renderer = undefined,
        .allocator = allocator,
        .generator = undefined,
        .render_distance = 8,
        .lod_chunk_render_radius_limit = 8,
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
}

fn deinitStorageOnlyPersistenceWorld(world: *world_runtime.World) void {
    if (world.save_manager) |save_manager| {
        save_manager.deinit();
        world.save_manager = null;
    }
    world.storage.deinitWithoutRHI();
}

const UploadScreen = struct {
    context: EngineContext,
    buffer: rhi.BufferHandle,
    payload: [64]u8 = [_]u8{0} ** 64,
    tick: u8 = 0,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*UploadScreen {
        const upload_screen = try allocator.create(UploadScreen);
        const rm = context.render_system.getRHI().resourceManager();
        const buffer = try rm.createBuffer(upload_screen.payload.len, .vertex);
        upload_screen.* = .{ .context = context, .buffer = buffer };
        return upload_screen;
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *UploadScreen = @ptrCast(@alignCast(ptr));
        self.context.render_system.getRHI().resourceManager().destroyBuffer(self.buffer);
        self.context.allocator.destroy(self);
    }

    fn update(ptr: *anyopaque, _: f32) !void {
        const self: *UploadScreen = @ptrCast(@alignCast(ptr));
        self.payload[0] = self.tick;
        self.tick +%= 1;
        try self.context.render_system.getRHI().resourceManager().updateBuffer(self.buffer, 0, self.payload[0..]);
    }

    fn draw(_: *anyopaque, ui: *UISystem) !void {
        ui.begin();
        ui.end();
    }
    pub fn screen(self: *UploadScreen) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

test "smoke test: launch, generate, render, exit" {
    const test_allocator = testing.allocator;

    @import("engine-core").log.log.min_level = .err;

    var app = App.init(test_allocator) catch |err| {
        if (err == error.WindowCreationFailed or err == error.SDLInitializationFailed) {
            std.debug.print("Skipping integration test: SDL/Vulkan initialization failed (likely no display or Vulkan driver)\n", .{});
            return;
        }
        return err;
    };
    defer app.deinit();

    const world_screen = try WorldScreen.init(test_allocator, app.engineContext(), 12345, 0);
    app.screen_manager.setScreen(world_screen.screen());

    try app.runSingleFrame();

    // The screen manager handles the screen transition in the next update/draw cycle
    // In our implementation, setScreen sets next_screen, and update() consumes it.

    try testing.expect(app.screen_manager.stack.items.len > 0);

    const stats = world_screen.session.world.getStats();

    try testing.expect(stats.chunks_loaded > 0);

    const upload_screen = try UploadScreen.init(test_allocator, app.engineContext());
    app.screen_manager.setScreen(upload_screen.screen());

    const frame_count = rhi.MAX_FRAMES_IN_FLIGHT + 2;
    for (0..frame_count) |_| {
        try app.runSingleFrame();
    }

    const resize_width: u32 = 1024;
    const resize_height: u32 = 720;
    app.window_manager.setSize(resize_width, resize_height);
    app.input.initWindowSize(app.window_manager.window);
    try app.runSingleFrame();

    var actual_w: c_int = 0;
    var actual_h: c_int = 0;
    _ = c.SDL_GetWindowSizeInPixels(app.window_manager.window, &actual_w, &actual_h);
    const extent = app.render_system.getRHI().vulkanHandles().getSwapchainExtent();
    if (!build_options.skip_present) {
        try testing.expectEqual(@as(u32, @intCast(actual_w)), extent[0]);
        try testing.expectEqual(@as(u32, @intCast(actual_h)), extent[1]);
    }

    const val_count = app.render_system.getRHI().query().getValidationErrorCount();
    if (val_count > 0) {
        std.debug.print("Integration test finished with {} Vulkan validation errors\n", .{val_count});
    }
    try testing.expectEqual(@as(u32, 0), val_count);
}

test "end-to-end edited terrain survives async save reload compact rebuild and corruption recovery" {
    const allocator = testing.allocator;
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try dir.realpath(".", &path_buf);

    // Persist a real world-owned full-detail chunk, destroy that storage-only
    // world state, then recreate it and reload before LOD ingestion.
    var source_world = initStorageOnlyPersistenceWorld(allocator);
    source_world.save_manager = try SaveManager.init(allocator, save_path, "edit-persistence", 923, "integration");
    const edited_data = try source_world.storage.getOrCreate(0, 0);
    edited_data.chunk.generated = true;
    var y: u32 = 0;
    while (y <= 96) : (y += 1) {
        edited_data.chunk.setBlock(0, y, 0, if (y == 96) .grass else .stone);
    }
    source_world.saveAllModifiedChunks();
    try testing.expect(!edited_data.chunk.modified);
    try testing.expectEqual(@as(usize, 0), source_world.takeSaveFailureWarningCount());
    deinitStorageOnlyPersistenceWorld(&source_world);

    var reloaded_world = initStorageOnlyPersistenceWorld(allocator);
    defer deinitStorageOnlyPersistenceWorld(&reloaded_world);
    reloaded_world.save_manager = try SaveManager.init(allocator, save_path, "edit-persistence", 923, "integration");
    var reloaded_chunk = world_core.Chunk.init(0, 0);
    const load_result = reloaded_world.loadChunkFromSave(0, 0, &reloaded_chunk);
    try testing.expect(load_result == .success or load_result == .success_relight_required);
    try testing.expectEqual(world_core.BlockType.grass, reloaded_chunk.getBlock(0, 96, 0));

    var config = world_lod.lod_chunk.LODConfig{};
    var atlas = @import("engine-assets").TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]@import("engine-assets").TextureAtlas.BlockTiles{@import("engine-assets").TextureAtlas.BlockTiles.uniform(0)} ** world_core.MAX_BLOCK_TYPES,
    };
    var manager_context: u8 = 0;
    const key = world_lod.lod_chunk.LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod3 };
    var manager = try initEditPersistenceLODManager(allocator, &config, &atlas, &manager_context);

    const region = try allocator.create(world_lod.LODChunk);
    region.* = world_lod.LODChunk.init(key.rx, key.rz, key.lod);
    region.data = .{ .simplified = try world_lod.lod_chunk.LODSimplifiedData.init(allocator, key.lod) };
    region.state = .renderable;
    try manager.regions[@intFromEnum(key.lod)].put(key, region);
    try manager.enableCache(save_path);

    manager.ingestChunk(0, 0, &reloaded_chunk, .edited);
    try testing.expectEqual(@as(f32, 96.0), region.data.simplified.getHeight(0, 0));
    try testing.expectEqual(world_core.LODColumnProvenance.edited, region.data.simplified.getColumnProvenance(0, 0));

    // More than the former expiry window of unresolved retries must retain the
    // edit. This exercises the public drain path under sustained unload pressure.
    manager.requestIngestion(4096, -4096, .edited);
    for (0..1000) |_| manager.drainPendingIngestions();
    var found_durable_edit = false;
    for (manager.ingestion_queue.pending_ingestions.items) |entry| {
        if (entry.cx == 4096 and entry.cz == -4096 and entry.provenance == .edited) found_durable_edit = true;
    }
    try testing.expect(found_durable_edit);

    // The update-side call only snapshots/enqueues; the explicit test boundary
    // waits for the dedicated cache worker and applies its completion.
    manager.flushDirtyStores();
    manager.flushCacheIO();
    try testing.expect(!region.store_dirty);
    manager.deinit();

    // Recreate manager state, reload the persisted source through the manager
    // API, and deterministically rebuild the production compact representation.
    manager = try initEditPersistenceLODManager(allocator, &config, &atlas, &manager_context);
    defer manager.deinit();
    try manager.enableCache(save_path);
    var loaded = manager.loadCachedSourceData(key) orelse return error.ExpectedCacheHit;
    defer loaded.deinit();
    try testing.expectEqual(@as(f32, 96.0), loaded.getHeight(0, 0));
    try testing.expectEqual(world_core.LODColumnProvenance.edited, loaded.getColumnProvenance(0, 0));

    var first_mesh = world_lod.LODMesh.init(allocator, .lod3);
    defer first_mesh.releasePendingCompactTile();
    var second_mesh = world_lod.LODMesh.init(allocator, .lod3);
    defer second_mesh.releasePendingCompactTile();
    try first_mesh.buildCompactTile(&loaded);
    try second_mesh.buildCompactTile(&loaded);
    const first_sample = first_mesh.compact_tile.?.sample(0, 0).?;
    const second_sample = second_mesh.compact_tile.?.sample(0, 0).?;
    try testing.expectEqualSlices(u8, first_sample.bytes[0..], second_sample.bytes[0..]);
    try testing.expectEqual(@as(f32, 96.0), first_sample.decode().terrain_height);
    try testing.expectEqual(world_core.LODColumnProvenance.edited, first_sample.decode().provenance);

    // A malformed source-store container is discarded rather than being
    // returned as valid edited terrain on the next reload.
    const container_path = try world_lod.lod_store.containerPath(allocator, save_path, manager.cacheKey(key));
    defer allocator.free(container_path);
    const corrupt_file = try fs.cwd().createFile(container_path, .{ .truncate = true });
    try corrupt_file.writeAll("not a region container");
    corrupt_file.close();
    try testing.expect(manager.loadCachedSourceData(key) == null);
    try testing.expectError(error.FileNotFound, fs.cwd().openFile(container_path, .{}));
}
