const std = @import("std");
const testing = std.testing;
const rhi = @import("engine-rhi").rhi;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const computeCascadesWithCamera = @import("csm.zig").computeCascadesWithCamera;
const ShadowCascades = @import("csm.zig").ShadowCascades;
const CASCADE_COUNT = @import("csm.zig").CASCADE_COUNT;

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

test "different resolution produces different texel sizes" {
    const cascades_1024 = computeCascadesWithCamera(
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

    const cascades_2048 = computeCascadesWithCamera(
        2048,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        Vec3.zero,
        true,
    );

    try testing.expect(cascades_1024.isValid());
    try testing.expect(cascades_2048.isValid());
    try testing.expect(cascades_1024.texel_sizes[0] > cascades_2048.texel_sizes[0]);
}
