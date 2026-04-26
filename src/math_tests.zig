const std = @import("std");
const testing = std.testing;

const Vec3 = @import("zig-math").Vec3;
const Mat4 = @import("zig-math").Mat4;
const AABB = @import("zig-math").AABB;
const Frustum = @import("zig-math").Frustum;
const Plane = @import("zig-math").Plane;

pub const std_options: std.Options = .{
    .log_level = .err,
};

test "Vec3 addition" {
    const a = Vec3.init(1, 2, 3);
    const b = Vec3.init(4, 5, 6);
    const c = a.add(b);
    try testing.expectEqual(@as(f32, 5), c.x);
    try testing.expectEqual(@as(f32, 7), c.y);
    try testing.expectEqual(@as(f32, 9), c.z);
}

test "Vec3 subtraction" {
    const a = Vec3.init(5, 7, 9);
    const b = Vec3.init(1, 2, 3);
    const c = a.sub(b);
    try testing.expectEqual(@as(f32, 4), c.x);
    try testing.expectEqual(@as(f32, 5), c.y);
    try testing.expectEqual(@as(f32, 6), c.z);
}

test "Vec3 scaling" {
    const a = Vec3.init(1, 2, 3);
    const b = a.scale(2.0);
    try testing.expectEqual(@as(f32, 2), b.x);
    try testing.expectEqual(@as(f32, 4), b.y);
    try testing.expectEqual(@as(f32, 6), b.z);
}

test "Vec3 dot product" {
    const a = Vec3.init(1, 0, 0);
    const b = Vec3.init(0, 1, 0);
    try testing.expectEqual(@as(f32, 0), a.dot(b));

    const c = Vec3.init(2, 0, 0);
    try testing.expectEqual(@as(f32, 2), a.dot(c));

    const d = Vec3.init(1, 2, 3);
    const e = Vec3.init(4, 5, 6);
    try testing.expectEqual(@as(f32, 32), d.dot(e));
}

test "Vec3 cross product" {
    const x = Vec3.init(1, 0, 0);
    const y = Vec3.init(0, 1, 0);
    const z = x.cross(y);
    try testing.expectEqual(@as(f32, 0), z.x);
    try testing.expectEqual(@as(f32, 0), z.y);
    try testing.expectEqual(@as(f32, 1), z.z);

    const neg_z = y.cross(x);
    try testing.expectEqual(@as(f32, -1), neg_z.z);
}

test "Vec3 length and lengthSquared" {
    const v = Vec3.init(3, 4, 0);
    try testing.expectEqual(@as(f32, 25), v.lengthSquared());
    try testing.expectEqual(@as(f32, 5), v.length());

    const v2 = Vec3.init(1, 2, 2);
    try testing.expectEqual(@as(f32, 9), v2.lengthSquared());
    try testing.expectEqual(@as(f32, 3), v2.length());
}

test "Vec3 normalize" {
    const v = Vec3.init(3, 4, 0);
    const n = v.normalize();
    try testing.expectApproxEqAbs(@as(f32, 0.6), n.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.8), n.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), n.z, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), n.length(), 0.0001);

    const zero = Vec3.zero.normalize();
    try testing.expectEqual(@as(f32, 0), zero.x);
    try testing.expectEqual(@as(f32, 0), zero.y);
    try testing.expectEqual(@as(f32, 0), zero.z);
}

test "Vec3 negate" {
    const v = Vec3.init(1, -2, 3);
    const neg = v.negate();
    try testing.expectEqual(@as(f32, -1), neg.x);
    try testing.expectEqual(@as(f32, 2), neg.y);
    try testing.expectEqual(@as(f32, -3), neg.z);
}

test "Vec3 lerp" {
    const a = Vec3.init(0, 0, 0);
    const b = Vec3.init(10, 20, 30);

    const mid = a.lerp(b, 0.5);
    try testing.expectEqual(@as(f32, 5), mid.x);
    try testing.expectEqual(@as(f32, 10), mid.y);
    try testing.expectEqual(@as(f32, 15), mid.z);

    const start = a.lerp(b, 0);
    try testing.expectEqual(a.x, start.x);

    const end = a.lerp(b, 1);
    try testing.expectEqual(b.x, end.x);
}

test "Vec3 distance" {
    const a = Vec3.init(0, 0, 0);
    const b = Vec3.init(3, 4, 0);
    try testing.expectEqual(@as(f32, 5), a.distance(b));
}

