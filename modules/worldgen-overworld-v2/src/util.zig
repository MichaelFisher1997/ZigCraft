const std = @import("std");

pub fn hashUnit(x: i32, z: i32, seed: i32) f32 {
    const h: u32 = @bitCast(hash2i(x, z, seed));
    return @as(f32, @floatFromInt(h)) / @as(f32, @floatFromInt(std.math.maxInt(u32)));
}

pub fn hash2i(x: i32, z: i32, seed: i32) i32 {
    var n = @as(u32, @bitCast(x)) *% 374761393 +% @as(u32, @bitCast(z)) *% 668265263 +% @as(u32, @bitCast(seed)) *% 2246822519;
    n = (n ^ (n >> 13)) *% 1274126177;
    n ^= n >> 16;
    return @bitCast(n);
}

pub fn floorToI32(v: f32) i32 {
    return @intFromFloat(@floor(v));
}
