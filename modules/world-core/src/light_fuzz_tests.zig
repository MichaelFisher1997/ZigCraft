const std = @import("std");
const light = @import("light.zig");

test "fuzz corpus: PackedLight round-trips all channel nibbles" {
    var sky: u8 = 0;
    while (sky <= 15) : (sky += 1) {
        var red: u8 = 0;
        while (red <= 15) : (red += 1) {
            var green: u8 = 0;
            while (green <= 15) : (green += 1) {
                var blue: u8 = 0;
                while (blue <= 15) : (blue += 1) {
                    const value = light.PackedLight.initRGB(
                        @intCast(sky),
                        @intCast(red),
                        @intCast(green),
                        @intCast(blue),
                    );

                    try std.testing.expectEqual(@as(u4, @intCast(sky)), value.getSkyLight());
                    try std.testing.expectEqual(@as(u4, @intCast(red)), value.getBlockLightR());
                    try std.testing.expectEqual(@as(u4, @intCast(green)), value.getBlockLightG());
                    try std.testing.expectEqual(@as(u4, @intCast(blue)), value.getBlockLightB());
                    try std.testing.expectEqual(@max(@as(u4, @intCast(red)), @max(@as(u4, @intCast(green)), @as(u4, @intCast(blue)))), value.getBlockLight());
                    try std.testing.expectEqual(@max(@as(u4, @intCast(sky)), value.getBlockLight()), value.getMaxLight());
                }
            }
        }
    }
}
