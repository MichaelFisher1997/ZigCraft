const std = @import("std");
const testing = std.testing;
const Vec3 = @import("zig-math").Vec3;
const AABB = @import("zig-math").AABB;
const collision = @import("engine-physics");
const VoxelCollisionWorld = collision.VoxelCollisionWorld;
const CollisionConfig = collision.CollisionConfig;

pub const std_options: std.Options = .{ .log_level = .err };

/// Mock voxel world used to drive collision resolution without a real World.
///
/// Geometry is configured declaratively:
///   - `floor`: when true, every block with `y < 0` is solid (flat ground at y=0).
///   - `wall_x`/`wall_z`: an optional full-height wall spanning the entire column
///     at the given x or z coordinate (so wall collision can be tested in
///     isolation from floor placement).
const MockWorld = struct {
    floor: bool = false,
    wall_x: ?i32 = null,
    wall_z: ?i32 = null,

    fn interface(self: *MockWorld) VoxelCollisionWorld {
        return .{ .ptr = self, .vtable = &VTABLE };
    }

    const VTABLE = VoxelCollisionWorld.VTable{ .isSolidAt = isSolidAt };

    fn isSolidAt(ptr: *anyopaque, x: i32, y: i32, z: i32) bool {
        const self: *MockWorld = @ptrCast(@alignCast(ptr));
        if (self.floor and y < 0) return true;
        if (self.wall_x) |wx| {
            if (x == wx) return true;
        }
        if (self.wall_z) |wz| {
            if (z == wz) return true;
        }
        return false;
    }
};

test "moveAndCollide lands on floor with default config" {
    var world = MockWorld{ .floor = true };
    const aabb = AABB.fromCenterSize(Vec3.init(5, 5, 5), Vec3.init(1, 1, 1));

    // Fall straight down at 5 blocks/sec for 1 second.
    const result = collision.moveAndCollide(
        world.interface(),
        aabb,
        Vec3.init(0, -5, 0),
        1.0,
        .{},
    );

    // AABB bottom rests on the floor surface (y=0), so center is at ~0.5.
    try testing.expect(result.grounded);
    try testing.expect(!result.hit_wall);
    try testing.expect(!result.hit_ceiling);
    try testing.expectApproxEqAbs(@as(f32, 0.5), result.position.y, 0.01);
    try testing.expectEqual(@as(f32, 0), result.velocity.y);
}

test "moveAndCollide honors max_iterations for binary search precision" {
    // Same scenario as above, but the binary search converges to the surface
    // (y ~= 0.5) only when given enough iterations. With max_iterations = 2 it
    // bails out far above the floor (y ~= 1.25), proving the field is consulted.
    var world = MockWorld{ .floor = true };
    const aabb = AABB.fromCenterSize(Vec3.init(5, 5, 5), Vec3.init(1, 1, 1));

    const low_iter = collision.moveAndCollide(
        world.interface(),
        aabb,
        Vec3.init(0, -5, 0),
        1.0,
        .{ .max_iterations = 2 },
    );
    const high_iter = collision.moveAndCollide(
        world.interface(),
        aabb,
        Vec3.init(0, -5, 0),
        1.0,
        .{ .max_iterations = 16 },
    );

    // Low iteration count stops well short of the true surface.
    try testing.expect(low_iter.grounded);
    try testing.expect(low_iter.position.y > 1.0);

    // High iteration count converges close to the surface.
    try testing.expect(high_iter.grounded);
    try testing.expectApproxEqAbs(@as(f32, 0.5), high_iter.position.y, 0.01);

    // The two results must differ meaningfully.
    try testing.expect(high_iter.position.y < low_iter.position.y);
    try testing.expect((low_iter.position.y - high_iter.position.y) > 0.5);
}

test "moveAndCollide resolves X-axis wall collision" {
    // Wall block at x=2 occupies x in [2,3], y in [0,1]. Player approaching
    // from +x must stop with AABB min.x == block max.x (center_x ~= 3.5).
    var world = MockWorld{ .wall_x = 2 };
    const aabb = AABB.fromCenterSize(Vec3.init(5, 5, 5), Vec3.init(1, 1, 1));

    const result = collision.moveAndCollide(
        world.interface(),
        aabb,
        Vec3.init(-3, 0, 0),
        1.0,
        .{},
    );

    try testing.expect(result.hit_wall);
    try testing.expect(!result.grounded);
    try testing.expectEqual(@as(f32, 0), result.velocity.x);
    try testing.expectApproxEqAbs(@as(f32, 3.5), result.position.x, 0.01);
    // Y and Z should be unchanged.
    try testing.expectApproxEqAbs(@as(f32, 5), result.position.y, 0.001);
    try testing.expectApproxEqAbs(@as(f32, 5), result.position.z, 0.001);
}
