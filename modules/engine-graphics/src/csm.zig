const std = @import("std");
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const rhi = @import("engine-rhi");
const runtime_env = @import("engine-core").runtime_env;

pub const CASCADE_COUNT = rhi.SHADOW_CASCADE_COUNT;

fn envFloat(name: [:0]const u8, default: f32) f32 {
    const value = runtime_env.getenv(name) orelse return default;
    return std.fmt.parseFloat(f32, value) catch default;
}

pub const ShadowCascades = struct {
    light_space_matrices: [CASCADE_COUNT]Mat4,
    cascade_splits: [CASCADE_COUNT]f32,
    overlap_starts: [CASCADE_COUNT]f32,
    texel_sizes: [CASCADE_COUNT]f32,
    depth_spans: [CASCADE_COUNT]f32,
    receiver_corners: [CASCADE_COUNT][8]Vec3,

    /// Initialize with safe defaults (zero-initialized)
    pub fn initZero() ShadowCascades {
        return .{
            .light_space_matrices = .{Mat4.identity} ** CASCADE_COUNT,
            .cascade_splits = .{0.0} ** CASCADE_COUNT,
            .overlap_starts = .{0.0} ** CASCADE_COUNT,
            .texel_sizes = .{0.0} ** CASCADE_COUNT,
            .depth_spans = .{0.0} ** CASCADE_COUNT,
            .receiver_corners = .{.{Vec3.zero} ** 8} ** CASCADE_COUNT,
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

pub const CasterBounds = struct {
    min: Vec3,
    max: Vec3,
};

pub fn practicalSplit(near: f32, far: f32, cascade: usize, lambda: f32) f32 {
    const ratio = @as(f32, @floatFromInt(cascade + 1)) / @as(f32, @floatFromInt(CASCADE_COUNT));
    const uniform = near + (far - near) * ratio;
    const logarithmic = near * std.math.pow(f32, far / near, ratio);
    return uniform + (logarithmic - uniform) * std.math.clamp(lambda, 0.0, 1.0);
}

pub fn selectCascade(view_depth: f32, splits: [CASCADE_COUNT]f32) usize {
    for (splits, 0..) |split, i| if (view_depth < split) return i;
    return CASCADE_COUNT - 1;
}

pub fn reverseZDepth(z: f32, min_z: f32, max_z: f32) f32 {
    return (z - min_z) / (max_z - min_z);
}

pub fn receiverBiasDepth(world_texel_size: f32, depth_span: f32, bias_texels: f32) f32 {
    return world_texel_size * bias_texels / depth_span;
}

pub fn computeCasterBounds(corners: [8]Vec3, sun_dir: Vec3, caster_distance: f32) CasterBounds {
    const toward_light = sun_dir.normalize();
    var bounds = CasterBounds{ .min = corners[0], .max = corners[0] };
    for (corners) |corner| {
        const extruded = corner.add(toward_light.scale(@max(caster_distance, 0.0)));
        for ([_]Vec3{ corner, extruded }) |point| {
            bounds.min.x = @min(bounds.min.x, point.x);
            bounds.min.y = @min(bounds.min.y, point.y);
            bounds.min.z = @min(bounds.min.z, point.z);
            bounds.max.x = @max(bounds.max.x, point.x);
            bounds.max.y = @max(bounds.max.y, point.y);
            bounds.max.z = @max(bounds.max.z, point.z);
        }
    }
    return bounds;
}

fn sliceCorners(cam_pos: Vec3, right: Vec3, up: Vec3, forward: Vec3, tan_x: f32, tan_y: f32, near: f32, far: f32) [8]Vec3 {
    var result: [8]Vec3 = undefined;
    var index: usize = 0;
    for ([_]f32{ near, far }) |depth| {
        const center = cam_pos.add(forward.scale(depth));
        const half_x = tan_x * depth;
        const half_y = tan_y * depth;
        for ([_]f32{ -1.0, 1.0 }) |y_sign| {
            for ([_]f32{ -1.0, 1.0 }) |x_sign| {
                result[index] = center.add(right.scale(half_x * x_sign)).add(up.scale(half_y * y_sign));
                index += 1;
            }
        }
    }
    return result;
}

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

    var cascades = ShadowCascades.initZero();
    const split_lambda = envFloat("ZIGCRAFT_CSM_SPLIT_LAMBDA", 0.75);
    for (0..CASCADE_COUNT) |i| {
        cascades.cascade_splits[i] = practicalSplit(near, far, i, split_lambda);
    }

    const inv_view = cam_view.inverse();
    const camera_forward = inv_view.transformDirection(Vec3.init(0, 0, -1)).normalize();
    const camera_right = inv_view.transformDirection(Vec3.init(1, 0, 0)).normalize();
    const camera_up = inv_view.transformDirection(Vec3.init(0, 1, 0)).normalize();
    const tan_fov_half = std.math.tan(camera_fov / 2.0);
    const tan_fov_h_half = tan_fov_half * aspect;
    const overlap_ratio = std.math.clamp(envFloat("ZIGCRAFT_CSM_OVERLAP", 0.1), 0.0, 0.25);

    for (0..CASCADE_COUNT) |i| {
        const split = cascades.cascade_splits[i];
        const nominal_near: f32 = if (i == 0) near else cascades.cascade_splits[i - 1];
        const overlap = if (i == 0) 0.0 else (split - nominal_near) * overlap_ratio;
        const prev_split = @max(near, nominal_near - overlap);
        cascades.overlap_starts[i] = prev_split;
        const slice_mid = (prev_split + split) * 0.5;
        const corners = sliceCorners(cam_pos, camera_right, camera_up, camera_forward, tan_fov_h_half, tan_fov_half, prev_split, split);
        cascades.receiver_corners[i] = corners;
        const center_world = cam_pos.add(camera_forward.scale(slice_mid));
        var radius: f32 = 0.0;
        for (corners) |corner| radius = @max(radius, corner.sub(center_world).length());
        // A resolution-derived quantization keeps projection scale stable under
        // small camera/FOV changes while guaranteeing all corners remain inside.
        const radius_step = @max(radius / @as(f32, @floatFromInt(resolution)), 1.0 / 1024.0);
        radius = @ceil(radius / radius_step) * radius_step;

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

        // The receiver sphere supplies deterministic depth bounds. Caster reach is
        // handled independently by receiver-volume extrusion during submission.
        // Extrusion toward the light changes only light-space Z. Reserve the
        // full configured settings range so off-screen casters are not clipped.
        const maxZ = center_ls.z + radius + envFloat("ZIGCRAFT_CSM_MAX_CASTER_REACH", 500.0);
        const minZ = center_ls.z - radius;
        cascades.depth_spans[i] = maxZ - minZ;

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

test "practical splits and view-depth selection" {
    var splits: [CASCADE_COUNT]f32 = undefined;
    for (0..CASCADE_COUNT) |i| splits[i] = practicalSplit(0.1, 500.0, i, 0.75);
    try std.testing.expect(splits[0] > 0.1);
    try std.testing.expect(splits[0] < splits[1]);
    try std.testing.expect(splits[1] < splits[2]);
    try std.testing.expectApproxEqAbs(@as(f32, 500.0), splits[3], 0.001);
    try std.testing.expectEqual(@as(usize, 0), selectCascade(splits[0] - 0.01, splits));
    try std.testing.expectEqual(@as(usize, 1), selectCascade(splits[0] + 0.01, splits));
}

test "reverse-Z endpoints and bias scaling" {
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), reverseZDepth(-10.0, -10.0, 30.0), 0.00001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), reverseZDepth(30.0, -10.0, 30.0), 0.00001);
    const near_bias = receiverBiasDepth(0.05, 40.0, 1.5);
    const far_bias = receiverBiasDepth(0.2, 160.0, 1.5);
    try std.testing.expectApproxEqAbs(near_bias, far_bias, 0.000001);
}

test "frustum corners and overlap are contained" {
    const camera = Vec3.init(12.0, 30.0, -7.0);
    const cascades = computeCascadesWithCamera(2048, std.math.degreesToRadians(70.0), 16.0 / 9.0, 0.1, 400.0, Vec3.init(0.4, -0.8, 0.2).normalize(), Mat4.identity, camera, true);
    try std.testing.expect(cascades.isValid());
    for (0..CASCADE_COUNT) |cascade| {
        for (cascades.receiver_corners[cascade]) |corner| {
            const clip = cascades.light_space_matrices[cascade].transformPoint(corner.sub(camera));
            try std.testing.expect(@abs(clip.x) <= 1.0001);
            try std.testing.expect(@abs(clip.y) <= 1.0001);
            try std.testing.expect(clip.z >= -0.0001 and clip.z <= 1.0001);
        }
        if (cascade > 0) try std.testing.expect(cascades.overlap_starts[cascade] < cascades.cascade_splits[cascade - 1]);
    }
}

test "caster bounds extrude toward the light" {
    const corners = sliceCorners(Vec3.zero, Vec3.init(1, 0, 0), Vec3.init(0, 1, 0), Vec3.init(0, 0, -1), 1.0, 1.0, 1.0, 2.0);
    const bounds = computeCasterBounds(corners, Vec3.init(1, 0, 0), 32.0);
    try std.testing.expect(bounds.max.x >= 34.0);
    try std.testing.expect(bounds.min.x <= -2.0);
    try std.testing.expect(bounds.min.z <= -2.0);
}

test "sub-texel camera translation keeps cascade scale stable" {
    const sun = Vec3.init(0.3, -1.0, 0.2).normalize();
    const first = computeCascadesWithCamera(4096, std.math.degreesToRadians(60.0), 16.0 / 9.0, 0.1, 250.0, sun, Mat4.identity, Vec3.zero, true);
    const motion = first.texel_sizes[0] * 0.25;
    const second = computeCascadesWithCamera(4096, std.math.degreesToRadians(60.0), 16.0 / 9.0, 0.1, 250.0, sun, Mat4.identity, Vec3.init(motion, 0, 0), true);
    for (0..CASCADE_COUNT) |cascade| {
        try std.testing.expectApproxEqAbs(first.light_space_matrices[cascade].data[0][0], second.light_space_matrices[cascade].data[0][0], 0.000001);
        try std.testing.expectApproxEqAbs(first.light_space_matrices[cascade].data[1][1], second.light_space_matrices[cascade].data[1][1], 0.000001);
    }
}
