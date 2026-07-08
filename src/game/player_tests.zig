const std = @import("std");
const testing = std.testing;
const Vec3 = @import("zig-math").Vec3;
const player_module = @import("game-core").player;
const Player = player_module.Player;
const world_runtime = @import("world-runtime");
const IWorld = world_runtime.IWorld;
const IWorldSimulation = world_runtime.IWorldSimulation;
const BlockType = @import("world-core").BlockType;
const Face = @import("world-core").Face;

test "Player.init creates player with correct initial state" {
    const spawn_pos = Vec3.init(10, 100, 20);
    const p = Player.init(spawn_pos, true);

    // Position should be at spawn
    try testing.expectEqual(@as(f32, 10), p.position.x);
    try testing.expectEqual(@as(f32, 100), p.position.y);
    try testing.expectEqual(@as(f32, 20), p.position.z);

    // Velocity should be zero
    try testing.expectEqual(@as(f32, 0), p.velocity.x);
    try testing.expectEqual(@as(f32, 0), p.velocity.y);
    try testing.expectEqual(@as(f32, 0), p.velocity.z);

    // Creative mode settings
    try testing.expect(p.fly_mode);
    try testing.expect(p.can_fly);
    try testing.expect(!p.noclip);

    // Ground state
    try testing.expect(!p.is_grounded);

    // Camera should be at eye height
    try testing.expectEqual(@as(f32, 10), p.camera.position.x);
    try testing.expectEqual(@as(f32, 100 + Player.EYE_HEIGHT), p.camera.position.y);
    try testing.expectEqual(@as(f32, 20), p.camera.position.z);

    // Target block should be null initially
    try testing.expect(p.target_block == null);
}

test "Player.init survival mode disables fly" {
    const spawn_pos = Vec3.init(0, 64, 0);
    const p = Player.init(spawn_pos, false);

    try testing.expect(!p.fly_mode);
    try testing.expect(!p.can_fly);
    try testing.expect(!p.noclip);
}

test "Player.getAABB returns correct collision box" {
    const p = Player.init(Vec3.init(0, 0, 0), true);
    const aabb = p.getAABB();

    const half_width = Player.WIDTH / 2.0;

    // Min corner
    try testing.expectApproxEqAbs(@as(f32, -half_width), aabb.min.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), aabb.min.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -half_width), aabb.min.z, 0.0001);

    // Max corner
    try testing.expectApproxEqAbs(@as(f32, half_width), aabb.max.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, Player.HEIGHT), aabb.max.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, half_width), aabb.max.z, 0.0001);
}

test "Player.getAABB at non-zero position" {
    const p = Player.init(Vec3.init(100, 50, -30), true);
    const aabb = p.getAABB();

    const half_width = Player.WIDTH / 2.0;

    try testing.expectApproxEqAbs(@as(f32, 100 - half_width), aabb.min.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 50), aabb.min.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -30 - half_width), aabb.min.z, 0.0001);

    try testing.expectApproxEqAbs(@as(f32, 100 + half_width), aabb.max.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 50 + Player.HEIGHT), aabb.max.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -30 + half_width), aabb.max.z, 0.0001);
}

test "Player.getEyePosition returns correct height" {
    const p = Player.init(Vec3.init(10, 20, 30), true);
    const eye_pos = p.getEyePosition();

    try testing.expectEqual(@as(f32, 10), eye_pos.x);
    try testing.expectEqual(@as(f32, 20 + Player.EYE_HEIGHT), eye_pos.y);
    try testing.expectEqual(@as(f32, 30), eye_pos.z);
}

test "Player.setCreativeMode enables fly mode" {
    var p = Player.init(Vec3.init(0, 0, 0), false);

    try testing.expect(!p.can_fly);
    try testing.expect(!p.fly_mode);

    p.setCreativeMode(true);

    try testing.expect(p.can_fly);
    try testing.expect(p.fly_mode);
    try testing.expect(!p.noclip);
}

test "Player.setCreativeMode disables fly mode" {
    var p = Player.init(Vec3.init(0, 0, 0), true);

    try testing.expect(p.can_fly);
    try testing.expect(p.fly_mode);

    // Enable noclip first
    p.noclip = true;

    p.setCreativeMode(false);

    try testing.expect(!p.can_fly);
    try testing.expect(!p.fly_mode);
    try testing.expect(!p.noclip);
}

test "Player.toggleNoclip only works in fly mode" {
    var p = Player.init(Vec3.init(0, 0, 0), true);

    try testing.expect(!p.noclip);

    // Should toggle on
    p.toggleNoclip();
    try testing.expect(p.noclip);

    // Should toggle off
    p.toggleNoclip();
    try testing.expect(!p.noclip);
}

test "Player.toggleNoclip does nothing when not in fly mode" {
    var p = Player.init(Vec3.init(0, 0, 0), false);

    try testing.expect(!p.noclip);
    try testing.expect(!p.fly_mode);

    p.toggleNoclip();

    // Should remain false since fly_mode is false
    try testing.expect(!p.noclip);
}

