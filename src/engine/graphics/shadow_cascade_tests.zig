const std = @import("std");
const testing = std.testing;
const rhi = @import("rhi.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;
const computeCascadesWithCamera = @import("csm.zig").computeCascadesWithCamera;
const ShadowCascades = @import("csm.zig").ShadowCascades;
const CASCADE_COUNT = @import("csm.zig").CASCADE_COUNT;
const ShadowConfig = rhi.ShadowConfig;
const ShadowParams = rhi.ShadowParams;

test "computeCascadesWithCamera with non-zero cam_pos produces valid cascades" {
    const cam_pos = Vec3.init(100.0, 50.0, -200.0);
    const cascades = computeCascadesWithCamera(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        500.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        cam_pos,
        true,
    );

    try testing.expect(cascades.isValid());
    try testing.expect(cascades.cascade_splits[0] > 0.0);
    try testing.expect(cascades.texel_sizes[0] > 0.0);
}

test "computeCascadesWithCamera with far-origin cam_pos produces different matrices" {
    const cascades_origin = computeCascadesWithCamera(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        Vec3.zero,
        true,
    );

    const cascades_offset = computeCascadesWithCamera(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        Vec3.init(500.0, 0.0, 500.0),
        true,
    );

    for (0..CASCADE_COUNT) |i| {
        const m_orig = cascades_origin.light_space_matrices[i];
        const m_offset = cascades_offset.light_space_matrices[i];
        var same = true;
        for (0..4) |row| {
            for (0..4) |col| {
                if (m_orig.data[row][col] != m_offset.data[row][col]) {
                    same = false;
                    break;
                }
            }
            if (!same) break;
        }
        try testing.expect(!same);
    }
}

test "computeCascadesWithCamera returns zero cascades when far less than near" {
    const cascades = computeCascadesWithCamera(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        100.0,
        50.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        Vec3.zero,
        true,
    );

    try testing.expect(!cascades.isValid());
}

test "computeCascadesWithCamera returns zero cascades when resolution is zero" {
    const cascades = computeCascadesWithCamera(
        0,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        Vec3.zero,
        true,
    );

    try testing.expect(!cascades.isValid());
}

test "computeCascadesWithCamera with extreme FOV (very wide) produces valid cascades" {
    const cascades = computeCascadesWithCamera(
        512,
        std.math.degreesToRadians(120.0),
        16.0 / 9.0,
        0.1,
        300.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        Mat4.identity,
        Vec3.zero,
        true,
    );

    try testing.expect(cascades.isValid());
    for (0..CASCADE_COUNT) |i| {
        try testing.expect(cascades.texel_sizes[i] > 0.0);
        try testing.expect(cascades.cascade_splits[i] > 0.0);
    }
}

test "computeCascadesWithCamera with extreme aspect ratio (ultra-wide) produces valid cascades" {
    const cascades = computeCascadesWithCamera(
        1024,
        std.math.degreesToRadians(60.0),
        32.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        Vec3.zero,
        true,
    );

    try testing.expect(cascades.isValid());
}

test "computeCascadesWithCamera with extreme aspect ratio (portrait) produces valid cascades" {
    const cascades = computeCascadesWithCamera(
        1024,
        std.math.degreesToRadians(60.0),
        9.0 / 32.0,
        0.1,
        200.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        Vec3.zero,
        true,
    );

    try testing.expect(cascades.isValid());
}

test "computeCascadesWithCamera with very small near (epsilon) produces valid cascades" {
    const cascades = computeCascadesWithCamera(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.001,
        100.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        Vec3.zero,
        true,
    );

    try testing.expect(cascades.isValid());
}

test "computeCascadesWithCamera with very large far produces valid cascades" {
    const cascades = computeCascadesWithCamera(
        2048,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        10000.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        Vec3.zero,
        true,
    );

    try testing.expect(cascades.isValid());
    try testing.expect(cascades.cascade_splits[3] > 9000.0);
}

test "computeCascadesWithCamera standard Z (not reverse-Z) produces valid cascades" {
    const cascades = computeCascadesWithCamera(
        1024,
        std.math.degreesToRadians(70.0),
        16.0 / 9.0,
        0.1,
        400.0,
        Vec3.init(-0.5, -0.866, 0.0).normalize(),
        Mat4.identity,
        Vec3.zero,
        false,
    );

    try testing.expect(cascades.isValid());
    for (0..CASCADE_COUNT) |i| {
        try testing.expect(cascades.cascade_splits[i] > 0.0);
        try testing.expect(cascades.texel_sizes[i] > 0.0);
        for (0..4) |row| {
            for (0..4) |col| {
                try testing.expect(std.math.isFinite(cascades.light_space_matrices[i].data[row][col]));
            }
        }
    }
}

test "computeCascadesWithCamera diagonal sun direction produces valid cascades" {
    const cascades = computeCascadesWithCamera(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(1.0, -1.0, 1.0).normalize(),
        Mat4.identity,
        Vec3.zero,
        true,
    );

    try testing.expect(cascades.isValid());
}

test "ShadowConfig non-default values are preserved" {
    const cfg = ShadowConfig{
        .distance = 1000.0,
        .resolution = 8192,
        .pcf_samples = 24,
        .cascade_blend = false,
        .strength = 0.7,
        .light_size = 7.5,
        .caster_distance = 800.0,
    };

    try testing.expectEqual(@as(f32, 1000.0), cfg.distance);
    try testing.expectEqual(@as(u32, 8192), cfg.resolution);
    try testing.expectEqual(@as(u8, 24), cfg.pcf_samples);
    try testing.expect(!cfg.cascade_blend);
    try testing.expectEqual(@as(f32, 0.7), cfg.strength);
    try testing.expectEqual(@as(f32, 7.5), cfg.light_size);
    try testing.expectEqual(@as(f32, 800.0), cfg.caster_distance);
}

test "ShadowParams all fields set correctly" {
    const params = ShadowParams{
        .light_space_matrices = .{Mat4.identity} ** CASCADE_COUNT,
        .cascade_splits = .{ 5.0, 25.0, 125.0, 625.0 },
        .shadow_texel_sizes = .{ 0.125, 0.25, 0.5, 1.0 },
        .light_size = 5.0,
    };

    try testing.expectEqual(@as(f32, 5.0), params.cascade_splits[0]);
    try testing.expectEqual(@as(f32, 25.0), params.cascade_splits[1]);
    try testing.expectEqual(@as(f32, 125.0), params.cascade_splits[2]);
    try testing.expectEqual(@as(f32, 625.0), params.cascade_splits[3]);
    try testing.expectEqual(@as(f32, 0.125), params.shadow_texel_sizes[0]);
    try testing.expectEqual(@as(f32, 0.25), params.shadow_texel_sizes[1]);
    try testing.expectEqual(@as(f32, 0.5), params.shadow_texel_sizes[2]);
    try testing.expectEqual(@as(f32, 1.0), params.shadow_texel_sizes[3]);
    try testing.expectEqual(@as(f32, 5.0), params.light_size);
}
