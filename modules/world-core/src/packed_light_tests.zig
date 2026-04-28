const std = @import("std");
const testing = std.testing;
const PackedLight = @import("light.zig").PackedLight;
const MAX_LIGHT = @import("chunk_constants.zig").MAX_LIGHT;
const packEntranceDir = @import("light.zig").packEntranceDir;
const unpackEntranceDirX = @import("light.zig").unpackEntranceDirX;
const unpackEntranceDirZ = @import("light.zig").unpackEntranceDirZ;

test "PackedLight init sets sky and block light" {
    const light = PackedLight.init(12, 8);
    try testing.expectEqual(@as(u4, 12), light.sky_light);
    try testing.expectEqual(@as(u4, 8), light.block_light_r);
    try testing.expectEqual(@as(u4, 8), light.block_light_g);
    try testing.expectEqual(@as(u4, 8), light.block_light_b);
}

test "PackedLight initRGB sets all channels independently" {
    const light = PackedLight.initRGB(10, 4, 8, 12);
    try testing.expectEqual(@as(u4, 10), light.sky_light);
    try testing.expectEqual(@as(u4, 4), light.block_light_r);
    try testing.expectEqual(@as(u4, 8), light.block_light_g);
    try testing.expectEqual(@as(u4, 12), light.block_light_b);
}

test "PackedLight getBlockLightR returns correct channel" {
    const light = PackedLight.initRGB(5, 3, 6, 9);
    try testing.expectEqual(@as(u4, 3), light.getBlockLightR());
    try testing.expectEqual(@as(u4, 6), light.getBlockLightG());
    try testing.expectEqual(@as(u4, 9), light.getBlockLightB());
}

test "PackedLight setBlockLightRGB updates all channels" {
    var light = PackedLight.init(0, 0);
    light.setBlockLightRGB(2, 4, 6);
    try testing.expectEqual(@as(u4, 2), light.block_light_r);
    try testing.expectEqual(@as(u4, 4), light.block_light_g);
    try testing.expectEqual(@as(u4, 6), light.block_light_b);
}

test "PackedLight getMaxLight returns highest channel" {
    const light = PackedLight.initRGB(5, 10, 3, 7);
    try testing.expectEqual(@as(u4, 10), light.getMaxLight());
}

test "PackedLight getMaxLight prefers sky_light over block" {
    const light = PackedLight.init(15, 10);
    try testing.expectEqual(@as(u4, 15), light.getMaxLight());
}

test "PackedLight getBrightness at max light returns 1.0" {
    const light = PackedLight.init(MAX_LIGHT, MAX_LIGHT);
    try testing.expectEqual(@as(f32, 1.0), light.getBrightness());
}

test "PackedLight getBrightness at zero returns 0.0" {
    const light = PackedLight.init(0, 0);
    try testing.expectEqual(@as(f32, 0.0), light.getBrightness());
}

test "PackedLight getBrightness at mid range" {
    const light = PackedLight.init(7, 0);
    try testing.expectApproxEqAbs(@as(f32, 7.0 / 15.0), light.getBrightness(), 0.001);
}

test "PackedLight default initialization is zero" {
    const light = PackedLight{};
    try testing.expectEqual(@as(u4, 0), light.sky_light);
    try testing.expectEqual(@as(u4, 0), light.block_light_r);
}

test "PackedLight size is 2 bytes" {
    try testing.expectEqual(@as(usize, 2), @sizeOf(PackedLight));
}

test "packEntranceDir encodes x and z" {
    const encoded = packEntranceDir(3, -5);
    try testing.expectEqual(@as(u8, 3), encoded & 0x0F);
    try testing.expectEqual(@as(u8, 0xB0), encoded & 0xF0);
}

test "packEntranceDir zero inputs" {
    const encoded = packEntranceDir(0, 0);
    try testing.expectEqual(@as(u8, 0), encoded);
}

test "unpackEntranceDirX recovers original x" {
    try testing.expectEqual(@as(i4, 3), unpackEntranceDirX(packEntranceDir(3, -5)));
    try testing.expectEqual(@as(i4, -1), unpackEntranceDirX(packEntranceDir(-1, 7)));
    try testing.expectEqual(@as(i4, 0), unpackEntranceDirX(packEntranceDir(0, 0)));
}

test "unpackEntranceDirZ recovers original z" {
    try testing.expectEqual(@as(i4, -5), unpackEntranceDirZ(packEntranceDir(3, -5)));
    try testing.expectEqual(@as(i4, 7), unpackEntranceDirZ(packEntranceDir(-1, 7)));
    try testing.expectEqual(@as(i4, 0), unpackEntranceDirZ(packEntranceDir(0, 0)));
}

test "unpackEntranceDirX and unpackEntranceDirZ are inverse of packEntranceDir" {
    inline for ([_]struct { i4, i4 }{ .{ 0, 0 }, .{ 1, -1 }, .{ -1, 1 }, .{ 7, 7 }, .{ -8, -8 } }) |case| {
        const x, const z = case;
        const encoded = packEntranceDir(x, z);
        try testing.expectEqual(x, unpackEntranceDirX(encoded));
        try testing.expectEqual(z, unpackEntranceDirZ(encoded));
    }
}

test "PackedLight setBlockLight sets all RGB channels" {
    var light = PackedLight.init(5, 0);
    try testing.expectEqual(@as(u4, 0), light.block_light_r);
    light.setBlockLight(8);
    try testing.expectEqual(@as(u4, 8), light.block_light_r);
    try testing.expectEqual(@as(u4, 8), light.block_light_g);
    try testing.expectEqual(@as(u4, 8), light.block_light_b);
}

test "PackedLight getBlockLight returns max of RGB channels" {
    const light = PackedLight.initRGB(0, 3, 10, 7);
    try testing.expectEqual(@as(u4, 10), light.getBlockLight());
}
