const std = @import("std");
const testing = std.testing;
const Mat4 = @import("mat4.zig").Mat4;
const Vec3 = @import("vec3.zig").Vec3;

test "Mat4 rotateX" {
    const rot = Mat4.rotateX(std.math.pi / 2.0);
    const v = Vec3.init(0, 1, 0);
    const rotated = rot.transformDirection(v);
    try testing.expectApproxEqAbs(@as(f32, 0), rotated.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), rotated.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), rotated.z, 0.0001);
}

test "Mat4 rotateZ" {
    const rot = Mat4.rotateZ(std.math.pi / 2.0);
    const v = Vec3.init(1, 0, 0);
    const rotated = rot.transformDirection(v);
    try testing.expectApproxEqAbs(@as(f32, 0), rotated.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), rotated.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), rotated.z, 0.0001);
}

test "Mat4 lookAt facing +Z" {
    const view = Mat4.lookAt(
        Vec3.init(0, 0, 5),
        Vec3.init(0, 0, 0),
        Vec3.init(0, 1, 0),
    );
    const forward = Vec3.init(0, 0, -1);
    const transformed = view.transformDirection(forward);
    try testing.expectApproxEqAbs(@as(f32, 0), transformed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), transformed.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -1), transformed.z, 0.0001);
}

test "Mat4 lookAt preserves length" {
    const view = Mat4.lookAt(
        Vec3.init(5, 5, 5),
        Vec3.init(0, 0, 0),
        Vec3.init(0, 1, 0),
    );
    const v = Vec3.init(1, 0, 0);
    const rotated = view.transformDirection(v);
    try testing.expectApproxEqAbs(@as(f32, 1), rotated.length(), 0.0001);
}

test "Mat4 lookAt handles looking straight up (+Y)" {
    const view = Mat4.lookAt(
        Vec3.init(0, 0, 0),
        Vec3.init(0, 5, 0),
        Vec3.init(0, 1, 0),
    );
    // Forward axis (Z column) should map the +Y forward to -Z, not collapse to zero.
    const fwd_col = Vec3.init(view.data[0][2], view.data[1][2], view.data[2][2]);
    try testing.expectApproxEqAbs(@as(f32, 1), fwd_col.length(), 0.0001);
    // Right axis (X column) should be a unit-length vector.
    const right_col = Vec3.init(view.data[0][0], view.data[1][0], view.data[2][0]);
    try testing.expectApproxEqAbs(@as(f32, 1), right_col.length(), 0.0001);
    // Up axis (Y column) should be a unit-length vector.
    const up_col = Vec3.init(view.data[0][1], view.data[1][1], view.data[2][1]);
    try testing.expectApproxEqAbs(@as(f32, 1), up_col.length(), 0.0001);
}

test "Mat4 lookAt handles looking straight down (-Y)" {
    const view = Mat4.lookAt(
        Vec3.init(0, 5, 0),
        Vec3.init(0, 0, 0),
        Vec3.init(0, 1, 0),
    );
    const fwd_col = Vec3.init(view.data[0][2], view.data[1][2], view.data[2][2]);
    try testing.expectApproxEqAbs(@as(f32, 1), fwd_col.length(), 0.0001);
    const right_col = Vec3.init(view.data[0][0], view.data[1][0], view.data[2][0]);
    try testing.expectApproxEqAbs(@as(f32, 1), right_col.length(), 0.0001);
    const up_col = Vec3.init(view.data[0][1], view.data[1][1], view.data[2][1]);
    try testing.expectApproxEqAbs(@as(f32, 1), up_col.length(), 0.0001);
}

test "Mat4 lookAt degenerate produces orthonormal axes" {
    // Forward parallel to world_up should still produce an orthonormal basis.
    const view = Mat4.lookAt(
        Vec3.init(1, 2, 3),
        Vec3.init(1, 5, 3),
        Vec3.init(0, 1, 0),
    );
    const right_col = Vec3.init(view.data[0][0], view.data[1][0], view.data[2][0]);
    const up_col = Vec3.init(view.data[0][1], view.data[1][1], view.data[2][1]);
    const fwd_col = Vec3.init(view.data[0][2], view.data[1][2], view.data[2][2]);
    // Each axis should be unit-length.
    try testing.expectApproxEqAbs(@as(f32, 1), right_col.length(), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), up_col.length(), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), fwd_col.length(), 0.0001);
    // Axes should be mutually orthogonal.
    try testing.expectApproxEqAbs(@as(f32, 0), right_col.dot(up_col), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), right_col.dot(fwd_col), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), up_col.dot(fwd_col), 0.0001);
}

test "Mat4 orthographic creates correct matrix" {
    const ortho = Mat4.orthographic(-10, 10, -10, 10, -100, 100);
    try testing.expectEqual(@as(f32, 0.1), ortho.data[0][0]);
    try testing.expectEqual(@as(f32, 0.1), ortho.data[1][1]);
    try testing.expectEqual(@as(f32, -0.01), ortho.data[2][2]);
}

test "Mat4 perspectiveReverseZ structure" {
    const p = Mat4.perspectiveReverseZ(std.math.pi / 4.0, 16.0 / 9.0, 0.1, 100.0);
    try testing.expectEqual(@as(f32, -1), p.data[2][3]);
    try testing.expectEqual(@as(f32, 0), p.data[3][3]);
}

test "Mat4 rotateX at 0 degrees returns identity direction" {
    const rot = Mat4.rotateX(0);
    const v = Vec3.init(0, 1, 0);
    const rotated = rot.transformDirection(v);
    try testing.expectApproxEqAbs(@as(f32, 0), rotated.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), rotated.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), rotated.z, 0.0001);
}

test "Mat4 ptr returns valid pointer to data" {
    const m = Mat4.identity;
    const ptr = m.ptr();
    try testing.expectEqual(@as(f32, 1), ptr[0]);
    try testing.expectEqual(@as(f32, 0), ptr[1]);
}
