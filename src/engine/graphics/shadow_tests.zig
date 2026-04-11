const std = @import("std");
const testing = std.testing;
const csm = @import("csm.zig");
const ShadowCascades = csm.ShadowCascades;
const computeCascades = csm.computeCascades;
const validateCascades = csm.validateCascades;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Mat4 = @import("../math/mat4.zig").Mat4;
const rhi = @import("rhi.zig");
const shadow_scene = @import("shadow_scene.zig");
const rhi_shadow_bridge = @import("vulkan/rhi_shadow_bridge.zig");
const ShadowConfig = @import("rhi_types.zig").ShadowConfig;
const ShadowParams = @import("rhi_types.zig").ShadowParams;

test "ShadowCascades.initZero creates identity matrices and zero arrays" {
    const cascades = ShadowCascades.initZero();

    try testing.expectEqual(@as(f32, 1), cascades.light_space_matrices[0].data[0][0]);
    try testing.expectEqual(@as(f32, 0), cascades.cascade_splits[0]);
    try testing.expectEqual(@as(f32, 0), cascades.texel_sizes[0]);

    try testing.expectEqual(@as(f32, 1), cascades.light_space_matrices[3].data[3][3]);
    try testing.expectEqual(@as(f32, 0), cascades.cascade_splits[3]);
    try testing.expectEqual(@as(f32, 0), cascades.texel_sizes[3]);
}

test "ShadowCascades.isValid returns true for properly initialized cascades" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits[0] = 50.0;
    cascades.cascade_splits[1] = 100.0;
    cascades.cascade_splits[2] = 175.0;
    cascades.cascade_splits[3] = 250.0;
    cascades.texel_sizes[0] = 0.5;
    cascades.texel_sizes[1] = 1.0;
    cascades.texel_sizes[2] = 2.0;
    cascades.texel_sizes[3] = 4.0;

    try testing.expect(cascades.isValid());
}

test "ShadowCascades.isValid returns false for non-increasing splits" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits[0] = 100.0;
    cascades.cascade_splits[1] = 50.0;
    cascades.cascade_splits[2] = 175.0;
    cascades.cascade_splits[3] = 250.0;
    cascades.texel_sizes[0] = 0.5;
    cascades.texel_sizes[1] = 1.0;
    cascades.texel_sizes[2] = 2.0;
    cascades.texel_sizes[3] = 4.0;

    try testing.expect(!cascades.isValid());
}

test "ShadowCascades.isValid returns false for non-positive texel size" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits[0] = 50.0;
    cascades.cascade_splits[1] = 100.0;
    cascades.cascade_splits[2] = 175.0;
    cascades.cascade_splits[3] = 250.0;
    cascades.texel_sizes[0] = 0.0;
    cascades.texel_sizes[1] = 1.0;
    cascades.texel_sizes[2] = 2.0;
    cascades.texel_sizes[3] = 4.0;

    try testing.expect(!cascades.isValid());
}

test "ShadowCascades.isValid returns false for NaN in splits" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits[0] = std.math.nan(f32);
    cascades.cascade_splits[1] = 100.0;
    cascades.cascade_splits[2] = 175.0;
    cascades.cascade_splits[3] = 250.0;
    cascades.texel_sizes[0] = 0.5;
    cascades.texel_sizes[1] = 1.0;
    cascades.texel_sizes[2] = 2.0;
    cascades.texel_sizes[3] = 4.0;

    try testing.expect(!cascades.isValid());
}

test "ShadowCascades.isValid returns false for NaN in texel sizes" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits[0] = 50.0;
    cascades.cascade_splits[1] = 100.0;
    cascades.cascade_splits[2] = 175.0;
    cascades.cascade_splits[3] = 250.0;
    cascades.texel_sizes[0] = 0.5;
    cascades.texel_sizes[1] = std.math.nan(f32);
    cascades.texel_sizes[2] = 2.0;
    cascades.texel_sizes[3] = 4.0;

    try testing.expect(!cascades.isValid());
}

test "computeCascades returns zero cascades for resolution == 0" {
    const cascades = computeCascades(
        0,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        Mat4.identity,
        true,
    );

    try testing.expectEqual(@as(f32, 0), cascades.cascade_splits[0]);
    try testing.expectEqual(@as(f32, 0), cascades.texel_sizes[0]);
}

test "computeCascades returns zero cascades for far <= near" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        100.0,
        50.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        Mat4.identity,
        true,
    );

    try testing.expectEqual(@as(f32, 0), cascades.cascade_splits[0]);
    try testing.expectEqual(@as(f32, 0), cascades.texel_sizes[0]);
}

test "computeCascades returns zero cascades for near <= 0" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.0,
        200.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        Mat4.identity,
        true,
    );

    try testing.expectEqual(@as(f32, 0), cascades.cascade_splits[0]);
    try testing.expectEqual(@as(f32, 0), cascades.texel_sizes[0]);
}