test "Player constants are reasonable values" {
    // Width should be less than 1 (to fit through 1-block gap)
    try testing.expect(Player.WIDTH < 1.0);
    try testing.expect(Player.WIDTH > 0.0);

    // Height should be reasonable
    try testing.expect(Player.HEIGHT > 1.0);
    try testing.expect(Player.HEIGHT < 3.0);

    // Eye height should be less than total height
    try testing.expect(Player.EYE_HEIGHT < Player.HEIGHT);
    try testing.expect(Player.EYE_HEIGHT > 0.0);

    // Speeds should be positive
    try testing.expect(Player.WALK_SPEED > 0.0);
    try testing.expect(Player.FLY_SPEED > 0.0);

    // Gravity should be positive
    try testing.expect(Player.GRAVITY > 0.0);

    // Jump velocity should be positive
    try testing.expect(Player.JUMP_VELOCITY > 0.0);

    // Terminal velocity magnitude should be positive
    try testing.expect(Player.TERMINAL_VELOCITY > 0.0);

    // Double tap threshold should be reasonable
    try testing.expect(Player.DOUBLE_TAP_THRESHOLD > 0.0);
    try testing.expect(Player.DOUBLE_TAP_THRESHOLD < 1.0);

    // Reach distance should be positive
    try testing.expect(Player.REACH_DISTANCE > 0.0);
}

test "Player block mutation errors are handled" {
    const FailingWorld = struct {
        set_block_calls: usize = 0,

        const VTABLE = IWorld.VTable{
            .update = update,
            .render = render,
            .renderOpaque = render,
            .renderFluid = render,
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

        fn interface(self: *@This()) IWorldSimulation {
            return .{ .world = .{ .ptr = self, .vtable = &VTABLE } };
        }

        fn update(_: *anyopaque, _: Vec3, _: f32) anyerror!void {}
        fn render(_: *anyopaque, _: @import("engine-math").Mat4, _: Vec3, _: bool) void {}
        fn deinit(_: *anyopaque) void {}
        fn getRenderStats(_: *anyopaque) @import("world-runtime").RenderStats {
            return .{};
        }
        fn getStats(_: *anyopaque) @import("world-runtime").WorldStatsData {
            return .{ .chunks_loaded = 0, .total_vertices = 0, .gen_queue = 0, .mesh_queue = 0, .upload_queue = 0 };
        }
        fn getLODStats(_: *anyopaque) ?@import("world-lod").LODStats {
            return null;
        }
        fn isLODEnabled(_: *anyopaque) bool {
            return false;
        }
        fn shadowScene(_: *anyopaque) @import("engine-rhi").IShadowScene {
            return undefined;
        }
        fn enableSaveManager(_: *anyopaque, _: []const u8, _: []const u8) anyerror!void {}
        fn takeSaveFailureWarningCount(_: *anyopaque) usize {
            return 0;
        }
        fn pauseGeneration(_: *anyopaque) void {}
        fn isPaused(_: *anyopaque) bool {
            return false;
        }
        fn collisionWorld(_: *anyopaque) @import("engine-physics").VoxelCollisionWorld {
            return undefined;
        }
        fn getBlock(_: *anyopaque, _: i32, _: i32, _: i32) BlockType {
            return .stone;
        }
        fn setBlock(ptr: *anyopaque, _: i32, _: i32, _: i32, _: BlockType) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.set_block_calls += 1;
            return error.TestExpectedError;
        }
        fn getColumnInfo(_: *anyopaque, _: i32, _: i32) @import("world-worldgen").ColumnInfo {
            return undefined;
        }
        fn getDebugLightInfo(_: *anyopaque, _: i32, _: i32, _: i32) ?@import("world-runtime").DebugLightInfo {
            return null;
        }
        fn getRegionInfo(_: *anyopaque, _: i32, _: i32) @import("world-worldgen").RegionInfo {
            return undefined;
        }
        fn getGenerator(_: *anyopaque) @import("world-worldgen").Generator {
            return undefined;
        }
        fn getGeneratorName(_: *anyopaque) []const u8 {
            return "failing";
        }
        fn getRenderDistance(_: *anyopaque) i32 {
            return 0;
        }
        fn setRenderDistance(_: *anyopaque, _: i32) void {}
        fn getHorizonDistance(_: *anyopaque) i32 {
            return 0;
        }
        fn setHorizonDistance(_: *anyopaque, _: i32) void {}
        fn isLODRenderingEnabled(_: *anyopaque) bool {
            return false;
        }
        fn toggleLODRendering(_: *anyopaque) bool {
            return false;
        }
        fn getChunkStateCounts(_: *anyopaque) @import("world-core").ChunkStateCounts {
            return .{};
        }
        fn isStartupBusy(_: *anyopaque) bool {
            return false;
        }
        fn getWorldStateData(_: *anyopaque) @import("world-core").WorldStateData {
            return .{ .generator_name = "failing", .seed = 0, .gen_queue = 0, .mesh_queue = 0, .upload_queue = 0 };
        }
        fn lpvWorld(_: *anyopaque) @import("engine-rhi").ILPVWorld {
            return undefined;
        }
        fn graphicsRenderView(ptr: *anyopaque) @import("engine-rhi").IWorldRenderView {
            return .{ .ptr = ptr, .vtable = &.{ .render = render, .renderOpaque = render, .renderFluid = render } };
        }
        fn getGpuMeshDispatch(_: *anyopaque) @import("world-runtime").GpuMeshDispatch {
            return .{ .dispatch_fn = null, .dispatch_ctx = null };
        }

        fn isGpuCullingEnabled(_: *anyopaque) bool {
            return false;
        }
    };

    var world = FailingWorld{};
    var player = Player.init(Vec3.init(0, 10, 0), true);
    player.target_block = .{ .x = 1, .y = 2, .z = 3, .face = Face.east, .distance = 1.0 };

    player.breakTargetBlock(world.interface());
    try testing.expectEqual(@as(usize, 1), world.set_block_calls);
}
