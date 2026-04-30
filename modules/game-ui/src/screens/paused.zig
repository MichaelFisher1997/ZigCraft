const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Theme = @import("../menu_theme.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const HomeScreen = @import("home.zig").HomeScreen;
const SettingsScreen = @import("settings.zig").SettingsScreen;

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
        self.* = .{ .context = context };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;
        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) self.context.screen_manager.popScreen();
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        try ctx.screen_manager.drawParentScreen(ptr, ui);

        ui.begin();
        defer ui.end();

        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());
        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);
        const ui_scale = Theme.scaleFor(screen_h, ctx.settings.ui_scale);

        ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0.002, 0.006, 0.010, 0.72));
        Theme.drawBackdrop(ui, screen_w, screen_h, ui_scale, .paused);
        ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.36));

        const panel_w = @min(520.0 * ui_scale, screen_w - 80.0 * ui_scale);
        const panel_h = 420.0 * ui_scale;
        const panel_x = (screen_w - panel_w) * 0.5;
        const panel_y = (screen_h - panel_h) * 0.5;
        const shell = Theme.drawShell(ui, .{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, ui_scale, "SESSION", "PAUSED", "Resume or leave the current world.");

        const bw = @min(360.0 * ui_scale, shell.content.width);
        const bx = shell.content.x + (shell.content.width - bw) * 0.5;
        var by = shell.content.y + 10.0 * ui_scale;
        const bh = 56.0 * ui_scale;
        const gap = 13.0 * ui_scale;
        const btn_scale = 1.42 * ui_scale;

        if (Theme.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = bh }, "RESUME WORLD", btn_scale, mouse_x, mouse_y, mouse_clicked, .primary, ui_scale)) ctx.screen_manager.popScreen();
        by += bh + gap;
        if (Theme.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = bh }, "SETTINGS", btn_scale, mouse_x, mouse_y, mouse_clicked, .secondary, ui_scale)) {
            const settings_screen = try SettingsScreen.init(ctx.allocator, ctx);
            errdefer settings_screen.deinit(settings_screen);
            ctx.screen_manager.pushScreen(settings_screen.screen());
        }
        by += bh + gap;
        if (Theme.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = bh }, "QUIT TO TITLE", btn_scale, mouse_x, mouse_y, mouse_clicked, .ghost, ui_scale)) {
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
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};
