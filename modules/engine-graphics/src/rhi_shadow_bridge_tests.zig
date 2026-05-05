const std = @import("std");
const testing = std.testing;
const rhi = @import("engine-rhi").rhi;
const Mat4 = @import("engine-math").Mat4;
const validateCascades = @import("engine-shadows").validateCascades;
const ShadowCascades = @import("engine-shadows").ShadowCascades;
const CASCADE_COUNT = @import("engine-shadows").CASCADE_COUNT;

const rhi_shadow_bridge = @import("vulkan/rhi_shadow_bridge.zig");

test "validateCascades returns true for valid cascades" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits = .{ 10.0, 50.0, 150.0, 500.0 };
    cascades.texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 };
    cascades.light_space_matrices = .{Mat4.identity} ** CASCADE_COUNT;

    const MockLogScope = struct {
        var warn_called: bool = false;
        fn warn(_: @TypeOf(@as(u32, 0)), comptime _: []const u8, _: anytype) void {
            warn_called = true;
        }
    };

    MockLogScope.warn_called = false;
    const result = validateCascades(cascades, MockLogScope{ .unused = 0 });
    try testing.expect(result);
    try testing.expect(!MockLogScope.warn_called);
}

test "validateCascades returns false and logs for invalid cascades" {
    var cascades = ShadowCascades.initZero();
    cascades.cascade_splits = .{ 10.0, std.math.nan(f32), 150.0, 500.0 };
    cascades.texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 };
    cascades.light_space_matrices = .{Mat4.identity} ** CASCADE_COUNT;

    const MockLogScope = struct {
        var warn_count: u32 = 0;
        fn warn(_: @TypeOf(@as(u32, 0)), comptime _: []const u8, _: anytype) void {
            warn_count += 1;
        }
    };

    MockLogScope.warn_count = 0;
    const result = validateCascades(cascades, MockLogScope{ .unused = 0 });
    try testing.expect(!result);
    try testing.expect(MockLogScope.warn_count > 0);
}

test "ShadowParams resolution defaults to 4096" {
    const params = rhi.ShadowParams{
        .light_space_matrices = .{Mat4.identity} ** rhi.SHADOW_CASCADE_COUNT,
        .cascade_splits = .{ 10.0, 50.0, 150.0, 500.0 },
        .shadow_texel_sizes = .{ 0.5, 1.0, 2.0, 4.0 },
    };

    try testing.expectEqual(@as(u32, 4096), params.resolution);
}

test "ShadowParams shadow_texel_sizes accessible via real field" {
    const params = rhi.ShadowParams{
        .light_space_matrices = .{Mat4.identity} ** rhi.SHADOW_CASCADE_COUNT,
        .cascade_splits = .{ 10.0, 50.0, 150.0, 500.0 },
        .shadow_texel_sizes = .{ 0.125, 0.25, 0.5, 1.0 },
        .resolution = 2048,
    };

    try testing.expectEqual(@as(f32, 0.125), params.shadow_texel_sizes[0]);
    try testing.expectEqual(@as(f32, 1.0), params.shadow_texel_sizes[3]);
    try testing.expectEqual(@as(u32, 2048), params.resolution);
}

test "rhi_shadow_bridge getShadowMapHandle returns 0 for OOB cascade" {
    const MockShadowRuntime = struct {
        shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle = .{ 10, 20, 30, 40 },
    };

    const ctx = struct {
        shadow_runtime: MockShadowRuntime,
    }{ .shadow_runtime = .{} };

    const handle = rhi_shadow_bridge.getShadowMapHandle(ctx, rhi.SHADOW_CASCADE_COUNT);
    try testing.expectEqual(@as(rhi.TextureHandle, 0), handle);

    const handle_plus_one = rhi_shadow_bridge.getShadowMapHandle(ctx, rhi.SHADOW_CASCADE_COUNT + 5);
    try testing.expectEqual(@as(rhi.TextureHandle, 0), handle_plus_one);
}

test "rhi_shadow_bridge getShadowMapHandle returns valid handle for cascade 0..3" {
    const MockShadowRuntime = struct {
        shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle = .{ 100, 200, 300, 400 },
    };

    const ctx = struct {
        shadow_runtime: MockShadowRuntime,
    }{ .shadow_runtime = .{} };

    try testing.expectEqual(@as(rhi.TextureHandle, 100), rhi_shadow_bridge.getShadowMapHandle(ctx, 0));
    try testing.expectEqual(@as(rhi.TextureHandle, 200), rhi_shadow_bridge.getShadowMapHandle(ctx, 1));
    try testing.expectEqual(@as(rhi.TextureHandle, 300), rhi_shadow_bridge.getShadowMapHandle(ctx, 2));
    try testing.expectEqual(@as(rhi.TextureHandle, 400), rhi_shadow_bridge.getShadowMapHandle(ctx, 3));
}

test "ShadowUniforms extern struct size matches production layout" {
    const ShadowUniforms = @import("vulkan/rhi_shadow_bridge.zig").ShadowUniforms;

    const matrices_size = @sizeOf([rhi.SHADOW_CASCADE_COUNT]Mat4);
    const splits_size = @sizeOf([4]f32);
    const sizes_size = @sizeOf([4]f32);
    const params_size = @sizeOf([4]f32);
    const expected = matrices_size + splits_size + sizes_size + params_size;

    try testing.expectEqual(@as(usize, expected), @sizeOf(ShadowUniforms));
}

test "ShadowUniforms field offsets are sequential for GPU upload" {
    const ShadowUniforms = @import("vulkan/rhi_shadow_bridge.zig").ShadowUniforms;

    const matrices_end = @sizeOf([rhi.SHADOW_CASCADE_COUNT]Mat4);
    const splits_offset = @offsetOf(ShadowUniforms, "cascade_splits");
    const sizes_offset = @offsetOf(ShadowUniforms, "shadow_texel_sizes");
    const params_offset = @offsetOf(ShadowUniforms, "shadow_params");

    try testing.expectEqual(matrices_end, splits_offset);
    try testing.expectEqual(matrices_end + @sizeOf([4]f32), sizes_offset);
    try testing.expectEqual(matrices_end + @sizeOf([4]f32) * 2, params_offset);
}
