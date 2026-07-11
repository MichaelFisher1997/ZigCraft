const testing = @import("std").testing;

const Theme = @import("menu_theme.zig");

test "scaleFor reduces layouts on short windows" {
    try testing.expectEqual(@as(f32, 0.72), Theme.scaleFor(720.0, 1.0));
}

test "scaleFor has a readable lower bound" {
    try testing.expectEqual(@as(f32, 0.72), Theme.scaleFor(480.0, 1.0));
}

test "scaleFor caps growth on tall displays" {
    try testing.expectApproxEqAbs(@as(f32, 4.0 / 3.0), Theme.scaleFor(1440.0, 1.0), 0.0001);
}

test "scaleFor applies manual user scale" {
    try testing.expectEqual(@as(f32, 1.08), Theme.scaleFor(720.0, 1.5));
}

test "scaleFor combines display and user scale" {
    try testing.expectApproxEqAbs(@as(f32, 2.0), Theme.scaleFor(1440.0, 1.5), 0.0001);
}

test "scaleFor reaches two times scale at 4K" {
    try testing.expectEqual(@as(f32, 2.0), Theme.scaleFor(2160.0, 1.0));
}
