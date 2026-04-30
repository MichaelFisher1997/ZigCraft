//! Shared Nordic glass menu rendering primitives.

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

pub const title = Color.rgba(0.88, 0.93, 0.96, 1.0);
pub const text = Color.rgba(0.73, 0.81, 0.87, 0.96);
pub const muted = Color.rgba(0.50, 0.61, 0.69, 0.94);
pub const dim = Color.rgba(0.32, 0.41, 0.48, 0.88);
pub const copper = Color.rgba(0.59, 0.70, 0.78, 1.0);
pub const amber = Color.rgba(0.70, 0.76, 0.62, 1.0);
pub const signal = Color.rgba(0.58, 0.72, 0.82, 1.0);
pub const danger = Color.rgba(0.78, 0.30, 0.34, 1.0);
pub const panel = Color.rgba(0.060, 0.095, 0.125, 0.66);
pub const panel_soft = Color.rgba(0.095, 0.135, 0.165, 0.46);
pub const panel_header = Color.rgba(0.075, 0.115, 0.148, 0.50);
pub const outline = Color.rgba(0.54, 0.66, 0.74, 0.58);

const backdrop_base = Color.rgba(0.018, 0.026, 0.036, 1.0);
const glass_top = Color.rgba(0.94, 0.98, 1.0, 0.16);
const glass_edge = Color.rgba(0.78, 0.88, 0.94, 0.42);
const shadow = Color.rgba(0, 0, 0, 0.32);

pub fn scaleFor(screen_h: f32, user_scale: f32) f32 {
    return @max(1.0, screen_h / 720.0) * user_scale;
}

pub fn drawBackdrop(ui: *UISystem, screen_w: f32, screen_h: f32, scale: f32, tone: Tone) void {
    _ = scale;
    _ = tone;
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, backdrop_base);
}

pub fn drawShell(ui: *UISystem, rect: Rect, scale: f32, kicker: []const u8, heading: []const u8, subtitle: []const u8) Shell {
    const header_h = @min(rect.height * 0.18, 108.0 * scale);
    const footer_h = 72.0 * scale;
    const content = Rect{
        .x = rect.x + 36.0 * scale,
        .y = rect.y + header_h + 28.0 * scale,
        .width = rect.width - 72.0 * scale,
        .height = rect.height - header_h - footer_h - 38.0 * scale,
    };

    drawSoftHalo(ui, rect, scale, 0.16);
    ui.drawRect(.{ .x = rect.x + 18.0 * scale, .y = rect.y + 24.0 * scale, .width = rect.width, .height = rect.height }, shadow);
    ui.drawRect(rect, panel);
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = header_h }, panel_header);
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 1.0 * scale }, glass_top);
    ui.drawRect(.{ .x = rect.x, .y = rect.y + header_h - 2.0 * scale, .width = rect.width, .height = 2.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, 0.52));
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = 2.0 * scale, .height = rect.height }, Color.rgba(1.0, 1.0, 1.0, 0.18));
    ui.drawRect(.{ .x = rect.x + rect.width - 2.0 * scale, .y = rect.y, .width = 2.0 * scale, .height = rect.height }, Color.rgba(signal.r, signal.g, signal.b, 0.22));
    drawFrost(ui, rect, scale, 0.045);
    ui.drawRectOutline(rect, outline, 1.0 * scale);
    drawGlassCorners(ui, rect, scale, Color.rgba(signal.r, signal.g, signal.b, 0.54));

    Font.drawText(ui, kicker, rect.x + 36.0 * scale, rect.y + 20.0 * scale, 0.78 * scale, muted);
    Font.drawText(ui, heading, rect.x + 30.0 * scale, rect.y + 40.0 * scale, 3.08 * scale, title);
    Font.drawText(ui, subtitle, rect.x + 38.0 * scale, rect.y + header_h - 22.0 * scale, 0.94 * scale, muted);

    ui.drawRect(.{ .x = content.x, .y = content.y - 15.0 * scale, .width = content.width * 0.62, .height = 1.0 * scale }, Color.rgba(0.80, 0.88, 0.92, 0.30));
    ui.drawRect(.{ .x = content.x, .y = content.y - 9.0 * scale, .width = content.width * 0.20, .height = 2.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, 0.44));
    ui.drawRect(.{ .x = rect.x + 24.0 * scale, .y = rect.y + rect.height - footer_h, .width = rect.width - 48.0 * scale, .height = 1.0 * scale }, Color.rgba(0.68, 0.76, 0.82, 0.22));

    return .{
        .rect = rect,
        .content = content,
        .footer_y = rect.y + rect.height - footer_h + 15.0 * scale,
        .scale = scale,
    };
}

