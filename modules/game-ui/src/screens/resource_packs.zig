const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Font = @import("engine-ui").font;
const Theme = @import("../menu_theme.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const ResourcePacksContext = Screen.ResourcePacksContext;
const settings_pkg = @import("game-core").settings;
const TextureAtlas = @import("engine-graphics").TextureAtlas;
const BLOCK_TEXTURE_DEFINITIONS = @import("game-core").BLOCK_TEXTURE_DEFINITIONS;

const PANEL_WIDTH_MAX = 900.0;
const PANEL_HEIGHT_MAX = 760.0;

pub const ResourcePacksScreen = struct {
    context: ResourcePacksContext,
    reload_status: ?[]const u8,
    scroll_offset: f32,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*ResourcePacksScreen {
        const self = try allocator.create(ResourcePacksScreen);
        self.* = .{
            .context = context.resourcePacksContext(),
            .reload_status = null,
            .scroll_offset = 0.0,
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
        const manager = ctx.render_system.getResourcePackManager();

        try ctx.screen_manager.drawBackgroundFor(ptr, ui);
        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);
        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());
        const ui_scale = Theme.scaleFor(screen_h, settings.ui_scale);

        Theme.drawBackdrop(ui, screen_w, screen_h, ui_scale, .packs);
        const margin: f32 = 48.0 * ui_scale;
        const panel_w: f32 = @min(screen_w - margin * 2.0, PANEL_WIDTH_MAX * ui_scale);
        const panel_h: f32 = @min(screen_h - margin * 2.0, PANEL_HEIGHT_MAX * ui_scale);
        const panel_x = (screen_w - panel_w) * 0.5;
        const panel_y = (screen_h - panel_h) * 0.5;
        const shell = Theme.drawShell(ui, .{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, ui_scale, "ASSETS", "RESOURCE PACKS", "Pick a texture pack for block materials.");

        Theme.drawListRail(ui, shell.content, ui_scale);
        const row_x = shell.content.x + 18.0 * ui_scale;
        const row_w = shell.content.width - 36.0 * ui_scale;
        const row_h = 56.0 * ui_scale;
        const btn_scale = 1.18 * ui_scale;
        const packs = manager.getPackNames();
        const content_h = @as(f32, @floatFromInt(packs.len + 1)) * (row_h + 10.0 * ui_scale) + 26.0 * ui_scale;
        const max_scroll = @max(0.0, content_h - shell.content.height);
        self.scroll_offset -= ctx.input.getScrollDelta().y * 32.0 * ui_scale;
        self.scroll_offset = @max(0.0, @min(self.scroll_offset, max_scroll));
        var y = shell.content.y + 18.0 * ui_scale - self.scroll_offset;
        Theme.drawScrollbar(ui, shell.content.x + shell.content.width - 10.0 * ui_scale, shell.content.y + 12.0 * ui_scale, shell.content.height - 24.0 * ui_scale, content_h, shell.content.height, self.scroll_offset, max_scroll, ui_scale);

        const is_default = std.mem.eql(u8, settings.texture_pack, "default");
        if (y + row_h >= shell.content.y and y <= shell.content.y + shell.content.height) {
            if (drawPackButton(ui, row_x, y, row_w, row_h, "DEFAULT / BUILT-IN", "Base texture atlas shipped with ZigCraft.", is_default, btn_scale, mouse_x, mouse_y, mouse_clicked, ui_scale)) {
                if (!is_default) {
                    try settings_pkg.persistence.setTexturePack(settings, ctx.allocator, "default");
                    try manager.setActivePack("default");
                    self.reload_status = "Reloading texture atlas...";
                    try self.reloadAtlas();
                    self.reload_status = "Texture pack reloaded.";
                }
            }
        }
        y += row_h + 10.0 * ui_scale;

        var buffer: [160]u8 = undefined;
        for (packs) |pack| {
            if (y + row_h < shell.content.y or y > shell.content.y + shell.content.height) {
                y += row_h + 10.0 * ui_scale;
                continue;
            }
            const is_selected = std.mem.eql(u8, settings.texture_pack, pack.name);
            const label = std.fmt.bufPrint(&buffer, "{s}", .{pack.name}) catch "PACK";
            if (drawPackButton(ui, row_x, y, row_w, row_h, label, "External pack discovered by the resource manager.", is_selected, btn_scale, mouse_x, mouse_y, mouse_clicked, ui_scale)) {
                if (!is_selected) {
                    try settings_pkg.persistence.setTexturePack(settings, ctx.allocator, pack.name);
                    try manager.setActivePack(pack.name);
                    self.reload_status = "Reloading texture atlas...";
                    try self.reloadAtlas();
                    self.reload_status = "Texture pack reloaded.";
                }
            }
            y += row_h + 10.0 * ui_scale;
        }

        if (self.reload_status) |status| {
            Font.drawTextCentered(ui, status, panel_x + panel_w * 0.5, shell.footer_y - 22.0 * ui_scale, 0.88 * ui_scale, Theme.signal);
        }
        if (Theme.drawButton(ui, .{ .x = panel_x + (panel_w - 180.0 * ui_scale) * 0.5, .y = shell.footer_y, .width = 180.0 * ui_scale, .height = 46.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked, .ghost, ui_scale)) {
            ctx.saveSettings();
            ctx.screen_manager.popScreen();
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    fn reloadAtlas(self: *@This()) !void {
        const ctx = self.context;
        const render_system = ctx.render_system;
        const rhi = render_system.getRHI();
        rhi.waitIdle();
        render_system.getAtlas().deinit();
        render_system.getAtlas().* = try TextureAtlas.init(ctx.allocator, rhi.resourceManager(), render_system.getResourcePackManager(), ctx.settings.max_texture_resolution, &BLOCK_TEXTURE_DEFINITIONS);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn drawPackButton(ui: *UISystem, x: f32, y: f32, w: f32, h: f32, label: []const u8, description: []const u8, selected: bool, btn_scale: f32, mx: f32, my: f32, clicked: bool, scale: f32) bool {
    const row = Theme.Rect{ .x = x, .y = y, .width = w, .height = h };
    Theme.drawOptionRow(ui, row, label, description, 1.04 * scale, selected, scale);
    const action_w = 150.0 * scale;
    const action_x = x + w - action_w - 12.0 * scale;
    const action_clicked = Theme.drawButton(ui, .{ .x = action_x, .y = y + 9.0 * scale, .width = action_w, .height = h - 18.0 * scale }, if (selected) "ACTIVE" else "USE PACK", btn_scale, mx, my, clicked, if (selected) .primary else .secondary, scale);
    return action_clicked or (clicked and row.contains(mx, my));
}
