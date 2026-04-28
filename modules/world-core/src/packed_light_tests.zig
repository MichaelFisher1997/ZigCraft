const std = @import("std");
const testing = std.testing;
const PackedLight = @import("light.zig").PackedLight;
const packEntranceDir = @import("light.zig").packEntranceDir;
const unpackEntranceDirX = @import("light.zig").unpackEntranceDirX;
const unpackEntranceDirZ = @import("light.zig").unpackEntranceDirZ;

test "packEntranceDir encodes x and z" {
    const encoded = packEntranceDir(3, -5);
    try testing.expectEqual(@as(u8, 3), encoded & 0x0F);
    try testing.expectEqual(@as(u8, 0xF0), encoded & 0xF0);
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
