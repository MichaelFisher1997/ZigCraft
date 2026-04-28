//! UI Widgets like buttons and text inputs.

const std = @import("std");
const UISystem = @import("ui_system.zig").UISystem;
const Color = @import("ui_system.zig").Color;
const Rect = @import("ui_system.zig").Rect;
const Font = @import("font.zig");

pub fn drawButton(u: *UISystem, rect: Rect, label: []const u8, scale: f32, mx: f32, my: f32, clicked: bool) bool {
    const hov = rect.contains(mx, my);
    const bg = if (hov) Color.rgba(0.18, 0.34, 0.46, 0.96) else Color.rgba(0.08, 0.13, 0.19, 0.92);
    const top = if (hov) Color.rgba(0.43, 0.78, 0.92, 0.20) else Color.rgba(0.38, 0.55, 0.72, 0.10);
    const border = if (hov) Color.rgba(0.70, 0.92, 1.0, 1.0) else Color.rgba(0.32, 0.48, 0.62, 0.92);
    const accent = if (hov) Color.rgba(0.98, 0.78, 0.32, 1.0) else Color.rgba(0.42, 0.68, 0.86, 0.86);

    u.drawRect(rect, bg);
    u.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = @max(2.0, rect.height * 0.42) }, top);
    u.drawRect(.{ .x = rect.x, .y = rect.y, .width = 5.0, .height = rect.height }, accent);
    u.drawRectOutline(rect, border, if (hov) 3.0 else 2.0);
    const max_text_width = @max(1.0, rect.width - 16.0 * scale);
    const text_color = if (hov) Color.rgba(1.0, 0.98, 0.90, 1.0) else Color.rgba(0.93, 0.97, 1.0, 1.0);
    Font.drawTextCenteredFit(u, label, rect.x + rect.width * 0.5, rect.y + (rect.height - 7.0 * scale) * 0.5, scale, max_text_width, text_color);
    return hov and clicked;
}

pub fn drawTextInput(u: *UISystem, rect: Rect, text: []const u8, ph: []const u8, scale: f32, foc: bool, caret: bool) void {
    const border = if (foc) Color.rgba(0.95, 0.68, 0.28, 1.0) else Color.rgba(0.34, 0.52, 0.66, 0.92);
    u.drawRect(rect, Color.rgba(0.025, 0.045, 0.065, 0.96));
    u.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = @max(2.0, rect.height * 0.38) }, Color.rgba(0.20, 0.36, 0.48, 0.16));
    u.drawRect(.{ .x = rect.x, .y = rect.y, .width = 4.0, .height = rect.height }, border);
    u.drawRectOutline(rect, border, if (foc) 3.0 else 2.0);
    const ty = rect.y + (rect.height - 7.0 * scale) * 0.5;
    if (text.len > 0) Font.drawText(u, text, rect.x + 14, ty, scale, Color.rgba(0.92, 0.97, 1.0, 1.0)) else Font.drawText(u, ph, rect.x + 14, ty, scale, Color.rgba(0.48, 0.60, 0.70, 1.0));
    if (foc and caret) u.drawRect(.{ .x = rect.x + 14 + Font.measureTextWidth(text, scale), .y = rect.y + 8, .width = 2, .height = rect.height - 16 }, Color.rgba(1.0, 0.78, 0.36, 1.0));
}
