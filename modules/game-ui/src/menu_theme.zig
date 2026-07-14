//! Shared menu design system. Screens compose these restrained, high-contrast
//! primitives instead of inventing local decoration and interaction states.

const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
pub const Color = @import("engine-ui").Color;
pub const Rect = @import("engine-ui").Rect;
const Font = @import("engine-ui").font;

pub const Tone = enum {
    home,
    create,
    library,
    settings,
    graphics,
    packs,
    environment,
    paused,
};

pub const ButtonStyle = enum {
    primary,
    secondary,
    ghost,
    danger,
    disabled,
};

pub const Shell = struct {
    rect: Rect,
    content: Rect,
    footer_y: f32,
    scale: f32,
};

pub const title = Color.rgba(0.96, 0.98, 1.0, 1.0);
pub const text = Color.rgba(0.80, 0.85, 0.89, 1.0);
pub const muted = Color.rgba(0.60, 0.67, 0.73, 1.0);
pub const dim = Color.rgba(0.42, 0.48, 0.53, 1.0);
pub const copper = Color.rgba(0.45, 0.70, 0.78, 1.0);
pub const amber = Color.rgba(0.94, 0.73, 0.33, 1.0);
pub const signal = Color.rgba(0.25, 0.75, 0.92, 1.0);
pub const danger = Color.rgba(0.95, 0.36, 0.40, 1.0);
pub const panel = Color.rgba(0.024, 0.075, 0.122, 0.87);
pub const panel_soft = Color.rgba(0.045, 0.090, 0.125, 0.46);
pub const panel_header = Color.rgba(0.035, 0.090, 0.125, 0.34);
pub const outline = Color.rgba(0.78, 0.95, 1.0, 0.38);

const backdrop_base = Color.rgba(0, 0, 0, 0.75);
const glass_top = Color.rgba(0.94, 0.98, 1.0, 0.62);
const glass_edge = Color.rgba(0.78, 0.95, 1.0, 0.38);
const shadow = Color.rgba(0, 0, 0, 0.32);

pub fn scaleFor(screen_h: f32, user_scale: f32) f32 {
    // Small windows must reduce the whole layout; large displays stop growing
    // before controls become oversized. The user preference remains effective.
    return std.math.clamp(screen_h / 1080.0, 0.72, 2.0) * user_scale;
}

pub fn drawBackdrop(ui: *UISystem, screen_w: f32, screen_h: f32, scale: f32, tone: Tone) void {
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, backdrop_base);
    const accent = toneAccent(tone);
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = 1.0 * scale }, Color.rgba(accent.r, accent.g, accent.b, 0.52));
}

pub fn drawWorldScrim(ui: *UISystem, screen_w: f32, screen_h: f32, scale: f32) void {
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, backdrop_base);
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = 1.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, 0.52));
}

pub fn drawGlassPanel(ui: *UISystem, rect: Rect, scale: f32) void {
    ui.drawRect(rect, panel);
    ui.drawRectOutline(rect, glass_edge, 1.0 * scale);
    const highlight_inset = @min(20.0 * scale, rect.width * 0.08);
    ui.drawRect(.{
        .x = rect.x + highlight_inset,
        .y = rect.y,
        .width = @max(0.0, rect.width - highlight_inset * 2.0),
        .height = 1.0 * scale,
    }, glass_top);
}

pub fn drawShell(ui: *UISystem, rect: Rect, scale: f32, kicker: []const u8, heading: []const u8, subtitle: []const u8) Shell {
    const padding = @min(32.0 * scale, rect.width * 0.07);
    const header_h = @min(rect.height * 0.20, 112.0 * scale);
    const footer_h = 68.0 * scale;
    const content = Rect{
        .x = rect.x + padding,
        .y = rect.y + header_h + 20.0 * scale,
        .width = rect.width - padding * 2.0,
        .height = rect.height - header_h - footer_h - 26.0 * scale,
    };

    drawGlassPanel(ui, rect, scale);
    ui.drawRect(.{ .x = rect.x + padding, .y = rect.y + header_h - 1.0 * scale, .width = rect.width - padding * 2.0, .height = 1.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, 0.28));

    Font.drawText(ui, kicker, rect.x + padding, rect.y + 17.0 * scale, 0.90 * scale, signal);
    Font.drawText(ui, heading, rect.x + padding, rect.y + 39.0 * scale, 2.80 * scale, title);
    Font.drawText(ui, subtitle, rect.x + padding, rect.y + header_h - 20.0 * scale, 1.05 * scale, text);

    ui.drawRect(.{ .x = rect.x + padding, .y = rect.y + rect.height - footer_h, .width = rect.width - padding * 2.0, .height = 1.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, 0.20));

    return .{
        .rect = rect,
        .content = content,
        .footer_y = rect.y + rect.height - footer_h + 15.0 * scale,
        .scale = scale,
    };
}

