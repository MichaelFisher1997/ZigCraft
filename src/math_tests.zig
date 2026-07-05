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

// ---------------------------------------------------------------------------
// Regression coverage for intersectsChunkRelative camera-relative semantics.
//
// The renderer builds the terrain view-projection from Camera.getViewMatrixOriginCentered
// (rotation only, camera at origin; see render_graph OpaquePass.execute and the chunk
// model matrices in world_renderer.zig that subtract camera_pos). The frustum passed to
// intersectsChunkRelative therefore lives in CAMERA-RELATIVE space, and the chunk's
// vertical center in that space is (CHUNK_SIZE_Y * 0.5) - cam_y. Audit issue #741
// incorrectly assumed world space and proposed anchoring world_y to 0, which would
// detach the bounding sphere from the camera and cull terrain whenever the camera is
// high above the world. These tests pin the correct behavior and would fail under the
// proposed "fix".
// ---------------------------------------------------------------------------

test "Frustum forward view sees chunk ahead across camera heights" {
    const view = Mat4.lookAt(Vec3.zero, Vec3.init(0, 0, -1), Vec3.init(0, 1, 0));
    const proj = Mat4.perspectiveReverseZ(std.math.pi / 4.0, 1.5, 0.5, 10000.0);
    const frustum = Frustum.fromViewProj(proj.multiply(view));

    // Camera at y = 0, 80, 200, 256 (issue acceptance criteria) must all see the
    // chunk directly in front. center.y tracks the camera as (128 - cam_y).
    const cam_heights = [_]f32{ 0.0, 80.0, 128.0, 200.0, 256.0 };
    for (cam_heights) |cam_y| {
        try testing.expect(
            frustum.intersectsChunkRelative(0, -3, 0, cam_y, 0),
        );
    }
}

test "Frustum looking down at chunk from high camera still sees it" {
    // Direct refutation of the audit's "missing terrain when camera is high" claim.
    // Camera is far above the terrain and aimed straight at the chunk, so the chunk
    // MUST be visible. The camera-relative chunk center (chunk_center - cam) lies on
    // the view axis, so the correct sphere is dead-center in the frustum. The proposed
    // world-space "fix" (anchoring center.y at 128 regardless of cam_y) would instead
    // place the sphere ~cam_y units above the view axis, far outside this narrow
    // downward frustum, and incorrectly cull the chunk. Camera height 600 >> radius
    // 144 guarantees the detached sphere can never reach back into the frustum.
    const cam = Vec3.init(8.0, 600.0, 300.0);
    const chunk_center_world = Vec3.init(8.0, 128.0, 8.0); // chunk (0, 0)
    const view_dir = chunk_center_world.sub(cam);
    const view = Mat4.lookAt(Vec3.zero, view_dir, Vec3.init(0, 1, 0));
    const proj = Mat4.perspectiveReverseZ(std.math.pi / 4.0, 1.5, 0.5, 10000.0);
    const frustum = Frustum.fromViewProj(proj.multiply(view));

    try testing.expect(frustum.intersectsChunkRelative(0, 0, cam.x, cam.y, cam.z));
    // Same setup with the camera lower (y = 200) must also see the chunk.
    const cam2 = Vec3.init(8.0, 200.0, 120.0);
    const view2 = Mat4.lookAt(Vec3.zero, chunk_center_world.sub(cam2), Vec3.init(0, 1, 0));
    const frustum2 = Frustum.fromViewProj(proj.multiply(view2));
    try testing.expect(frustum2.intersectsChunkRelative(0, 0, cam2.x, cam2.y, cam2.z));
}

