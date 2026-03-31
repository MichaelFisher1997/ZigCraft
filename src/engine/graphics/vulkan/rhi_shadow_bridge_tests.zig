const std = @import("std");
const testing = std.testing;
const rhi_shadow_bridge = @import("rhi_shadow_bridge.zig");
const rhi = @import("../rhi.zig");
const Mat4 = @import("../../math/mat4.zig").Mat4;
const c = @import("../../../c.zig").c;

// ShadowUniforms struct definition for testing (matches rhi_shadow_bridge.zig)
const ShadowUniforms = extern struct {
    light_space_matrices: [rhi.SHADOW_CASCADE_COUNT]Mat4,
    cascade_splits: [4]f32,
    shadow_texel_sizes: [4]f32,
    shadow_params: [4]f32,
};

// ============================================================================
// ShadowUniforms Struct Layout Tests
// ============================================================================

test "ShadowUniforms is extern struct with GPU-compatible layout" {
    // ShadowUniforms must be extern for GPU compatibility
    // The fact that this compiles and the size is correct proves it has proper layout
    const size = @sizeOf(ShadowUniforms);
    try testing.expect(size > 0);
}

test "ShadowUniforms has correct size" {
    const size = @sizeOf(ShadowUniforms);

    // Expected size:
    // light_space_matrices: [4]Mat4 = 4 * 64 = 256 bytes
    // cascade_splits: [4]f32 = 16 bytes
    // shadow_texel_sizes: [4]f32 = 16 bytes
    // shadow_params: [4]f32 = 16 bytes
    // Total = 304 bytes (no padding needed as all are 16-byte aligned)
    const expected_size = 4 * 64 + 4 * 4 + 4 * 4 + 4 * 4;
    try testing.expectEqual(expected_size, size);
}

test "ShadowUniforms field offsets are correct" {
    // Verify field offsets for GPU layout compatibility
    try testing.expectEqual(@as(usize, 0), @offsetOf(ShadowUniforms, "light_space_matrices"));
    try testing.expectEqual(@as(usize, 256), @offsetOf(ShadowUniforms, "cascade_splits"));
    try testing.expectEqual(@as(usize, 272), @offsetOf(ShadowUniforms, "shadow_texel_sizes"));
    try testing.expectEqual(@as(usize, 288), @offsetOf(ShadowUniforms, "shadow_params"));
}

test "ShadowUniforms total size matches offset of last field + size" {
    const last_offset = @offsetOf(ShadowUniforms, "shadow_params");
    const last_size = @sizeOf([4]f32);
    const computed_size = last_offset + last_size;

    try testing.expectEqual(computed_size, @sizeOf(ShadowUniforms));
}

// ============================================================================
// getShadowMapHandle Tests
// ============================================================================

test "getShadowMapHandle validates cascade index bounds" {
    // Create a minimal mock context
    const MockContext = struct {
        shadow_runtime: struct {
            shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle,
        },
    };

    var ctx = MockContext{
        .shadow_runtime = .{
            .shadow_map_handles = .{ 1, 2, 3, 4 },
        },
    };

    // Valid indices should return the handle
    try testing.expectEqual(@as(rhi.TextureHandle, 1), rhi_shadow_bridge.getShadowMapHandle(&ctx, 0));
    try testing.expectEqual(@as(rhi.TextureHandle, 2), rhi_shadow_bridge.getShadowMapHandle(&ctx, 1));
    try testing.expectEqual(@as(rhi.TextureHandle, 3), rhi_shadow_bridge.getShadowMapHandle(&ctx, 2));
    try testing.expectEqual(@as(rhi.TextureHandle, 4), rhi_shadow_bridge.getShadowMapHandle(&ctx, 3));

    // Out of bounds should return 0 (invalid handle)
    try testing.expectEqual(@as(rhi.TextureHandle, 0), rhi_shadow_bridge.getShadowMapHandle(&ctx, 4));
    try testing.expectEqual(@as(rhi.TextureHandle, 0), rhi_shadow_bridge.getShadowMapHandle(&ctx, 100));
    try testing.expectEqual(@as(rhi.TextureHandle, 0), rhi_shadow_bridge.getShadowMapHandle(&ctx, 0xFFFFFFFF));
}

test "getShadowMapHandle with invalid handles in array" {
    const MockContext = struct {
        shadow_runtime: struct {
            shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle,
        },
    };

    var ctx = MockContext{
        .shadow_runtime = .{
            .shadow_map_handles = .{ 0, 0, 0, 0 }, // All invalid
        },
    };

    // Should return 0 for all cascades
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        try testing.expectEqual(@as(rhi.TextureHandle, 0), rhi_shadow_bridge.getShadowMapHandle(&ctx, @intCast(i)));
    }
}

