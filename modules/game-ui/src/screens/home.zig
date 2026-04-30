const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Font = @import("engine-ui").font;
const Theme = @import("../menu_theme.zig");
const Rect = Theme.Rect;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const SingleplayerScreen = @import("singleplayer.zig").SingleplayerScreen;
const SettingsScreen = @import("settings.zig").SettingsScreen;
const ResourcePacksScreen = @import("resource_packs.zig").ResourcePacksScreen;
const EnvironmentScreen = @import("environment.zig").EnvironmentScreen;

pub const HomeScreen = struct {
    context: EngineContext,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*HomeScreen {
        const self = try allocator.create(HomeScreen);
        self.* = .{ .context = context };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.allocator.destroy(self);
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;

        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);

        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());
        const ui_scale = Theme.scaleFor(screen_h, ctx.settings.ui_scale);
        const compact = screen_w < 980.0 * ui_scale;

        Theme.drawBackdrop(ui, screen_w, screen_h, ui_scale, .home);

        const hero_x = if (compact) 34.0 * ui_scale else 88.0 * ui_scale;
        const hero_y = if (compact) 82.0 * ui_scale else 112.0 * ui_scale;
        Theme.drawHeroTitle(ui, hero_x, hero_y, ui_scale, compact);

        try drawLaunchPanel(ui, screen_w, screen_h, ui_scale, compact, mouse_x, mouse_y, mouse_clicked, ctx);
        drawFooter(ui, screen_w, screen_h, ui_scale);
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(@ptrCast(self.context.window_manager.window), false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn drawLaunchPanel(ui: *UISystem, screen_w: f32, screen_h: f32, scale: f32, compact: bool, mouse_x: f32, mouse_y: f32, mouse_clicked: bool, ctx: EngineContext) !void {
    const panel_w: f32 = if (compact) @min(screen_w - 44.0 * scale, 600.0 * scale) else @min(screen_w * 0.43, 620.0 * scale);
    const panel_h: f32 = if (compact) 398.0 * scale else 486.0 * scale;
    const panel_x: f32 = if (compact) (screen_w - panel_w) * 0.5 else screen_w - panel_w - 82.0 * scale;
    const panel_y: f32 = if (compact) screen_h * 0.46 else screen_h * 0.24;
    const panel = Rect{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h };
    const row_h: f32 = if (compact) 50.0 * scale else 58.0 * scale;
    const gap: f32 = 12.0 * scale;
    const text_scale: f32 = if (compact) 1.22 * scale else 1.42 * scale;

    drawOuterGlow(ui, panel, scale);
    ui.drawRect(.{ .x = panel.x + 18.0 * scale, .y = panel.y + 22.0 * scale, .width = panel.width, .height = panel.height }, Color.rgba(0, 0, 0, 0.28));
    ui.drawRect(panel, Color.rgba(0.060, 0.095, 0.125, 0.58));
    ui.drawRect(.{ .x = panel.x, .y = panel.y, .width = panel.width, .height = 1.0 * scale }, Color.rgba(0.94, 0.98, 1.0, 0.20));
    ui.drawRect(.{ .x = panel.x, .y = panel.y + 42.0 * scale, .width = panel.width, .height = 1.0 * scale }, Color.rgba(0.58, 0.72, 0.82, 0.42));
    ui.drawRect(.{ .x = panel.x, .y = panel.y, .width = 4.0 * scale, .height = panel.height }, Theme.signal);
    ui.drawRectOutline(panel, Color.rgba(0.54, 0.66, 0.74, 0.58), 1.0 * scale);
    drawPanelNoise(ui, panel, scale);

    Font.drawText(ui, "LAUNCH", panel.x + 30.0 * scale, panel.y + 17.0 * scale, 0.88 * scale, Theme.signal);
    Font.drawText(ui, "READY", panel.x + panel.width - 104.0 * scale, panel.y + 17.0 * scale, 0.78 * scale, Theme.amber);

    var y = panel.y + 68.0 * scale;
    const x = panel.x + 28.0 * scale;
    const w = panel.width - 56.0 * scale;

    if (Theme.drawButton(ui, .{ .x = x, .y = y, .width = w, .height = row_h + 8.0 * scale }, "PLAY WORLD", text_scale, mouse_x, mouse_y, mouse_clicked, .primary, scale)) {
        const sp_screen = try SingleplayerScreen.init(ctx.allocator, ctx);
        errdefer sp_screen.deinit(sp_screen);
        ctx.screen_manager.pushScreen(sp_screen.screen());
    }
    y += row_h + 8.0 * scale + gap;

    if (Theme.drawButton(ui, .{ .x = x, .y = y, .width = w, .height = row_h }, "RESOURCE PACKS", text_scale, mouse_x, mouse_y, mouse_clicked, .secondary, scale)) {
        const rp_screen = try ResourcePacksScreen.init(ctx.allocator, ctx);
        errdefer rp_screen.deinit(rp_screen);
        ctx.screen_manager.pushScreen(rp_screen.screen());
    }
    y += row_h + gap;

    if (Theme.drawButton(ui, .{ .x = x, .y = y, .width = w, .height = row_h }, "ENVIRONMENT", text_scale, mouse_x, mouse_y, mouse_clicked, .secondary, scale)) {
        const env_screen = try EnvironmentScreen.init(ctx.allocator, ctx);
        errdefer env_screen.deinit(env_screen);
        ctx.screen_manager.pushScreen(env_screen.screen());
    }
    y += row_h + gap;

    if (Theme.drawButton(ui, .{ .x = x, .y = y, .width = w, .height = row_h }, "SETTINGS", text_scale, mouse_x, mouse_y, mouse_clicked, .ghost, scale)) {
        const settings_screen = try SettingsScreen.init(ctx.allocator, ctx);
        errdefer settings_screen.deinit(settings_screen);
        ctx.screen_manager.pushScreen(settings_screen.screen());
    }
    y += row_h + gap;

    if (Theme.drawButton(ui, .{ .x = x, .y = y, .width = w, .height = row_h }, "EXIT", text_scale, mouse_x, mouse_y, mouse_clicked, .ghost, scale)) {
        ctx.input.setShouldQuit(true);
    }
}

fn drawOuterGlow(ui: *UISystem, rect: Rect, scale: f32) void {
    ui.drawRect(.{ .x = rect.x - 22.0 * scale, .y = rect.y - 22.0 * scale, .width = rect.width + 44.0 * scale, .height = rect.height + 44.0 * scale }, Color.rgba(0.58, 0.72, 0.82, 0.018));
    ui.drawRect(.{ .x = rect.x - 8.0 * scale, .y = rect.y - 8.0 * scale, .width = rect.width + 16.0 * scale, .height = rect.height + 16.0 * scale }, Color.rgba(0.84, 0.90, 0.94, 0.026));
}

fn drawPanelNoise(ui: *UISystem, rect: Rect, scale: f32) void {
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const px = rect.x + 20.0 * scale + (@as(f32, @floatFromInt((i * 113) % 1000)) / 1000.0) * (rect.width - 40.0 * scale);
        const py = rect.y + 54.0 * scale + (@as(f32, @floatFromInt((i * 271) % 1000)) / 1000.0) * (rect.height - 74.0 * scale);
        const w_base: f32 = if (i % 3 == 0) 34.0 else if (i % 3 == 1) 16.0 else 8.0;
        ui.drawRect(.{ .x = px, .y = py, .width = w_base * scale, .height = 1.0 * scale }, Color.rgba(0.94, 0.98, 1.0, 0.045));
    }
}

fn drawFooter(ui: *UISystem, screen_w: f32, screen_h: f32, scale: f32) void {
    ui.drawRect(.{ .x = screen_w * 0.36, .y = screen_h - 38.0 * scale, .width = screen_w * 0.28, .height = 1.0 * scale }, Color.rgba(0.58, 0.72, 0.82, 0.24));
    Font.drawTextCentered(ui, "ZIGCRAFT ENGINE 0.1", screen_w * 0.5, screen_h - 25.0 * scale, 0.66 * scale, Theme.dim);
}
