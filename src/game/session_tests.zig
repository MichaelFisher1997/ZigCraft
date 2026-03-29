const std = @import("std");
const testing = std.testing;
const session_module = @import("session.zig");
const CloudState = session_module.CloudState;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;

test "CloudState.init has default values" {
    const clouds = CloudState{};

    try testing.expectEqual(@as(f32, 0.0), clouds.wind_offset_x);
    try testing.expectEqual(@as(f32, 0.0), clouds.wind_offset_z);
    try testing.expectEqual(@as(f32, 1.0 / 64.0), clouds.cloud_scale);
    try testing.expectEqual(@as(f32, 0.5), clouds.cloud_coverage);
    try testing.expectEqual(@as(f32, 160.0), clouds.cloud_height);
    try testing.expectEqual(@as(f32, 12.0), clouds.cloud_thickness);
    try testing.expectEqual(@as(f32, 1.0), clouds.base_color.x);
    try testing.expectEqual(@as(f32, 1.0), clouds.base_color.y);
    try testing.expectEqual(@as(f32, 1.0), clouds.base_color.z);
}

test "CloudState.update moves wind offset" {
    var clouds = CloudState{};

    const initial_x = clouds.wind_offset_x;
    const initial_z = clouds.wind_offset_z;

    clouds.update(0.1);

    // Wind should have moved
    try testing.expect(clouds.wind_offset_x != initial_x);
    try testing.expect(clouds.wind_offset_z != initial_z);
}

test "CloudState.update wind direction is consistent" {
    var clouds = CloudState{};

    // Update multiple times
    clouds.update(1.0);
    const x1 = clouds.wind_offset_x;
    const z1 = clouds.wind_offset_z;

    clouds.update(1.0);
    const x2 = clouds.wind_offset_x;
    const z2 = clouds.wind_offset_z;

    // Wind direction is (1.0, 0.2), so X should increase more than Z
    const dx = x2 - x1;
    const dz = z2 - z1;

    // Both should be positive
    try testing.expect(dx > 0);
    try testing.expect(dz > 0);

    // X should increase approximately 5x more than Z (1.0 / 0.2 = 5)
    const ratio = dx / dz;
    try testing.expectApproxEqAbs(@as(f32, 5.0), ratio, 0.1);
}

test "CloudState.update with zero delta time" {
    var clouds = CloudState{};

    const initial_x = clouds.wind_offset_x;
    const initial_z = clouds.wind_offset_z;

    clouds.update(0.0);

    // Should not change
    try testing.expectEqual(initial_x, clouds.wind_offset_x);
    try testing.expectEqual(initial_z, clouds.wind_offset_z);
}

test "CloudState.update scales with delta time" {
    var clouds1 = CloudState{};
    var clouds2 = CloudState{};

    // Update with different delta times
    clouds1.update(1.0);
    clouds2.update(2.0);

    // clouds2 should have moved twice as much
    try testing.expectApproxEqAbs(clouds1.wind_offset_x * 2, clouds2.wind_offset_x, 0.0001);
    try testing.expectApproxEqAbs(clouds1.wind_offset_z * 2, clouds2.wind_offset_z, 0.0001);
}

test "CloudState.getShadowParams returns correct values" {
    const clouds = CloudState{
        .wind_offset_x = 100.0,
        .wind_offset_z = 50.0,
        .cloud_scale = 0.02,
        .cloud_coverage = 0.75,
        .cloud_height = 200.0,
        .cloud_thickness = 15.0,
        .base_color = Vec3.init(0.9, 0.95, 1.0),
    };

    const params = clouds.getShadowParams();

    try testing.expectEqual(@as(f32, 100.0), params.wind_offset_x);
    try testing.expectEqual(@as(f32, 50.0), params.wind_offset_z);
    try testing.expectEqual(@as(f32, 0.02), params.cloud_scale);
    try testing.expectEqual(@as(f32, 0.75), params.cloud_coverage);
    try testing.expectEqual(@as(f32, 200.0), params.cloud_height);
}

test "CloudState.getShadowParams after update" {
    var clouds = CloudState{};

    clouds.update(5.0);
    const params = clouds.getShadowParams();

    // Wind offset should have changed
    try testing.expect(params.wind_offset_x > 0);
    try testing.expect(params.wind_offset_z > 0);

    // Other values should be unchanged
    try testing.expectEqual(clouds.cloud_scale, params.cloud_scale);
    try testing.expectEqual(clouds.cloud_coverage, params.cloud_coverage);
    try testing.expectEqual(clouds.cloud_height, params.cloud_height);
}

test "CloudState wind accumulates over multiple updates" {
    var clouds = CloudState{};

    // Simulate 60 frames at 60fps (1 second total)
    for (0..60) |_| {
        clouds.update(1.0 / 60.0);
    }

    // Should be approximately the same as one 1.0 second update
    var clouds2 = CloudState{};
    clouds2.update(1.0);

    try testing.expectApproxEqAbs(clouds.wind_offset_x, clouds2.wind_offset_x, 0.0001);
    try testing.expectApproxEqAbs(clouds.wind_offset_z, clouds2.wind_offset_z, 0.0001);
}

test "CloudState wind speed calculation" {
    var clouds = CloudState{};

    // Wind dir is (1.0, 0.2) with speed 2.0
    // Per second: x += 1.0 * 2.0 * dt, z += 0.2 * 2.0 * dt
    clouds.update(1.0);

    // Expected: wind_offset_x = 2.0, wind_offset_z = 0.4
    try testing.expectApproxEqAbs(@as(f32, 2.0), clouds.wind_offset_x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.4), clouds.wind_offset_z, 0.0001);
}
