const testing = @import("std").testing;

const Theme = @import("menu_theme.zig");

test "scaleFor keeps 720p baseline at user scale" {
    try testing.expectEqual(@as(f32, 1.0), Theme.scaleFor(720.0, 1.0));
}

test "scaleFor does not shrink below baseline before user scale" {
    try testing.expectEqual(@as(f32, 1.0), Theme.scaleFor(480.0, 1.0));
}

test "scaleFor grows on taller displays" {
    try testing.expectEqual(@as(f32, 2.0), Theme.scaleFor(1440.0, 1.0));
}

test "scaleFor applies manual user scale" {
    try testing.expectEqual(@as(f32, 1.5), Theme.scaleFor(720.0, 1.5));
}

test "scaleFor combines display and user scale" {
    try testing.expectEqual(@as(f32, 3.0), Theme.scaleFor(1440.0, 1.5));
}