pub fn drawHeroTitle(ui: *UISystem, x: f32, y: f32, scale: f32, compact: bool) void {
    const word_scale: f32 = if (compact) 3.15 * scale else 4.15 * scale;
    const line_w: f32 = if (compact) 420.0 * scale else 620.0 * scale;
    const word_y = y + 4.0 * scale;
    const zig_w = Font.measureTextWidth("Zig", word_scale);
    const craft_w = Font.measureTextWidth("Craft", word_scale);
    const mark_w = zig_w + craft_w + 3.0 * scale;
    const mark_h = word_scale * 7.0 + 22.0 * scale;
    const copy_y = word_y + mark_h + 18.0 * scale;

    ui.drawRect(.{ .x = x, .y = y - 18.0 * scale, .width = line_w, .height = 1.0 * scale }, Color.rgba(0.72, 0.82, 0.88, 0.34));
    ui.drawRect(.{ .x = x, .y = y - 10.0 * scale, .width = line_w * 0.46, .height = 2.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, 0.48));
    Font.drawText(ui, "VOXEL SURVIVAL ENGINE", x + 2.0 * scale, y - 48.0 * scale, 0.92 * scale, muted);

    ui.drawRect(.{ .x = x - 10.0 * scale, .y = word_y - 10.0 * scale, .width = mark_w + 28.0 * scale, .height = mark_h }, Color.rgba(0.060, 0.095, 0.125, 0.28));
    ui.drawRect(.{ .x = x - 10.0 * scale, .y = word_y - 10.0 * scale, .width = mark_w + 28.0 * scale, .height = 1.0 * scale }, Color.rgba(0.94, 0.98, 1.0, 0.16));
    ui.drawRect(.{ .x = x - 10.0 * scale, .y = word_y + mark_h - 12.0 * scale, .width = mark_w + 28.0 * scale, .height = 1.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, 0.36));
    Font.drawText(ui, "Zig", x + 2.0 * scale, word_y + 2.0 * scale, word_scale, Color.rgba(0, 0, 0, 0.28));
    Font.drawText(ui, "Craft", x + zig_w + 5.0 * scale, word_y + 2.0 * scale, word_scale, Color.rgba(0, 0, 0, 0.24));
    Font.drawText(ui, "Zig", x, word_y, word_scale, title);
    Font.drawText(ui, "Craft", x + zig_w + 3.0 * scale, word_y, word_scale, Color.rgba(0.72, 0.82, 0.88, 1.0));

    Font.drawText(ui, "BUILD WORLDS IN QUIET GLASS", x + 4.0 * scale, copy_y, 1.05 * scale, text);
    Font.drawText(ui, "PROCEDURAL TERRAIN  /  LOCAL SAVES  /  VULKAN", x + 4.0 * scale, copy_y + 28.0 * scale, 0.74 * scale, muted);
}

