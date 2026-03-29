const std = @import("std");
const testing = std.testing;
const Vec3 = @import("zig-math").Vec3;
const player_module = @import("player.zig");
const Player = player_module.Player;

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
