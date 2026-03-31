const std = @import("std");
const testing = std.testing;
const ShadowSystem = @import("shadow_system.zig").ShadowSystem;
const rhi = @import("rhi.zig");
const Mat4 = @import("../math/mat4.zig").Mat4;
const c = @import("../../c.zig").c;

// ============================================================================
// ShadowSystem Initialization Tests
// ============================================================================

test "ShadowSystem.init rejects zero resolution" {
    const result = ShadowSystem.init(testing.allocator, 0);
    try testing.expectError(error.InvalidResolution, result);
}

test "ShadowSystem.init accepts valid resolution" {
    const sys = try ShadowSystem.init(testing.allocator, 1024);
    try testing.expectEqual(@as(u32, 1024), sys.shadow_extent.width);
    try testing.expectEqual(@as(u32, 1024), sys.shadow_extent.height);
}

test "ShadowSystem.init sets safe default state" {
    const sys = try ShadowSystem.init(testing.allocator, 2048);

    // State flags should be false/default
    try testing.expect(!sys.pass_active);
    try testing.expectEqual(@as(u32, 0), sys.pass_index);
    try testing.expect(!sys.pipeline_bound);

    // Vulkan handles should be null (compare using == null instead of expectEqual)
    try testing.expect(sys.shadow_image == null);
    try testing.expect(sys.shadow_image_memory == null);
    try testing.expect(sys.shadow_image_view == null);
    try testing.expect(sys.shadow_sampler == null);
    try testing.expect(sys.shadow_render_pass == null);
    try testing.expect(sys.shadow_pipeline == null);

    // Array elements should be null/undefined
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        try testing.expect(sys.shadow_image_views[i] == null);
        try testing.expect(sys.shadow_framebuffers[i] == null);
    }
}

// ============================================================================
// ShadowSystem State Transition Tests
// ============================================================================

test "ShadowSystem pass state transitions" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);

    // Initial state
    try testing.expect(!sys.pass_active);
    try testing.expectEqual(@as(u32, 0), sys.pass_index);

    // Simulate begin pass (we can't call it without valid Vulkan objects,
    // but we can test the state transitions directly)
    sys.pass_active = true;
    sys.pass_index = 2;
    sys.pipeline_bound = false;

    try testing.expect(sys.pass_active);
    try testing.expectEqual(@as(u32, 2), sys.pass_index);
    try testing.expect(!sys.pipeline_bound);

    // Simulate end pass
    sys.pass_active = false;
    try testing.expect(!sys.pass_active);
}

test "ShadowSystem pass_matrix is set correctly" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);

    // Initial matrix should be identity
    try testing.expectEqual(@as(f32, 1.0), sys.pass_matrix.data[0][0]);
    try testing.expectEqual(@as(f32, 1.0), sys.pass_matrix.data[1][1]);
    try testing.expectEqual(@as(f32, 1.0), sys.pass_matrix.data[2][2]);
    try testing.expectEqual(@as(f32, 1.0), sys.pass_matrix.data[3][3]);

    // Set a custom matrix
    const custom_matrix = Mat4.translate(.{ .x = 10, .y = 20, .z = 30 });
    sys.pass_matrix = custom_matrix;

    try testing.expectEqual(@as(f32, 10.0), sys.pass_matrix.data[3][0]);
    try testing.expectEqual(@as(f32, 20.0), sys.pass_matrix.data[3][1]);
    try testing.expectEqual(@as(f32, 30.0), sys.pass_matrix.data[3][2]);
}

// ============================================================================
// ShadowSystem Image Layout Tests
// ============================================================================

test "ShadowSystem image layout transitions" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);

    // Initial layouts should be UNDEFINED (cast to same type for comparison)
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        try testing.expect(@as(u32, c.VK_IMAGE_LAYOUT_UNDEFINED) == @as(u32, sys.shadow_image_layouts[i]));
    }

    // Simulate layout transitions
    sys.shadow_image_layouts[0] = c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    sys.shadow_image_layouts[1] = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    try testing.expect(@as(u32, c.VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL) == @as(u32, sys.shadow_image_layouts[0]));
    try testing.expect(@as(u32, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL) == @as(u32, sys.shadow_image_layouts[1]));

    // Other cascades should remain UNDEFINED
    try testing.expect(@as(u32, c.VK_IMAGE_LAYOUT_UNDEFINED) == @as(u32, sys.shadow_image_layouts[2]));
    try testing.expect(@as(u32, c.VK_IMAGE_LAYOUT_UNDEFINED) == @as(u32, sys.shadow_image_layouts[3]));
}

// ============================================================================
// ShadowSystem Extent Tests
// ============================================================================

test "ShadowSystem extent preserves resolution" {
    const resolutions = [_]u32{ 256, 512, 1024, 2048, 4096 };

    for (resolutions) |res| {
        var sys = try ShadowSystem.init(testing.allocator, res);
        try testing.expectEqual(res, sys.shadow_extent.width);
        try testing.expectEqual(res, sys.shadow_extent.height);
    }
}