test "Frustum intersectsChunkRelative matches independent circumscribed sphere" {
    // Independent reference: the bounding sphere MUST be centered at the
    // camera-relative chunk center with radius >= the true circumscribed radius
    // sqrt(8^2 + 128^2 + 8^2) ~= 128.5. Because the implementation reuses that exact
    // center and a larger radius (144), intersectsChunkRelative is required to report
    // visible whenever the reference sphere does, for any frustum/camera/chunk combo.
    // This directly verifies the sphere contains the full chunk (all 256 Y levels)
    // and would fail if the center drifted out of camera-relative space.
    const CHUNK_SIZE_X: f32 = 16.0;
    const CHUNK_SIZE_Y: f32 = 256.0;
    const CHUNK_SIZE_Z: f32 = 16.0;
    const half_x: f32 = CHUNK_SIZE_X * 0.5;
    const half_y: f32 = CHUNK_SIZE_Y * 0.5;
    const half_z: f32 = CHUNK_SIZE_Z * 0.5;
    const ref_radius: f32 = @sqrt(half_x * half_x + half_y * half_y + half_z * half_z);

    const Dir = struct { fwd: Vec3, up: Vec3 };
    const directions = [_]Dir{
        .{ .fwd = Vec3.init(0, 0, -1), .up = Vec3.init(0, 1, 0) }, // forward
        .{ .fwd = Vec3.init(0, -1, 0), .up = Vec3.init(0, 0, -1) }, // straight down
        .{ .fwd = Vec3.init(0, 1, 0), .up = Vec3.init(0, 0, 1) }, // straight up
        .{ .fwd = Vec3.init(1, -1, -1), .up = Vec3.init(0, 1, 0) }, // angled
    };
    const cam_heights = [_]f32{ 0.0, 80.0, 128.0, 200.0, 256.0, 500.0 };
    const chunks = [_]struct { x: i32, z: i32 }{
        .{ .x = 0, .z = 0 },
        .{ .x = 1, .z = 0 },
        .{ .x = -1, .z = 1 },
        .{ .x = 0, .z = -2 },
    };
    const cam_xz = [_]struct { x: f32, z: f32 }{
        .{ .x = 0.0, .z = 0.0 },
        .{ .x = 8.0, .z = 8.0 },
    };

    const proj = Mat4.perspectiveReverseZ(std.math.pi / 4.0, 1.5, 0.5, 10000.0);
    var ref_visible_count: u32 = 0;
    for (directions) |d| {
        const view = Mat4.lookAt(Vec3.zero, d.fwd, d.up);
        const frustum = Frustum.fromViewProj(proj.multiply(view));
        for (cam_heights) |cam_y| {
            for (cam_xz) |cxz| {
                for (chunks) |ch| {
                    const ref_center = Vec3.init(
                        @as(f32, @floatFromInt(ch.x * 16)) + half_x - cxz.x,
                        half_y - cam_y,
                        @as(f32, @floatFromInt(ch.z * 16)) + half_z - cxz.z,
                    );
                    if (frustum.intersectsSphere(ref_center, ref_radius)) {
                        ref_visible_count += 1;
                        try testing.expect(
                            frustum.intersectsChunkRelative(ch.x, ch.z, cxz.x, cam_y, cxz.z),
                        );
                    }
                }
            }
        }
    }
    // Sanity: the battery must actually exercise the visible case, otherwise the
    // implication above would hold vacuously.
    try testing.expect(ref_visible_count > 0);
}

// Regression guard for issue #715 (atmosphere sky-palette gamma audit).
//
// The audit claimed `Vec3.toLinear()` (which applies `pow(x, 2.2)`) was the
// wrong direction and proposed `pow(x, 1/2.2)` instead. That proposal is
// backwards. `pow(x, 2.2)` is the sRGB Electro-Optical Transfer Function
// (signal -> linear light) and matches every other sRGB->linear conversion in
// the engine:
//   - `srgbByteToLinear` in modules/engine-graphics/src/texture_atlas.zig (pow 2.4)
//   - `agxEotf` in assets/shaders/vulkan/post_process.frag (pow 2.2, commented
//     "sRGB IEC 61966-2-1 2.2 Exponent Reference EOTF Display")
//   - `pow(vColor.rgb, vec3(2.2))` in assets/shaders/vulkan/ui.frag
//   - the moon color `pow(vec3(0.9,0.9,1.0), vec3(2.2))` in sky.frag
// The swapchain is VK_FORMAT_B8G8R8A8_SRGB, so shading happens in linear space
// and CPU-side sRGB color constants must be decoded with `toLinear()`.
//
// These tests pin the correct direction so the audit mistake is not reintroduced.

test "Vec3.toLinear decodes sRGB to linear via the EOTF (darkens, exponent 2.2)" {
    // A mid-tone sRGB signal (e.g. 97/255, the day-sky red channel).
    const srgb_r = 97.0 / 255.0;

    // Decoding sRGB signal to linear light darkens mid-tones (exponent > 1).
    const decoded = Vec3.init(srgb_r, srgb_r, srgb_r).toLinear();
    try testing.expect(decoded.x < srgb_r);

    // The proposed-but-incorrect direction (pow 1/2.2) would *brighten*; make
    // sure we are not doing that.
    const wrong = std.math.pow(f32, srgb_r, 1.0 / 2.2);
    try testing.expect(decoded.x < wrong);

    // toLinear must apply pow(x, 2.2), matching the engine's other EOTFs.
    try testing.expectApproxEqAbs(decoded.x, std.math.pow(f32, srgb_r, 2.2), 0.0001);

    // Round-trip: applying the inverse OETF (pow 1/2.2) recovers the signal.
    const recovered = std.math.pow(f32, decoded.x, 1.0 / 2.2);
    try testing.expectApproxEqAbs(srgb_r, recovered, 0.001);
}

test "Vec3.toLinear matches the absolute linear-light value of sRGB day-sky blue" {
    // day_sky is the sRGB triple (97, 181, 245). Its correct linear intensity is
    // obtained by the sRGB EOTF (pow 2.2): approx (0.119, 0.471, 0.916). Assert
    // absolute values so that flipping the exponent is caught independently of
    // how the expectation is computed. (A pow 1/2.2 mistake would yield the
    // much-too-bright approx (0.645, 0.855, 0.982) and wash the sky out.)
    const day_sky = Vec3.init(97.0 / 255.0, 181.0 / 255.0, 245.0 / 255.0).toLinear();
    try testing.expectApproxEqAbs(@as(f32, 0.119), day_sky.x, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.471), day_sky.y, 0.01);
    try testing.expectApproxEqAbs(@as(f32, 0.916), day_sky.z, 0.01);
}
