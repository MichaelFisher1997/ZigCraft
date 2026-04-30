const std = @import("std");
const fs = @import("fs");
const UISystem = @import("engine-ui").UISystem;
const Font = @import("engine-ui").font;
const Theme = @import("../menu_theme.zig");
const Rect = Theme.Rect;
const Color = Theme.Color;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const seed_gen = @import("game-core").seed;
const log = @import("engine-core").log;
const text_input = @import("game-core").text_input;
const WorldScreen = @import("world.zig").WorldScreen;
const WorldListScreen = @import("world_list.zig").WorldListScreen;
const world_list = @import("world_list.zig");
const registry = @import("world-worldgen").registry;

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

const PANEL_WIDTH_MAX = 1160.0;
const PANEL_HEIGHT_MAX = 760.0;

pub const SingleplayerScreen = struct {
    context: EngineContext,
    seed_input: std.ArrayListUnmanaged(u8),
    seed_focused: bool,
    name_input: std.ArrayListUnmanaged(u8),
    name_focused: bool,
    selected_generator_index: usize,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*SingleplayerScreen {
        const self = try allocator.create(SingleplayerScreen);
        self.* = .{
            .context = context,
            .seed_input = std.ArrayListUnmanaged(u8).empty,
            .seed_focused = false,
            .name_input = std.ArrayListUnmanaged(u8).empty,
            .name_focused = true,
            .selected_generator_index = 0,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.seed_input.deinit(self.context.allocator);
        self.name_input.deinit(self.context.allocator);
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;

        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            self.context.screen_manager.popScreen();
            return;
        }
        if (self.seed_focused) try text_input.handleTextTyping(&self.seed_input, self.context.allocator, self.context.input, 32);
        if (self.name_focused) try text_input.handleTextTyping(&self.name_input, self.context.allocator, self.context.input, 32);
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
        const compact = screen_w < 940.0 * ui_scale;

        Theme.drawBackdrop(ui, screen_w, screen_h, ui_scale, .create);

        const margin: f32 = 42.0 * ui_scale;
        const panel_w: f32 = @min(screen_w - margin * 2.0, PANEL_WIDTH_MAX * ui_scale);
        const panel_h: f32 = @min(screen_h - margin * 2.0, PANEL_HEIGHT_MAX * ui_scale);
        const panel_x: f32 = (screen_w - panel_w) * 0.5;
        const panel_y: f32 = (screen_h - panel_h) * 0.5;
        const shell = Theme.drawShell(ui, .{ .x = panel_x, .y = panel_y, .width = panel_w, .height = panel_h }, ui_scale, "GENERATOR", "NEW WORLD", "Name it, seed it, pick a terrain generator.");

        const cursor_visible = @as(u32, @truncate(@as(u64, @intFromFloat(ctx.time.elapsed * 2.0)))) % 2 == 0;
        const form_scale: f32 = 1.18 * ui_scale;
        const btn_scale: f32 = 1.16 * ui_scale;
        const input_h: f32 = 52.0 * ui_scale;

        const gap: f32 = 28.0 * ui_scale;
        const preview_w: f32 = if (compact) 0.0 else shell.content.width * 0.40;
        const form_x: f32 = if (compact) shell.content.x else shell.content.x + preview_w + gap;
        const form_w: f32 = if (compact) shell.content.width else shell.content.width - preview_w - gap;

        if (!compact) drawGeneratorPreview(ui, .{ .x = shell.content.x, .y = shell.content.y, .width = preview_w, .height = shell.content.height }, self.selected_generator_index, ui_scale);

        var y = shell.content.y + 6.0 * ui_scale;
        Theme.drawSectionLabel(ui, form_x, y, "WORLD NAME", ui_scale);
        y += 34.0 * ui_scale;

        Font.drawText(ui, "WORLD NAME", form_x, y, 0.82 * ui_scale, Theme.muted);
        y += 20.0 * ui_scale;
        const name_rect = Rect{ .x = form_x, .y = y, .width = form_w, .height = input_h };
        y += input_h + 18.0 * ui_scale;

        Font.drawText(ui, "SEED", form_x, y, 0.82 * ui_scale, Theme.muted);
        y += 20.0 * ui_scale;
        const random_w: f32 = @min(150.0 * ui_scale, form_w * 0.34);
        const seed_rect = Rect{ .x = form_x, .y = y, .width = form_w - random_w - 12.0 * ui_scale, .height = input_h };
        const random_rect = Rect{ .x = seed_rect.x + seed_rect.width + 12.0 * ui_scale, .y = y, .width = random_w, .height = input_h };
        y += input_h + 24.0 * ui_scale;

        if (mouse_clicked) {
            self.name_focused = name_rect.contains(mouse_x, mouse_y);
            self.seed_focused = seed_rect.contains(mouse_x, mouse_y);
        }
        Theme.drawTextInput(ui, name_rect, self.name_input.items, "ENTER WORLD NAME", form_scale, self.name_focused, cursor_visible, ui_scale);
        Theme.drawTextInput(ui, seed_rect, self.seed_input.items, "BLANK MEANS RANDOM", form_scale * 0.92, self.seed_focused, cursor_visible, ui_scale);
        if (Theme.drawButton(ui, random_rect, "RANDOM", btn_scale, mouse_x, mouse_y, mouse_clicked, .secondary, ui_scale)) {
            const gen = seed_gen.randomSeedValue();
            try seed_gen.setSeedInput(&self.seed_input, ctx.allocator, gen);
            self.seed_focused = true;
            self.name_focused = false;
        }

        Theme.drawSectionLabel(ui, form_x, y, "TERRAIN TYPE", ui_scale);
        y += 38.0 * ui_scale;
        const g_info = registry.getGeneratorInfo(self.selected_generator_index);
        const gen_count = registry.getGeneratorCount();
        const profile_h: f32 = 76.0 * ui_scale;
        Theme.drawOptionRow(ui, .{ .x = form_x, .y = y, .width = form_w, .height = profile_h }, g_info.name, g_info.description, 1.22 * ui_scale, true, ui_scale);

        const arrow_w: f32 = 48.0 * ui_scale;
        const label_w: f32 = 142.0 * ui_scale;
        const ctrl_y = y + 14.0 * ui_scale;
        const right_x = form_x + form_w - arrow_w - 12.0 * ui_scale;
        const value_x = right_x - label_w - 8.0 * ui_scale;
        const left_x = value_x - arrow_w - 8.0 * ui_scale;
        if (Theme.drawButton(ui, .{ .x = left_x, .y = ctrl_y, .width = arrow_w, .height = 46.0 * ui_scale }, "<", btn_scale, mouse_x, mouse_y, mouse_clicked, .ghost, ui_scale)) {
            self.selected_generator_index = if (self.selected_generator_index == 0) gen_count - 1 else self.selected_generator_index - 1;
        }
        var gen_label_buf: [32]u8 = undefined;
        const gen_label = std.fmt.bufPrint(&gen_label_buf, "{}/{}", .{ self.selected_generator_index + 1, gen_count }) catch "?";
        Theme.drawValueText(ui, .{ .x = value_x, .y = ctrl_y, .width = label_w, .height = 46.0 * ui_scale }, gen_label, btn_scale, ui_scale);
        if (Theme.drawButton(ui, .{ .x = right_x, .y = ctrl_y, .width = arrow_w, .height = 46.0 * ui_scale }, ">", btn_scale, mouse_x, mouse_y, mouse_clicked, .ghost, ui_scale)) {
            self.selected_generator_index = (self.selected_generator_index + 1) % gen_count;
        }

        const bottom_y = shell.footer_y;
        const load_w = @min(260.0 * ui_scale, form_w * 0.42);
        const action_w = (form_w - load_w - 24.0 * ui_scale) * 0.5;
        if (Theme.drawButton(ui, .{ .x = form_x, .y = bottom_y, .width = load_w, .height = 48.0 * ui_scale }, "LOAD WORLD", btn_scale, mouse_x, mouse_y, mouse_clicked, .ghost, ui_scale)) {
            const wl_screen = try WorldListScreen.init(ctx.allocator, ctx);
            errdefer wl_screen.deinit(wl_screen);
            ctx.screen_manager.pushScreen(wl_screen.screen());
        }
        if (Theme.drawButton(ui, .{ .x = form_x + load_w + 12.0 * ui_scale, .y = bottom_y, .width = action_w, .height = 48.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked, .ghost, ui_scale)) {
            ctx.screen_manager.popScreen();
        }
        if (Theme.drawButton(ui, .{ .x = form_x + load_w + 24.0 * ui_scale + action_w, .y = bottom_y, .width = action_w, .height = 48.0 * ui_scale }, "CREATE", btn_scale, mouse_x, mouse_y, mouse_clicked, .primary, ui_scale) or ctx.input_mapper.isActionPressed(ctx.input, .ui_confirm)) {
            const seed = try seed_gen.resolveSeed(&self.seed_input, ctx.allocator);
            const trimmed_name = std.mem.trim(u8, self.name_input.items, " \t\r\n");
            const world_name = if (trimmed_name.len > 0) trimmed_name else "New World";
            log.log.info("World seed: {} | Type: {s} | Name: {s}", .{ seed, registry.getGeneratorInfo(self.selected_generator_index).name, world_name });
            saveNewWorld(ctx.allocator, seed, self.selected_generator_index, world_name) catch |err| log.log.warn("Failed to save level.dat for new world: {}", .{err});
            const world_screen = try WorldScreen.init(ctx.allocator, ctx, seed, self.selected_generator_index);
            errdefer world_screen.deinit(world_screen);
            ctx.screen_manager.setScreen(world_screen.screen());
        }
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn drawGeneratorPreview(ui: *UISystem, rect: Rect, selected_generator_index: usize, scale: f32) void {
    const g_info = registry.getGeneratorInfo(selected_generator_index);
    Theme.drawListRail(ui, rect, scale);
    Font.drawText(ui, "TERRAIN PREVIEW", rect.x + 22.0 * scale, rect.y + 20.0 * scale, 0.82 * scale, Theme.muted);
    Font.drawText(ui, g_info.name, rect.x + 22.0 * scale, rect.y + 50.0 * scale, 1.72 * scale, Theme.title);
    Font.drawText(ui, g_info.description, rect.x + 22.0 * scale, rect.y + 86.0 * scale, 0.82 * scale, Theme.text);

    const terrain_y = rect.y + rect.height - 158.0 * scale;
    ui.drawRect(.{ .x = rect.x + 22.0 * scale, .y = terrain_y, .width = rect.width - 44.0 * scale, .height = 104.0 * scale }, Color.rgba(0.034, 0.054, 0.070, 0.92));
    ui.drawRect(.{ .x = rect.x + 22.0 * scale, .y = terrain_y + 52.0 * scale, .width = rect.width - 44.0 * scale, .height = 2.0 * scale }, Color.rgba(0.58, 0.72, 0.82, 0.44));

    var x = rect.x + 40.0 * scale;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        const w: f32 = if (i % 3 == 0) 34.0 * scale else if (i % 3 == 1) 48.0 * scale else 28.0 * scale;
        const h: f32 = if (i % 4 == 0) 78.0 * scale else if (i % 4 == 1) 46.0 * scale else if (i % 4 == 2) 92.0 * scale else 60.0 * scale;
        ui.drawRect(.{ .x = x, .y = terrain_y + 104.0 * scale - h, .width = w, .height = h }, Color.rgba(0.080, 0.120, 0.150, 0.86));
        ui.drawRect(.{ .x = x, .y = terrain_y + 104.0 * scale - h, .width = w, .height = 7.0 * scale }, if (i % 2 == 0) Theme.signal else Theme.copper);
        x += w + 12.0 * scale;
    }
}

fn saveNewWorld(allocator: std.mem.Allocator, seed: u64, generator_index: usize, world_name: []const u8) !void {
    const home = getenv("HOME") orelse {
        log.log.warn("Cannot save world: HOME not set", .{});
        return error.NoHome;
    };
    var home_dir = fs.openDirAbsolute(home, .{}) catch |err| {
        log.log.warn("Cannot save world: failed to open home dir: {}", .{err});
        return err;
    };
    defer home_dir.close();
    home_dir.makePath(world_list.SAVE_DIR) catch |err| {
        log.log.warn("Cannot save world: failed to create saves dir: {}", .{err});
        return err;
    };
    var dir_name_buf: [128]u8 = undefined;
    const timestamp = std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
    const dir_name = std.fmt.bufPrint(&dir_name_buf, "world_{}", .{timestamp}) catch "world_new";
    const world_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ world_list.SAVE_DIR, dir_name });
    defer allocator.free(world_dir_path);
    home_dir.makePath(world_dir_path) catch |err| {
        log.log.warn("Cannot save world: failed to create world dir: {}", .{err});
        return err;
    };
    var save_dir = home_dir.openDir(world_dir_path, .{}) catch |err| {
        log.log.warn("Cannot save world: failed to open world dir: {}", .{err});
        return err;
    };
    defer save_dir.close();
    world_list.writeLevelDat(allocator, save_dir, world_name, seed, generator_index, timestamp) catch |err| {
        log.log.warn("Cannot save world: failed to write level.dat: {}", .{err});
        return err;
    };
}
