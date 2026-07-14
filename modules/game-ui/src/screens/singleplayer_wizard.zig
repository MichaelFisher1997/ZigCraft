const std = @import("std");

pub const Step = enum {
    details,
    terrain,
    review,
};

pub const DetailsField = enum {
    name,
    seed,
};

pub const Direction = enum {
    left,
    right,
    up,
    down,
};

pub const ConfirmAction = union(enum) {
    show: Step,
    create_world,
};

pub const BackAction = union(enum) {
    show: Step,
    exit_wizard,
};

pub fn confirmAction(step: Step) ConfirmAction {
    return switch (step) {
        .details => .{ .show = .terrain },
        .terrain => .{ .show = .review },
        .review => .create_world,
    };
}

pub fn backAction(step: Step) BackAction {
    return switch (step) {
        .details => .exit_wizard,
        .terrain => .{ .show = .details },
        .review => .{ .show = .terrain },
    };
}

pub fn nextField(field: DetailsField) DetailsField {
    return switch (field) {
        .name => .seed,
        .seed => .name,
    };
}

pub fn nextGenerator(index: usize, count: usize) usize {
    if (count == 0) return 0;
    return (index + 1) % count;
}

pub fn moveGenerator(index: usize, count: usize, columns: usize, direction: Direction) usize {
    if (count == 0) return 0;
    const safe_index = @min(index, count - 1);
    const safe_columns = @max(columns, 1);
    const row = safe_index / safe_columns;
    const column = safe_index % safe_columns;
    return switch (direction) {
        .left => if (column == 0) safe_index else safe_index - 1,
        .right => if (column + 1 >= safe_columns or safe_index + 1 >= count) safe_index else safe_index + 1,
        .up => if (row == 0) safe_index else safe_index - safe_columns,
        .down => blk: {
            const candidate = safe_index + safe_columns;
            if (candidate < count) break :blk candidate;
            const final_row_start = ((count - 1) / safe_columns) * safe_columns;
            if (final_row_start > safe_index) break :blk @min(final_row_start + column, count - 1);
            break :blk safe_index;
        },
    };
}

pub fn displayWorldName(name: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    return if (trimmed.len > 0) trimmed else "New World";
}

test "wizard confirm advances and creates only from review" {
    try std.testing.expectEqual(ConfirmAction{ .show = .terrain }, confirmAction(.details));
    try std.testing.expectEqual(ConfirmAction{ .show = .review }, confirmAction(.terrain));
    try std.testing.expectEqual(ConfirmAction.create_world, confirmAction(.review));
}

test "wizard back retreats before exiting" {
    try std.testing.expectEqual(BackAction.exit_wizard, backAction(.details));
    try std.testing.expectEqual(BackAction{ .show = .details }, backAction(.terrain));
    try std.testing.expectEqual(BackAction{ .show = .terrain }, backAction(.review));
}

test "wizard details field toggles" {
    try std.testing.expectEqual(DetailsField.seed, nextField(.name));
    try std.testing.expectEqual(DetailsField.name, nextField(.seed));
}

test "wizard terrain navigation handles partial rows" {
    try std.testing.expectEqual(@as(usize, 1), moveGenerator(0, 4, 2, .right));
    try std.testing.expectEqual(@as(usize, 0), moveGenerator(0, 4, 2, .left));
    try std.testing.expectEqual(@as(usize, 3), moveGenerator(1, 4, 2, .down));
    try std.testing.expectEqual(@as(usize, 4), moveGenerator(2, 5, 2, .down));
    try std.testing.expectEqual(@as(usize, 0), moveGenerator(0, 0, 2, .down));
}

test "wizard display name trims input and supplies a default" {
    try std.testing.expectEqualStrings("My World", displayWorldName("  My World  "));
    try std.testing.expectEqualStrings("New World", displayWorldName("  \t"));
}
