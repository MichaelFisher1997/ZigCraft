const std = @import("std");
const testing = std.testing;
const Frustum = @import("frustum.zig").Frustum;
const Plane = @import("frustum.zig").Plane;
const Vec3 = @import("vec3.zig").Vec3;
const Mat4 = @import("mat4.zig").Mat4;
const AABB = @import("zig-math").AABB;

test "Frustum containsPoint returns true for point inside" {
    const vp = Mat4.identity;
    const frustum = Frustum.fromViewProj(vp);
    try testing.expect(frustum.containsPoint(Vec3.init(0, 0, 0)));
}

test "Frustum containsPoint returns false for point behind camera" {
    const view = Mat4.lookAt(Vec3.init(0, 0, 0), Vec3.init(0, 0, -1), Vec3.init(0, 1, 0));
    const proj = Mat4.perspective(std.math.pi / 4.0, 16.0 / 9.0, 0.1, 100.0);
    const vp = proj.multiply(view);
    const frustum = Frustum.fromViewProj(vp);
    try testing.expect(!frustum.containsPoint(Vec3.init(0, 0, 50)));
}

test "Frustum intersectsAABB returns true for AABB intersecting frustum" {
    const frustum = Frustum.fromViewProj(Mat4.identity);
    const aabb = AABB.init(Vec3.init(-1, -1, -1), Vec3.init(1, 1, 1));
    const result = frustum.intersectsAABB(aabb);
    try testing.expect(result);
}

test "Frustum intersectsAABB returns false for AABB completely outside" {
    const p = Mat4.perspective(std.math.pi / 4.0, 16.0 / 9.0, 0.1, 100.0);
    const frustum = Frustum.fromViewProj(p);
    const aabb = AABB.init(Vec3.init(-200, -200, -200), Vec3.init(-100, -100, -100));
    try testing.expect(!frustum.intersectsAABB(aabb));
}

test "Frustum intersectsChunk returns true for chunk near origin" {
    const frustum = Frustum.fromViewProj(Mat4.identity);
    try testing.expect(frustum.intersectsChunk(0, 0));
}

test "Frustum intersectsChunk returns false for distant chunk" {
    const p = Mat4.perspective(std.math.pi / 4.0, 16.0 / 9.0, 0.1, 100.0);
    const frustum = Frustum.fromViewProj(p);
    try testing.expect(!frustum.intersectsChunk(100, 100));
}

test "Plane init and signedDistance" {
    const plane = Plane.init(Vec3.init(0, 0, 1), 0);
    try testing.expectEqual(@as(f32, 5), plane.signedDistance(Vec3.init(0, 0, 5)));
    try testing.expectEqual(@as(f32, -3), plane.signedDistance(Vec3.init(0, 0, -3)));
    try testing.expectEqual(@as(f32, 0), plane.signedDistance(Vec3.init(0, 0, 0)));
}

test "Plane normalize preserves distance ratio" {
    const plane = Plane.init(Vec3.init(0, 0, 2), 4);
    const normalized = plane.normalize();
    try testing.expectApproxEqAbs(@as(f32, 1), normalized.normal.z, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2), normalized.distance, 0.0001);
}