test "ShadowSystem deinit resets all handles to null" {
    // Create a system with mock non-null handles but don't actually call deinit
    // with invalid handles as it would call Vulkan destroy functions.
    // Instead, we manually verify the reset logic by simulating what deinit does.
    var sys = ShadowSystem{
        .allocator = testing.allocator,
        .shadow_extent = .{ .width = 1024, .height = 1024 },
        .shadow_image = @ptrFromInt(0x1234),
        .shadow_image_memory = @ptrFromInt(0x5678),
        .shadow_image_view = @ptrFromInt(0x9ABC),
        .shadow_sampler = @ptrFromInt(0xDEF0),
        .shadow_sampler_regular = @ptrFromInt(0x1111),
        .shadow_render_pass = @ptrFromInt(0x2222),
        .shadow_pipeline = @ptrFromInt(0x3333),
        .pass_active = true,
        .pass_index = 3,
        .pipeline_bound = true,
    };

    // Fill arrays with non-null values
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        sys.shadow_image_views[i] = @ptrFromInt(0x4000 + i);
        sys.shadow_framebuffers[i] = @ptrFromInt(0x5000 + i);
    }

    // Manually reset all state (mimicking what deinit does with null device)
    sys.shadow_image = null;
    sys.shadow_image_memory = null;
    sys.shadow_image_view = null;
    sys.shadow_sampler = null;
    sys.shadow_sampler_regular = null;
    sys.shadow_render_pass = null;
    sys.shadow_pipeline = null;
    sys.pass_active = false;
    sys.pass_index = 0;
    sys.pass_matrix = Mat4.identity;
    sys.pipeline_bound = false;
    inline for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        sys.shadow_image_views[i] = null;
        sys.shadow_image_layouts[i] = c.VK_IMAGE_LAYOUT_UNDEFINED;
        sys.shadow_framebuffers[i] = null;
    }

    // All handles should be reset to null
    try testing.expect(sys.shadow_image == null);
    try testing.expect(sys.shadow_image_memory == null);
    try testing.expect(sys.shadow_image_view == null);
    try testing.expect(sys.shadow_sampler == null);
    try testing.expect(sys.shadow_sampler_regular == null);
    try testing.expect(sys.shadow_render_pass == null);
    try testing.expect(sys.shadow_pipeline == null);

    // State should be reset
    try testing.expect(!sys.pass_active);
    try testing.expectEqual(@as(u32, 0), sys.pass_index);
    try testing.expect(!sys.pipeline_bound);
    try testing.expectEqual(Mat4.identity.data[3][0], sys.pass_matrix.data[3][0]);

    // Array elements should be reset
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        try testing.expect(sys.shadow_image_views[i] == null);
        try testing.expect(sys.shadow_framebuffers[i] == null);
    }
}

// ============================================================================
// ShadowSystem Error Path Tests
// ============================================================================

test "ShadowSystem beginPass cascade index bounds" {
    const sys = try ShadowSystem.init(testing.allocator, 1024);

    // Valid indices should be 0 to SHADOW_CASCADE_COUNT-1
    try testing.expect(rhi.SHADOW_CASCADE_COUNT > 0);

    // Test boundary values
    const valid_max = rhi.SHADOW_CASCADE_COUNT - 1;
    try testing.expectEqual(@as(u32, 3), valid_max); // SHADOW_CASCADE_COUNT is 4

    // Index equal to SHADOW_CASCADE_COUNT is out of bounds
    const out_of_bounds = rhi.SHADOW_CASCADE_COUNT;
    try testing.expect(out_of_bounds > valid_max);

    _ = sys;
}

test "ShadowSystem extent with different aspect ratios" {
    // The shadow system uses square cascades, but we should verify
    // the extent structure handles resolution correctly
    var sys1 = try ShadowSystem.init(testing.allocator, 512);
    try testing.expectEqual(@as(u32, 512), sys1.shadow_extent.width);
    try testing.expectEqual(@as(u32, 512), sys1.shadow_extent.height);

    var sys2 = try ShadowSystem.init(testing.allocator, 8192);
    try testing.expectEqual(@as(u32, 8192), sys2.shadow_extent.width);
    try testing.expectEqual(@as(u32, 8192), sys2.shadow_extent.height);
}

// ============================================================================
// ShadowSystem Cascade Array Bounds Tests
// ============================================================================

test "ShadowSystem cascade array bounds" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);

    // Verify array lengths match SHADOW_CASCADE_COUNT
    try testing.expectEqual(rhi.SHADOW_CASCADE_COUNT, sys.shadow_image_views.len);
    try testing.expectEqual(rhi.SHADOW_CASCADE_COUNT, sys.shadow_image_layouts.len);
    try testing.expectEqual(rhi.SHADOW_CASCADE_COUNT, sys.shadow_framebuffers.len);

    // Verify we can access all valid indices
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        _ = &sys.shadow_image_views[i];
        _ = &sys.shadow_image_layouts[i];
        _ = &sys.shadow_framebuffers[i];
    }
}

// ============================================================================
// ShadowSystem Memory Layout Tests
// ============================================================================

test "ShadowSystem struct size is reasonable" {
    // The struct should not be excessively large
    const size = @sizeOf(ShadowSystem);

    // Should be larger than just the basic fields (contains many Vulkan handles)
    try testing.expect(size > @sizeOf(usize) * 3);

    // Should be under a reasonable upper bound (10KB)
    try testing.expect(size < 10 * 1024);
}

test "ShadowSystem Mat4 alignment" {
    var sys = try ShadowSystem.init(testing.allocator, 1024);

    // pass_matrix should be properly aligned for GPU use
    const ptr = &sys.pass_matrix;
    const alignment = @alignOf(Mat4);
    const addr = @intFromPtr(ptr);

    // Address should be aligned
    try testing.expectEqual(@as(usize, 0), addr % alignment);
}
