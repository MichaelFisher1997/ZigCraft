const std = @import("std");
const Vec3 = @import("vec3.zig").Vec3;
const Mat4 = @import("mat4.zig").Mat4;
const AABB = @import("aabb.zig").AABB;

pub const Plane = struct {
    normal: Vec3,
    distance: f32,

    pub fn init(normal: Vec3, distance: f32) Plane {
        return .{ .normal = normal, .distance = distance };
    }

    pub fn signedDistance(self: Plane, point: Vec3) f32 {
        return self.normal.dot(point) + self.distance;
    }

    pub fn normalize(self: Plane) Plane {
        const len = self.normal.length();
        if (len < 0.0001) return self;
        return .{
            .normal = self.normal.scale(1.0 / len),
            .distance = self.distance / len,
        };
    }
};

pub const Frustum = struct {
    planes: [6]Plane,

    pub const Side = enum(u3) {
        left = 0,
        right = 1,
        bottom = 2,
        top = 3,
        near = 4,
        far = 5,
    };

    pub fn fromViewProj(vp: Mat4) Frustum {
        const m = vp.data;

        var planes: [6]Plane = undefined;

        planes[0] = Plane.init(
            Vec3.init(m[0][3] + m[0][0], m[1][3] + m[1][0], m[2][3] + m[2][0]),
            m[3][3] + m[3][0],
        ).normalize();

        planes[1] = Plane.init(
            Vec3.init(m[0][3] - m[0][0], m[1][3] - m[1][0], m[2][3] - m[2][0]),
            m[3][3] - m[3][0],
        ).normalize();

        planes[2] = Plane.init(
            Vec3.init(m[0][3] + m[0][1], m[1][3] + m[1][1], m[2][3] + m[2][1]),
            m[3][3] + m[3][1],
        ).normalize();

        planes[3] = Plane.init(
            Vec3.init(m[0][3] - m[0][1], m[1][3] - m[1][1], m[2][3] - m[2][1]),
            m[3][3] - m[3][1],
        ).normalize();

        planes[4] = Plane.init(
            Vec3.init(m[0][3] + m[0][2], m[1][3] + m[1][2], m[2][3] + m[2][2]),
            m[3][3] + m[3][2],
        ).normalize();

        planes[5] = Plane.init(
            Vec3.init(m[0][3] - m[0][2], m[1][3] - m[1][2], m[2][3] - m[2][2]),
            m[3][3] - m[3][2],
        ).normalize();

        return .{ .planes = planes };
    }

    pub fn containsPoint(self: Frustum, point: Vec3) bool {
        for (self.planes) |plane| {
            if (plane.signedDistance(point) < 0) {
                return false;
            }
        }
        return true;
    }

    pub fn intersectsSphere(self: Frustum, center: Vec3, radius: f32) bool {
        for (self.planes) |plane| {
            if (plane.signedDistance(center) < -radius) {
                return false;
            }
        }
        return true;
    }

    pub fn intersectsAABB(self: Frustum, aabb: AABB) bool {
        for (self.planes) |plane| {
            const p = Vec3.init(
                if (plane.normal.x >= 0) aabb.max.x else aabb.min.x,
                if (plane.normal.y >= 0) aabb.max.y else aabb.min.y,
                if (plane.normal.z >= 0) aabb.max.z else aabb.min.z,
            );

            if (plane.signedDistance(p) < 0) {
                return false;
            }
        }
        return true;
    }

    pub fn intersectsChunk(self: Frustum, chunk_x: i32, chunk_z: i32) bool {
        return self.intersectsChunkRelative(chunk_x, chunk_z, 0, 0, 0);
    }

    pub fn intersectsChunkRelative(self: Frustum, chunk_x: i32, chunk_z: i32, cam_x: f32, cam_y: f32, cam_z: f32) bool {
        const CHUNK_SIZE_X: f32 = 16.0;
        const CHUNK_SIZE_Y: f32 = 256.0;
        const CHUNK_SIZE_Z: f32 = 16.0;

        const world_x: f32 = @as(f32, @floatFromInt(chunk_x * 16)) - cam_x;
        const world_z: f32 = @as(f32, @floatFromInt(chunk_z * 16)) - cam_z;
        const world_y: f32 = -cam_y;

        const center = Vec3.init(
            world_x + CHUNK_SIZE_X * 0.5,
            world_y + CHUNK_SIZE_Y * 0.5,
            world_z + CHUNK_SIZE_Z * 0.5,
        );
        const radius: f32 = CHUNK_SIZE_Y * 0.5 + CHUNK_SIZE_X;

        return self.intersectsSphere(center, radius);
    }
};

test "Frustum culls front-facing chunks" {
    const view = Mat4.lookAt(Vec3.init(0, 0, 0), Vec3.init(0, 0, -1), Vec3.init(0, 1, 0));
    const proj = Mat4.perspectiveReverseZ(std.math.pi / 2.0, 1.0, 0.1, 512.0);
    const frustum = Frustum.fromViewProj(proj.multiply(view));

    try std.testing.expect(frustum.intersectsChunkRelative(0, -4, 0, 0, 0));
    try std.testing.expect(!frustum.intersectsChunkRelative(0, 40, 0, 0, 0));
}
