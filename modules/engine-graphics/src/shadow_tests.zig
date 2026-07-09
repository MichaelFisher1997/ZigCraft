const std = @import("std");
const testing = std.testing;
const c = @import("c").c;
const rhi = @import("engine-rhi").rhi;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const ShadowSystem = @import("engine-shadows").ShadowSystem;
const computeCascades = @import("engine-shadows").computeCascades;
const practicalSplit = @import("engine-shadows").practicalSplit;
const ShadowCascades = @import("engine-shadows").ShadowCascades;
const CASCADE_COUNT = @import("engine-shadows").CASCADE_COUNT;
const shadow_scene = @import("engine-shadows").shadow_scene;
const ShadowConfig = rhi.ShadowConfig;

fn mat4IsIdentity(m: Mat4) bool {
    for (0..4) |row| {
        for (0..4) |col| {
            const expected: f32 = if (row == col) 1.0 else 0.0;
            if (@abs(m.data[row][col] - expected) > 0.0001) return false;
        }
    }
    return true;
}

test "ShadowSystem init rejects zero resolution" {
    try testing.expectError(error.InvalidResolution, ShadowSystem.init(testing.allocator, 0));
}

test "ShadowSystem init accepts valid resolution" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer {
        sys.deinit(null);
    }

    try testing.expectEqual(@as(u32, 1024), sys.shadow_extent.width);
    try testing.expectEqual(@as(u32, 1024), sys.shadow_extent.height);
}

test "ShadowSystem state defaults after init" {
    var sys = try ShadowSystem.init(testing.allocator, 2048);
    defer sys.deinit(null);

    try testing.expect(!sys.pass_active);
    try testing.expectEqual(@as(u32, 0), sys.pass_index);
    try testing.expect(!sys.pipeline_bound);
    try testing.expect(mat4IsIdentity(sys.pass_matrix));
}

test "ShadowSystem init various resolutions" {
    const resolutions = [_]u32{ 512, 1024, 2048, 4096 };
    for (resolutions) |res| {
        var sys = try ShadowSystem.init(testing.allocator, res);
        defer sys.deinit(null);

        try testing.expectEqual(res, sys.shadow_extent.width);
        try testing.expectEqual(res, sys.shadow_extent.height);
    }
}

test "ShadowCascades initZero sets identity matrices" {
    const cascades = ShadowCascades.initZero();

    for (0..CASCADE_COUNT) |i| {
        try testing.expectEqual(@as(f32, 0.0), cascades.cascade_splits[i]);
        try testing.expectEqual(@as(f32, 0.0), cascades.texel_sizes[i]);
        try testing.expect(mat4IsIdentity(cascades.light_space_matrices[i]));
    }
}

test "ShadowCascades isValid returns true for valid cascades" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits = .{ 10.0, 50.0, 150.0, 500.0 };
    cascades.overlap_starts = .{ 0.1, 9.0, 45.0, 140.0 };
    cascades.texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 };
    cascades.depth_spans = .{ 10.0, 20.0, 40.0, 80.0 };
    cascades.light_space_matrices = .{Mat4.identity} ** CASCADE_COUNT;

    try testing.expect(cascades.isValid());
}

test "ShadowCascades isValid returns false for non-finite splits" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits = .{ 10.0, std.math.nan(f32), 150.0, 500.0 };
    cascades.texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 };

    try testing.expect(!cascades.isValid());
}

test "ShadowCascades isValid returns false for zero texel size" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits = .{ 10.0, 50.0, 150.0, 500.0 };
    cascades.texel_sizes = .{ 0.5, 0.0, 2.0, 4.0 };

    try testing.expect(!cascades.isValid());
}

test "ShadowCascades isValid returns false for non-increasing splits" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits = .{ 10.0, 50.0, 40.0, 500.0 };
    cascades.texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 };

    try testing.expect(!cascades.isValid());
}

test "computeCascades returns zeroed cascades on invalid input" {
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

    try testing.expect(!cascades.isValid());
}

test "computeCascades returns zeroed cascades when far equals near" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        100.0,
        100.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        Mat4.identity,
        true,
    );

    try testing.expect(!cascades.isValid());
}

test "computeCascades returns zeroed cascades when near is zero" {
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

    try testing.expect(!cascades.isValid());
}

