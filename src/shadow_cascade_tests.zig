const std = @import("std");
const testing = std.testing;
const Vec3 = @import("zig-math").Vec3;
const Mat4 = @import("zig-math").Mat4;
const CSM = @import("engine/graphics/csm.zig");

pub const std_options: std.Options = .{ .log_level = .err };

test "ShadowCascades initZero produces valid zero state" {
    const cascades = CSM.ShadowCascades.initZero();
    // Zero-initialized cascades are NOT valid (splits must be > 0)
    try testing.expect(!cascades.isValid());

    // But all values must be finite (no NaN/Inf from uninitialized memory)
    for (0..CSM.CASCADE_COUNT) |i| {
        try testing.expect(std.math.isFinite(cascades.cascade_splits[i]));
        try testing.expect(std.math.isFinite(cascades.texel_sizes[i]));
        for (0..4) |row| {
            for (0..4) |col| {
                try testing.expect(std.math.isFinite(cascades.light_space_matrices[i].data[row][col]));
            }
        }
    }
}

test "ShadowCascades isValid rejects NaN splits" {
    var cascades = CSM.ShadowCascades.initZero();
    // Set up valid-looking data first
    for (0..CSM.CASCADE_COUNT) |i| {
        cascades.cascade_splits[i] = @as(f32, @floatFromInt(i + 1)) * 50.0;
        cascades.texel_sizes[i] = 0.1 * @as(f32, @floatFromInt(i + 1));
        cascades.light_space_matrices[i] = Mat4.identity;
    }
    try testing.expect(cascades.isValid());

    // Inject NaN into one cascade split
    cascades.cascade_splits[1] = std.math.nan(f32);
    try testing.expect(!cascades.isValid());
}

test "ShadowCascades isValid rejects non-monotonic splits" {
    var cascades = CSM.ShadowCascades.initZero();
    for (0..CSM.CASCADE_COUNT) |i| {
        cascades.cascade_splits[i] = @as(f32, @floatFromInt(i + 1)) * 50.0;
        cascades.texel_sizes[i] = 0.1 * @as(f32, @floatFromInt(i + 1));
        cascades.light_space_matrices[i] = Mat4.identity;
    }
    try testing.expect(cascades.isValid());

    // Make splits non-monotonic
    cascades.cascade_splits[2] = cascades.cascade_splits[1]; // equal, not increasing
    try testing.expect(!cascades.isValid());
}

test "computeCascades produces valid output for typical inputs" {
    const cascades = CSM.computeCascades(
        2048,
        std.math.degreesToRadians(70.0),
        16.0 / 9.0,
        0.1,
        250.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        Mat4.identity,
        true,
    );

    try testing.expect(cascades.isValid());

    // Splits should be monotonically increasing and bounded by shadow distance
    var last_split: f32 = 0.0;
    for (0..CSM.CASCADE_COUNT) |i| {
        try testing.expect(cascades.cascade_splits[i] > last_split);
        try testing.expect(cascades.cascade_splits[i] <= 250.0);
        last_split = cascades.cascade_splits[i];
    }

    // Last cascade should reach shadow distance
    try testing.expectApproxEqAbs(@as(f32, 250.0), cascades.cascade_splits[CSM.CASCADE_COUNT - 1], 1.0);
}

test "computeCascades deterministic with same inputs" {
    const args = .{
        @as(u32, 2048),
        std.math.degreesToRadians(@as(f32, 60.0)),
        @as(f32, 16.0 / 9.0),
        @as(f32, 0.1),
        @as(f32, 200.0),
        Vec3.init(0.5, -0.8, 0.3).normalize(),
        Mat4.identity,
        true,
    };

    const c1 = @call(.auto, CSM.computeCascades, args);
    const c2 = @call(.auto, CSM.computeCascades, args);

    for (0..CSM.CASCADE_COUNT) |i| {
        try testing.expectEqual(c1.cascade_splits[i], c2.cascade_splits[i]);
        try testing.expectEqual(c1.texel_sizes[i], c2.texel_sizes[i]);
        for (0..4) |row| {
            for (0..4) |col| {
                try testing.expectEqual(
                    c1.light_space_matrices[i].data[row][col],
                    c2.light_space_matrices[i].data[row][col],
                );
            }
        }
    }
}

test "computeCascades returns safe defaults for invalid inputs" {
    // Zero resolution
    const c1 = CSM.computeCascades(0, 1.0, 1.0, 0.1, 200.0, Vec3.init(0, -1, 0), Mat4.identity, true);
    try testing.expectEqual(@as(f32, 0.0), c1.cascade_splits[0]);

    // far <= near
    const c2 = CSM.computeCascades(1024, 1.0, 1.0, 200.0, 0.1, Vec3.init(0, -1, 0), Mat4.identity, true);
    try testing.expectEqual(@as(f32, 0.0), c2.cascade_splits[0]);

    // near <= 0
    const c3 = CSM.computeCascades(1024, 1.0, 1.0, 0.0, 200.0, Vec3.init(0, -1, 0), Mat4.identity, true);
    try testing.expectEqual(@as(f32, 0.0), c3.cascade_splits[0]);

    // Negative near plane
    const c4 = CSM.computeCascades(1024, 1.0, 1.0, -0.1, 200.0, Vec3.init(0, -1, 0), Mat4.identity, true);
    try testing.expectEqual(@as(f32, 0.0), c4.cascade_splits[0]);
}

test "computeCascades stable at large world coordinates" {
    // Test that texel snapping precision fix works at large coordinates
    // by verifying matrices are finite and valid even with a camera far from origin
    const far_view = Mat4.translate(Vec3.init(-50000.0, -100.0, -50000.0));
    const cascades = CSM.computeCascades(
        2048,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        250.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        far_view,
        true,
    );

    try testing.expect(cascades.isValid());

    // All matrix elements must be finite (no precision overflow)
    for (0..CSM.CASCADE_COUNT) |i| {
        for (0..4) |row| {
            for (0..4) |col| {
                try testing.expect(std.math.isFinite(cascades.light_space_matrices[i].data[row][col]));
            }
        }
    }
}

test "computeCascades uses fixed splits for large distances" {
    // Fixed split ratios (25%, 50%, 75%, 100%) keep practical voxel shadow
    // resolution across common near/medium distances.
    const cascades = CSM.computeCascades(
        2048,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        1000.0,
        Vec3.init(0, -1, 0),
        Mat4.identity,
        true,
    );

    try testing.expectApproxEqAbs(@as(f32, 250.0), cascades.cascade_splits[0], 0.1); // 25%
    try testing.expectApproxEqAbs(@as(f32, 500.0), cascades.cascade_splits[1], 0.1); // 50%
    try testing.expectApproxEqAbs(@as(f32, 750.0), cascades.cascade_splits[2], 0.1); // 75%
    try testing.expectApproxEqAbs(@as(f32, 1000.0), cascades.cascade_splits[3], 0.1); // 100%
}
