const std = @import("std");
const testing = std.testing;
const PackedLight = @import("chunk.zig").PackedLight;
const MAX_LIGHT = @import("chunk.zig").MAX_LIGHT;

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
