const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const ResourcePacksContext = Screen.ResourcePacksContext;
const settings_pkg = @import("../settings.zig");
const Settings = settings_pkg.Settings;
const TextureAtlas = @import("../../engine/graphics/texture_atlas.zig").TextureAtlas;
const BLOCK_TEXTURE_DEFINITIONS = @import("../app.zig").BLOCK_TEXTURE_DEFINITIONS;

const PANEL_WIDTH_MAX = 750.0;
const PANEL_HEIGHT_MAX = 800.0;
const BG_COLOR = Color.rgba(0.025, 0.045, 0.065, 0.95);
const BORDER_COLOR = Color.rgba(0.42, 0.66, 0.82, 0.78);
const TITLE_COLOR = Color.rgba(1.0, 0.93, 0.76, 1.0);
const MUTED_COLOR = Color.rgba(0.48, 0.60, 0.70, 0.92);

pub const ResourcePacksScreen = struct {
    context: ResourcePacksContext,
    reload_status: ?[]const u8,

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
        const render_system = ctx.render_system;
        const manager = render_system.getResourcePackManager();

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
        const title_scale: f32 = 3.0 * ui_scale;
        const btn_scale: f32 = 1.55 * ui_scale;

        const pw: f32 = @min(screen_w * 0.75, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = @min(screen_h - 80.0 * ui_scale, PANEL_HEIGHT_MAX * ui_scale);
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = (screen_h - ph) * 0.5;

        drawResourcePackBackdrop(ui, screen_w, screen_h, ui_scale);
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRect(.{ .x = px, .y = py, .width = 7.0 * ui_scale, .height = ph }, Color.rgba(0.95, 0.62, 0.24, 0.95));
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = 72.0 * ui_scale }, Color.rgba(0.12, 0.22, 0.30, 0.64));
        ui.drawRect(.{ .x = px + pw - 2.0 * ui_scale, .y = py, .width = 2.0 * ui_scale, .height = ph }, Color.rgba(0.48, 0.76, 0.93, 0.62));
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawText(ui, "RESOURCE PACKS", px + 34.0 * ui_scale, py + 24.0 * ui_scale, title_scale, TITLE_COLOR);
        Font.drawText(ui, "Switch texture sources without leaving the session.", px + 38.0 * ui_scale, py + 56.0 * ui_scale, 1.05 * ui_scale, MUTED_COLOR);

        var sy: f32 = py + 102.0 * ui_scale;
        const btn_width: f32 = pw - 100.0 * ui_scale;
        const btn_height: f32 = 50.0 * ui_scale;
        const btn_x: f32 = px + 50.0 * ui_scale;

        // Default pack button
        const is_default = std.mem.eql(u8, settings.texture_pack, "default");
        const def_label = if (is_default) "Default (Built-in) [SELECTED]" else "Default (Built-in)";

        if (Widgets.drawButton(ui, .{ .x = btn_x, .y = sy, .width = btn_width, .height = btn_height }, def_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const prev_pack = settings.texture_pack;
            if (!std.mem.eql(u8, prev_pack, "default")) {
                try settings_pkg.persistence.setTexturePack(settings, ctx.allocator, "default");
                try manager.setActivePack("default");
                self.reload_status = "Reloading textures; rendering may pause briefly...";
                try self.reloadAtlas();
                self.reload_status = "Texture pack reloaded.";
            }
        }
        sy += btn_height + 10.0 * ui_scale;

        // Available packs
        const packs = manager.getPackNames();
        var buffer: [128]u8 = undefined;
        for (packs) |pack| {
            const is_selected = std.mem.eql(u8, settings.texture_pack, pack.name);
            const label = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ pack.name, if (is_selected) " [SELECTED]" else "" });

            if (Widgets.drawButton(ui, .{ .x = btn_x, .y = sy, .width = btn_width, .height = btn_height }, label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                if (!is_selected) {
                    try settings_pkg.persistence.setTexturePack(settings, ctx.allocator, pack.name);
                    try manager.setActivePack(pack.name);
                    self.reload_status = "Reloading textures; rendering may pause briefly...";
                    try self.reloadAtlas();
                    self.reload_status = "Texture pack reloaded.";
                }
            }
            sy += btn_height + 10.0 * ui_scale;
        }

        if (self.reload_status) |status| {
            Font.drawTextCentered(ui, status, screen_w * 0.5, py + ph - 105.0 * ui_scale, 1.15 * ui_scale, Color.rgba(0.75, 0.86, 0.94, 1.0));
        }

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

fn drawResourcePackBackdrop(ui: *UISystem, screen_w: f32, screen_h: f32, ui_scale: f32) void {
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0.010, 0.018, 0.030, 0.88));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.64, .width = screen_w, .height = screen_h * 0.36 }, Color.rgba(0.075, 0.048, 0.028, 0.58));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.64, .width = screen_w, .height = 2.0 * ui_scale }, Color.rgba(0.92, 0.62, 0.24, 0.44));
    ui.drawRect(.{ .x = 64.0 * ui_scale, .y = screen_h * 0.64 - 74.0 * ui_scale, .width = 88.0 * ui_scale, .height = 74.0 * ui_scale }, Color.rgba(0.07, 0.14, 0.15, 0.28));
    ui.drawRect(.{ .x = screen_w - 168.0 * ui_scale, .y = screen_h * 0.64 - 110.0 * ui_scale, .width = 112.0 * ui_scale, .height = 110.0 * ui_scale }, Color.rgba(0.50, 0.29, 0.12, 0.30));
}
