const std = @import("std");
const testing = std.testing;
const voxel = @import("voxel.zig");
const Face = voxel.Face;

test "Face.getShade returns correct values per face" {
    try testing.expectApproxEqAbs(@as(f32, 1.0), Face.top.getShade(), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.5), Face.bottom.getShade(), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), Face.north.getShade(), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), Face.south.getShade(), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), Face.east.getShade(), 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.7), Face.west.getShade(), 0.0001);
}

test "Face.getNormal returns correct normals" {
    try testing.expectEqual([3]i8{ 0, 1, 0 }, Face.top.getNormal());
    try testing.expectEqual([3]i8{ 0, -1, 0 }, Face.bottom.getNormal());
    try testing.expectEqual([3]i8{ 0, 0, -1 }, Face.north.getNormal());
    try testing.expectEqual([3]i8{ 0, 0, 1 }, Face.south.getNormal());
    try testing.expectEqual([3]i8{ 1, 0, 0 }, Face.east.getNormal());
    try testing.expectEqual([3]i8{ -1, 0, 0 }, Face.west.getNormal());
}

test "Face.getOffset returns integer offsets matching normals" {
    try testing.expectEqual(Face.top.getOffset(), .{ .x = 0, .y = 1, .z = 0 });
    try testing.expectEqual(Face.bottom.getOffset(), .{ .x = 0, .y = -1, .z = 0 });
    try testing.expectEqual(Face.north.getOffset(), .{ .x = 0, .y = 0, .z = -1 });
    try testing.expectEqual(Face.south.getOffset(), .{ .x = 0, .y = 0, .z = 1 });
    try testing.expectEqual(Face.east.getOffset(), .{ .x = 1, .y = 0, .z = 0 });
    try testing.expectEqual(Face.west.getOffset(), .{ .x = -1, .y = 0, .z = 0 });
}

test "ALL_FACES contains exactly six distinct faces" {
    try testing.expectEqual(@as(usize, 6), voxel.ALL_FACES.len);
    var seen = std.EnumArray(Face, bool).initEmpty();
    for (voxel.ALL_FACES) |f| {
        seen.set(f, true);
    }
    for (comptime std.enums.values(Face)) |f| {
        try testing.expect(seen.get(f));
    }
}

test "Mat4.multiply identity preserves matrix" {
    const Mat4 = @import("mat4.zig").Mat4;
    const m = Mat4.identity;
    const result = Mat4.multiply(m, m);
    try testing.expectApproxEqAbs(@as(f32, 1), result.data[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), result.data[1][1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), result.data[2][2], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), result.data[3][3], 0.0001);
}

test "Mat4.multiply translate then rotate produces correct transform" {
    const Mat4 = @import("mat4.zig").Mat4;
    const Vec3 = @import("vec3.zig").Vec3;
    const translate = Mat4.translate(Vec3.init(5, 0, 0));
    const rotate = Mat4.rotateY(std.math.pi / 2.0);
    const combined = Mat4.multiply(rotate, translate);
    const point = combined.transformPoint(Vec3.zero);
    try testing.expectApproxEqAbs(@as(f32, 0), point.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), point.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -5), point.z, 0.0001);
}

test "Mat4.transformPoint with w=1 does not divide" {
    const Mat4 = @import("mat4.zig").Mat4;
    const Vec3 = @import("vec3.zig").Vec3;
    const m = Mat4.identity;
    const result = m.transformPoint(Vec3.init(1, 2, 3));
    try testing.expectApproxEqAbs(@as(f32, 1), result.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2), result.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 3), result.z, 0.0001);
}

test "Mat4.inverse of singular matrix returns identity" {
    const Mat4 = @import("mat4.zig").Mat4;
    const singular = Mat4.zero;
    const inv = singular.inverse();
    try testing.expectApproxEqAbs(@as(f32, 1), inv.data[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), inv.data[1][1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), inv.data[2][2], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), inv.data[3][3], 0.0001);
}

test "Mat4.rotateY 90 degrees maps +X to -Z" {
    const Mat4 = @import("mat4.zig").Mat4;
    const Vec3 = @import("vec3.zig").Vec3;
    const rot = Mat4.rotateY(std.math.pi / 2.0);
    const v = Vec3.init(1, 0, 0);
    const transformed = rot.transformDirection(v);
    try testing.expectApproxEqAbs(@as(f32, 0), transformed.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), transformed.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, -1), transformed.z, 0.0001);
}
