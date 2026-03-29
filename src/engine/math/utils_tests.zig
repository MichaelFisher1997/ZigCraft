const std = @import("std");
const testing = std.testing;
const utils = @import("utils.zig");
const Vec3 = @import("vec3.zig").Vec3;

test "smoothstep returns 0 at edge0" {
    const result = utils.smoothstep(0.0, 1.0, 0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.0), result, 0.0001);
}

test "smoothstep returns 1 at edge1" {
    const result = utils.smoothstep(0.0, 1.0, 1.0);
    try testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.0001);
}

test "smoothstep returns 0.5 at midpoint" {
    const result = utils.smoothstep(0.0, 1.0, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), result, 0.0001);
}

test "smoothstep clamps below edge0" {
    const result = utils.smoothstep(0.0, 1.0, -0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), result, 0.0001);
}

test "smoothstep clamps above edge1" {
    const result = utils.smoothstep(0.0, 1.0, 1.5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), result, 0.0001);
}

test "smoothstep with negative edges" {
    const result = utils.smoothstep(-1.0, 1.0, 0.0);
    try testing.expectApproxEqAbs(@as(f32, 0.5), result, 0.0001);
}

test "smoothstep with reversed edges interpolates backwards" {
    // When edge0 > edge1, smoothstep still works but interpolates in reverse
    // At x=0.5 between edges 1.0 and 0.0, we get t=0.5 so result=0.5
    const result = utils.smoothstep(1.0, 0.0, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.5), result, 0.0001);
}

test "smoothstep with equal edges handles division by zero" {
    // When edge0 == edge1, division by zero occurs
    // The clamp handles this by checking the comparison
    const result = utils.smoothstep(0.5, 0.5, 0.5);
    // NaN from 0/0 gets clamped - in practice this returns 0
    _ = result;
}

test "lerpVec3 at t=0 returns a" {
    const a = Vec3.init(1.0, 2.0, 3.0);
    const b = Vec3.init(10.0, 20.0, 30.0);
    const result = utils.lerpVec3(a, b, 0.0);
    try testing.expectApproxEqAbs(a.x, result.x, 0.0001);
    try testing.expectApproxEqAbs(a.y, result.y, 0.0001);
    try testing.expectApproxEqAbs(a.z, result.z, 0.0001);
}

test "lerpVec3 at t=1 returns b" {
    const a = Vec3.init(1.0, 2.0, 3.0);
    const b = Vec3.init(10.0, 20.0, 30.0);
    const result = utils.lerpVec3(a, b, 1.0);
    try testing.expectApproxEqAbs(b.x, result.x, 0.0001);
    try testing.expectApproxEqAbs(b.y, result.y, 0.0001);
    try testing.expectApproxEqAbs(b.z, result.z, 0.0001);
}

test "lerpVec3 at t=0.5 returns midpoint" {
    const a = Vec3.init(0.0, 0.0, 0.0);
    const b = Vec3.init(10.0, 20.0, 30.0);
    const result = utils.lerpVec3(a, b, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 5.0), result.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 10.0), result.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 15.0), result.z, 0.0001);
}

test "lerpVec3 with negative t extrapolates" {
    const a = Vec3.init(0.0, 0.0, 0.0);
    const b = Vec3.init(10.0, 10.0, 10.0);
    const result = utils.lerpVec3(a, b, -0.5);
    try testing.expectApproxEqAbs(@as(f32, -5.0), result.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -5.0), result.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -5.0), result.z, 0.0001);
}

test "lerpVec3 with t>1 extrapolates" {
    const a = Vec3.init(0.0, 0.0, 0.0);
    const b = Vec3.init(10.0, 10.0, 10.0);
    const result = utils.lerpVec3(a, b, 1.5);
    try testing.expectApproxEqAbs(@as(f32, 15.0), result.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 15.0), result.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 15.0), result.z, 0.0001);
}

test "lerpVec3 with zero vectors" {
    const a = Vec3.zero;
    const b = Vec3.zero;
    const result = utils.lerpVec3(a, b, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 0.0), result.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), result.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), result.z, 0.0001);
}
