const std = @import("std");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const rhi = @import("rhi.zig");

pub const CASCADE_COUNT = rhi.SHADOW_CASCADE_COUNT;

pub const ShadowCascades = struct {
    light_space_matrices: [CASCADE_COUNT]Mat4,
    cascade_splits: [CASCADE_COUNT]f32,
    texel_sizes: [CASCADE_COUNT]f32,

    /// Initialize with safe defaults (zero-initialized)
    pub fn initZero() ShadowCascades {
        return .{
            .light_space_matrices = .{Mat4.identity} ** CASCADE_COUNT,
            .cascade_splits = .{0.0} ** CASCADE_COUNT,
            .texel_sizes = .{0.0} ** CASCADE_COUNT,
        };
    }

    /// Validate that all cascade data is finite and reasonable
    pub fn isValid(self: ShadowCascades) bool {
        for (0..CASCADE_COUNT) |i| {
            // Check cascade splits are finite and increasing
            if (!std.math.isFinite(self.cascade_splits[i])) return false;
            if (self.cascade_splits[i] <= 0.0) return false;
            if (i > 0 and self.cascade_splits[i] <= self.cascade_splits[i - 1]) return false;

            // Check texel sizes are finite and positive
            if (!std.math.isFinite(self.texel_sizes[i])) return false;
            if (self.texel_sizes[i] <= 0.0) return false;

            // Check light space matrices are finite
            for (0..4) |row| {
                for (0..4) |col| {
                    if (!std.math.isFinite(self.light_space_matrices[i].data[row][col])) return false;
                }
            }
        }
        return true;
    }
};

