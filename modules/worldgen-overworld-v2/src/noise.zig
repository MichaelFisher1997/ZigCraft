const std = @import("std");

pub const NOISE_FLAG_DEFAULTS: u32 = 0x01;
pub const NOISE_FLAG_EASED: u32 = 0x02;
pub const NOISE_FLAG_ABSVALUE: u32 = 0x04;

pub const Vec3f = struct {
    x: f32,
    y: f32,
    z: f32,

    pub fn uniform(v: f32) Vec3f {
        return .{ .x = v, .y = v, .z = v };
    }
};

pub const LuantiNoiseParams = struct {
    offset: f32,
    scale: f32,
    spread: Vec3f,
    seed: i32,
    octaves: u16,
    persist: f32,
    lacunarity: f32,
    flags: u32 = NOISE_FLAG_DEFAULTS,
};

pub fn np(offset: f32, scale: f32, spread: Vec3f, seed: i32, octaves: u16, persist: f32, lacunarity: f32) LuantiNoiseParams {
    return .{ .offset = offset, .scale = scale, .spread = spread, .seed = seed, .octaves = octaves, .persist = persist, .lacunarity = lacunarity };
}

pub fn noiseFractal2D(params: *const LuantiNoiseParams, x_in: f32, y_in: f32, seed: i32) f32 {
    return noiseFractal2DWithPersist(params, x_in, y_in, seed, params.persist);
}

pub fn noiseFractal2DWithPersist(params: *const LuantiNoiseParams, x_in: f32, y_in: f32, seed: i32, persist: f32) f32 {
    const x = x_in / params.spread.x;
    const y = y_in / params.spread.y;
    var frequency: f32 = 1.0;
    var amplitude: f32 = 1.0;
    var value: f32 = 0.0;
    const eased = params.flags & (NOISE_FLAG_DEFAULTS | NOISE_FLAG_EASED) != 0;
    const noise_seed = seed +% params.seed;

    var octave: u16 = 0;
    while (octave < params.octaves) : (octave += 1) {
        var noise_val = noise2dValue(x * frequency, y * frequency, noise_seed +% @as(i32, @intCast(octave)), eased);
        if (params.flags & NOISE_FLAG_ABSVALUE != 0) noise_val = @abs(noise_val);
        value += amplitude * noise_val;
        frequency *= params.lacunarity;
        amplitude *= persist;
    }

    return params.offset + value * params.scale;
}

pub fn noiseFractal3D(params: *const LuantiNoiseParams, x_in: f32, y_in: f32, z_in: f32, seed: i32) f32 {
    const x = x_in / params.spread.x;
    const y = y_in / params.spread.y;
    const z = z_in / params.spread.z;
    var frequency: f32 = 1.0;
    var amplitude: f32 = 1.0;
    var value: f32 = 0.0;
    const eased = params.flags & NOISE_FLAG_EASED != 0;
    const noise_seed = seed +% params.seed;

    var octave: u16 = 0;
    while (octave < params.octaves) : (octave += 1) {
        var noise_val = noise3dValue(x * frequency, y * frequency, z * frequency, noise_seed +% @as(i32, @intCast(octave)), eased);
        if (params.flags & NOISE_FLAG_ABSVALUE != 0) noise_val = @abs(noise_val);
        value += amplitude * noise_val;
        frequency *= params.lacunarity;
        amplitude *= params.persist;
    }

    return params.offset + value * params.scale;
}

fn noise2dValue(x: f32, y: f32, seed: i32, eased: bool) f32 {
    const x0 = myFloor(x);
    const y0 = myFloor(y);
    var xl = x - @as(f32, @floatFromInt(x0));
    var yl = y - @as(f32, @floatFromInt(y0));
    const v00 = noise2d(x0, y0, seed);
    const v10 = noise2d(x0 + 1, y0, seed);
    const v01 = noise2d(x0, y0 + 1, seed);
    const v11 = noise2d(x0 + 1, y0 + 1, seed);
    if (eased) {
        xl = easeCurve(xl);
        yl = easeCurve(yl);
    }
    const u = lerp(v00, v10, xl);
    const v = lerp(v01, v11, xl);
    return lerp(u, v, yl);
}

fn noise3dValue(x: f32, y: f32, z: f32, seed: i32, eased: bool) f32 {
    const x0 = myFloor(x);
    const y0 = myFloor(y);
    const z0 = myFloor(z);
    var xl = x - @as(f32, @floatFromInt(x0));
    var yl = y - @as(f32, @floatFromInt(y0));
    var zl = z - @as(f32, @floatFromInt(z0));
    if (eased) {
        xl = easeCurve(xl);
        yl = easeCurve(yl);
        zl = easeCurve(zl);
    }

    const v000 = noise3d(x0, y0, z0, seed);
    const v100 = noise3d(x0 + 1, y0, z0, seed);
    const v010 = noise3d(x0, y0 + 1, z0, seed);
    const v110 = noise3d(x0 + 1, y0 + 1, z0, seed);
    const v001 = noise3d(x0, y0, z0 + 1, seed);
    const v101 = noise3d(x0 + 1, y0, z0 + 1, seed);
    const v011 = noise3d(x0, y0 + 1, z0 + 1, seed);
    const v111 = noise3d(x0 + 1, y0 + 1, z0 + 1, seed);

    const x00 = lerp(v000, v100, xl);
    const x10 = lerp(v010, v110, xl);
    const x01 = lerp(v001, v101, xl);
    const x11 = lerp(v011, v111, xl);
    const v0 = lerp(x00, x10, yl);
    const v1 = lerp(x01, x11, yl);
    return lerp(v0, v1, zl);
}

fn noise2d(x: i32, y: i32, seed: i32) f32 {
    var n = @as(u32, @bitCast(x)) *% 1619 +% @as(u32, @bitCast(y)) *% 31337 +% @as(u32, @bitCast(seed)) *% 1013;
    n &= 0x7fffffff;
    n = (n >> 13) ^ n;
    n = (n *% (n *% n *% 60493 +% 19990303) +% 1376312589) & 0x7fffffff;
    return 1.0 - @as(f32, @floatFromInt(n)) / 0x40000000;
}

fn noise3d(x: i32, y: i32, z: i32, seed: i32) f32 {
    var n = @as(u32, @bitCast(x)) *% 1619 +% @as(u32, @bitCast(y)) *% 31337 +% @as(u32, @bitCast(z)) *% 52591 +% @as(u32, @bitCast(seed)) *% 1013;
    n &= 0x7fffffff;
    n = (n >> 13) ^ n;
    n = (n *% (n *% n *% 60493 +% 19990303) +% 1376312589) & 0x7fffffff;
    return 1.0 - @as(f32, @floatFromInt(n)) / 0x40000000;
}

fn myFloor(v: f32) i32 {
    const truncated: i32 = @intFromFloat(v);
    return if (v < 0.0) truncated - 1 else truncated;
}

fn easeCurve(t: f32) f32 {
    return t * t * t * (t * (6.0 * t - 15.0) + 10.0);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}