pub fn drawButton(ui: *UISystem, rect: Rect, label: []const u8, text_scale: f32, mx: f32, my: f32, clicked: bool, style: ButtonStyle, scale: f32) bool {
    const disabled = style == .disabled;
    const hovered = !disabled and rect.contains(mx, my);
    const colors = buttonColors(style, hovered);

    ui.drawRect(.{ .x = rect.x + 8.0 * scale, .y = rect.y + 10.0 * scale, .width = rect.width, .height = rect.height }, colors.shadow_color);
    ui.drawRect(rect, colors.bg);
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 1.0 * scale }, colors.top);
    ui.drawRect(.{ .x = rect.x, .y = rect.y + rect.height - 1.0 * scale, .width = rect.width, .height = 1.0 * scale }, colors.bottom);
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = 3.0 * scale, .height = rect.height }, colors.accent);
    ui.drawRect(.{ .x = rect.x + 10.0 * scale, .y = rect.y + 9.0 * scale, .width = rect.width - 20.0 * scale, .height = 1.0 * scale }, Color.rgba(1.0, 1.0, 1.0, if (hovered) 0.20 else 0.11));
    ui.drawRectOutline(rect, colors.border, if (hovered) 2.0 * scale else 1.0 * scale);

    const max_text_width = @max(1.0, rect.width - 58.0 * scale);
    Font.drawTextCenteredFit(ui, label, rect.x + rect.width * 0.5 + 2.0 * scale, rect.y + (rect.height - 7.0 * text_scale) * 0.5, text_scale, max_text_width, colors.text);
    return hovered and clicked;
}

pub fn drawTextInput(ui: *UISystem, rect: Rect, value: []const u8, placeholder: []const u8, text_scale: f32, focused: bool, caret: bool, scale: f32) void {
    const border = if (focused) signal else Color.rgba(0.42, 0.54, 0.62, 0.50);
    ui.drawRect(.{ .x = rect.x + 5.0 * scale, .y = rect.y + 7.0 * scale, .width = rect.width, .height = rect.height }, shadow);
    ui.drawRect(rect, Color.rgba(0.075, 0.110, 0.140, 0.66));
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = rect.height * 0.30 }, Color.rgba(0.92, 0.97, 1.0, if (focused) 0.12 else 0.08));
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
    ui.drawRect(.{ .x = x, .y = y + 8.0 * scale, .width = 40.0 * scale, .height = 1.0 * scale }, Color.rgba(signal.r, signal.g, signal.b, 0.50));
    Font.drawText(ui, label, x + 58.0 * scale, y, 0.88 * scale, muted);
}

pub fn drawOptionRow(ui: *UISystem, rect: Rect, label: []const u8, description: []const u8, label_scale: f32, selected: bool, scale: f32) void {
    const bg = if (selected) Color.rgba(0.095, 0.140, 0.170, 0.70) else Color.rgba(0.060, 0.095, 0.125, 0.52);
    const edge = if (selected) signal else Color.rgba(0.40, 0.52, 0.60, 0.40);
    ui.drawRect(.{ .x = rect.x + 5.0 * scale, .y = rect.y + 7.0 * scale, .width = rect.width, .height = rect.height }, shadow);
    ui.drawRect(rect, bg);
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 1.0 * scale }, Color.rgba(1.0, 1.0, 1.0, if (selected) 0.20 else 0.10));
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = 3.0 * scale, .height = rect.height }, edge);
    ui.drawRectOutline(rect, Color.rgba(edge.r, edge.g, edge.b, if (selected) 0.62 else 0.34), 1.0 * scale);
    Font.drawText(ui, label, rect.x + 18.0 * scale, rect.y + 10.0 * scale, label_scale, if (selected) title else text);
    if (description.len > 0) Font.drawText(ui, description, rect.x + 18.0 * scale, rect.y + 34.0 * scale, label_scale * 0.54, muted);
}

pub fn drawValueText(ui: *UISystem, rect: Rect, value: []const u8, text_scale: f32, scale: f32) void {
    ui.drawRect(.{ .x = rect.x + 4.0 * scale, .y = rect.y + 5.0 * scale, .width = rect.width, .height = rect.height }, shadow);
    ui.drawRect(rect, Color.rgba(0.045, 0.070, 0.092, 0.74));
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 1.0 * scale }, glass_top);
    ui.drawRectOutline(rect, Color.rgba(signal.r, signal.g, signal.b, 0.44), 1.0 * scale);
    Font.drawTextCenteredFit(ui, value, rect.x + rect.width * 0.5, rect.y + (rect.height - 7.0 * text_scale) * 0.5, text_scale, rect.width - 12.0 * scale, title);
}

