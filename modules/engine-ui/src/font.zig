//! Bitmap font rendering for UI system.

const std = @import("std");
const UISystem = @import("ui_system.zig").UISystem;
const Color = @import("ui_system.zig").Color;
const FontAtlas = @import("font_atlas.zig").FontAtlas;

var active_atlas: ?*const FontAtlas = null;

pub fn setActiveAtlas(atlas: ?*const FontAtlas) void {
    active_atlas = atlas;
}

const font_letters = [_][7]u8{ .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }, .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 }, .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10000, 0b10001, 0b01110 }, .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 }, .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 }, .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 }, .{ 0b01110, 0b10001, 0b10000, 0b10000, 0b10011, 0b10001, 0b01110 }, .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 }, .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 }, .{ 0b00001, 0b00001, 0b00001, 0b00001, 0b10001, 0b10001, 0b01110 }, .{ 0b10001, 0b10100, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 }, .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 }, .{ 0b10001, 0b11011, 0b10101, 0b10001, 0b10001, 0b10001, 0b10001 }, .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 }, .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 }, .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 }, .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 }, .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 }, .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 }, .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10101, 0b01010, 0b00100 }, .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10101, 0b11011, 0b10001 }, .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001, 0b10001 }, .{ 0b10001, 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100 }, .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 } };
const font_digits = [_][7]u8{ .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 }, .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 }, .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 }, .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 }, .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 }, .{ 0b11111, 0b10000, 0b11110, 0b00001, 0b00001, 0b10001, 0b01110 }, .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 }, .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 }, .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 }, .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 } };

fn glyphForChar(ch: u8) [7]u8 {
    if (ch >= 'A' and ch <= 'Z') return font_letters[ch - 'A'];
    if (ch >= '0' and ch <= '9') return font_digits[ch - '0'];
    return switch (ch) {
        ' ' => .{ 0, 0, 0, 0, 0, 0, 0 },
        '-' => .{ 0, 0, 0, 0b01110, 0, 0, 0 },
        ':' => .{ 0, 0b00100, 0b00100, 0, 0b00100, 0b00100, 0 },
        '.' => .{ 0, 0, 0, 0, 0, 0b00100, 0b00100 },
        '?' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0, 0b00100 },
        else => .{ 0b11111, 0b10001, 0b00001, 0b00010, 0b00100, 0, 0b00100 },
    };
}

pub fn drawGlyph(u: *UISystem, glyph: [7]u8, x: f32, y: f32, scale: f32, color: Color) void {
    var row: usize = 0;
    while (row < 7) : (row += 1) {
        const rb = glyph[row];
        var col: usize = 0;
        while (col < 5) : (col += 1) {
            const shift: u3 = @intCast(4 - col);
            if ((rb & (@as(u8, 1) << shift)) != 0) u.drawRect(.{ .x = x + @as(f32, @floatFromInt(col)) * scale, .y = y + @as(f32, @floatFromInt(row)) * scale, .width = scale, .height = scale }, color);
        }
    }
}

pub fn drawText(u: *UISystem, text: []const u8, x: f32, y: f32, scale: f32, color: Color) void {
    if (active_atlas) |atlas| {
        if (atlas.drawText(u, text, x, y, scale, color)) return;
    }

    var cx = x;
    for (text) |raw| {
        var ch = raw;
        if (ch >= 'a' and ch <= 'z') ch = std.ascii.toUpper(ch);
        drawGlyph(u, glyphForChar(ch), cx, y, scale, color);
        cx += 6.0 * scale;
    }
}

pub fn measureTextWidth(text: []const u8, scale: f32) f32 {
    if (active_atlas) |atlas| {
        if (atlas.measureTextWidth(text, scale)) |width| return width;
    }

    if (text.len == 0) return 0;
    return @as(f32, @floatFromInt(text.len)) * 6.0 * scale;
}

test "font measureTextWidth matches drawText advance (fallback path)" {
    const scale: f32 = 2.0;
    const cases = [_][]const u8{ "", "A", "AB", "ABC", "12345" };
    for (cases) |t| {
        const expected: f32 = @as(f32, @floatFromInt(t.len)) * 6.0 * scale;
        try std.testing.expectEqual(expected, measureTextWidth(t, scale));
    }
    try std.testing.expectEqual(@as(f32, 0), measureTextWidth("", 1.0));
}

test "font measureTextWidth fallback scales linearly" {
    const text = "HELLO";
    try std.testing.expectEqual(
        measureTextWidth(text, 1.0) * 3.0,
        measureTextWidth(text, 3.0),
    );
}

pub fn drawTextCentered(u: *UISystem, text: []const u8, cx: f32, y: f32, scale: f32, color: Color) void {
    const w = measureTextWidth(text, scale);
    drawText(u, text, cx - w * 0.5, y, scale, color);
}

pub fn drawTextCenteredFit(u: *UISystem, text: []const u8, cx: f32, y: f32, scale: f32, max_width: f32, color: Color) void {
    const w = measureTextWidth(text, scale);
    const fit_scale = if (w > max_width and w > 0.0) scale * (max_width / w) else scale;
    drawTextCentered(u, text, cx, y, fit_scale, color);
}

pub fn drawNumber(u: *UISystem, num: i32, x: f32, y: f32, color: Color) void {
    var buffer: [12]u8 = undefined;
    const text = std.fmt.bufPrint(&buffer, "{d}", .{num}) catch return;
    drawText(u, text, x, y, 2.0, color);
}

pub fn drawDigit(u: *UISystem, digit: u4, x: f32, y: f32, color: Color) void {
    const segments: [10][7]bool = .{ .{ true, true, true, false, true, true, true }, .{ false, false, true, false, false, true, false }, .{ true, false, true, true, true, false, true }, .{ true, false, true, true, false, true, true }, .{ false, true, true, true, false, true, false }, .{ true, true, false, true, false, true, true }, .{ true, true, false, true, true, true, true }, .{ true, false, true, false, false, true, false }, .{ true, true, true, true, true, true, true }, .{ true, true, true, true, false, true, true } };
    const seg = segments[digit];
    if (seg[0]) u.drawRect(.{ .x = x, .y = y, .width = 10, .height = 2 }, color);
    if (seg[1]) u.drawRect(.{ .x = x, .y = y, .width = 2, .height = 8 }, color);
    if (seg[2]) u.drawRect(.{ .x = x + 8, .y = y, .width = 2, .height = 8 }, color);
    if (seg[3]) u.drawRect(.{ .x = x, .y = y + 7, .width = 10, .height = 2 }, color);
    if (seg[4]) u.drawRect(.{ .x = x, .y = y + 8, .width = 2, .height = 8 }, color);
    if (seg[5]) u.drawRect(.{ .x = x + 8, .y = y + 8, .width = 2, .height = 8 }, color);
    if (seg[6]) u.drawRect(.{ .x = x, .y = y + 14, .width = 10, .height = 2 }, color);
}