pub fn drawHeroTitle(ui: *UISystem, x: f32, y: f32, scale: f32, compact: bool) void {
    const word_scale: f32 = if (compact) 3.6 * scale else 5.2 * scale;
    const line_w: f32 = if (compact) 400.0 * scale else 620.0 * scale;
    const word_y = y;
    const zig_w = Font.measureTextWidth("Zig", word_scale);
    const copy_y = word_y + word_scale * 7.0 + 18.0 * scale;

    Font.drawText(ui, "ZIGCRAFT", x, y - 38.0 * scale, 0.92 * scale, signal);
    Font.drawText(ui, "Zig", x, word_y, word_scale, title);
    Font.drawText(ui, "Craft", x + zig_w + 3.0 * scale, word_y, word_scale, Color.rgba(0.72, 0.82, 0.88, 1.0));
    Font.drawText(ui, "Explore procedural worlds, your way.", x, copy_y, 1.24 * scale, title);
    ui.drawRect(.{ .x = x, .y = copy_y + 34.0 * scale, .width = line_w, .height = 1.0 * scale }, outline);
}

pub fn drawButton(ui: *UISystem, rect: Rect, label: []const u8, text_scale: f32, mx: f32, my: f32, clicked: bool, style: ButtonStyle, scale: f32) bool {
    return drawButtonFocused(ui, rect, label, text_scale, mx, my, clicked, style, false, scale);
}

pub fn drawButtonFocused(ui: *UISystem, rect: Rect, label: []const u8, text_scale: f32, mx: f32, my: f32, clicked: bool, style: ButtonStyle, focused: bool, scale: f32) bool {
    const disabled = style == .disabled;
    const hovered = !disabled and rect.contains(mx, my);
    const highlighted = hovered or focused;
    const colors = buttonColors(style, highlighted);

    ui.drawRect(rect, colors.bg);
    if (highlighted or style == .primary or style == .danger) {
        ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = if (highlighted) 3.0 * scale else 2.0 * scale, .height = rect.height }, colors.accent);
    }
    ui.drawRectOutline(rect, colors.border, 1.0 * scale);
    if (focused) ui.drawRectOutline(.{ .x = rect.x - 2.0 * scale, .y = rect.y - 2.0 * scale, .width = rect.width + 4.0 * scale, .height = rect.height + 4.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, 0.64), 1.0 * scale);

    const max_text_width = @max(1.0, rect.width - 42.0 * scale);
    Font.drawTextCenteredFit(ui, label, rect.x + rect.width * 0.5 + 2.0 * scale, rect.y + (rect.height - 7.0 * text_scale) * 0.5, text_scale, max_text_width, colors.text);
    return hovered and clicked;
}

pub fn drawActionCard(ui: *UISystem, rect: Rect, heading: []const u8, description: []const u8, meta: []const u8, mx: f32, my: f32, clicked: bool, primary: bool, focused: bool, scale: f32) bool {
    const hovered = rect.contains(mx, my);
    const active = hovered or focused;
    const edge = signal;
    const bg = if (primary)
        if (active) Color.rgba(0.04, 0.60, 0.71, 0.91) else Color.rgba(0.03, 0.50, 0.60, 0.83)
    else if (active)
        Color.rgba(0.60, 0.91, 1.0, 0.11)
    else
        Color.rgba(0.60, 0.91, 1.0, 0.03);

    ui.drawRect(rect, bg);
    if (primary or active) ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = if (primary) 3.0 * scale else 2.0 * scale, .height = rect.height }, edge);
    if (primary) {
        ui.drawRectOutline(rect, if (active) title else Color.rgba(0.82, 0.97, 1.0, 0.72), 1.0 * scale);
    } else {
        ui.drawRect(.{ .x = rect.x, .y = rect.y + rect.height - 1.0 * scale, .width = rect.width, .height = 1.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, if (active) 0.34 else 0.16));
    }
    if (focused) ui.drawRectOutline(.{ .x = rect.x - 2.0 * scale, .y = rect.y - 2.0 * scale, .width = rect.width + 4.0 * scale, .height = rect.height + 4.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, 0.64), 1.0 * scale);

    const heading_scale: f32 = if (primary) 1.92 * scale else 1.28 * scale;
    const description_offset: f32 = if (primary) 62.0 else 49.0;
    Font.drawText(ui, heading, rect.x + 26.0 * scale, rect.y + 20.0 * scale, heading_scale, title);
    Font.drawText(ui, description, rect.x + 26.0 * scale, rect.y + description_offset * scale, 0.90 * scale, if (primary) text else muted);
    if (meta.len > 0) {
        const meta_w = Font.measureTextWidth(meta, 0.68 * scale);
        Font.drawText(ui, meta, rect.x + rect.width - meta_w - 20.0 * scale, rect.y + 22.0 * scale, 0.76 * scale, if (primary) title else if (active) signal else dim);
    }
    return hovered and clicked;
}

