const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const SingleplayerScreen = @import("singleplayer.zig").SingleplayerScreen;
const SettingsScreen = @import("settings.zig").SettingsScreen;
const ResourcePacksScreen = @import("resource_packs.zig").ResourcePacksScreen;
const EnvironmentScreen = @import("environment.zig").EnvironmentScreen;

const TITLE_COLOR = Color.rgba(1.0, 0.94, 0.78, 1.0);
const BUTTON_WIDTH_MAX = 430.0;
const BUTTON_HEIGHT_BASE = 56.0;
const BUTTON_SPACING_BASE = 14.0;

pub const HomeScreen = struct {
    context: EngineContext,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*HomeScreen {
        const self = try allocator.create(HomeScreen);
        self.* = .{
            .context = context,
        };
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

        // Scale UI based on screen height for better readability at high resolutions
        const auto_scale: f32 = @max(1.0, screen_h / 720.0);
        const ui_scale: f32 = auto_scale * ctx.settings.ui_scale;
        const title_scale: f32 = 4.8 * ui_scale;
        const subtitle_scale: f32 = 1.18 * ui_scale;
        const btn_scale: f32 = 2.25 * ui_scale;
        const btn_height: f32 = BUTTON_HEIGHT_BASE * ui_scale;
        const btn_spacing: f32 = BUTTON_SPACING_BASE * ui_scale;

        drawHomeBackdrop(ui, screen_w, screen_h, ui_scale);

        const rail_w = @min(screen_w * 0.36, 470.0 * ui_scale);
        const rail_x = screen_w - rail_w - 64.0 * ui_scale;
        const rail_y = 86.0 * ui_scale;
        const rail_h = screen_h - 172.0 * ui_scale;
        ui.drawRect(.{ .x = rail_x, .y = rail_y, .width = rail_w, .height = rail_h }, Color.rgba(0.03, 0.055, 0.085, 0.80));
        ui.drawRect(.{ .x = rail_x, .y = rail_y, .width = 6.0 * ui_scale, .height = rail_h }, Color.rgba(0.92, 0.62, 0.24, 0.95));
        ui.drawRect(.{ .x = rail_x + rail_w - 2.0 * ui_scale, .y = rail_y, .width = 2.0 * ui_scale, .height = rail_h }, Color.rgba(0.48, 0.76, 0.93, 0.65));
        ui.drawRectOutline(.{ .x = rail_x, .y = rail_y, .width = rail_w, .height = rail_h }, Color.rgba(0.44, 0.64, 0.76, 0.50), 2.0 * ui_scale);

        const title_x = 76.0 * ui_scale;
        const title_y = screen_h * 0.18;
        Font.drawText(ui, "ZIGCRAFT", title_x, title_y, title_scale, TITLE_COLOR);
        Font.drawText(ui, "Chunk streams. Vulkan light.", title_x + 4.0 * ui_scale, title_y + 56.0 * ui_scale, subtitle_scale, Color.rgba(0.72, 0.86, 0.95, 0.96));
        Font.drawText(ui, "Sharp-edged worlds from Zig.", title_x + 4.0 * ui_scale, title_y + 78.0 * ui_scale, subtitle_scale, Color.rgba(0.58, 0.72, 0.82, 0.92));
        Font.drawText(ui, "v0.1 / Vulkan", title_x + 4.0 * ui_scale, screen_h - 72.0 * ui_scale, subtitle_scale, Color.rgba(0.45, 0.62, 0.76, 0.86));

        const bw: f32 = @min(rail_w - 74.0 * ui_scale, BUTTON_WIDTH_MAX * ui_scale);
        const bx: f32 = rail_x + 42.0 * ui_scale;
        var by: f32 = rail_y + 94.0 * ui_scale;

        if (Widgets.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "SINGLEPLAYER", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const sp_screen = try SingleplayerScreen.init(ctx.allocator, ctx);
            errdefer sp_screen.deinit(sp_screen);
            ctx.screen_manager.pushScreen(sp_screen.screen());
        }
        by += btn_height + btn_spacing;
        if (Widgets.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "TEXTURE PACKS", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const rp_screen = try ResourcePacksScreen.init(ctx.allocator, ctx);
            errdefer rp_screen.deinit(rp_screen);
            ctx.screen_manager.pushScreen(rp_screen.screen());
        }
        by += btn_height + btn_spacing;
        if (Widgets.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "ENVIRONMENT", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const env_screen = try EnvironmentScreen.init(ctx.allocator, ctx);
            errdefer env_screen.deinit(env_screen);
            ctx.screen_manager.pushScreen(env_screen.screen());
        }
        by += btn_height + btn_spacing;
        if (Widgets.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "SETTINGS", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const settings_screen = try SettingsScreen.init(ctx.allocator, ctx);
            errdefer settings_screen.deinit(settings_screen);
            ctx.screen_manager.pushScreen(settings_screen.screen());
        }
        by += btn_height + btn_spacing;
        if (Widgets.drawButton(ui, .{ .x = bx, .y = by, .width = bw, .height = btn_height }, "QUIT", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            ctx.input.setShouldQuit(true);
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(@ptrCast(self.context.window_manager.window), false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn drawHomeBackdrop(ui: *UISystem, screen_w: f32, screen_h: f32, ui_scale: f32) void {
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0.010, 0.018, 0.030, 1.0));
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h * 0.55 }, Color.rgba(0.04, 0.10, 0.16, 0.70));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.55, .width = screen_w, .height = screen_h * 0.45 }, Color.rgba(0.08, 0.055, 0.030, 0.82));

    const horizon = screen_h * 0.58;
    ui.drawRect(.{ .x = 0, .y = horizon, .width = screen_w, .height = 2.0 * ui_scale }, Color.rgba(0.96, 0.65, 0.26, 0.68));
    ui.drawRect(.{ .x = 70.0 * ui_scale, .y = horizon - 118.0 * ui_scale, .width = 118.0 * ui_scale, .height = 118.0 * ui_scale }, Color.rgba(0.95, 0.61, 0.22, 0.16));

    drawVoxelColumn(ui, 36.0 * ui_scale, horizon - 54.0 * ui_scale, 84.0 * ui_scale, 54.0 * ui_scale, Color.rgba(0.07, 0.14, 0.15, 0.58));
    drawVoxelColumn(ui, 126.0 * ui_scale, horizon - 122.0 * ui_scale, 112.0 * ui_scale, 122.0 * ui_scale, Color.rgba(0.50, 0.29, 0.12, 0.78));
    drawVoxelColumn(ui, 250.0 * ui_scale, horizon - 76.0 * ui_scale, 94.0 * ui_scale, 76.0 * ui_scale, Color.rgba(0.07, 0.13, 0.14, 0.54));
    drawVoxelColumn(ui, 356.0 * ui_scale, horizon - 48.0 * ui_scale, 88.0 * ui_scale, 48.0 * ui_scale, Color.rgba(0.05, 0.10, 0.12, 0.48));
    drawVoxelColumn(ui, 476.0 * ui_scale, horizon - 68.0 * ui_scale, 90.0 * ui_scale, 68.0 * ui_scale, Color.rgba(0.05, 0.10, 0.12, 0.42));

    ui.drawRect(.{ .x = 0, .y = horizon + 2.0 * ui_scale, .width = screen_w, .height = 84.0 * ui_scale }, Color.rgba(0.02, 0.04, 0.045, 0.42));
}

fn drawVoxelColumn(ui: *UISystem, x: f32, y: f32, w: f32, h: f32, color: Color) void {
    ui.drawRect(.{ .x = x, .y = y, .width = w, .height = h }, color);
    ui.drawRect(.{ .x = x, .y = y, .width = w, .height = @min(h, 16.0) }, Color.rgba(0.68, 0.43, 0.16, color.a * 0.34));
}
