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
        if (self.context.input.isKeyPressed(.tab)) {
            self.name_focused = !self.name_focused;
            self.seed_focused = !self.name_focused;
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

        const cursor_visible = @as(u32, @truncate(@as(u64, @intFromFloat(ctx.time.elapsed * 2.0)))) % 2 == 0;
        const form_scale: f32 = 1.18 * ui_scale;
        const btn_scale: f32 = 1.16 * ui_scale;
        const input_h: f32 = 58.0 * ui_scale;

        const margin: f32 = 48.0 * ui_scale;
        const page_w = @min(screen_w - margin * 2.0, 1420.0 * ui_scale);
        const page_x = (screen_w - page_w) * 0.5;
        const page_top = @max(38.0 * ui_scale, (screen_h - 860.0 * ui_scale) * 0.5);
        const header_h: f32 = 128.0 * ui_scale;
        const footer_h: f32 = 74.0 * ui_scale;
        const body_y = page_top + header_h;
        const body_h = @min(610.0 * ui_scale, screen_h - body_y - footer_h - 32.0 * ui_scale);
        const column_gap: f32 = 18.0 * ui_scale;
        const rail_w: f32 = if (compact) 0.0 else 190.0 * ui_scale;
        const summary_visible = page_w >= 1120.0 * ui_scale;
        const summary_w: f32 = if (summary_visible) 330.0 * ui_scale else 0.0;
        const form_x = page_x + rail_w + (if (compact) 0.0 else column_gap);
        const form_w = page_w - rail_w - summary_w - (if (compact) 0.0 else column_gap) - (if (summary_visible) column_gap else 0.0);
        const summary_x = form_x + form_w + column_gap;

        Font.drawText(ui, "NEW WORLD", page_x, page_top, 0.88 * ui_scale, Theme.signal);
        Font.drawText(ui, "Create something new.", page_x, page_top + 28.0 * ui_scale, 4.2 * ui_scale, Theme.title);
        Font.drawText(ui, "Name your world, choose its terrain, then jump in.", page_x, page_top + 86.0 * ui_scale, 1.06 * ui_scale, Theme.muted);

        if (!compact) drawCreateSteps(ui, .{ .x = page_x, .y = body_y, .width = rail_w, .height = body_h }, ui_scale);

        const form_rect = Rect{ .x = form_x, .y = body_y, .width = form_w, .height = body_h };
        ui.drawRect(.{ .x = form_rect.x + 9.0 * ui_scale, .y = form_rect.y + 10.0 * ui_scale, .width = form_rect.width, .height = form_rect.height }, Color.rgba(0, 0, 0, 0.38));
        ui.drawRect(form_rect, Color.rgba(0.045, 0.070, 0.090, 0.98));
        ui.drawRect(.{ .x = form_rect.x, .y = form_rect.y, .width = 7.0 * ui_scale, .height = form_rect.height }, Theme.signal);

        const content_x = form_rect.x + 34.0 * ui_scale;
        const content_w = form_rect.width - 68.0 * ui_scale;
        var y = form_rect.y + 28.0 * ui_scale;
        Font.drawText(ui, "World details", content_x, y, 1.62 * ui_scale, Theme.title);
        y += 35.0 * ui_scale;
        Font.drawText(ui, "Give this save a recognizable name.", content_x, y, 0.84 * ui_scale, Theme.muted);
        y += 35.0 * ui_scale;

        Font.drawText(ui, "NAME", content_x, y, 0.76 * ui_scale, Theme.signal);
        y += 21.0 * ui_scale;
        const name_rect = Rect{ .x = content_x, .y = y, .width = content_w, .height = input_h };
        y += input_h + 20.0 * ui_scale;

        Font.drawText(ui, "SEED", content_x, y, 0.76 * ui_scale, Theme.signal);
        y += 21.0 * ui_scale;
        const random_w: f32 = @min(144.0 * ui_scale, content_w * 0.30);
        const seed_rect = Rect{ .x = content_x, .y = y, .width = content_w - random_w - 12.0 * ui_scale, .height = input_h };
        const random_rect = Rect{ .x = seed_rect.x + seed_rect.width + 12.0 * ui_scale, .y = y, .width = random_w, .height = input_h };
        y += input_h + 30.0 * ui_scale;

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

        Font.drawText(ui, "CHOOSE TERRAIN", content_x, y, 0.76 * ui_scale, Theme.signal);
        y += 24.0 * ui_scale;
        const gen_count = registry.getGeneratorCount();
        const generator_gap: f32 = 12.0 * ui_scale;
        const generator_cols: usize = if (content_w >= 480.0 * ui_scale) 2 else 1;
        const generator_w = (content_w - generator_gap * @as(f32, @floatFromInt(generator_cols - 1))) / @as(f32, @floatFromInt(generator_cols));
        const generator_h: f32 = 82.0 * ui_scale;
        var generator_index: usize = 0;
        while (generator_index < gen_count) : (generator_index += 1) {
            const col = generator_index % generator_cols;
            const row = generator_index / generator_cols;
            const generator_rect = Rect{
                .x = content_x + @as(f32, @floatFromInt(col)) * (generator_w + generator_gap),
                .y = y + @as(f32, @floatFromInt(row)) * (generator_h + generator_gap),
                .width = generator_w,
                .height = generator_h,
            };
            const info = registry.getGeneratorInfo(generator_index);
            const selected = self.selected_generator_index == generator_index;
            drawTerrainTile(ui, generator_rect, info.name, info.description, generator_index, selected, ui_scale);
            if (mouse_clicked and generator_rect.contains(mouse_x, mouse_y)) self.selected_generator_index = generator_index;
        }

        if (summary_visible) drawWorldSummary(ui, .{ .x = summary_x, .y = body_y, .width = summary_w, .height = body_h }, self.selected_generator_index, self.seed_input.items, ui_scale);

        const bottom_y = body_y + body_h + 20.0 * ui_scale;
        const load_w = @min(220.0 * ui_scale, page_w * 0.30);
        const action_w = 176.0 * ui_scale;
        const actions_x = page_x + page_w - action_w * 2.0 - 12.0 * ui_scale;
        if (Theme.drawButton(ui, .{ .x = page_x, .y = bottom_y, .width = load_w, .height = 52.0 * ui_scale }, "MY WORLDS", btn_scale, mouse_x, mouse_y, mouse_clicked, .ghost, ui_scale)) {
            const wl_screen = try WorldListScreen.init(ctx.allocator, ctx);
            errdefer wl_screen.deinit(wl_screen);
            ctx.screen_manager.pushScreen(wl_screen.screen());
        }
        if (Theme.drawButton(ui, .{ .x = actions_x, .y = bottom_y, .width = action_w, .height = 52.0 * ui_scale }, "CANCEL", btn_scale, mouse_x, mouse_y, mouse_clicked, .ghost, ui_scale)) {
            ctx.screen_manager.popScreen();
        }
        if (Theme.drawButton(ui, .{ .x = actions_x + action_w + 12.0 * ui_scale, .y = bottom_y, .width = action_w, .height = 52.0 * ui_scale }, "CREATE", btn_scale, mouse_x, mouse_y, mouse_clicked, .primary, ui_scale) or ctx.input_mapper.isActionPressed(ctx.input, .ui_confirm)) {
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

fn drawWorldSummary(ui: *UISystem, rect: Rect, selected_generator_index: usize, seed: []const u8, scale: f32) void {
    const g_info = registry.getGeneratorInfo(selected_generator_index);
    ui.drawRect(rect, Color.rgba(0.035, 0.145, 0.185, 0.98));
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = 8.0 * scale }, Theme.signal);
    Font.drawText(ui, "READY TO CREATE", rect.x + 28.0 * scale, rect.y + 30.0 * scale, 0.78 * scale, Color.rgba(0.72, 0.92, 1.0, 1.0));
    Font.drawText(ui, g_info.name, rect.x + 28.0 * scale, rect.y + 68.0 * scale, 1.82 * scale, Theme.title);
    Font.drawText(ui, g_info.description, rect.x + 28.0 * scale, rect.y + 110.0 * scale, 0.86 * scale, Theme.text);

    const divider_y = rect.y + 156.0 * scale;
    ui.drawRect(.{ .x = rect.x + 28.0 * scale, .y = divider_y, .width = rect.width - 56.0 * scale, .height = 1.0 * scale }, Color.rgba(0.55, 0.82, 0.90, 0.42));
    drawSummaryFact(ui, rect.x + 28.0 * scale, divider_y + 28.0 * scale, "SEED", if (seed.len == 0) "Random on launch" else "Custom seed", scale);
    drawSummaryFact(ui, rect.x + 28.0 * scale, divider_y + 90.0 * scale, "SAVED TO", "My Worlds", scale);
    drawSummaryFact(ui, rect.x + 28.0 * scale, divider_y + 152.0 * scale, "ACCESS", "Offline / local", scale);

    const note_y = rect.y + rect.height - 62.0 * scale;
    Font.drawText(ui, "PRESS ENTER TO CREATE", rect.x + 28.0 * scale, note_y, 0.74 * scale, Color.rgba(0.72, 0.92, 1.0, 1.0));
}