pub fn drawListRail(ui: *UISystem, rect: Rect, scale: f32) void {
    ui.drawRect(.{ .x = rect.x + 8.0 * scale, .y = rect.y + 10.0 * scale, .width = rect.width, .height = rect.height }, shadow);
    ui.drawRect(rect, Color.rgba(0.052, 0.086, 0.112, 0.54));
    drawFrost(ui, rect, scale, 0.035);
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = 3.0 * scale, .height = rect.height }, Color.rgba(signal.r, signal.g, signal.b, 0.44));
    ui.drawRect(.{ .x = rect.x + rect.width - 1.0 * scale, .y = rect.y, .width = 1.0 * scale, .height = rect.height }, Color.rgba(1.0, 1.0, 1.0, 0.14));
    ui.drawRectOutline(rect, Color.rgba(0.48, 0.60, 0.68, 0.42), 1.0 * scale);
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
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0.010, 0.016, 0.024, 0.72));
    const edge = if (destructive) danger else signal;
    ui.drawRect(.{ .x = rect.x + 14.0 * scale, .y = rect.y + 16.0 * scale, .width = rect.width, .height = rect.height }, shadow);
    ui.drawRect(rect, Color.rgba(0.060, 0.095, 0.125, 0.82));
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 42.0 * scale }, Color.rgba(edge.r, edge.g, edge.b, 0.14));
    ui.drawRect(.{ .x = rect.x, .y = rect.y + 42.0 * scale, .width = rect.width, .height = 1.0 * scale }, Color.rgba(edge.r, edge.g, edge.b, 0.56));
    ui.drawRectOutline(rect, Color.rgba(edge.r, edge.g, edge.b, 0.64), 1.0 * scale);
    Font.drawTextCentered(ui, heading, rect.x + rect.width * 0.5, rect.y + 14.0 * scale, 1.52 * scale, title);
    if (subtitle.len > 0) Font.drawTextCentered(ui, subtitle, rect.x + rect.width * 0.5, rect.y + 64.0 * scale, 0.88 * scale, muted);
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
            .bg = if (hovered) Color.rgba(0.105, 0.155, 0.190, 0.76) else Color.rgba(0.075, 0.120, 0.155, 0.66),
            .top = Color.rgba(0.94, 0.98, 1.0, if (hovered) 0.22 else 0.14),
            .bottom = Color.rgba(signal.r, signal.g, signal.b, 0.46),
            .border = if (hovered) Color.rgba(0.72, 0.84, 0.90, 0.72) else Color.rgba(signal.r, signal.g, signal.b, 0.54),
            .accent = signal,
            .text = title,
            .shadow_color = Color.rgba(0, 0.02, 0.04, 0.34),
        };
    }
    if (style == .ghost) {
        return .{
            .bg = if (hovered) Color.rgba(0.078, 0.105, 0.130, 0.54) else Color.rgba(0.050, 0.075, 0.095, 0.42),
            .top = Color.rgba(1.0, 1.0, 1.0, if (hovered) 0.16 else 0.08),
            .bottom = Color.rgba(0.50, 0.62, 0.70, if (hovered) 0.32 else 0.18),
            .border = if (hovered) Color.rgba(0.60, 0.72, 0.80, 0.62) else Color.rgba(0.40, 0.52, 0.60, 0.42),
            .accent = Color.rgba(0.48, 0.60, 0.68, 0.74),
            .text = text,
            .shadow_color = Color.rgba(0, 0, 0, 0.24),
        };
    }
    return .{
        .bg = if (hovered) Color.rgba(0.105, 0.135, 0.160, 0.70) else Color.rgba(0.075, 0.105, 0.130, 0.58),
        .top = Color.rgba(0.94, 0.98, 1.0, if (hovered) 0.19 else 0.12),
        .bottom = Color.rgba(copper.r, copper.g, copper.b, 0.36),
        .border = if (hovered) Color.rgba(0.68, 0.78, 0.84, 0.66) else Color.rgba(copper.r, copper.g, copper.b, 0.48),
        .accent = copper,
        .text = title,
        .shadow_color = Color.rgba(0, 0, 0, 0.28),
    };
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
