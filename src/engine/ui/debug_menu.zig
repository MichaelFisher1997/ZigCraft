//! Centralized debug menu overlay.
//! Lists all debug features with toggle state and hotkey labels.
//! Opened via F3 (toggle_debug_menu action).

const std = @import("std");
const UISystem = @import("ui_system.zig").UISystem;
const Color = @import("ui_system.zig").Color;
const Rect = @import("ui_system.zig").Rect;
const Font = @import("font.zig");

pub const DebugFeature = enum(u8) {
    wireframe,
    textures,
    vsync,
    fps_counter,
    block_info,
    shadow_debug,
    timing_overlay,
    lod_render,
    gpass_render,
    ssao,
    clouds,
    fog,
    lpv_overlay,
    creative_mode,
    time_pause,

    pub const count = @typeInfo(DebugFeature).@"enum".fields.len;
};

pub const FeatureInfo = struct {
    label: []const u8,
    hotkey: []const u8,
};

pub const FEATURE_INFOS = [DebugFeature.count]FeatureInfo{
    .{ .label = "WIREFRAME", .hotkey = "F" },
    .{ .label = "TEXTURES", .hotkey = "T" },
    .{ .label = "VSYNC", .hotkey = "V" },
    .{ .label = "FPS COUNTER", .hotkey = "F2" },
    .{ .label = "BLOCK INFO", .hotkey = "F5" },
    .{ .label = "SHADOW DEBUG", .hotkey = "G" },
    .{ .label = "TIMING OVERLAY", .hotkey = "F4" },
    .{ .label = "LOD RENDER", .hotkey = "F6" },
    .{ .label = "G-PASS RENDER", .hotkey = "F7" },
    .{ .label = "SSAO", .hotkey = "F8" },
    .{ .label = "CLOUDS", .hotkey = "F9" },
    .{ .label = "FOG", .hotkey = "F10" },
    .{ .label = "LPV OVERLAY", .hotkey = "F11" },
    .{ .label = "CREATIVE MODE", .hotkey = "F12" },
    .{ .label = "TIME PAUSE", .hotkey = "N" },
};

pub const DebugMenuOverlay = struct {
    enabled: bool = false,

    const BASE_PANEL_X: f32 = 10.0;
    const BASE_PANEL_Y: f32 = 10.0;
    const BASE_PANEL_WIDTH: f32 = 300.0;
    const BASE_LINE_HEIGHT: f32 = 18.0;
    const BASE_HEADER_HEIGHT: f32 = 28.0;
    const BASE_PADDING: f32 = 8.0;
    const BASE_TITLE_SCALE: f32 = 1.5;
    const BASE_TEXT_SCALE: f32 = 1.2;
    const MAX_VISIBLE_ROWS: usize = 15;

    pub fn toggle(self: *DebugMenuOverlay) void {
        self.enabled = !self.enabled;
    }

    pub const ClickResult = struct {
        feature: DebugFeature,
    };

    pub fn draw(self: *DebugMenuOverlay, ui: *UISystem, feature_states: [DebugFeature.count]bool, mouse_x: f32, mouse_y: f32, mouse_clicked: bool, ui_scale: f32) ?ClickResult {
        if (!self.enabled) return null;

        const panel_x = BASE_PANEL_X * ui_scale;
        const panel_y = BASE_PANEL_Y * ui_scale;
        const panel_width = BASE_PANEL_WIDTH * ui_scale;
        const line_height = BASE_LINE_HEIGHT * ui_scale;
        const header_height = BASE_HEADER_HEIGHT * ui_scale;
        const padding = BASE_PADDING * ui_scale;
        const title_scale = BASE_TITLE_SCALE * ui_scale;
        const text_scale = BASE_TEXT_SCALE * ui_scale;

        const visible_rows = @min(DebugFeature.count, MAX_VISIBLE_ROWS);
        const panel_height = header_height + padding * 2 + @as(f32, @floatFromInt(visible_rows)) * line_height;
        const panel_rect = Rect{ .x = panel_x, .y = panel_y, .width = panel_width, .height = panel_height };

        ui.drawRect(panel_rect, Color.rgba(0.0, 0.0, 0.0, 0.7));
        ui.drawRectOutline(panel_rect, Color.rgba(0.4, 0.6, 0.8, 0.8), 2.0 * ui_scale);

        var y = panel_y + padding;
        Font.drawText(ui, "DEBUG MENU", panel_x + padding, y, title_scale, Color.rgba(0.95, 0.98, 1.0, 1.0));
        y += header_height;

        var result: ?ClickResult = null;

        for (0..visible_rows) |i| {
            const feature: DebugFeature = @enumFromInt(i);
            const info = FEATURE_INFOS[i];
            const state = feature_states[i];
            const row_rect = Rect{ .x = panel_x + 2 * ui_scale, .y = y - 2 * ui_scale, .width = panel_width - 4 * ui_scale, .height = line_height };
            const hovered = row_rect.contains(mouse_x, mouse_y);

            if (hovered) {
                ui.drawRect(row_rect, Color.rgba(0.2, 0.3, 0.45, 0.5));
                if (mouse_clicked) {
                    result = .{ .feature = feature };
                }
            }

            Font.drawText(ui, info.label, panel_x + padding + 4 * ui_scale, y, text_scale, Color.rgba(0.85, 0.88, 0.92, 1.0));

            const state_text = if (state) "ON" else "OFF";
            const state_color = if (state) Color.rgba(0.3, 1.0, 0.4, 1.0) else Color.rgba(0.7, 0.35, 0.35, 1.0);
            const state_x = panel_x + panel_width - padding - 4 * ui_scale - Font.measureTextWidth(state_text, text_scale) - 50.0 * ui_scale;
            Font.drawText(ui, state_text, state_x, y, text_scale, state_color);

            const hotkey_x = panel_x + panel_width - padding - 4 * ui_scale - Font.measureTextWidth(info.hotkey, text_scale);
            Font.drawText(ui, info.hotkey, hotkey_x, y, text_scale, Color.rgba(0.55, 0.58, 0.65, 1.0));

            y += line_height;
        }

        return result;
    }
};
