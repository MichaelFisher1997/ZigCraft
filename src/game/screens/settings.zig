const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const settings_pkg = @import("../settings.zig");
const Settings = settings_pkg.Settings;
const GraphicsScreen = @import("graphics.zig").GraphicsScreen;
const apply_logic = settings_pkg.apply_logic;

const PANEL_WIDTH_MAX = 760.0;
const PANEL_HEIGHT_BASE = 820.0;
const BG_COLOR = Color.rgba(0.025, 0.045, 0.065, 0.95);
const BORDER_COLOR = Color.rgba(0.42, 0.66, 0.82, 0.78);
const TITLE_COLOR = Color.rgba(1.0, 0.93, 0.76, 1.0);
const LABEL_COLOR = Color.rgba(0.72, 0.86, 0.96, 1.0);
const MUTED_COLOR = Color.rgba(0.48, 0.60, 0.70, 0.92);

pub const SettingsScreen = struct {
    context: EngineContext,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*SettingsScreen {
        const self = try allocator.create(SettingsScreen);
        self.* = .{
            .context = context,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;

        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            self.context.saveSettings();
            self.context.screen_manager.popScreen();
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        const settings = ctx.settings;
        const rs = ctx.render_settings;

        // Draw background screen if it exists
        try ctx.screen_manager.drawParentScreen(ptr, ui);

        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());

        const auto_scale: f32 = @max(1.0, screen_h / 720.0);
        const ui_scale: f32 = auto_scale * settings.ui_scale;
        const label_scale: f32 = 1.75 * ui_scale;
        const btn_scale: f32 = 1.55 * ui_scale;
        const title_scale: f32 = 3.0 * ui_scale;
        const row_height: f32 = 52.0 * ui_scale;
        const btn_height: f32 = 38.0 * ui_scale;
        const btn_width: f32 = 40.0 * ui_scale;
        const toggle_width: f32 = 160.0 * ui_scale;

        const pw: f32 = @min(screen_w * 0.75, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = @min(screen_h - 80.0 * ui_scale, PANEL_HEIGHT_BASE * ui_scale);
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = (screen_h - ph) * 0.5;

        drawSettingsBackdrop(ui, screen_w, screen_h, ui_scale);
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRect(.{ .x = px, .y = py, .width = 7.0 * ui_scale, .height = ph }, Color.rgba(0.95, 0.62, 0.24, 0.95));
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = 72.0 * ui_scale }, Color.rgba(0.12, 0.22, 0.30, 0.64));
        ui.drawRect(.{ .x = px + pw - 2.0 * ui_scale, .y = py, .width = 2.0 * ui_scale, .height = ph }, Color.rgba(0.48, 0.76, 0.93, 0.62));
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawText(ui, "SETTINGS", px + 34.0 * ui_scale, py + 24.0 * ui_scale, title_scale, TITLE_COLOR);
        Font.drawText(ui, "Tune the renderer and input feel.", px + 38.0 * ui_scale, py + 56.0 * ui_scale, 1.05 * ui_scale, MUTED_COLOR);
        var sy: f32 = py + 96.0 * ui_scale;
        const lx: f32 = px + 50.0 * ui_scale;
        const vx: f32 = px + pw - 250.0 * ui_scale;

        drawSectionLabel(ui, lx, sy - 28.0 * ui_scale, "DISPLAY", ui_scale);

        // Resolution
        Font.drawText(ui, "RESOLUTION", lx, sy, label_scale, LABEL_COLOR);
        const res_idx = settings.getResolutionIndex();
        const res_label = settings_pkg.RESOLUTIONS[res_idx].label;
        if (Widgets.drawButton(ui, .{ .x = vx - 20.0, .y = sy - 5.0, .width = 180.0 * ui_scale, .height = btn_height }, res_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const new_idx = (res_idx + 1) % settings_pkg.RESOLUTIONS.len;
            settings.setResolutionByIndex(new_idx);
            ctx.window_manager.setSize(settings.window_width, settings.window_height);
        }
        sy += row_height;

        // Render Distance
        Font.drawText(ui, "RENDER DISTANCE", lx, sy, label_scale, LABEL_COLOR);
        Font.drawNumber(ui, @intCast(settings.render_distance), vx + 70.0 * ui_scale, sy, TITLE_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.render_distance > 1) settings.render_distance -= 1;
        }
        if (Widgets.drawButton(ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.render_distance += 1;
        }
        sy += row_height;

        // Sensitivity
        Font.drawText(ui, "SENSITIVITY", lx, sy, label_scale, LABEL_COLOR);
        Font.drawNumber(ui, @intFromFloat(settings.mouse_sensitivity), vx + 70.0 * ui_scale, sy, TITLE_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.mouse_sensitivity > 10.0) settings.mouse_sensitivity -= 5.0;
        }
        if (Widgets.drawButton(ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.mouse_sensitivity < 200.0) settings.mouse_sensitivity += 5.0;
        }
        sy += row_height;

        // FOV
        Font.drawText(ui, "FOV", lx, sy, label_scale, LABEL_COLOR);
        Font.drawNumber(ui, @intFromFloat(settings.fov), vx + 70.0 * ui_scale, sy, TITLE_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.fov > 30.0) settings.fov -= 5.0;
        }
        if (Widgets.drawButton(ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 5.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.fov < 120.0) settings.fov += 5.0;
        }
        sy += row_height;

        // VSync
        Font.drawText(ui, "VSYNC", lx, sy, label_scale, LABEL_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.vsync) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.vsync = !settings.vsync;
            apply_logic.applyToRenderSettings(settings, rs);
        }
        sy += row_height + 12.0 * ui_scale;

        // Advanced Graphics Button
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 250.0 * ui_scale) * 0.5, .y = sy, .width = 250.0 * ui_scale, .height = btn_height + 10.0 * ui_scale }, "ADVANCED GRAPHICS...", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const graphics_screen = try GraphicsScreen.init(ctx.allocator, ctx);
            errdefer graphics_screen.deinit(graphics_screen);
            ctx.screen_manager.pushScreen(graphics_screen.screen());
        }
        sy += row_height + 12.0 * ui_scale;

        drawSectionLabel(ui, lx, sy - 14.0 * ui_scale, "SYSTEMS", ui_scale);
        sy += 18.0 * ui_scale;

        // UI Scale
        Font.drawText(ui, "UI SCALE", lx, sy, label_scale, LABEL_COLOR);
        const ui_scale_label = settings_pkg.ui_helpers.getUIScaleLabel(settings.ui_scale);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, ui_scale_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.ui_scale = settings_pkg.ui_helpers.cycleUIScale(settings.ui_scale);
        }
        sy += row_height;

        // LOD System
        Font.drawText(ui, "LOD SYSTEM", lx, sy, label_scale, LABEL_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.lod_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.lod_enabled = !settings.lod_enabled;
        }
        sy += row_height;

        // Textures
        Font.drawText(ui, "TEXTURES", lx, sy, label_scale, LABEL_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.textures_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.textures_enabled = !settings.textures_enabled;
            apply_logic.applyToRenderSettings(settings, rs);
        }
        sy += row_height;

        // Wireframe (debug)
        Font.drawText(ui, "WIREFRAME", lx, sy, label_scale, MUTED_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, if (settings.wireframe_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.wireframe_enabled = !settings.wireframe_enabled;
            apply_logic.applyToRenderSettings(settings, rs);
        }
        Font.drawText(ui, "(DEBUG)", vx + toggle_width + 10.0, sy, 1.1 * ui_scale, MUTED_COLOR);

        // Back button
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 150.0 * ui_scale) * 0.5, .y = py + ph - 70.0 * ui_scale, .width = 150.0 * ui_scale, .height = 50.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            ctx.saveSettings();
            ctx.screen_manager.popScreen();
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn drawSettingsBackdrop(ui: *UISystem, screen_w: f32, screen_h: f32, ui_scale: f32) void {
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0.010, 0.018, 0.030, 0.72));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.64, .width = screen_w, .height = screen_h * 0.36 }, Color.rgba(0.075, 0.048, 0.028, 0.50));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.64, .width = screen_w, .height = 2.0 * ui_scale }, Color.rgba(0.92, 0.62, 0.24, 0.38));
    ui.drawRect(.{ .x = 46.0 * ui_scale, .y = screen_h * 0.64 - 84.0 * ui_scale, .width = 96.0 * ui_scale, .height = 84.0 * ui_scale }, Color.rgba(0.07, 0.14, 0.15, 0.28));
    ui.drawRect(.{ .x = screen_w - 132.0 * ui_scale, .y = screen_h * 0.64 - 148.0 * ui_scale, .width = 74.0 * ui_scale, .height = 148.0 * ui_scale }, Color.rgba(0.50, 0.29, 0.12, 0.30));
}

fn drawSectionLabel(ui: *UISystem, x: f32, y: f32, label: []const u8, ui_scale: f32) void {
    ui.drawRect(.{ .x = x, .y = y + 8.0 * ui_scale, .width = 26.0 * ui_scale, .height = 2.0 * ui_scale }, Color.rgba(0.95, 0.62, 0.24, 0.86));
    Font.drawText(ui, label, x + 36.0 * ui_scale, y, 1.05 * ui_scale, MUTED_COLOR);
}