pub fn drawNavItem(ui: *UISystem, rect: Rect, label: []const u8, index: usize, selected: bool, mx: f32, my: f32, clicked: bool, scale: f32) bool {
    const hovered = rect.contains(mx, my);
    const active = selected or hovered;
    ui.drawRect(rect, if (active) Color.rgba(0.60, 0.91, 1.0, 0.10) else Color.rgba(0, 0, 0, 0));
    if (selected) ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = 3.0 * scale, .height = rect.height }, signal);
    ui.drawRect(.{ .x = rect.x, .y = rect.y + rect.height - 1.0 * scale, .width = rect.width, .height = 1.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, if (active) 0.32 else 0.14));
    Font.drawText(ui, label, rect.x + 18.0 * scale, rect.y + (rect.height - 7.0 * 0.92 * scale) * 0.5, 0.92 * scale, if (selected) title else text);
    var index_buf: [8]u8 = undefined;
    const index_text = std.fmt.bufPrint(&index_buf, "0{}", .{index + 1}) catch "";
    const index_w = Font.measureTextWidth(index_text, 0.66 * scale);
    Font.drawText(ui, index_text, rect.x + rect.width - index_w - 16.0 * scale, rect.y + (rect.height - 7.0 * 0.66 * scale) * 0.5, 0.66 * scale, if (selected) signal else dim);
    return hovered and clicked;
}

pub fn drawTextInput(ui: *UISystem, rect: Rect, value: []const u8, placeholder: []const u8, text_scale: f32, focused: bool, caret: bool, scale: f32) void {
    const border = if (focused) signal else Color.rgba(0.42, 0.54, 0.62, 0.50);
    ui.drawRect(rect, if (focused) Color.rgba(0.035, 0.125, 0.170, 0.90) else Color.rgba(0.020, 0.055, 0.080, 0.82));
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = 3.0 * scale, .height = rect.height }, border);
    ui.drawRectOutline(rect, Color.rgba(border.r, border.g, border.b, if (focused) 0.78 else 0.46), if (focused) 2.0 * scale else 1.0 * scale);

    const tx = rect.x + 16.0 * scale;
    const ty = rect.y + (rect.height - 7.0 * text_scale) * 0.5;
    if (value.len > 0) {
        Font.drawText(ui, value, tx, ty, text_scale, title);
    } else {
        Font.drawText(ui, placeholder, tx, ty, text_scale, dim);
    }
    if (focused and caret) {
        ui.drawRect(.{ .x = tx + Font.measureTextWidth(value, text_scale) + 5.0 * scale, .y = rect.y + 8.0 * scale, .width = 2.0 * scale, .height = rect.height - 16.0 * scale }, signal);
    }
}

pub fn drawSectionLabel(ui: *UISystem, x: f32, y: f32, label: []const u8, scale: f32) void {
    ui.drawRect(.{ .x = x, .y = y + 7.0 * scale, .width = 24.0 * scale, .height = 2.0 * scale }, signal);
    Font.drawText(ui, label, x + 36.0 * scale, y, 0.88 * scale, muted);
}

