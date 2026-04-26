const std = @import("std");
const testing = std.testing;

pub const std_options: std.Options = .{ .log_level = .err };

const Noise = @import("zig-noise").Noise;
const noise_mod = @import("world/worldgen/noise.zig");

test "Noise deterministic with same seed" {
    const noise1 = Noise.init(12345);
    const noise2 = Noise.init(12345);

    const val1 = noise1.perlin2D(1.5, 2.5);
    const val2 = noise2.perlin2D(1.5, 2.5);

    try testing.expectEqual(val1, val2);
}

test "Noise different with different seed" {
    const noise1 = Noise.init(12345);
    const noise2 = Noise.init(54321);

    const val1 = noise1.perlin2D(1.5, 2.5);
    const val2 = noise2.perlin2D(1.5, 2.5);

    try testing.expect(val1 != val2);
}

test "Noise perlin2D range" {
    const noise = Noise.init(42);

    // Sample many points and verify range is approximately [-1, 1]
    var min_val: f32 = 1.0;
    var max_val: f32 = -1.0;

    var y: f32 = 0;
    while (y < 10) : (y += 0.5) {
        var x: f32 = 0;
        while (x < 10) : (x += 0.5) {
            const val = noise.perlin2D(x, y);
            min_val = @min(min_val, val);
            max_val = @max(max_val, val);
        }
    }

    // Perlin noise should be in [-1, 1] range
    try testing.expect(min_val >= -1.0);
    try testing.expect(max_val <= 1.0);
}

test "Noise perlin3D range" {
    const noise = Noise.init(42);

    var min_val: f32 = 1.0;
    var max_val: f32 = -1.0;

    var z: f32 = 0;
    while (z < 5) : (z += 1) {
        var y: f32 = 0;
        while (y < 5) : (y += 1) {
            var x: f32 = 0;
            while (x < 5) : (x += 1) {
                const val = noise.perlin3D(x, y, z);
                min_val = @min(min_val, val);
                max_val = @max(max_val, val);
            }
        }
    }

    try testing.expect(min_val >= -1.0);
    try testing.expect(max_val <= 1.0);
}

test "Noise fbm2D produces varied output" {
    const noise = Noise.init(42);

    // Sample at positions that are far apart for noticeable variation
    const val1 = noise.fbm2D(0.5, 0.5, 4, 2.0, 0.5, 0.01);
    const val2 = noise.fbm2D(50.5, 50.5, 4, 2.0, 0.5, 0.01);
    const val3 = noise.fbm2D(100.5, 100.5, 4, 2.0, 0.5, 0.01);

    // At least two of three values should differ (noise is continuous)
    const all_same = (val1 == val2) and (val2 == val3);
    try testing.expect(!all_same);
}

test "Noise fbm2DNormalized range" {
    const noise = Noise.init(42);

    var y: f32 = 0;
    while (y < 10) : (y += 0.5) {
        var x: f32 = 0;
        while (x < 10) : (x += 0.5) {
            const val = noise.fbm2DNormalized(x, y, 4, 2.0, 0.5, 0.1);
            // Normalized should be in [0, 1]
            try testing.expect(val >= 0.0);
            try testing.expect(val <= 1.0);
        }
    }
}

test "Noise ridged2D range" {
    const noise = Noise.init(42);

    var y: f32 = 0;
    while (y < 10) : (y += 0.5) {
        var x: f32 = 0;
        while (x < 10) : (x += 0.5) {
            const val = noise.ridged2D(x, y, 4, 2.0, 0.5, 0.1);
            // Ridged should be in [0, 1]
            try testing.expect(val >= 0.0);
            try testing.expect(val <= 1.0);
        }
    }
}

test "Noise handles large coordinates" {
    const noise = Noise.init(42);

    // Large coordinates should not panic (used i64 internally to avoid overflow)
    const val = noise.perlin2D(100000.5, -100000.5);
    try testing.expect(val >= -1.0 and val <= 1.0);
}

test "Noise getHeight returns normalized value" {
    const noise = Noise.init(42);
    const height = noise.getHeight(10.0, 20.0, 64.0);
    try testing.expect(height >= 0.0 and height <= 1.0);
}

test "Vec3f init and uniform" {
    const v1 = noise_mod.Vec3f.init(1.0, 2.0, 3.0);
    try testing.expectEqual(@as(f32, 1.0), v1.x);
    try testing.expectEqual(@as(f32, 2.0), v1.y);
    try testing.expectEqual(@as(f32, 3.0), v1.z);

    const v2 = noise_mod.Vec3f.uniform(500.0);
    try testing.expectEqual(@as(f32, 500.0), v2.x);
    try testing.expectEqual(@as(f32, 500.0), v2.y);
    try testing.expectEqual(@as(f32, 500.0), v2.z);
}

