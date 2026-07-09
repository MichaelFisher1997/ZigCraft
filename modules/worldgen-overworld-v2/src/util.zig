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
    const floored = @floor(v);
    if (!std.math.isFinite(floored)) return 0;
    if (floored <= @as(f32, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (floored >= @as(f32, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(floored);
}

pub fn addWorldOffset(base: i32, offset: anytype) i32 {
    return clampI32(@as(i64, base) + @as(i64, @intCast(offset)));
}

pub fn chunkWorldOffset(chunk_coord: i32, local_offset: anytype, chunk_size: anytype) i32 {
    return clampI32(@as(i64, chunk_coord) * @as(i64, @intCast(chunk_size)) + @as(i64, @intCast(local_offset)));
}

pub fn clampI32(value: i64) i32 {
    return @intCast(std.math.clamp(
        value,
        @as(i64, std.math.minInt(i32)),
        @as(i64, std.math.maxInt(i32)),
    ));
}