pub fn drawOptionRow(ui: *UISystem, rect: Rect, label: []const u8, description: []const u8, label_scale: f32, selected: bool, scale: f32) void {
    const bg = if (selected) Color.rgba(0.60, 0.91, 1.0, 0.10) else Color.rgba(0, 0, 0, 0);
    const edge = if (selected) signal else Color.rgba(signal.r, signal.g, signal.b, 0.14);
    ui.drawRect(rect, bg);
    if (selected) ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = 2.0 * scale, .height = rect.height }, edge);
    ui.drawRect(.{ .x = rect.x, .y = rect.y + rect.height - 1.0 * scale, .width = rect.width, .height = 1.0 * scale }, Color.rgba(edge.r, edge.g, edge.b, if (selected) 0.42 else 0.18));
    Font.drawText(ui, label, rect.x + 20.0 * scale, rect.y + 10.0 * scale, label_scale, if (selected) title else text);
    if (description.len > 0) Font.drawText(ui, description, rect.x + 20.0 * scale, rect.y + 35.0 * scale, @max(label_scale * 0.72, 0.96 * scale), muted);
}

pub fn drawValueText(ui: *UISystem, rect: Rect, value: []const u8, text_scale: f32, scale: f32) void {
    ui.drawRect(rect, Color.rgba(0.050, 0.085, 0.112, 1.0));
    ui.drawRectOutline(rect, Color.rgba(signal.r, signal.g, signal.b, 0.44), 1.0 * scale);
    Font.drawTextCenteredFit(ui, value, rect.x + rect.width * 0.5, rect.y + (rect.height - 7.0 * text_scale) * 0.5, text_scale, rect.width - 12.0 * scale, title);
}

pub fn drawListRail(ui: *UISystem, rect: Rect, scale: f32) void {
    ui.drawRect(rect, Color.rgba(0.02, 0.05, 0.08, 0.48));
    ui.drawRectOutline(rect, Color.rgba(signal.r, signal.g, signal.b, 0.20), 1.0 * scale);
}

pub fn drawScrollbar(ui: *UISystem, x: f32, y: f32, h: f32, content_h: f32, viewport_h: f32, scroll: f32, max_scroll: f32, scale: f32) void {
    if (max_scroll <= 0.0 or content_h <= 0.0) return;
    const track_w = 8.0 * scale;
    ui.drawRect(.{ .x = x, .y = y, .width = track_w, .height = h }, Color.rgba(0.10, 0.15, 0.18, 0.42));
    const thumb_h = @max(28.0 * scale, h * (viewport_h / content_h));
    const thumb_y = y + (h - thumb_h) * (scroll / max_scroll);
    ui.drawRect(.{ .x = x, .y = thumb_y, .width = track_w, .height = thumb_h }, Color.rgba(signal.r, signal.g, signal.b, 0.70));
}

pub fn drawModal(ui: *UISystem, screen_w: f32, screen_h: f32, rect: Rect, scale: f32, heading: []const u8, subtitle: []const u8, destructive: bool) void {
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.76));
    const edge = if (destructive) danger else signal;
    ui.drawRect(rect, Color.rgba(0.024, 0.075, 0.122, 0.96));
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 42.0 * scale }, Color.rgba(edge.r, edge.g, edge.b, 0.14));
    ui.drawRect(.{ .x = rect.x, .y = rect.y + 42.0 * scale, .width = rect.width, .height = 1.0 * scale }, Color.rgba(edge.r, edge.g, edge.b, 0.56));
    ui.drawRectOutline(rect, Color.rgba(edge.r, edge.g, edge.b, 0.64), 1.0 * scale);
    Font.drawTextCentered(ui, heading, rect.x + rect.width * 0.5, rect.y + 14.0 * scale, 1.70 * scale, title);
    if (subtitle.len > 0) Font.drawTextCentered(ui, subtitle, rect.x + rect.width * 0.5, rect.y + 64.0 * scale, 1.00 * scale, muted);
}