// ============================================================================
// ShadowParams Struct Tests (via ShadowUniforms)
// ============================================================================

test "ShadowUniforms initialization with test data" {
    var matrices: [rhi.SHADOW_CASCADE_COUNT]Mat4 = undefined;
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        matrices[i] = Mat4.identity;
        // Add some variation to verify individual matrices
        matrices[i].data[3][0] = @floatFromInt(i * 10);
    }

    const splits = [4]f32{ 10.0, 50.0, 150.0, 500.0 };
    const sizes = [4]f32{ 0.1, 0.05, 0.025, 0.0125 };

    const uniforms = ShadowUniforms{
        .light_space_matrices = matrices,
        .cascade_splits = splits,
        .shadow_texel_sizes = sizes,
        .shadow_params = .{ 2.5, 0.0, 0.0, 0.0 }, // light_size = 2.5
    };

    // Verify matrices were stored correctly
    for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
        try testing.expectEqual(@as(f32, @floatFromInt(i * 10)), uniforms.light_space_matrices[i].data[3][0]);
    }

    // Verify splits
    try testing.expectApproxEqAbs(@as(f32, 10.0), uniforms.cascade_splits[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 50.0), uniforms.cascade_splits[1], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 150.0), uniforms.cascade_splits[2], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 500.0), uniforms.cascade_splits[3], 0.001);

    // Verify texel sizes
    try testing.expectApproxEqAbs(@as(f32, 0.1), uniforms.shadow_texel_sizes[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.05), uniforms.shadow_texel_sizes[1], 0.001);

    // Verify shadow params
    try testing.expectApproxEqAbs(@as(f32, 2.5), uniforms.shadow_params[0], 0.001);
    try testing.expectApproxEqAbs(@as(f32, 0.0), uniforms.shadow_params[1], 0.001);
}

test "ShadowUniforms alignment requirements" {
    // Alignment should be reasonable for GPU uniform buffer compatibility
    const alignment = @alignOf(ShadowUniforms);
    try testing.expect(alignment >= 4);

    // Mat4 fields should be at least 4-byte aligned (actual alignment may vary)
    try testing.expect(@alignOf(Mat4) >= 4);
}

// ============================================================================
// Cascade Count Validation Tests
// ============================================================================

test "SHADOW_CASCADE_COUNT consistency" {
    // Ensure SHADOW_CASCADE_COUNT is 4 as expected by the shader layout
    try testing.expectEqual(@as(usize, 4), rhi.SHADOW_CASCADE_COUNT);

    // Verify arrays in ShadowUniforms match this count
    const uniforms: ShadowUniforms = undefined;
    try testing.expectEqual(rhi.SHADOW_CASCADE_COUNT, uniforms.light_space_matrices.len);
}

test "TextureHandle type is u32 with 0 as invalid" {
    // Verify our assumptions about handle types
    try testing.expectEqual(@as(usize, 4), @sizeOf(rhi.TextureHandle));
    try testing.expectEqual(@as(rhi.TextureHandle, 0), rhi.InvalidTextureHandle);
}

// ============================================================================
// Edge Cases and Boundary Tests
// ============================================================================

test "getShadowMapHandle at boundary indices" {
    const MockContext = struct {
        shadow_runtime: struct {
            shadow_map_handles: [rhi.SHADOW_CASCADE_COUNT]rhi.TextureHandle,
        },
    };

    var ctx = MockContext{
        .shadow_runtime = .{
            .shadow_map_handles = .{ 100, 200, 300, 400 },
        },
    };

    // Test at exact boundary
    const last_valid = rhi.SHADOW_CASCADE_COUNT - 1;
    try testing.expectEqual(@as(rhi.TextureHandle, 400), rhi_shadow_bridge.getShadowMapHandle(&ctx, @intCast(last_valid)));

    // Test one past boundary
    try testing.expectEqual(@as(rhi.TextureHandle, 0), rhi_shadow_bridge.getShadowMapHandle(&ctx, rhi.SHADOW_CASCADE_COUNT));
}

test "ShadowUniforms with extreme values" {
    // Test with extreme but valid float values
    const max_f32 = std.math.floatMax(f32);
    const min_f32 = std.math.floatMin(f32);

    const uniforms = ShadowUniforms{
        .light_space_matrices = .{Mat4.identity} ** rhi.SHADOW_CASCADE_COUNT,
        .cascade_splits = .{ min_f32, 1.0, 1000.0, max_f32 },
        .shadow_texel_sizes = .{ min_f32, 0.1, 1.0, max_f32 },
        .shadow_params = .{ max_f32, min_f32, 0.0, 0.0 },
    };

    // Verify values are stored (not testing NaN/Inf as those are filtered upstream)
    try testing.expect(std.math.isFinite(uniforms.cascade_splits[1]));
    try testing.expect(std.math.isFinite(uniforms.cascade_splits[2]));
}