test "NoiseParams default values" {
    const params = noise_mod.NoiseParams{ .seed = 12345 };
    try testing.expectEqual(@as(f32, 0), params.offset);
    try testing.expectEqual(@as(f32, 1), params.scale);
    try testing.expectEqual(@as(f32, 600), params.spread.x);
    try testing.expectEqual(@as(f32, 600), params.spread.y);
    try testing.expectEqual(@as(f32, 600), params.spread.z);
    try testing.expectEqual(@as(u16, 4), params.octaves);
    try testing.expectEqual(@as(f32, 0.5), params.persist);
    try testing.expectEqual(@as(f32, 2.0), params.lacunarity);
    try testing.expect(params.flags.eased);
    try testing.expect(!params.flags.absvalue);
}

test "NoiseParams frequency from spread" {
    const params = noise_mod.NoiseParams{
        .seed = 12345,
        .spread = noise_mod.Vec3f.uniform(500),
    };
    try testing.expectApproxEqAbs(@as(f32, 0.002), params.getFrequency2D(), 0.0001);

    // Anisotropic spread
    const params2 = noise_mod.NoiseParams{
        .seed = 12345,
        .spread = noise_mod.Vec3f.init(250, 350, 250),
    };
    const freq3d = params2.getFrequency3D();
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 250.0), freq3d.x, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 350.0), freq3d.y, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 1.0 / 250.0), freq3d.z, 0.0001);
}

test "NoiseFlags packed struct size" {
    // NoiseFlags should be 1 byte
    try testing.expectEqual(@as(usize, 1), @sizeOf(noise_mod.NoiseFlags));
}

test "ConfiguredNoise init" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 70.0,
        .offset = 4.0,
        .spread = noise_mod.Vec3f.uniform(600),
        .octaves = 5,
        .persist = 0.6,
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    try testing.expectEqual(@as(u64, 42), cn.params.seed);
    try testing.expectEqual(@as(f32, 70.0), cn.params.scale);
    try testing.expectEqual(@as(f32, 4.0), cn.params.offset);
}

test "ConfiguredNoise get2D returns value with offset and scale" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 10.0,
        .offset = 5.0,
        .spread = noise_mod.Vec3f.uniform(100),
        .octaves = 3,
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    const val = cn.get2D(100, 100);
    // FBM output is roughly -1 to 1
    // After scale and offset: offset + scale * fbm = 5 + 10 * [-1,1] = [-5, 15]
    try testing.expect(val >= -10 and val <= 20);
}

test "ConfiguredNoise absvalue flag produces non-negative" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 1.0,
        .offset = 0,
        .spread = noise_mod.Vec3f.uniform(50),
        .flags = .{ .absvalue = true },
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    // Sample multiple points - all should be >= 0
    var all_non_negative = true;
    var x: f32 = 0;
    while (x < 100) : (x += 10) {
        var z: f32 = 0;
        while (z < 100) : (z += 10) {
            const val = cn.get2D(x, z);
            if (val < 0) all_non_negative = false;
        }
    }
    try testing.expect(all_non_negative);
}

test "ConfiguredNoise get3D anisotropic spread" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 1.0,
        .offset = 0,
        .spread = noise_mod.Vec3f.init(250, 350, 250),
        .octaves = 3,
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    const val = cn.get3D(100, 50, 100);
    // Should be in valid range
    try testing.expect(val >= -2 and val <= 2);
}

test "ConfiguredNoise get2DNormalized returns 0-1 range" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 1.0,
        .offset = 0,
        .spread = noise_mod.Vec3f.uniform(100),
        .octaves = 4,
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    var x: f32 = 0;
    while (x < 50) : (x += 5) {
        var z: f32 = 0;
        while (z < 50) : (z += 5) {
            const val = cn.get2DNormalized(x, z);
            try testing.expect(val >= 0.0);
            try testing.expect(val <= 1.0);
        }
    }
}

test "ConfiguredNoise get2DRidged produces ridged output" {
    const params = noise_mod.NoiseParams{
        .seed = 42,
        .scale = 1.0,
        .offset = 0,
        .spread = noise_mod.Vec3f.uniform(100),
        .octaves = 4,
    };
    const cn = noise_mod.ConfiguredNoise.init(params);

    // Ridged noise should be in [0, 1] range regardless of flags
    var x: f32 = 0;
    while (x < 50) : (x += 5) {
        var z: f32 = 0;
        while (z < 50) : (z += 5) {
            const val = cn.get2DRidged(x, z);
            try testing.expect(val >= 0.0);
            try testing.expect(val <= 1.0);
        }
    }
}

test "ConfiguredNoise determinism with same params" {
    const params = noise_mod.NoiseParams{
        .seed = 12345,
        .scale = 50.0,
        .offset = 10.0,
        .spread = noise_mod.Vec3f.uniform(300),
        .octaves = 5,
        .persist = 0.6,
    };

    const cn1 = noise_mod.ConfiguredNoise.init(params);
    const cn2 = noise_mod.ConfiguredNoise.init(params);

    const val1 = cn1.get2D(123.456, 789.012);
    const val2 = cn2.get2D(123.456, 789.012);

    try testing.expectEqual(val1, val2);
}
