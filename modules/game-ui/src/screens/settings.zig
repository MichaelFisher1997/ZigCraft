const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Font = @import("engine-ui").font;
const Widgets = @import("engine-ui").widgets;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const settings_pkg = @import("game-core").settings;
const Settings = settings_pkg.Settings;
const GraphicsScreen = @import("graphics.zig").GraphicsScreen;
const apply_logic = settings_pkg.apply_logic;

const PANEL_WIDTH_MAX = 900.0;
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
        const label_scale: f32 = 1.55 * ui_scale;
        const btn_scale: f32 = 1.35 * ui_scale;
        const title_scale: f32 = 2.8 * ui_scale;
        const row_height: f32 = 48.0 * ui_scale;
        const btn_height: f32 = 34.0 * ui_scale;
        const btn_width: f32 = 38.0 * ui_scale;
        const toggle_width: f32 = 150.0 * ui_scale;

        const margin: f32 = 50.0 * ui_scale;
        const pw: f32 = @min(screen_w - margin * 2.0, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = screen_h - margin * 2.0;
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = margin;

        const header_h: f32 = 72.0 * ui_scale;
        const footer_h: f32 = 64.0 * ui_scale;
        const content_top: f32 = py + header_h;
        const content_bottom: f32 = py + ph - footer_h;

        drawSettingsBackdrop(ui, screen_w, screen_h, ui_scale);
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRect(.{ .x = px, .y = py, .width = 7.0 * ui_scale, .height = ph }, Color.rgba(0.95, 0.62, 0.24, 0.95));
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = header_h }, Color.rgba(0.12, 0.22, 0.30, 0.64));
        ui.drawRect(.{ .x = px + pw - 2.0 * ui_scale, .y = py, .width = 2.0 * ui_scale, .height = ph }, Color.rgba(0.48, 0.76, 0.93, 0.62));
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawText(ui, "SETTINGS", px + 34.0 * ui_scale, py + 20.0 * ui_scale, title_scale, TITLE_COLOR);
        Font.drawText(ui, "Tune the renderer and input feel.", px + 38.0 * ui_scale, py + 48.0 * ui_scale, 1.0 * ui_scale, MUTED_COLOR);

        // Layout constants
        const ix: f32 = px + 40.0 * ui_scale;
        const vx: f32 = px + pw - 250.0 * ui_scale;

        // Calculate content start Y to center everything vertically
        const section_gap: f32 = 20.0 * ui_scale;
        const label_h: f32 = 20.0 * ui_scale;
        const total_content: f32 = 2.0 * label_h + 9.0 * row_height + 2.0 * section_gap + 42.0 * ui_scale;
        var sy: f32 = content_top + @max(10.0 * ui_scale, (content_bottom - content_top - total_content) * 0.4);

        // DISPLAY section
        drawSectionLabel(ui, ix, sy, "DISPLAY", ui_scale);
        sy += label_h + 6.0 * ui_scale;

        // Resolution
        Font.drawText(ui, "RESOLUTION", ix, sy, label_scale, LABEL_COLOR);
        const res_idx = settings.getResolutionIndex();
        const res_label = settings_pkg.RESOLUTIONS[res_idx].label;
        const res_val_w: f32 = 150.0 * ui_scale;
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = btn_width, .height = btn_height }, "<", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const new_idx = if (res_idx == 0) settings_pkg.RESOLUTIONS.len - 1 else res_idx - 1;
            settings.setResolutionByIndex(new_idx);
            ctx.window_manager.setSize(settings.window_width, settings.window_height);
        }
        Font.drawTextCentered(ui, res_label, vx + btn_width + res_val_w * 0.5, sy + (btn_height - 7.0 * btn_scale) * 0.5, btn_scale, TITLE_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx + btn_width + res_val_w, .y = sy - 4.0, .width = btn_width, .height = btn_height }, ">", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const new_idx = (res_idx + 1) % settings_pkg.RESOLUTIONS.len;
            settings.setResolutionByIndex(new_idx);
            ctx.window_manager.setSize(settings.window_width, settings.window_height);
        }
        sy += row_height;

        // Render Distance
        Font.drawText(ui, "RENDER DISTANCE", ix, sy, label_scale, LABEL_COLOR);
        Font.drawNumber(ui, @intCast(settings.render_distance), vx + 70.0 * ui_scale, sy, TITLE_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.render_distance > 1) settings.render_distance -= 1;
        }
        if (Widgets.drawButton(ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 4.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.render_distance += 1;
        }
        sy += row_height;

        // Sensitivity
        Font.drawText(ui, "SENSITIVITY", ix, sy, label_scale, LABEL_COLOR);
        Font.drawNumber(ui, @intFromFloat(settings.mouse_sensitivity), vx + 70.0 * ui_scale, sy, TITLE_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.mouse_sensitivity > 10.0) settings.mouse_sensitivity -= 5.0;
        }
        if (Widgets.drawButton(ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 4.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.mouse_sensitivity < 200.0) settings.mouse_sensitivity += 5.0;
        }
        sy += row_height;

        // FOV
        Font.drawText(ui, "FOV", ix, sy, label_scale, LABEL_COLOR);
        Font.drawNumber(ui, @intFromFloat(settings.fov), vx + 70.0 * ui_scale, sy, TITLE_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = btn_width, .height = btn_height }, "-", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.fov > 30.0) settings.fov -= 5.0;
        }
        if (Widgets.drawButton(ui, .{ .x = vx + 120.0 * ui_scale, .y = sy - 4.0, .width = btn_width, .height = btn_height }, "+", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (settings.fov < 120.0) settings.fov += 5.0;
        }
        sy += row_height;

        // VSync
        Font.drawText(ui, "VSYNC", ix, sy, label_scale, LABEL_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = toggle_width, .height = btn_height }, if (settings.vsync) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.vsync = !settings.vsync;
            apply_logic.applyToRenderSettings(settings, rs);
        }
        sy += row_height + section_gap;

        // Advanced Graphics Button
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 250.0 * ui_scale) * 0.5, .y = sy, .width = 250.0 * ui_scale, .height = btn_height + 8.0 * ui_scale }, "ADVANCED GRAPHICS...", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const graphics_screen = try GraphicsScreen.init(ctx.allocator, ctx);
            errdefer graphics_screen.deinit(graphics_screen);
            ctx.screen_manager.pushScreen(graphics_screen.screen());
        }
        sy += row_height + section_gap;

        // SYSTEMS section
        drawSectionLabel(ui, ix, sy, "SYSTEMS", ui_scale);
        sy += label_h + 6.0 * ui_scale;

        // UI Scale
        Font.drawText(ui, "UI SCALE", ix, sy, label_scale, LABEL_COLOR);
        const ui_scale_label = settings_pkg.ui_helpers.getUIScaleLabel(settings.ui_scale);
        const ui_val_w: f32 = 90.0 * ui_scale;
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = btn_width, .height = btn_height }, "<", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.ui_scale = settings_pkg.ui_helpers.prevUIScale(settings.ui_scale);
        }
        Font.drawTextCentered(ui, ui_scale_label, vx + btn_width + ui_val_w * 0.5, sy + (btn_height - 7.0 * btn_scale) * 0.5, btn_scale, TITLE_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx + btn_width + ui_val_w, .y = sy - 4.0, .width = btn_width, .height = btn_height }, ">", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.ui_scale = settings_pkg.ui_helpers.cycleUIScale(settings.ui_scale);
        }
        sy += row_height;

        // LOD System
        Font.drawText(ui, "LOD SYSTEM", ix, sy, label_scale, LABEL_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = toggle_width, .height = btn_height }, if (settings.lod_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.lod_enabled = !settings.lod_enabled;
            if (settings_pkg.sanitizeRuntimeConflicts(settings)) {
                apply_logic.applyToRenderSettings(settings, rs);
            }
        }
        sy += row_height;

        // Textures
        Font.drawText(ui, "TEXTURES", ix, sy, label_scale, LABEL_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = toggle_width, .height = btn_height }, if (settings.textures_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.textures_enabled = !settings.textures_enabled;
            apply_logic.applyToRenderSettings(settings, rs);
        }
        sy += row_height;

        // Wireframe (debug)
        Font.drawText(ui, "WIREFRAME", ix, sy, label_scale, MUTED_COLOR);
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = toggle_width, .height = btn_height }, if (settings.wireframe_enabled) "ENABLED" else "DISABLED", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            settings.wireframe_enabled = !settings.wireframe_enabled;
            apply_logic.applyToRenderSettings(settings, rs);
        }
        Font.drawText(ui, "(DEBUG)", vx + toggle_width + 10.0, sy, 1.0 * ui_scale, MUTED_COLOR);

        // Footer / Back button
        const footer_y: f32 = py + ph - footer_h + 10.0 * ui_scale;
        ui.drawRect(.{ .x = px, .y = py + ph - footer_h, .width = pw, .height = 2.0 * ui_scale }, Color.rgba(0.20, 0.36, 0.48, 0.50));
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 150.0 * ui_scale) * 0.5, .y = footer_y, .width = 150.0 * ui_scale, .height = 42.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
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
    Font.drawText(ui, label, x + 36.0 * ui_scale, y, 1.0 * ui_scale, MUTED_COLOR);
}