test "Vec3 constants" {
    try testing.expectEqual(@as(f32, 0), Vec3.zero.x);
    try testing.expectEqual(@as(f32, 1), Vec3.one.x);
    try testing.expectEqual(@as(f32, 1), Vec3.up.y);
    try testing.expectEqual(@as(f32, -1), Vec3.down.y);
    try testing.expectEqual(@as(f32, 1), Vec3.right.x);
    try testing.expectEqual(@as(f32, -1), Vec3.left.x);
}

test "Mat4 identity" {
    const id = Mat4.identity;
    try testing.expectEqual(@as(f32, 1), id.data[0][0]);
    try testing.expectEqual(@as(f32, 1), id.data[1][1]);
    try testing.expectEqual(@as(f32, 1), id.data[2][2]);
    try testing.expectEqual(@as(f32, 1), id.data[3][3]);
    try testing.expectEqual(@as(f32, 0), id.data[0][1]);
    try testing.expectEqual(@as(f32, 0), id.data[1][0]);
}

test "Mat4 multiply identity" {
    const id = Mat4.identity;
    const result = id.multiply(id);
    try testing.expectEqual(@as(f32, 1), result.data[0][0]);
    try testing.expectEqual(@as(f32, 1), result.data[1][1]);
    try testing.expectEqual(@as(f32, 0), result.data[0][1]);
}

test "Mat4 translate" {
    const t = Mat4.translate(Vec3.init(5, 10, 15));
    try testing.expectEqual(@as(f32, 5), t.data[3][0]);
    try testing.expectEqual(@as(f32, 10), t.data[3][1]);
    try testing.expectEqual(@as(f32, 15), t.data[3][2]);

    const point = Vec3.init(1, 2, 3);
    const transformed = t.transformPoint(point);
    try testing.expectEqual(@as(f32, 6), transformed.x);
    try testing.expectEqual(@as(f32, 12), transformed.y);
    try testing.expectEqual(@as(f32, 18), transformed.z);
}

test "Mat4 scale" {
    const s = Mat4.scale(Vec3.init(2, 3, 4));
    try testing.expectEqual(@as(f32, 2), s.data[0][0]);
    try testing.expectEqual(@as(f32, 3), s.data[1][1]);
    try testing.expectEqual(@as(f32, 4), s.data[2][2]);

    const point = Vec3.init(1, 1, 1);
    const scaled = s.transformPoint(point);
    try testing.expectEqual(@as(f32, 2), scaled.x);
    try testing.expectEqual(@as(f32, 3), scaled.y);
    try testing.expectEqual(@as(f32, 4), scaled.z);
}

test "Mat4 transformDirection ignores translation" {
    const t = Mat4.translate(Vec3.init(100, 200, 300));
    const dir = Vec3.init(1, 0, 0);
    const transformed = t.transformDirection(dir);
    try testing.expectEqual(@as(f32, 1), transformed.x);
    try testing.expectEqual(@as(f32, 0), transformed.y);
    try testing.expectEqual(@as(f32, 0), transformed.z);
}

test "Mat4 inverse of identity" {
    const id = Mat4.identity;
    const inv = id.inverse();
    try testing.expectApproxEqAbs(@as(f32, 1), inv.data[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), inv.data[1][1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), inv.data[0][1], 0.0001);
}

test "Mat4 inverse multiplied by original gives identity" {
    const s = Mat4.scale(Vec3.init(2, 3, 4));
    const inv = s.inverse();
    const product = s.multiply(inv);

    try testing.expectApproxEqAbs(@as(f32, 1), product.data[0][0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), product.data[1][1], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), product.data[2][2], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1), product.data[3][3], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0), product.data[0][1], 0.0001);
}

test "Mat4 rotation preserves length" {
    const rot = Mat4.rotateY(std.math.pi / 4.0);
    const v = Vec3.init(1, 0, 0);
    const rotated = rot.transformDirection(v);
    try testing.expectApproxEqAbs(@as(f32, 1), rotated.length(), 0.0001);
}

test "Mat4 perspective has correct structure" {
    const p = Mat4.perspective(std.math.pi / 4.0, 16.0 / 9.0, 0.1, 1000.0);
    try testing.expectEqual(@as(f32, -1), p.data[2][3]);
    try testing.expectEqual(@as(f32, 0), p.data[3][3]);
}

