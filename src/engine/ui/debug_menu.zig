//! Centralized debug menu overlay.
//! Lists all debug features with toggle state and hotkey labels.
//! Opened via F3 (toggle_debug_menu action).

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

    const PANEL_X: f32 = 10.0;
    const PANEL_Y: f32 = 10.0;
    const PANEL_WIDTH: f32 = 300.0;
    const LINE_HEIGHT: f32 = 18.0;
    const HEADER_HEIGHT: f32 = 28.0;
    const PADDING: f32 = 8.0;
    const TITLE_SCALE: f32 = 1.5;
    const TEXT_SCALE: f32 = 1.2;

    pub fn toggle(self: *DebugMenuOverlay) void {
        self.enabled = !self.enabled;
    }

    pub const ClickResult = struct {
        feature: DebugFeature,
    };

    pub fn draw(self: *DebugMenuOverlay, ui: *UISystem, feature_states: [DebugFeature.count]bool, mouse_x: f32, mouse_y: f32, mouse_clicked: bool) ?ClickResult {
        if (!self.enabled) return null;

        const panel_height = HEADER_HEIGHT + PADDING * 2 + @as(f32, @floatFromInt(DebugFeature.count)) * LINE_HEIGHT;
        const panel_rect = Rect{ .x = PANEL_X, .y = PANEL_Y, .width = PANEL_WIDTH, .height = panel_height };

        ui.drawRect(panel_rect, Color.rgba(0.0, 0.0, 0.0, 0.7));
        ui.drawRectOutline(panel_rect, Color.rgba(0.4, 0.6, 0.8, 0.8), 2.0);

        var y = PANEL_Y + PADDING;
        Font.drawText(ui, "DEBUG MENU", PANEL_X + PADDING, y, TITLE_SCALE, Color.rgba(0.95, 0.98, 1.0, 1.0));
        y += HEADER_HEIGHT;

        var result: ?ClickResult = null;

        for (0..DebugFeature.count) |i| {
            const feature: DebugFeature = @enumFromInt(i);
            const info = FEATURE_INFOS[i];
            const state = feature_states[i];
            const row_rect = Rect{ .x = PANEL_X + 2, .y = y - 2, .width = PANEL_WIDTH - 4, .height = LINE_HEIGHT };
            const hovered = row_rect.contains(mouse_x, mouse_y);

            if (hovered) {
                ui.drawRect(row_rect, Color.rgba(0.2, 0.3, 0.45, 0.5));
                if (mouse_clicked) {
                    result = .{ .feature = feature };
                }
            }

            Font.drawText(ui, info.label, PANEL_X + PADDING + 4, y, TEXT_SCALE, Color.rgba(0.85, 0.88, 0.92, 1.0));

            const state_text = if (state) "ON" else "OFF";
            const state_color = if (state) Color.rgba(0.3, 1.0, 0.4, 1.0) else Color.rgba(0.7, 0.35, 0.35, 1.0);
            const state_x = PANEL_X + PANEL_WIDTH - PADDING - 4 - Font.measureTextWidth(state_text, TEXT_SCALE) - 50.0;
            Font.drawText(ui, state_text, state_x, y, TEXT_SCALE, state_color);

            const hotkey_x = PANEL_X + PANEL_WIDTH - PADDING - 4 - Font.measureTextWidth(info.hotkey, TEXT_SCALE);
            Font.drawText(ui, info.hotkey, hotkey_x, y, TEXT_SCALE, Color.rgba(0.55, 0.58, 0.65, 1.0));

            y += LINE_HEIGHT;
        }

        return result;
    }
};
