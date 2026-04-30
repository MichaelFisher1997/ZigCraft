const std = @import("std");
const fs = @import("fs");
const UISystem = @import("engine-ui").UISystem;
const Font = @import("engine-ui").font;
const Theme = @import("../menu_theme.zig");
const Color = Theme.Color;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const EnvironmentContext = Screen.EnvironmentContext;
const settings_pkg = @import("game-core").settings;
const Texture = @import("engine-rhi").Texture;
const log = @import("engine-core").log;

const PANEL_WIDTH_MAX = 920.0;
const PANEL_HEIGHT_MAX = 760.0;

pub const EnvironmentScreen = struct {
    context: EnvironmentContext,
    environment_maps: std.ArrayListUnmanaged([]const u8),

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

        const preview_w = @min(260.0 * ui_scale, shell.content.width * 0.34);
        const list_x = shell.content.x + preview_w + 24.0 * ui_scale;
        const list_w = shell.content.width - preview_w - 24.0 * ui_scale;
        drawSkyPreview(ui, shell.content.x, shell.content.y, preview_w, shell.content.height, settings.environment_map, ui_scale);

        Theme.drawListRail(ui, .{ .x = list_x, .y = shell.content.y, .width = list_w, .height = shell.content.height }, ui_scale);
        var y = shell.content.y + 18.0 * ui_scale;
        const row_x = list_x + 18.0 * ui_scale;
        const row_w = list_w - 36.0 * ui_scale;
        const row_h = 56.0 * ui_scale;
        const btn_scale = 1.12 * ui_scale;

        const is_default = std.mem.eql(u8, settings.environment_map, "default");
        if (drawEnvironmentButton(ui, row_x, y, row_w, row_h, "DEFAULT SKY", "Neutral white environment texture.", is_default, btn_scale, mouse_x, mouse_y, mouse_clicked, ui_scale)) {
            if (!is_default) {
                try settings_pkg.persistence.setEnvironmentMap(settings, ctx.allocator, "default");
                try self.reloadEnvMap();
            }
        }
        y += row_h + 10.0 * ui_scale;

        var buffer: [160]u8 = undefined;
        for (self.environment_maps.items) |environment_map| {
            if (y + row_h > shell.content.y + shell.content.height) break;
            const is_selected = std.mem.eql(u8, settings.environment_map, environment_map);
            const label = std.fmt.bufPrint(&buffer, "{s}", .{environment_map}) catch "ENVIRONMENT";
            if (drawEnvironmentButton(ui, row_x, y, row_w, row_h, label, "HDR/EXR sky probe from the working directory.", is_selected, btn_scale, mouse_x, mouse_y, mouse_clicked, ui_scale)) {
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

fn drawSkyPreview(ui: *UISystem, x: f32, y: f32, w: f32, h: f32, active_name: []const u8, scale: f32) void {
    Theme.drawListRail(ui, .{ .x = x, .y = y, .width = w, .height = h }, scale);
    Font.drawText(ui, "ACTIVE SKY", x + 18.0 * scale, y + 22.0 * scale, 0.78 * scale, Theme.muted);
    Font.drawText(ui, active_name, x + 18.0 * scale, y + 52.0 * scale, 1.04 * scale, Theme.title);

    const orb = @min(w - 60.0 * scale, 150.0 * scale);
    const ox = x + (w - orb) * 0.5;
    const oy = y + h * 0.44 - orb * 0.5;
    ui.drawRect(.{ .x = ox - 20.0 * scale, .y = oy - 20.0 * scale, .width = orb + 40.0 * scale, .height = orb + 40.0 * scale }, Color.rgba(0.58, 0.72, 0.82, 0.055));
    ui.drawRect(.{ .x = ox, .y = oy, .width = orb, .height = orb }, Color.rgba(0.42, 0.54, 0.62, 0.16));
    ui.drawRect(.{ .x = ox + 22.0 * scale, .y = oy + 22.0 * scale, .width = orb - 44.0 * scale, .height = orb - 44.0 * scale }, Color.rgba(0.82, 0.88, 0.91, 0.12));
    Font.drawTextCentered(ui, "ACTIVE LIGHT", x + w * 0.5, y + h - 70.0 * scale, 0.86 * scale, Theme.signal);
}

fn drawEnvironmentButton(ui: *UISystem, x: f32, y: f32, w: f32, h: f32, label: []const u8, description: []const u8, selected: bool, btn_scale: f32, mx: f32, my: f32, clicked: bool, scale: f32) bool {
    Theme.drawOptionRow(ui, .{ .x = x, .y = y, .width = w, .height = h }, label, description, 1.02 * scale, selected, scale);
    const action_w = 150.0 * scale;
    const action_x = x + w - action_w - 12.0 * scale;
    return Theme.drawButton(ui, .{ .x = action_x, .y = y + 9.0 * scale, .width = action_w, .height = h - 18.0 * scale }, if (selected) "ACTIVE" else "SELECT", btn_scale, mx, my, clicked, if (selected) .primary else .secondary, scale);
}