test "AABB init and accessors" {
    const aabb = AABB.init(Vec3.init(0, 0, 0), Vec3.init(10, 20, 30));
    try testing.expectEqual(@as(f32, 0), aabb.min.x);
    try testing.expectEqual(@as(f32, 30), aabb.max.z);

    const center = aabb.center();
    try testing.expectEqual(@as(f32, 5), center.x);
    try testing.expectEqual(@as(f32, 10), center.y);
    try testing.expectEqual(@as(f32, 15), center.z);

    const size = aabb.size();
    try testing.expectEqual(@as(f32, 10), size.x);
    try testing.expectEqual(@as(f32, 20), size.y);
    try testing.expectEqual(@as(f32, 30), size.z);
}

test "AABB fromCenterSize" {
    const aabb = AABB.fromCenterSize(Vec3.init(5, 5, 5), Vec3.init(10, 10, 10));
    try testing.expectEqual(@as(f32, 0), aabb.min.x);
    try testing.expectEqual(@as(f32, 10), aabb.max.x);
}

test "AABB contains point" {
    const aabb = AABB.init(Vec3.init(0, 0, 0), Vec3.init(10, 10, 10));

    try testing.expect(aabb.contains(Vec3.init(5, 5, 5)));
    try testing.expect(aabb.contains(Vec3.init(0, 0, 0)));
    try testing.expect(aabb.contains(Vec3.init(10, 10, 10)));
    try testing.expect(!aabb.contains(Vec3.init(-1, 5, 5)));
    try testing.expect(!aabb.contains(Vec3.init(11, 5, 5)));
}

test "AABB intersects" {
    const a = AABB.init(Vec3.init(0, 0, 0), Vec3.init(10, 10, 10));
    const b = AABB.init(Vec3.init(5, 5, 5), Vec3.init(15, 15, 15));
    const c = AABB.init(Vec3.init(20, 20, 20), Vec3.init(30, 30, 30));

    try testing.expect(a.intersects(b));
    try testing.expect(b.intersects(a));
    try testing.expect(!a.intersects(c));
    try testing.expect(!c.intersects(a));
}

test "AABB expand and translate" {
    const aabb = AABB.init(Vec3.init(0, 0, 0), Vec3.init(10, 10, 10));

    const expanded = aabb.expand(Vec3.init(1, 1, 1));
    try testing.expectEqual(@as(f32, -1), expanded.min.x);
    try testing.expectEqual(@as(f32, 11), expanded.max.x);

    const translated = aabb.translate(Vec3.init(5, 5, 5));
    try testing.expectEqual(@as(f32, 5), translated.min.x);
    try testing.expectEqual(@as(f32, 15), translated.max.x);
}

test "Plane signedDistance" {
    const plane = Plane.init(Vec3.init(0, 0, 1), 0);

    try testing.expectEqual(@as(f32, 5), plane.signedDistance(Vec3.init(0, 0, 5)));
    try testing.expectEqual(@as(f32, -3), plane.signedDistance(Vec3.init(0, 0, -3)));
    try testing.expectEqual(@as(f32, 0), plane.signedDistance(Vec3.init(0, 0, 0)));
}

test "Plane normalize" {
    const plane = Plane.init(Vec3.init(0, 0, 2), 4);
    const normalized = plane.normalize();
    try testing.expectApproxEqAbs(@as(f32, 1), normalized.normal.z, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2), normalized.distance, 0.0001);
}

test "Frustum intersectsSphere" {
    const vp = Mat4.identity;
    const frustum = Frustum.fromViewProj(vp);
    try testing.expect(frustum.intersectsSphere(Vec3.init(0, 0, 0), 0.5));
}

test "Frustum forward view at y=80 sees all nearby chunks" {
    const view = Mat4.lookAt(Vec3.init(0, 0, 0), Vec3.init(0, 0, -1), Vec3.init(0, 1, 0));
    const proj = Mat4.perspectiveReverseZ(std.math.pi / 4.0, 1.5, 0.5, 10000.0);
    const frustum = Frustum.fromViewProj(proj.multiply(view));

    var not_visible: u32 = 0;
    const rd: i32 = 8;
    var cz: i32 = -rd;
    while (cz <= rd) : (cz += 1) {
        var cx: i32 = -rd;
        while (cx <= rd) : (cx += 1) {
            if (cx * cx + cz * cz > rd * rd) continue;
            if (!frustum.intersectsChunkRelative(cx, cz, 0, 80, 0)) {
                not_visible += 1;
            }
        }
    }
    try testing.expectEqual(@as(u32, 0), not_visible);
}
