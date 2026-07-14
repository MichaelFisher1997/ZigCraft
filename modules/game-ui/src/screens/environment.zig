const std = @import("std");
const fs = @import("fs");
const UISystem = @import("engine-ui").UISystem;
const Font = @import("engine-ui").font;
const Theme = @import("../menu_theme.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const EnvironmentContext = Screen.EnvironmentContext;
const settings_pkg = @import("game-core").settings;
const Texture = @import("engine-rhi").Texture;
const log = @import("engine-core").log;

const PANEL_WIDTH_MAX = 900.0;
const PANEL_HEIGHT_MAX = 660.0;

pub const EnvironmentScreen = struct {
    context: EnvironmentContext,
    environment_maps: std.ArrayListUnmanaged([]const u8),
    scroll_offset: f32,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*EnvironmentScreen {
        const self = try allocator.create(EnvironmentScreen);
        errdefer {
            self.clearEnvironmentMaps();
            self.environment_maps.deinit(allocator);
            allocator.destroy(self);
        }
        self.* = .{
            .context = context.environmentContext(),
            .environment_maps = .empty,
            .scroll_offset = 0.0,
        };
        try self.refreshEnvironmentMaps();
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.clearEnvironmentMaps();
        self.environment_maps.deinit(self.context.allocator);
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

        Theme.drawBackdrop(ui, screen_w, screen_h, ui_scale, .environment);
        const margin: f32 = 48.0 * ui_scale;
        const panel_w: f32 = @min(screen_w - margin * 2.0, PANEL_WIDTH_MAX * ui_scale);
        const panel_h: f32 = @min(screen_h - margin * 2.0, PANEL_HEIGHT_MAX * ui_scale);
        const panel_x = (screen_w - panel_w) * 0.5;
        const panel_y = (screen_h - panel_h) * 0.5;
        const shell = Theme.drawShell(ui, .{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, ui_scale, "LIGHT PROBE", "ENVIRONMENT", "Choose the sky probe that lights the scene.");

        Theme.drawListRail(ui, shell.content, ui_scale);
        const row_x = shell.content.x + 18.0 * ui_scale;
        const row_w = shell.content.width - 36.0 * ui_scale;
        const row_h = 64.0 * ui_scale;
        const btn_scale = 1.12 * ui_scale;
        const content_h = @as(f32, @floatFromInt(self.environment_maps.items.len + 1)) * (row_h + 10.0 * ui_scale) + 26.0 * ui_scale;
        const max_scroll = @max(0.0, content_h - shell.content.height);
        self.scroll_offset -= ctx.input.getScrollDelta().y * 32.0 * ui_scale;
        self.scroll_offset = @max(0.0, @min(self.scroll_offset, max_scroll));
        var y = shell.content.y + 18.0 * ui_scale - self.scroll_offset;
        Theme.drawScrollbar(ui, shell.content.x + shell.content.width - 10.0 * ui_scale, shell.content.y + 12.0 * ui_scale, shell.content.height - 24.0 * ui_scale, content_h, shell.content.height, self.scroll_offset, max_scroll, ui_scale);

        const is_default = std.mem.eql(u8, settings.environment_map, "default");
        if (y + row_h >= shell.content.y and y <= shell.content.y + shell.content.height) {
            if (drawEnvironmentButton(ui, row_x, y, row_w, row_h, "DEFAULT SKY", "Neutral white environment texture.", is_default, mouse_x, mouse_y, mouse_clicked, ui_scale)) {
                if (!is_default) {
                    try settings_pkg.persistence.setEnvironmentMap(settings, ctx.allocator, "default");
                    try self.reloadEnvMap();
                }
            }
        }
        y += row_h + 10.0 * ui_scale;

        var buffer: [160]u8 = undefined;
        for (self.environment_maps.items) |environment_map| {
            if (y + row_h < shell.content.y or y > shell.content.y + shell.content.height) {
                y += row_h + 10.0 * ui_scale;
                continue;
            }
            const is_selected = std.mem.eql(u8, settings.environment_map, environment_map);
            const label = std.fmt.bufPrint(&buffer, "{s}", .{environment_map}) catch "ENVIRONMENT";
            if (drawEnvironmentButton(ui, row_x, y, row_w, row_h, label, "HDR/EXR sky probe from the working directory.", is_selected, mouse_x, mouse_y, mouse_clicked, ui_scale)) {
                if (!is_selected) {
                    try settings_pkg.persistence.setEnvironmentMap(settings, ctx.allocator, environment_map);
                    try self.reloadEnvMap();
                }
            }
            y += row_h + 10.0 * ui_scale;
        }

        if (Theme.drawButton(ui, .{ .x = panel_x + (panel_w - 180.0 * ui_scale) * 0.5, .y = shell.footer_y, .width = 180.0 * ui_scale, .height = 46.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked, .ghost, ui_scale)) {
            ctx.saveSettings();
            ctx.screen_manager.popScreen();
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
        self.refreshEnvironmentMaps() catch |err| log.log.warn("Failed to refresh environment map list: {}", .{err});
    }

    fn clearEnvironmentMaps(self: *@This()) void {
        for (self.environment_maps.items) |name| self.context.allocator.free(name);
        self.environment_maps.clearRetainingCapacity();
    }

    fn refreshEnvironmentMaps(self: *@This()) !void {
        self.clearEnvironmentMaps();
        var dir = fs.cwd().openDir(".", .{ .iterate = true }) catch return;
        defer dir.close();

        var iterator = dir.iterate();
        while (try iterator.next()) |entry| {
            if (entry.kind != .file) continue;
            const is_exr = std.mem.endsWith(u8, entry.name, ".exr");
            const is_hdr = std.mem.endsWith(u8, entry.name, ".hdr");
            if (!is_exr and !is_hdr) continue;
            if (is_hdr and std.mem.endsWith(u8, entry.name, ".exr.hdr")) continue;
            const name = try self.context.allocator.dupe(u8, entry.name);
            errdefer self.context.allocator.free(name);
            try self.environment_maps.append(self.context.allocator, name);
        }
    }

    fn reloadEnvMap(self: *@This()) !void {
        const ctx = self.context;
        const render_system = ctx.render_system;
        const env_ptr = render_system.getEnvMapPtr();
        const rhi = render_system.getRHI();

        rhi.waitIdle();
        if (env_ptr.*) |*t| t.deinit();
        env_ptr.* = null;

        if (!std.mem.eql(u8, ctx.settings.environment_map, "default")) {
            if (render_system.getResourcePackManager().loadImageFileFloat(ctx.settings.environment_map)) |tex_data| {
                env_ptr.* = try Texture.initFloat(rhi.resourceManager(), tex_data.width, tex_data.height, tex_data.pixels);
                log.log.info("Loaded Environment Map: {s}", .{ctx.settings.environment_map});
                var td = tex_data;
                td.deinit(ctx.allocator);
            } else {
                log.log.warn("Could not load environment map: {s}", .{ctx.settings.environment_map});
                const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
                env_ptr.* = try Texture.initFloat(rhi.resourceManager(), 1, 1, &white_pixel);
            }
        } else {
            const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
            env_ptr.* = try Texture.initFloat(rhi.resourceManager(), 1, 1, &white_pixel);
        }
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn drawEnvironmentButton(ui: *UISystem, x: f32, y: f32, w: f32, h: f32, label: []const u8, description: []const u8, selected: bool, mx: f32, my: f32, clicked: bool, scale: f32) bool {
    const row = Theme.Rect{ .x = x, .y = y, .width = w, .height = h };
    const label_scale = 1.14 * scale;
    const active_scale = 0.90 * scale;
    const active_w = if (selected) Font.measureTextWidthWithUI(ui, "ACTIVE", active_scale) + 20.0 * scale else 0.0;
    const max_label_w = row.width - 40.0 * scale - active_w;
    const label_w = Font.measureTextWidthWithUI(ui, label, label_scale);
    const fitted_label_scale = if (label_w > max_label_w and label_w > 0.0) label_scale * (max_label_w / label_w) else label_scale;

    Theme.drawOptionRow(ui, row, "", "", label_scale, selected or row.contains(mx, my), scale);
    Font.drawText(ui, label, x + 20.0 * scale, y + 10.0 * scale, fitted_label_scale, if (selected) Theme.title else Theme.text);
    Font.drawText(ui, description, x + 20.0 * scale, y + 39.0 * scale, 0.96 * scale, Theme.muted);
    if (selected) {
        Font.drawText(ui, "ACTIVE", x + w - active_w, y + 17.0 * scale, active_scale, Theme.signal);
    }
    return clicked and row.contains(mx, my);
}
