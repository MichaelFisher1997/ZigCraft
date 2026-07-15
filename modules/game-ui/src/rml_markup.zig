const std = @import("std");

pub fn appendEscaped(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try out.appendSlice(allocator, "&amp;"),
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            0...8, 11, 12, 14...31 => try out.appendSlice(allocator, "\xEF\xBF\xBD"),
            else => try out.append(allocator, byte),
        }
    }
}

pub fn sentinel(out: *std.ArrayList(u8), allocator: std.mem.Allocator) ![:0]const u8 {
    try out.append(allocator, 0);
    return out.items[0 .. out.items.len - 1 :0];
}

test "Rml markup escaping handles user-controlled text" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try appendEscaped(&out, std.testing.allocator, "A&B <world>");
    const result = try sentinel(&out, std.testing.allocator);
    try std.testing.expectEqualStrings("A&amp;B &lt;world&gt;", result);
}

test "Rml markup escaping replaces embedded control bytes" {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(std.testing.allocator);
    try appendEscaped(&out, std.testing.allocator, "before\x00after");
    const result = try sentinel(&out, std.testing.allocator);
    try std.testing.expectEqualStrings("before\xEF\xBF\xBDafter", result);
}