test "computeCascades returns zeroed cascades when near is negative" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        -10.0,
        200.0,
        Vec3.init(0.3, -1.0, 0.2).normalize(),
        Mat4.identity,
        true,
    );

    try testing.expect(!cascades.isValid());
}

test "computeCascades produces increasing splits" {
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
        try testing.expect(cascades.cascade_splits[i] > last_split);
        last_split = cascades.cascade_splits[i];
    }
}

test "computeCascades produces positive texel sizes" {
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

    for (0..CASCADE_COUNT) |i| {
        try testing.expect(cascades.texel_sizes[i] > 0.0);
    }
}

test "computeCascades uses practical splits for large shadow distance" {
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

    for (0..CASCADE_COUNT) |i| {
        const expected = practicalSplit(0.1, 1000.0, i, 0.75);
        try testing.expectApproxEqAbs(expected, cascades.cascade_splits[i], 0.001);
    }
}

test "computeCascades uses practical splits for small shadow distance" {
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

    for (0..CASCADE_COUNT) |i| {
        const expected = practicalSplit(0.1, 200.0, i, 0.75);
        try testing.expectApproxEqAbs(expected, cascades.cascade_splits[i], 0.001);
    }
}

test "computeCascades with reverse-Z produces valid matrices" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        500.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        true,
    );

    try testing.expect(cascades.isValid());
}

test "computeCascades with standard Z produces valid matrices" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        500.0,
        Vec3.init(0.0, -1.0, 0.0),
        Mat4.identity,
        false,
    );

    try testing.expect(cascades.isValid());
}

test "computeCascades handles extreme sun direction (up)" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(0.0, 1.0, 0.0),
        Mat4.identity,
        true,
    );

    try testing.expect(cascades.isValid());
}

test "computeCascades handles extreme sun direction (near-horizontal)" {
    const cascades = computeCascades(
        1024,
        std.math.degreesToRadians(60.0),
        16.0 / 9.0,
        0.1,
        200.0,
        Vec3.init(1.0, 0.1, 0.0).normalize(),
        Mat4.identity,
        true,
    );

    try testing.expect(cascades.isValid());
}

test "ShadowUniforms extern struct has correct size" {
    const ShadowUniforms = @import("vulkan/descriptor_manager.zig").ShadowUniforms;

    const expected_size = @sizeOf([rhi.SHADOW_CASCADE_COUNT]Mat4) + (@sizeOf(f32) * 24);
    try testing.expectEqual(@as(usize, expected_size), @sizeOf(ShadowUniforms));
}

test "ShadowUniforms field offsets" {
    const ShadowUniforms = @import("vulkan/descriptor_manager.zig").ShadowUniforms;

    const matrices_size = @sizeOf([rhi.SHADOW_CASCADE_COUNT]Mat4);
    const splits_offset = @offsetOf(ShadowUniforms, "cascade_splits");
    const overlap_offset = @offsetOf(ShadowUniforms, "overlap_starts");
    const texel_offset = @offsetOf(ShadowUniforms, "shadow_texel_sizes");
    const depth_span_offset = @offsetOf(ShadowUniforms, "shadow_depth_spans");
    const params_offset = @offsetOf(ShadowUniforms, "shadow_params");

    try testing.expectEqual(matrices_size, splits_offset);
    try testing.expectEqual(matrices_size + @sizeOf([4]f32), overlap_offset);
    try testing.expectEqual(matrices_size + @sizeOf([4]f32) * 2, texel_offset);
    try testing.expectEqual(matrices_size + @sizeOf([4]f32) * 3, depth_span_offset);
    try testing.expectEqual(matrices_size + @sizeOf([4]f32) * 4, params_offset);
}

test "getShadowMapHandle returns 0 for out-of-bounds cascade" {
    const MockShadowCtx = struct {
        fn getShadowMapHandle(ctx: *anyopaque, cascade_index: u32) rhi.TextureHandle {
            _ = ctx;
            if (cascade_index >= rhi.SHADOW_CASCADE_COUNT) return 0;
            return cascade_index + 1;
        }
    };

    const VTable = rhi.IShadowContext.VTable{
        .beginPass = undefined,
        .endPass = undefined,
        .updateUniforms = undefined,
        .getShadowMapHandle = MockShadowCtx.getShadowMapHandle,
    };

    const ctx = @as(*anyopaque, @ptrFromInt(0x1234));
    const shadow_ctx = rhi.IShadowContext{ .ptr = ctx, .vtable = &VTable };

    try testing.expectEqual(@as(rhi.TextureHandle, 0), shadow_ctx.getShadowMapHandle(rhi.SHADOW_CASCADE_COUNT));
    try testing.expectEqual(@as(rhi.TextureHandle, 0), shadow_ctx.getShadowMapHandle(rhi.SHADOW_CASCADE_COUNT + 1));
}

