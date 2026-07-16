const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Font = @import("engine-ui").font;
const Theme = @import("../menu_theme.zig");
const Rect = Theme.Rect;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const WorldListScreen = @import("world_list.zig").WorldListScreen;
const SettingsScreen = @import("settings.zig").SettingsScreen;
const ResourcePacksScreen = @import("resource_packs.zig").ResourcePacksScreen;
const EnvironmentScreen = @import("environment.zig").EnvironmentScreen;
const WorldScreen = @import("world.zig").WorldScreen;

const MENU_PREVIEW_SEED: u64 = 0x5A49_4743_5241_4654;

pub const HomeScreen = struct {
    context: EngineContext,
    focused_action: usize,
    preview: *WorldScreen,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .drawBackground = drawBackground,
        .onEnter = onEnter,
        .getWorldStats = getWorldStats,
        .isReadyForPresentation = isReadyForPresentation,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*HomeScreen {
        const self = try allocator.create(HomeScreen);
        errdefer allocator.destroy(self);
        self.* = .{
            .context = context,
            .focused_action = 0,
            .preview = try WorldScreen.initMenuPreview(allocator, context, MENU_PREVIEW_SEED, 0),
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        WorldScreen.deinit(self.preview);
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try WorldScreen.update(self.preview, dt);
        const input = self.context.input;
        if (input.isKeyPressed(.down) or input.isKeyPressed(.right_arrow) or input.isKeyPressed(.tab)) {
            self.focused_action = (self.focused_action + 1) % 5;
        }
        if (input.isKeyPressed(.up) or input.isKeyPressed(.left_arrow)) {
            self.focused_action = if (self.focused_action == 0) 4 else self.focused_action - 1;
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        try drawBackground(ptr, ui);

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

        Theme.drawWorldScrim(ui, screen_w, screen_h, ui_scale);

        const hero_x = if (compact) 34.0 * ui_scale else 88.0 * ui_scale;
        const hero_y = if (compact) 82.0 * ui_scale else 112.0 * ui_scale;
        Theme.drawHeroTitle(ui, hero_x, hero_y, ui_scale, compact);

        try drawLaunchPanel(ui, self, screen_w, screen_h, ui_scale, compact, mouse_x, mouse_y, mouse_clicked, ctx);
        drawFooter(ui, screen_w, screen_h, ui_scale);
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(@ptrCast(self.context.window_manager.window), false);
    }

    fn drawBackground(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try WorldScreen.draw(self.preview, ui);
    }

    fn getWorldStats(ptr: *anyopaque) ?@import("engine-ui").WorldStats {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.preview.getWorldStats();
    }

    fn isReadyForPresentation(ptr: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const stats = self.preview.getWorldStats() orelse return false;
        // Reveal once terrain is drawable; the remaining preview chunks keep
        // streaming behind the menu instead of blocking the hidden window.
        return stats.chunks_rendered > 0;
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn drawLaunchPanel(ui: *UISystem, self: *HomeScreen, screen_w: f32, screen_h: f32, scale: f32, compact: bool, mouse_x: f32, mouse_y: f32, mouse_clicked: bool, ctx: EngineContext) !void {
    const panel_w: f32 = @min(screen_w - 40.0 * scale, 460.0 * scale);
    const panel_h: f32 = @min(540.0 * scale, screen_h - 48.0 * scale);
    const panel_x: f32 = if (compact) (screen_w - panel_w) * 0.5 else screen_w - panel_w - 64.0 * scale;
    const panel_y: f32 = if (compact) screen_h - panel_h - 24.0 * scale else (screen_h - panel_h) * 0.5;
    const panel = Rect{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h };

    Theme.drawGlassPanel(ui, panel, scale);

    Font.drawText(ui, "WORLD MENU", panel.x + 26.0 * scale, panel.y + 18.0 * scale, 0.86 * scale, Theme.signal);
    Font.drawText(ui, "Choose your adventure", panel.x + 26.0 * scale, panel.y + 43.0 * scale, 1.42 * scale, Theme.title);

    var y = panel.y + 82.0 * scale;
    const x = panel.x + 26.0 * scale;
    const w = panel.width - 52.0 * scale;
    const confirm = ctx.input_mapper.isActionPressed(ctx.input, .ui_confirm);

    const play_h: f32 = 86.0 * scale;
    if (Theme.drawActionCard(ui, .{ .x = x, .y = y, .width = w, .height = play_h }, "WORLD LIBRARY", "Choose, create, or continue a local world.", "ENTER", mouse_x, mouse_y, mouse_clicked, true, self.focused_action == 0, scale) or (confirm and self.focused_action == 0)) {
        const world_list_screen = try WorldListScreen.init(ctx.allocator, ctx);
        errdefer world_list_screen.deinit(world_list_screen);
        ctx.screen_manager.pushScreen(world_list_screen.screen());
    }
    y += play_h + 18.0 * scale;
    Theme.drawSectionLabel(ui, x, y, "GAME OPTIONS", scale);
    y += 30.0 * scale;

    const card_h: f32 = 62.0 * scale;
    if (Theme.drawActionCard(ui, .{ .x = x, .y = y, .width = w, .height = card_h }, "RESOURCE PACKS", "Change block textures.", "", mouse_x, mouse_y, mouse_clicked, false, self.focused_action == 1, scale) or (confirm and self.focused_action == 1)) {
        const rp_screen = try ResourcePacksScreen.init(ctx.allocator, ctx);
        errdefer rp_screen.deinit(rp_screen);
        ctx.screen_manager.pushScreen(rp_screen.screen());
    }
    y += card_h;
    if (Theme.drawActionCard(ui, .{ .x = x, .y = y, .width = w, .height = card_h }, "SKY & LIGHTING", "Choose environment light.", "", mouse_x, mouse_y, mouse_clicked, false, self.focused_action == 2, scale) or (confirm and self.focused_action == 2)) {
        const env_screen = try EnvironmentScreen.init(ctx.allocator, ctx);
        errdefer env_screen.deinit(env_screen);
        ctx.screen_manager.pushScreen(env_screen.screen());
    }
    y += card_h;
    if (Theme.drawActionCard(ui, .{ .x = x, .y = y, .width = w, .height = card_h }, "SETTINGS", "Display, controls, and graphics.", "", mouse_x, mouse_y, mouse_clicked, false, self.focused_action == 3, scale) or (confirm and self.focused_action == 3)) {
        const settings_screen = try SettingsScreen.init(ctx.allocator, ctx);
        errdefer settings_screen.deinit(settings_screen);
        ctx.screen_manager.pushScreen(settings_screen.screen());
    }
    y += card_h;
    if (Theme.drawActionCard(ui, .{ .x = x, .y = y, .width = w, .height = card_h }, "EXIT", "Close ZigCraft safely.", "", mouse_x, mouse_y, mouse_clicked, false, self.focused_action == 4, scale) or (confirm and self.focused_action == 4)) {
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
