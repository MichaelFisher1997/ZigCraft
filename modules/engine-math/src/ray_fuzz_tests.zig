const std = @import("std");
const math = @import("zig-math");
const ray = @import("ray.zig");

const Vec3 = math.Vec3;
const AABB = math.AABB;

test "fuzz corpus: AABB slab intersections handle boundary and parallel rays" {
    const box = AABB.init(Vec3.init(0, 0, 0), Vec3.init(1, 1, 1));
    const cases = [_]struct {
        origin: Vec3,
        direction: Vec3,
        should_hit: bool,
    }{
        .{ .origin = Vec3.init(-1, 0.5, 0.5), .direction = Vec3.init(1, 0, 0), .should_hit = true },
        .{ .origin = Vec3.init(0, 0.5, 0.5), .direction = Vec3.init(1, 0, 0), .should_hit = true },
        .{ .origin = Vec3.init(1, 0.5, 0.5), .direction = Vec3.init(1, 0, 0), .should_hit = true },
        .{ .origin = Vec3.init(0.5, 2, 0.5), .direction = Vec3.init(1, 0, 0), .should_hit = false },
        .{ .origin = Vec3.init(0.5, 0.5, -4), .direction = Vec3.init(0, 0, 1), .should_hit = true },
        .{ .origin = Vec3.init(0.5, 0.5, 4), .direction = Vec3.init(0, 0, -1), .should_hit = true },
        .{ .origin = Vec3.init(2, 2, 2), .direction = Vec3.init(0, 1, 0), .should_hit = false },
    };

    for (cases) |case| {
        const hit = ray.intersectAABB(ray.Ray.init(case.origin, case.direction), box);
        try std.testing.expectEqual(case.should_hit, hit != null);
        if (hit) |h| {
            try std.testing.expect(std.math.isFinite(h.t));
            try std.testing.expect(h.t >= 0);
        }
    }
}

test "fuzz corpus: voxel raycast edge cases stay bounded" {
    const Context = struct {
        pub fn isSolid(_: @This(), x: i32, y: i32, z: i32) bool {
            return x == 2 and y == 0 and z == 0;
        }
    };

    const cases = [_]struct {
        origin: Vec3,
        direction: Vec3,
        max_distance: f32,
        expect_hit: bool,
    }{
        .{ .origin = Vec3.init(0, 0, 0), .direction = Vec3.init(1, 0, 0), .max_distance = 4, .expect_hit = true },
        .{ .origin = Vec3.init(0.9999, 0, 0), .direction = Vec3.init(1, 0, 0), .max_distance = 4, .expect_hit = true },
        .{ .origin = Vec3.init(0, 0, 0), .direction = Vec3.init(0, 1, 0), .max_distance = 4, .expect_hit = false },
        .{ .origin = Vec3.init(-2, 0, 0), .direction = Vec3.init(1, 0, 0), .max_distance = 3.9, .expect_hit = true },
        .{ .origin = Vec3.init(-2, 0, 0), .direction = Vec3.init(1, 0, 0), .max_distance = 1.9, .expect_hit = false },
    };

    for (cases) |case| {
        const hit = ray.castThroughVoxels(case.origin, case.direction, case.max_distance, Context, .{}, Context.isSolid);
        try std.testing.expectEqual(case.expect_hit, hit != null);
        if (hit) |h| try std.testing.expect(h.distance <= case.max_distance);
    }
}