test "getShadowMapHandle returns valid handle for valid cascade" {
    const MockShadowCtx = struct {
        fn getShadowMapHandle(ctx: *anyopaque, cascade_index: u32) rhi.TextureHandle {
            _ = ctx;
            if (cascade_index >= rhi.SHADOW_CASCADE_COUNT) return 0;
            return cascade_index + 1;
        }
    };

    const VTable = rhi.IShadowContext.VTable{
        .beginPass = undefined,
        .endPass = undefined,
        .updateUniforms = undefined,
        .getShadowMapHandle = MockShadowCtx.getShadowMapHandle,
    };

    const ctx = @as(*anyopaque, @ptrFromInt(0x1234));
    const shadow_ctx = rhi.IShadowContext{ .ptr = ctx, .vtable = &VTable };

    try testing.expectEqual(@as(rhi.TextureHandle, 1), shadow_ctx.getShadowMapHandle(0));
    try testing.expectEqual(@as(rhi.TextureHandle, 2), shadow_ctx.getShadowMapHandle(1));
    try testing.expectEqual(@as(rhi.TextureHandle, 3), shadow_ctx.getShadowMapHandle(2));
    try testing.expectEqual(@as(rhi.TextureHandle, 4), shadow_ctx.getShadowMapHandle(3));
}

test "ShadowConfig default values" {
    const config = rhi.ShadowConfig{};
    try testing.expectEqual(@as(f32, 250.0), config.distance);
    try testing.expectEqual(@as(u32, 4096), config.resolution);
    try testing.expectEqual(@as(u8, 9), config.pcf_samples);
    try testing.expect(config.cascade_blend);
    try testing.expectEqual(@as(f32, 0.35), config.strength);
    try testing.expectEqual(@as(f32, 3.0), config.light_size);
    try testing.expectEqual(@as(f32, 250.0), config.caster_distance);
}

test "ShadowParams struct layout" {
    const params = rhi.ShadowParams{
        .light_space_matrices = .{Mat4.identity} ** rhi.SHADOW_CASCADE_COUNT,
        .cascade_splits = .{ 10.0, 50.0, 150.0, 500.0 },
        .shadow_texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 },
        .shadow_depth_spans = .{ 100.0, 200.0, 400.0, 800.0 },
        .light_size = 3.0,
    };

    try testing.expectEqual(@as(f32, 10.0), params.cascade_splits[0]);
    try testing.expectEqual(@as(f32, 500.0), params.cascade_splits[3]);
    try testing.expectEqual(@as(f32, 3.0), params.light_size);
}

test "ShadowCascades isValid detects non-finite light space matrix" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits = .{ 10.0, 50.0, 150.0, 500.0 };
    cascades.overlap_starts = .{ 0.1, 9.0, 45.0, 140.0 };
    cascades.texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 };
    cascades.depth_spans = .{ 10.0, 20.0, 40.0, 80.0 };

    var bad_matrix = Mat4.identity;
    bad_matrix.data[0][0] = std.math.nan(f32);
    cascades.light_space_matrices[1] = bad_matrix;

    try testing.expect(!cascades.isValid());
}

test "ShadowCascades isValid returns false for zero split" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits = .{ 0.0, 50.0, 150.0, 500.0 };
    cascades.texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 };

    try testing.expect(!cascades.isValid());
}

