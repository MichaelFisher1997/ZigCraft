const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Font = @import("engine-ui").font;
const Theme = @import("../menu_theme.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const HomeScreen = @import("home.zig").HomeScreen;
const RmlHomeScreen = @import("rml_home.zig").RmlHomeScreen;
const SettingsScreen = @import("settings.zig").SettingsScreen;
const rmlui = @import("engine-ui").rmlui;

pub const PausedScreen = struct {
    context: EngineContext,
    focused_action: usize,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .drawBackground = drawBackground,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*PausedScreen {
        const self = try allocator.create(PausedScreen);
        self.* = .{ .context = context, .focused_action = 0 };
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
            return;
        }
        const input = self.context.input;
        if (input.isKeyPressed(.down) or input.isKeyPressed(.tab)) self.focused_action = (self.focused_action + 1) % 3;
        if (input.isKeyPressed(.up)) self.focused_action = if (self.focused_action == 0) 2 else self.focused_action - 1;
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        try ctx.screen_manager.drawBackgroundFor(ptr, ui);

        ui.begin();
        defer ui.end();

        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());
        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);
        const ui_scale = Theme.scaleFor(screen_h, ctx.settings.ui_scale);

        Theme.drawBackdrop(ui, screen_w, screen_h, ui_scale, .paused);

        const panel_w = @min(440.0 * ui_scale, screen_w - 48.0 * ui_scale);
        const panel_h = @min(340.0 * ui_scale, screen_h - 32.0 * ui_scale);
        const panel_x = (screen_w - panel_w) * 0.5;
        const panel_y = (screen_h - panel_h) * 0.5;
        const shell = Theme.drawShell(ui, .{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, ui_scale, "SESSION", "PAUSED", "Resume or leave the current world.");

        const bw = @min(320.0 * ui_scale, shell.content.width);
        const bx = shell.content.x + (shell.content.width - bw) * 0.5;
        var by = shell.content.y + 8.0 * ui_scale;
        const bh = 44.0 * ui_scale;
        const gap = 8.0 * ui_scale;
        const btn_scale = 1.16 * ui_scale;
        const confirm = ctx.input_mapper.isActionPressed(ctx.input, .ui_confirm);

        if (Theme.drawButtonFocused(ui, .{ .x = bx, .y = by, .width = bw, .height = bh }, "RESUME", btn_scale, mouse_x, mouse_y, mouse_clicked, .primary, self.focused_action == 0, ui_scale) or (confirm and self.focused_action == 0)) ctx.screen_manager.popScreen();
        by += bh + gap;
        if (Theme.drawButtonFocused(ui, .{ .x = bx, .y = by, .width = bw, .height = bh }, "SETTINGS", btn_scale, mouse_x, mouse_y, mouse_clicked, .secondary, self.focused_action == 1, ui_scale) or (confirm and self.focused_action == 1)) {
            const factory = try Screen.makeScreenFactory(SettingsScreenFactory, ctx.allocator, .{ .context = ctx });
            ctx.screen_manager.pushScreenFactory(factory);
        }
        by += bh + gap;
        if (Theme.drawButtonFocused(ui, .{ .x = bx, .y = by, .width = bw, .height = bh }, "QUIT TO TITLE", btn_scale, mouse_x, mouse_y, mouse_clicked, .ghost, self.focused_action == 2, ui_scale) or (confirm and self.focused_action == 2)) {
            const factory = try Screen.makeScreenFactory(HomeScreenFactory, ctx.allocator, .{ .context = ctx });
            ctx.screen_manager.setScreenFactory(factory);
        }
        Font.drawTextCentered(ui, "ESC / BACK TO RESUME", panel_x + panel_w * 0.5, shell.footer_y + 12.0 * ui_scale, 0.86 * ui_scale, Theme.muted);
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    fn drawBackground(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.context.screen_manager.drawBackgroundFor(ptr, ui);
    }

    pub fn onExit(ptr: *anyopaque) void {
        _ = ptr;
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn createHomeScreen(ctx: EngineContext) !IScreen {
    if (rmlui.available and ctx.ui_manager.getRmlUi() != null) {
        const screen = try RmlHomeScreen.init(ctx.allocator, ctx);
        return screen.screen();
    }
    const screen = try HomeScreen.init(ctx.allocator, ctx);
    return screen.screen();
}

const SettingsScreenFactory = struct {
    context: EngineContext,

    pub fn construct(self: *@This()) !IScreen {
        const settings_screen = try SettingsScreen.init(self.context.allocator, self.context);
        return settings_screen.screen();
    }
};

const HomeScreenFactory = struct {
    context: EngineContext,

    pub fn construct(self: *@This()) !IScreen {
        return createHomeScreen(self.context);
    }
};