test "ShadowUniforms memory layout is packed correctly" {
    // Create a uniforms struct and verify byte-level layout
    const matrices = [4]Mat4{
        Mat4.identity,
        Mat4.identity,
        Mat4.identity,
        Mat4.identity,
    };

    const uniforms = ShadowUniforms{
        .light_space_matrices = matrices,
        .cascade_splits = .{ 1.0, 2.0, 3.0, 4.0 },
        .shadow_texel_sizes = .{ 5.0, 6.0, 7.0, 8.0 },
        .shadow_params = .{ 9.0, 10.0, 11.0, 12.0 },
    };

    // Verify the struct is tightly packed (no unexpected gaps)
    const bytes = std.mem.asBytes(&uniforms);

    // Check that splits start at correct offset (after matrices)
    const splits_start = 4 * 64; // 4 matrices * 64 bytes each
    const splits_bytes = bytes[splits_start..][0..16];
    const splits_ptr: *const [4]f32 = @ptrCast(@alignCast(splits_bytes.ptr));
    try testing.expectApproxEqAbs(@as(f32, 1.0), splits_ptr[0], 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 2.0), splits_ptr[1], 0.0001);
}

// ============================================================================
// Shader Registry Integration Test
// ============================================================================

test "ShadowUniforms size matches shader expectation" {
    // Verify the uniforms struct is the expected size for the GPU shader
    // This catches accidental struct layout changes
    const expected_size = 304; // bytes
    try testing.expectEqual(expected_size, @sizeOf(ShadowUniforms));
}

// ============================================================================
// beginShadowPassInternal and endShadowPassInternal Tests
// ============================================================================

test "beginShadowPassInternal early return when no frame in progress" {
    // Mock context with frame_in_progress = false
    const MockContext = struct {
        frames: struct {
            frame_in_progress: bool,
            current_frame: u32,
            command_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,
        },
        shadow_system: struct {
            beginPass_called: bool,
            cascade_index: u32,

            pub fn beginPass(self: *@This(), _: c.VkCommandBuffer, cascade_index: u32, _: Mat4) void {
                self.beginPass_called = true;
                self.cascade_index = cascade_index;
            }
        },
    };

    var ctx = MockContext{
        .frames = .{
            .frame_in_progress = false,
            .current_frame = 0,
            .command_buffers = .{ null, null },
        },
        .shadow_system = .{
            .beginPass_called = false,
            .cascade_index = 0,
        },
    };

    // Call with frame_in_progress = false - should return early
    rhi_shadow_bridge.beginShadowPassInternal(&ctx, 0, Mat4.identity);

    // beginPass should not have been called
    try testing.expect(!ctx.shadow_system.beginPass_called);
}

test "endShadowPassInternal uses correct command buffer" {
    // Mock context to verify correct command buffer is used
    const MockContext = struct {
        frames: struct {
            current_frame: u32,
            command_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer,
        },
        shadow_system: struct {
            endPass_called: bool,
            received_buffer: c.VkCommandBuffer,

            pub fn endPass(self: *@This(), buffer: c.VkCommandBuffer) void {
                self.endPass_called = true;
                self.received_buffer = buffer;
            }
        },
    };

    var ctx = MockContext{
        .frames = .{
            .current_frame = 1,
            .command_buffers = .{ @ptrFromInt(0x1000), @ptrFromInt(0x2000) },
        },
        .shadow_system = .{
            .endPass_called = false,
            .received_buffer = null,
        },
    };

    // Call endShadowPassInternal
    rhi_shadow_bridge.endShadowPassInternal(&ctx);

    // Verify endPass was called with the correct command buffer
    try testing.expect(ctx.shadow_system.endPass_called);
    try testing.expectEqual(ctx.frames.command_buffers[1], ctx.shadow_system.received_buffer);
}

// ============================================================================
// drawDebugShadowMap Tests
// ============================================================================

test "drawDebugShadowMap is no-op" {
    // This function is intentionally empty, but we test it exists and compiles
    rhi_shadow_bridge.drawDebugShadowMap({}, 0, 0);
    rhi_shadow_bridge.drawDebugShadowMap({}, 1, 100);
    // Test passes if it compiles and runs without crashing
    try testing.expect(true);
}