fn drawSummaryFact(ui: *UISystem, x: f32, y: f32, label: []const u8, value: []const u8, scale: f32) void {
    Font.drawText(ui, label, x, y, 0.68 * scale, Color.rgba(0.58, 0.80, 0.88, 1.0));
    Font.drawText(ui, value, x, y + 22.0 * scale, 1.04 * scale, Theme.title);
}

fn drawCreateSteps(ui: *UISystem, rect: Rect, scale: f32) void {
    ui.drawRect(rect, Color.rgba(0.024, 0.038, 0.052, 0.92));
    const labels = [_][]const u8{ "DETAILS", "TERRAIN", "REVIEW" };
    for (labels, 0..) |label, i| {
        const y = rect.y + 30.0 * scale + @as(f32, @floatFromInt(i)) * 82.0 * scale;
        var number_buf: [4]u8 = undefined;
        const number = std.fmt.bufPrint(&number_buf, "0{}", .{i + 1}) catch "";
        Font.drawText(ui, number, rect.x + 22.0 * scale, y, 1.38 * scale, if (i == 0) Theme.signal else Theme.dim);
        Font.drawText(ui, label, rect.x + 68.0 * scale, y + 5.0 * scale, 0.82 * scale, if (i == 0) Theme.title else Theme.muted);
        if (i == 0) ui.drawRect(.{ .x = rect.x, .y = y - 8.0 * scale, .width = 5.0 * scale, .height = 42.0 * scale }, Theme.signal);
    }
}

fn drawTerrainTile(ui: *UISystem, rect: Rect, label: []const u8, description: []const u8, index: usize, selected: bool, scale: f32) void {
    const accents = [_]Color{ Theme.signal, Color.rgba(0.42, 0.78, 0.56, 1.0), Color.rgba(0.88, 0.52, 0.38, 1.0), Color.rgba(0.62, 0.54, 0.94, 1.0) };
    const accent = accents[index % accents.len];
    ui.drawRect(rect, if (selected) Color.rgba(accent.r * 0.24, accent.g * 0.24, accent.b * 0.24, 1.0) else Color.rgba(0.025, 0.044, 0.060, 1.0));
    ui.drawRect(.{ .x = rect.x, .y = rect.y, .width = 8.0 * scale, .height = rect.height }, accent);
    Font.drawText(ui, label, rect.x + 22.0 * scale, rect.y + 17.0 * scale, 1.08 * scale, Theme.title);
    Font.drawText(ui, description, rect.x + 22.0 * scale, rect.y + 48.0 * scale, 0.68 * scale, Theme.muted);
    if (selected) Font.drawText(ui, "SELECTED", rect.x + rect.width - 82.0 * scale, rect.y + 18.0 * scale, 0.62 * scale, accent);
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