fn buttonColors(style: ButtonStyle, hovered: bool) struct { bg: Color, top: Color, bottom: Color, border: Color, accent: Color, text: Color, shadow_color: Color } {
    if (style == .disabled) {
        return .{
            .bg = Color.rgba(0.045, 0.060, 0.075, 0.38),
            .top = Color.rgba(0.50, 0.56, 0.60, 0.10),
            .bottom = Color.rgba(0.22, 0.27, 0.31, 0.15),
            .border = Color.rgba(0.20, 0.25, 0.29, 0.62),
            .accent = Color.rgba(0.22, 0.28, 0.32, 0.60),
            .text = Color.rgba(0.38, 0.44, 0.48, 1.0),
            .shadow_color = Color.rgba(0, 0, 0, 0.12),
        };
    }
    if (style == .danger) {
        return .{
            .bg = if (hovered) Color.rgba(0.30, 0.105, 0.115, 0.70) else Color.rgba(0.24, 0.075, 0.085, 0.58),
            .top = Color.rgba(0.95, 0.74, 0.74, if (hovered) 0.18 else 0.11),
            .bottom = Color.rgba(danger.r, danger.g, danger.b, 0.48),
            .border = if (hovered) Color.rgba(0.88, 0.40, 0.43, 0.78) else Color.rgba(0.74, 0.30, 0.34, 0.56),
            .accent = danger,
            .text = title,
            .shadow_color = Color.rgba(0.12, 0, 0.02, 0.30),
        };
    }
    if (style == .primary) {
        return .{
            .bg = if (hovered) Color.rgba(0.04, 0.60, 0.71, 0.91) else Color.rgba(0.03, 0.50, 0.60, 0.83),
            .top = Color.rgba(0.94, 0.98, 1.0, if (hovered) 0.28 else 0.18),
            .bottom = signal,
            .border = if (hovered) title else Color.rgba(0.82, 0.97, 1.0, 0.72),
            .accent = signal,
            .text = title,
            .shadow_color = Color.rgba(0, 0, 0, 0),
        };
    }
    if (style == .ghost) {
        return .{
            .bg = if (hovered) Color.rgba(0.60, 0.91, 1.0, 0.10) else Color.rgba(0.02, 0.05, 0.08, 0.46),
            .top = Color.rgba(1.0, 1.0, 1.0, if (hovered) 0.16 else 0.08),
            .bottom = Color.rgba(0.50, 0.62, 0.70, if (hovered) 0.32 else 0.18),
            .border = if (hovered) Color.rgba(0.70, 0.92, 1.0, 0.56) else Color.rgba(0.65, 0.88, 0.96, 0.28),
            .accent = signal,
            .text = text,
            .shadow_color = Color.rgba(0, 0, 0, 0),
        };
    }
    return .{
        .bg = if (hovered) Color.rgba(0.60, 0.91, 1.0, 0.12) else Color.rgba(0.60, 0.91, 1.0, 0.04),
        .top = Color.rgba(0.94, 0.98, 1.0, if (hovered) 0.19 else 0.12),
        .bottom = Color.rgba(copper.r, copper.g, copper.b, 0.36),
        .border = if (hovered) Color.rgba(0.70, 0.92, 1.0, 0.56) else Color.rgba(0.65, 0.88, 0.96, 0.24),
        .accent = signal,
        .text = title,
        .shadow_color = Color.rgba(0, 0, 0, 0),
    };
}

fn toneAccent(tone: Tone) Color {
    _ = tone;
    return signal;
}

fn drawSoftHalo(ui: *UISystem, rect: Rect, scale: f32, alpha: f32) void {
    ui.drawRect(.{ .x = rect.x - 18.0 * scale, .y = rect.y - 18.0 * scale, .width = rect.width + 36.0 * scale, .height = rect.height + 36.0 * scale }, Color.rgba(0.58, 0.72, 0.82, alpha * 0.10));
    ui.drawRect(.{ .x = rect.x - 7.0 * scale, .y = rect.y - 7.0 * scale, .width = rect.width + 14.0 * scale, .height = rect.height + 14.0 * scale }, Color.rgba(0.80, 0.88, 0.92, alpha * 0.16));
}

fn drawFrost(ui: *UISystem, rect: Rect, scale: f32, alpha: f32) void {
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        const px = rect.x + (@as(f32, @floatFromInt((i * 181) % 1000)) / 1000.0) * rect.width;
        const py = rect.y + (@as(f32, @floatFromInt((i * 367) % 1000)) / 1000.0) * rect.height;
        const w_base: f32 = if (i % 3 == 0) 36.0 else if (i % 3 == 1) 18.0 else 8.0;
        ui.drawRect(.{ .x = px, .y = py, .width = w_base * scale, .height = 1.0 * scale }, Color.rgba(0.94, 0.98, 1.0, alpha));
    }
}

fn drawGlassCorners(ui: *UISystem, rect: Rect, scale: f32, color: Color) void {
    const s = 30.0 * scale;
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = s, .height = 1.0 * scale }, color);
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = 1.0 * scale, .height = s }, color);
    ui.drawRect(.{ .x = rect.x + rect.width - s, .y = rect.y + rect.height - 1.0 * scale, .width = s, .height = 1.0 * scale }, color);
    ui.drawRect(.{ .x = rect.x + rect.width - 1.0 * scale, .y = rect.y + rect.height - s, .width = 1.0 * scale, .height = s }, color);
}