/// Computes stable cascaded shadow map matrices using texel snapping.
///
/// Parameters:
/// - resolution: shadow map resolution per cascade.
/// - camera_fov: vertical FOV in radians.
/// - aspect: viewport aspect ratio.
/// - near/far: camera depth range for cascade splitting.
/// - sun_dir: normalized direction to the sun (world space).
/// - cam_view: camera view matrix (origin-centered, retained for API compatibility).
/// - cam_pos: camera world position used to convert world-space cascades into
///   the existing camera-relative render space.
/// - z_range_01: map depth to [0,1] for reverse-Z when true.
///
/// Notes:
/// - lambda=0.92 biases the split scheme toward logarithmic distribution.
/// - min/max Z offsets are tuned to avoid clipping during camera motion.
pub fn computeCascadesWithCamera(resolution: u32, camera_fov: f32, aspect: f32, near: f32, far: f32, sun_dir: Vec3, cam_view: Mat4, cam_pos: Vec3, z_range_01: bool) ShadowCascades {
    // Validate inputs to prevent division by zero
    if (resolution == 0 or far <= near or near <= 0.0) {
        return ShadowCascades.initZero();
    }

    const shadow_dist = far;

    var cascades = ShadowCascades.initZero();

    // Practical fixed splits avoid the old logarithmic layout's huge final
    // cascade, which made medium-distance voxel shadows visibly stair-step and
    // pulse as soon as they crossed out of the tiny near cascades.
    const split_ratios = [4]f32{ 0.25, 0.50, 0.75, 1.0 };
    for (0..CASCADE_COUNT) |i| {
        cascades.cascade_splits[i] = shadow_dist * split_ratios[i];
    }

    // Calculate matrices for each cascade.
    // Keep cascade centers tied to camera position rather than camera forward.
    // Frustum-slice centering has better texel density, but it makes the entire
    // shadow projection slide during yaw/pitch-only camera rotation, which causes
    // shadows to visibly morph even when caster and receiver are stationary.
    _ = cam_view;
    for (0..CASCADE_COUNT) |i| {
        const split = cascades.cascade_splits[i];

        // 1. Compute a rotation-invariant bounding sphere from the camera origin
        // to the far plane of this cascade.
        const tan_fov_half = std.math.tan(camera_fov / 2.0);
        const tan_fov_h_half = tan_fov_half * aspect;

        const far_v = split;
        const xf = far_v * tan_fov_h_half;
        const yf = far_v * tan_fov_half;
        var radius = std.math.sqrt(xf * xf + yf * yf + far_v * far_v);
        radius = @ceil(radius * 16.0) / 16.0;

        // 2. Use camera world position as the cascade center. This intentionally
        // sacrifices some texel density for rotation stability.
        const center_world = cam_pos;

        // 3. Build Light Rotation Matrix (Looking FROM sun TO scene)
        var up = Vec3.init(0, 1, 0);
        if (@abs(sun_dir.y) > 0.99) up = Vec3.init(0, 0, 1);
        const light_rot = Mat4.lookAt(Vec3.zero, sun_dir.scale(-1.0), up);

        // 4. Transform center to Light Space
        const center_ls = light_rot.transformPoint(center_world);

        // 5. Snap center to texel grid in LIGHT SPACE for stability
        const texel_size = (2.0 * radius) / @as(f32, @floatFromInt(resolution));
        cascades.texel_sizes[i] = texel_size;

        // Stabilize ortho bounds by snapping center to the nearest texel grid
        // in light-space. Snapping Z would shift depth ranges, so only X/Y are
        // quantized. Round-to-nearest avoids the one-direction crawl caused by
        // floor snapping when the camera crosses texel boundaries.
        const center_snapped = Vec3.init(
            @round(center_ls.x / texel_size) * texel_size,
            @round(center_ls.y / texel_size) * texel_size,
            center_ls.z,
        );

        // 6. Build Ortho Projection (Centered around snapped center)
        const minX = center_snapped.x - radius;
        const maxX = center_snapped.x + radius;
        const minY = center_snapped.y - radius;
        const maxY = center_snapped.y + radius;

        // Use fixed large depth range to avoid clipping during camera motion
        const maxZ = center_ls.z + radius + 400.0;
        const minZ = center_ls.z - radius - 200.0;

        var light_ortho = Mat4.identity;
        light_ortho.data[0][0] = 2.0 / (maxX - minX);
        light_ortho.data[3][0] = -(maxX + minX) / (maxX - minX);

        light_ortho.data[1][1] = 2.0 / (maxY - minY);
        light_ortho.data[3][1] = -(maxY + minY) / (maxY - minY);

        if (z_range_01) {
            // Proper Reverse-Z: map Near (maxZ) to 1.0 and Far (minZ) to 0.0
            // Since lookAt(zero, -sun_dir, up) makes Z decrease as we move away from light,
            // larger Light Space Z values are CLOSER to the light.
            // minZ is Far, maxZ is Near.
            const A = 1.0 / (maxZ - minZ);
            const B = -minZ / (maxZ - minZ);
            light_ortho.data[2][2] = A;
            light_ortho.data[3][2] = B;
        } else {
            // Standard perspective: map closer to -1, further to 1
            const A = -2.0 / (maxZ - minZ);
            const B = (maxZ + minZ) / (maxZ - minZ);
            light_ortho.data[2][2] = A;
            light_ortho.data[3][2] = B;
        }

        const world_to_shadow = light_ortho.multiply(light_rot);
        const relative_to_world = Mat4.translate(cam_pos);
        cascades.light_space_matrices[i] = world_to_shadow.multiply(relative_to_world);
    }

    // Validate results before returning - use runtime check instead of
    // debug.assert so invalid data is caught in ReleaseFast builds too.
    if (!cascades.isValid()) {
        return ShadowCascades.initZero();
    }

    return cascades;
}

pub fn computeCascades(resolution: u32, camera_fov: f32, aspect: f32, near: f32, far: f32, sun_dir: Vec3, cam_view: Mat4, z_range_01: bool) ShadowCascades {
    return computeCascadesWithCamera(resolution, camera_fov, aspect, near, far, sun_dir, cam_view, Vec3.zero, z_range_01);
}

/// Validates cascade data and logs warnings if invalid
pub fn validateCascades(cascades: ShadowCascades, log_scope: anytype) bool {
    if (cascades.isValid()) return true;

    log_scope.warn("Invalid shadow cascade data detected:", .{});
    for (0..CASCADE_COUNT) |i| {
        if (!std.math.isFinite(cascades.cascade_splits[i])) {
            log_scope.warn("  Cascade {} split is non-finite: {}", .{ i, cascades.cascade_splits[i] });
        }
        if (!std.math.isFinite(cascades.texel_sizes[i])) {
            log_scope.warn("  Cascade {} texel size is non-finite: {}", .{ i, cascades.texel_sizes[i] });
        }
    }
    return false;
}

test "computeCascades splits and texel sizes" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        Mat4.identity,
        true,
    );

    var last_split: f32 = 0.0;
    for (0..CASCADE_COUNT) |i| {
        try std.testing.expect(cascades.cascade_splits[i] > last_split);
        try std.testing.expect(cascades.texel_sizes[i] > 0.0);
        last_split = cascades.cascade_splits[i];
    }
}