test "computeCascades uses fixed splits for large shadow distance (>500)" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        1000.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        Mat4.identity,
        true,
    );

    try testing.expect(cascades.cascade_splits[3] > 500.0);
    try testing.expect(cascades.texel_sizes[0] > 0.0);
    try testing.expect(cascades.isValid());
}

test "computeCascades uses logarithmic splits for small shadow distance (<=500)" {
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

    try testing.expect(cascades.cascade_splits[3] <= 200.0);
    try testing.expect(cascades.isValid());
}

test "ShadowConfig default values" {
    const config = ShadowConfig{};
    try testing.expectEqual(@as(f32, 250.0), config.distance);
    try testing.expectEqual(@as(u32, 4096), config.resolution);
    try testing.expectEqual(@as(u8, 12), config.pcf_samples);
    try testing.expectEqual(@as(bool, true), config.cascade_blend);
    try testing.expectEqual(@as(f32, 0.35), config.strength);
    try testing.expectEqual(@as(f32, 3.0), config.light_size);
    try testing.expectEqual(@as(f32, 250.0), config.caster_distance);
}

test "ShadowParams struct layout and defaults" {
    const params = ShadowParams{
        .light_space_matrices = .{Mat4.identity} ** rhi.SHADOW_CASCADE_COUNT,
        .cascade_splits = .{ 50.0, 100.0, 175.0, 250.0 },
        .shadow_texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 },
        .light_size = 3.0,
    };

    try testing.expectEqual(@as(f32, 3.0), params.light_size);
    try testing.expectEqual(@as(f32, 50.0), params.cascade_splits[0]);
    try testing.expectEqual(@as(f32, 250.0), params.cascade_splits[3]);
}

test "IShadowScene interface delegation" {
    const MockScene = struct {
        fn renderShadowPassFn(ptr: *anyopaque, light_space_matrix: Mat4, camera_pos: Vec3, shadow_config: ShadowConfig) void {
            _ = light_space_matrix;
            _ = camera_pos;
            _ = shadow_config;
            const count: *u32 = @ptrCast(@alignCast(ptr));
            count.* += 1;
        }
    };

    var counter: u32 = 0;
    const mock = shadow_scene.IShadowScene{
        .ptr = &counter,
        .vtable = &.{
            .renderShadowPass = MockScene.renderShadowPassFn,
        },
    };

    try testing.expectEqual(@as(u32, 0), counter);

    mock.renderShadowPass(Mat4.identity, Vec3.zero, ShadowConfig{});
    try testing.expectEqual(@as(u32, 1), counter);

    mock.renderShadowPass(Mat4.identity, Vec3.zero, ShadowConfig{});
    try testing.expectEqual(@as(u32, 2), counter);
}

test "CASCADE_COUNT is 4" {
    try testing.expectEqual(@as(u32, 4), csm.CASCADE_COUNT);
    try testing.expectEqual(@as(u32, 4), rhi.SHADOW_CASCADE_COUNT);
}

test "getShadowMapHandle returns 0 for out-of-bounds cascade index" {
    const MockShadowBridge = struct {
        fn getShadowMapHandleImpl(_: *anyopaque, cascade_index: u32) rhi.TextureHandle {
            if (cascade_index >= rhi.SHADOW_CASCADE_COUNT) return 0;
            return 42;
        }
    };

    var ctx: usize = 0;
    try testing.expectEqual(@as(rhi.TextureHandle, 0), MockShadowBridge.getShadowMapHandleImpl(&ctx, 4));
    try testing.expectEqual(@as(rhi.TextureHandle, 0), MockShadowBridge.getShadowMapHandleImpl(&ctx, 100));
    try testing.expectEqual(@as(rhi.TextureHandle, 42), MockShadowBridge.getShadowMapHandleImpl(&ctx, 0));
    try testing.expectEqual(@as(rhi.TextureHandle, 42), MockShadowBridge.getShadowMapHandleImpl(&ctx, 3));
}

test "validateCascades returns true for valid cascades" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits[0] = 50.0;
    cascades.cascade_splits[1] = 100.0;
    cascades.cascade_splits[2] = 175.0;
    cascades.cascade_splits[3] = 250.0;
    cascades.texel_sizes[0] = 0.5;
    cascades.texel_sizes[1] = 1.0;
    cascades.texel_sizes[2] = 2.0;
    cascades.texel_sizes[3] = 4.0;

    const result = validateCascades(cascades, std.log.default);
    try testing.expect(result);
}

test "validateCascades returns false for invalid cascades" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits[0] = 50.0;
    cascades.cascade_splits[1] = 0.0;
    cascades.cascade_splits[2] = 175.0;
    cascades.cascade_splits[3] = 250.0;
    cascades.texel_sizes[0] = 0.5;
    cascades.texel_sizes[1] = 1.0;
    cascades.texel_sizes[2] = 2.0;
    cascades.texel_sizes[3] = 4.0;

    const result = validateCascades(cascades, std.log.default);
    try testing.expect(!result);
}
