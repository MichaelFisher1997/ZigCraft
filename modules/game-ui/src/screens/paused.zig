const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Font = @import("engine-ui").font;
const Widgets = @import("engine-ui").widgets;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const HomeScreen = @import("home.zig").HomeScreen;
const SettingsScreen = @import("settings.zig").SettingsScreen;

const PAUSED_OVERLAY_COLOR = Color.rgba(0.010, 0.018, 0.030, 0.70);
const BUTTON_WIDTH = 340.0;
const BUTTON_HEIGHT = 52.0;
const BUTTON_SPACING = 14.0;

pub const PausedScreen = struct {
    context: EngineContext,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*PausedScreen {
        const self = try allocator.create(PausedScreen);
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
            self.context.screen_manager.popScreen();
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;

        // Draw the world in the background (the screen below us in the stack)
        try ctx.screen_manager.drawParentScreen(ptr, ui);

        ui.begin();
        defer ui.end();

        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

        const ui_scale: f32 = @max(1.0, screen_h / 720.0) * ctx.settings.ui_scale;
        const panel_w: f32 = @min(460.0 * ui_scale, screen_w * 0.48);
        const panel_h: f32 = 330.0 * ui_scale;
        const panel_x: f32 = (screen_w - panel_w) * 0.5;
        const panel_y: f32 = (screen_h - panel_h) * 0.5;

        ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, PAUSED_OVERLAY_COLOR);
        ui.drawRect(.{ .x = 0, .y = screen_h * 0.62, .width = screen_w, .height = screen_h * 0.38 }, Color.rgba(0.075, 0.048, 0.028, 0.36));
        ui.drawRect(.{ .x = 0, .y = screen_h * 0.62, .width = screen_w, .height = 2.0 * ui_scale }, Color.rgba(0.92, 0.62, 0.24, 0.36));

        ui.drawRect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.025, 0.045, 0.065, 0.94));
        ui.drawRect(.{ .x = panel_x, .y = panel_y, .width = 7.0 * ui_scale, .height = panel_h }, Color.rgba(0.95, 0.62, 0.24, 0.95));
        ui.drawRect(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = 72.0 * ui_scale }, Color.rgba(0.12, 0.22, 0.30, 0.66));
        ui.drawRect(.{ .x = panel_x + panel_w - 2.0 * ui_scale, .y = panel_y, .width = 2.0 * ui_scale, .height = panel_h }, Color.rgba(0.48, 0.76, 0.93, 0.60));
        ui.drawRectOutline(.{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, Color.rgba(0.42, 0.66, 0.82, 0.78), 2.0 * ui_scale);

        Font.drawText(ui, "PAUSED", panel_x + 34.0 * ui_scale, panel_y + 24.0 * ui_scale, 3.0 * ui_scale, Color.rgba(1.0, 0.93, 0.76, 1.0));
        Font.drawText(ui, "World simulation suspended.", panel_x + 38.0 * ui_scale, panel_y + 56.0 * ui_scale, 1.05 * ui_scale, Color.rgba(0.48, 0.60, 0.70, 0.92));

        const pw: f32 = @min(BUTTON_WIDTH * ui_scale, panel_w - 84.0 * ui_scale);
        const ph: f32 = BUTTON_HEIGHT * ui_scale;
        const px: f32 = panel_x + (panel_w - pw) * 0.5;
        var py: f32 = panel_y + 116.0 * ui_scale;
        const btn_scale: f32 = 1.75 * ui_scale;

        if (Widgets.drawButton(ui, .{ .x = px, .y = py, .width = pw, .height = ph }, "RESUME", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            ctx.screen_manager.popScreen();
        }
        py += ph + BUTTON_SPACING * ui_scale;
        if (Widgets.drawButton(ui, .{ .x = px, .y = py, .width = pw, .height = ph }, "SETTINGS", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const settings_screen = try SettingsScreen.init(ctx.allocator, ctx);
            errdefer settings_screen.deinit(settings_screen);
            ctx.screen_manager.pushScreen(settings_screen.screen());
        }
        py += ph + BUTTON_SPACING * ui_scale;
        if (Widgets.drawButton(ui, .{ .x = px, .y = py, .width = pw, .height = ph }, "QUIT TO TITLE", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const home_screen = try HomeScreen.init(ctx.allocator, ctx);
            errdefer home_screen.deinit(home_screen);
            ctx.screen_manager.setScreen(home_screen.screen());
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn onExit(ptr: *anyopaque) void {
        _ = ptr;
        // No longer capturing here, as the parent screen (World) will capture in its onEnter()
        // and child screens (Settings) don't want the mouse captured.
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};