test "IShadowScene renderShadowPass delegates to vtable" {
    const CallTracker = struct {
        calls: u32 = 0,
        last_matrix: Mat4 = Mat4.identity,
        last_camera: Vec3 = Vec3.zero,
        last_config: ShadowConfig = .{},

        fn render(ptr: *anyopaque, light_space_matrix: Mat4, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3, shadow_config: ShadowConfig) void {
            _ = caster_min;
            _ = caster_max;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            self.last_matrix = light_space_matrix;
            self.last_camera = camera_pos;
            self.last_config = shadow_config;
        }
    };

    var tracker = CallTracker{};
    const vtable = shadow_scene.IShadowScene.VTable{
        .renderShadowPass = CallTracker.render,
    };
    const scene = shadow_scene.IShadowScene{
        .ptr = &tracker,
        .vtable = &vtable,
    };

    const matrix = Mat4.identity;
    const camera = Vec3.init(1.0, 2.0, 3.0);
    const config = ShadowConfig{ .distance = 500.0, .resolution = 2048 };

    scene.renderShadowPass(matrix, camera, Vec3.zero, Vec3.zero, config);

    try testing.expectEqual(@as(u32, 1), tracker.calls);
    try testing.expectEqual(@as(f32, 1.0), tracker.last_camera.x);
    try testing.expectEqual(@as(f32, 2.0), tracker.last_camera.y);
    try testing.expectEqual(@as(f32, 3.0), tracker.last_camera.z);
    try testing.expectEqual(@as(f32, 500.0), tracker.last_config.distance);
}

test "ShadowParams default light_size is 3.0" {
    const params = rhi.ShadowParams{
        .light_space_matrices = .{Mat4.identity} ** rhi.SHADOW_CASCADE_COUNT,
        .cascade_splits = .{ 10.0, 50.0, 150.0, 500.0 },
        .shadow_texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 },
        .shadow_depth_spans = .{ 100.0, 200.0, 400.0, 800.0 },
    };

    try testing.expectEqual(@as(f32, 3.0), params.light_size);
}

test "ShadowSystem endPass is safe when pass not active" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);
    defer sys.deinit(null);

    try testing.expect(!sys.pass_active);
    sys.pass_index = 2;

    sys.endPass(null);

    try testing.expect(!sys.pass_active);
    try testing.expectEqual(@as(u32, 2), sys.pass_index);
}

test "ShadowSystem deinit resets pass state" {
    var sys = try ShadowSystem.init(testing.allocator, 2048);
    defer sys.deinit(null);

    sys.pass_active = true;
    sys.pass_index = 3;
    sys.pass_matrix = Mat4.identity;
    sys.pipeline_bound = true;

    sys.deinit(null);

    try testing.expect(!sys.pass_active);
    try testing.expectEqual(@as(u32, 0), sys.pass_index);
    try testing.expect(!sys.pipeline_bound);
}

test "IShadowScene vtable renderShadowPass is called with correct parameters" {
    const VerifyParams = struct {
        called: bool = false,
        matrix_received: Mat4 = Mat4.identity,
        camera_received: Vec3 = Vec3.zero,
        config_received: ShadowConfig = .{},

        fn render(ptr: *anyopaque, light_space_matrix: Mat4, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3, shadow_config: ShadowConfig) void {
            _ = caster_min;
            _ = caster_max;
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.called = true;
            self.matrix_received = light_space_matrix;
            self.camera_received = camera_pos;
            self.config_received = shadow_config;
        }
    };

    var verify = VerifyParams{};
    const vtable = shadow_scene.IShadowScene.VTable{
        .renderShadowPass = VerifyParams.render,
    };
    const scene = shadow_scene.IShadowScene{
        .ptr = &verify,
        .vtable = &vtable,
    };

    var custom_matrix = Mat4.identity;
    custom_matrix.data[0][0] = 5.0;
    const custom_camera = Vec3.init(100.0, -50.0, 200.0);
    const custom_config = ShadowConfig{ .strength = 0.5, .light_size = 10.0 };

    scene.renderShadowPass(custom_matrix, custom_camera, Vec3.zero, Vec3.zero, custom_config);

    try testing.expect(verify.called);
    try testing.expectEqual(@as(f32, 5.0), verify.matrix_received.data[0][0]);
    try testing.expectEqual(@as(f32, 100.0), verify.camera_received.x);
    try testing.expectEqual(@as(f32, -50.0), verify.camera_received.y);
    try testing.expectEqual(@as(f32, 200.0), verify.camera_received.z);
    try testing.expectEqual(@as(f32, 0.5), verify.config_received.strength);
    try testing.expectEqual(@as(f32, 10.0), verify.config_received.light_size);
}
