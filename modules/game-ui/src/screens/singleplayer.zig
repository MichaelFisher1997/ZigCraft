const std = @import("std");
const fs = @import("fs");
const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Rect = @import("engine-ui").Rect;
const Font = @import("engine-ui").font;
const Widgets = @import("engine-ui").widgets;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const seed_gen = @import("game-core").seed;
const log = @import("engine-core").log;
const text_input = @import("game-core").text_input;
const Input = @import("engine-input").Input;
const WorldScreen = @import("world.zig").WorldScreen;
const WorldListScreen = @import("world_list.zig").WorldListScreen;
const world_list = @import("world_list.zig");
const registry = @import("world-worldgen").registry;
const gen_interface = @import("world-worldgen");

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

const PANEL_WIDTH_MAX = 780.0;
const BG_COLOR = Color.rgba(0.025, 0.045, 0.065, 0.94);
const BORDER_COLOR = Color.rgba(0.42, 0.66, 0.82, 0.80);
const TITLE_COLOR = Color.rgba(1.0, 0.93, 0.76, 1.0);
const LABEL_COLOR = Color.rgba(0.70, 0.84, 0.94, 1.0);

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

        if (self.seed_focused) {
            try text_input.handleTextTyping(&self.seed_input, self.context.allocator, self.context.input, 32);
        }
        if (self.name_focused) {
            try text_input.handleTextTyping(&self.name_input, self.context.allocator, self.context.input, 32);
        }
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

        const ui_scale: f32 = @max(1.0, screen_h / 720.0);
        const title_scale: f32 = 3.0 * ui_scale;
        const label_scale: f32 = 1.65 * ui_scale;
        const btn_scale: f32 = 1.55 * ui_scale;
        const input_scale: f32 = 1.45 * ui_scale;

        const margin: f32 = 60.0 * ui_scale;
        const pw: f32 = @min(screen_w - margin * 2.0, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = screen_h - margin * 2.0;
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = margin;

        const header_h: f32 = 80.0 * ui_scale;
        const footer_h: f32 = 70.0 * ui_scale;
        const content_top: f32 = py + header_h;
        const content_bottom: f32 = py + ph - footer_h;
        const content_h: f32 = content_bottom - content_top;

        drawCreateWorldBackdrop(ui, screen_w, screen_h, ui_scale);
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRect(.{ .x = px, .y = py, .width = 7.0 * ui_scale, .height = ph }, Color.rgba(0.95, 0.62, 0.24, 0.95));
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = header_h }, Color.rgba(0.12, 0.22, 0.30, 0.62));
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawText(ui, "CREATE WORLD", px + 34.0 * ui_scale, py + 22.0 * ui_scale, title_scale, TITLE_COLOR);
        Font.drawText(ui, "Name your world, choose a seed and terrain profile.", px + 38.0 * ui_scale, py + 54.0 * ui_scale, 1.0 * ui_scale, Color.rgba(0.58, 0.73, 0.84, 0.92));

        const cursor_visible = @as(u32, @truncate(@as(u64, @intFromFloat(ctx.time.elapsed * 2.0)))) % 2 == 0;
        const ih: f32 = 48.0 * ui_scale;
        const ix: f32 = px + 30.0 * ui_scale;
        const iw: f32 = pw - 60.0 * ui_scale;

        // Calculate centered vertical positions for 3 sections + buttons within content area
        const section_gap: f32 = 28.0 * ui_scale;
        const label_h: f32 = 22.0 * ui_scale;
        const desc_h: f32 = 18.0 * ui_scale;
        const btn_row_h: f32 = 42.0 * ui_scale;
        const total_content_needed: f32 = 3.0 * label_h + 3.0 * ih + 2.0 * section_gap + desc_h + section_gap + btn_row_h + 10.0 * ui_scale;
        const start_y: f32 = content_top + @max(10.0 * ui_scale, (content_h - total_content_needed) * 0.3);

        // World Name
        var cy: f32 = start_y;
        Font.drawText(ui, "WORLD NAME", ix, cy, label_scale, LABEL_COLOR);
        cy += label_h + 4.0 * ui_scale;
        const name_rect = Rect{ .x = ix, .y = cy, .width = iw, .height = ih };
        if (mouse_clicked) self.name_focused = name_rect.contains(mouse_x, mouse_y);
        Widgets.drawTextInput(ui, name_rect, self.name_input.items, "ENTER WORLD NAME", input_scale, self.name_focused, cursor_visible);

        // Seed
        cy += ih + section_gap;
        Font.drawText(ui, "SEED", ix, cy, label_scale, LABEL_COLOR);
        cy += label_h + 4.0 * ui_scale;
        const rw: f32 = 140.0 * ui_scale;
        const sw: f32 = iw - rw - 15.0 * ui_scale;
        const seed_rect = Rect{ .x = ix, .y = cy, .width = sw, .height = ih };
        const random_rect = Rect{ .x = ix + sw + 15.0 * ui_scale, .y = cy, .width = rw, .height = ih };
        if (mouse_clicked) {
            const in_seed = seed_rect.contains(mouse_x, mouse_y);
            const in_name = name_rect.contains(mouse_x, mouse_y);
            self.seed_focused = in_seed;
            self.name_focused = in_name;
        }
        Widgets.drawTextInput(ui, seed_rect, self.seed_input.items, "LEAVE BLANK FOR RANDOM", input_scale, self.seed_focused, cursor_visible);

        if (Widgets.drawButton(ui, random_rect, "RANDOM", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const gen = seed_gen.randomSeedValue();
            try seed_gen.setSeedInput(&self.seed_input, ctx.allocator, gen);
            self.seed_focused = true;
            self.name_focused = false;
        }

        // World Type
        cy += ih + section_gap;
        Font.drawText(ui, "WORLD TYPE", ix, cy, label_scale, LABEL_COLOR);
        cy += label_h + 4.0 * ui_scale;
        const arrow_w: f32 = 44.0 * ui_scale;
        const g_label_w: f32 = iw - 2.0 * arrow_w - 2.0 * 10.0 * ui_scale;
        const g_info = registry.getGeneratorInfo(self.selected_generator_index);
        const gen_count = registry.getGeneratorCount();

        if (Widgets.drawButton(ui, .{ .x = ix, .y = cy, .width = arrow_w, .height = ih }, "<", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            if (self.selected_generator_index == 0) {
                self.selected_generator_index = gen_count - 1;
            } else {
                self.selected_generator_index -= 1;
            }
        }
        var g_label_buf: [128]u8 = undefined;
        const g_label = try std.fmt.bufPrint(&g_label_buf, "{s} ({}/{})", .{ g_info.name, self.selected_generator_index + 1, gen_count });
        Font.drawTextCentered(ui, g_label, ix + arrow_w + 10.0 * ui_scale + g_label_w * 0.5, cy + (ih - 7.0 * btn_scale) * 0.5, btn_scale, TITLE_COLOR);
        if (Widgets.drawButton(ui, .{ .x = ix + arrow_w + g_label_w + 20.0 * ui_scale, .y = cy, .width = arrow_w, .height = ih }, ">", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            self.selected_generator_index = (self.selected_generator_index + 1) % gen_count;
        }
        cy += ih + 8.0 * ui_scale;
        Font.drawText(ui, g_info.description, ix, cy, label_scale * 0.62, Color.rgba(0.55, 0.68, 0.78, 0.95));

        // Footer buttons - positioned at fixed bottom of panel
        const footer_y: f32 = py + ph - footer_h + 10.0 * ui_scale;
        ui.drawRect(.{ .x = px, .y = py + ph - footer_h, .width = pw, .height = 2.0 * ui_scale }, Color.rgba(0.20, 0.36, 0.48, 0.50));

        const load_btn_y: f32 = footer_y;
        if (Widgets.drawButton(ui, .{ .x = ix, .y = load_btn_y, .width = iw, .height = btn_row_h }, "LOAD WORLD", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const wl_screen = try WorldListScreen.init(ctx.allocator, ctx);
            errdefer wl_screen.deinit(wl_screen);
            ctx.screen_manager.pushScreen(wl_screen.screen());
        }

        const bottom_btn_y: f32 = load_btn_y + btn_row_h + 10.0 * ui_scale;
        const hw: f32 = (iw - 15.0 * ui_scale) / 2.0;
        if (Widgets.drawButton(ui, .{ .x = ix, .y = bottom_btn_y, .width = hw, .height = btn_row_h }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            ctx.screen_manager.popScreen();
        }
        if (Widgets.drawButton(ui, .{ .x = ix + hw + 15.0 * ui_scale, .y = bottom_btn_y, .width = hw, .height = btn_row_h }, "CREATE", btn_scale, mouse_x, mouse_y, mouse_clicked) or ctx.input_mapper.isActionPressed(ctx.input, .ui_confirm)) {
            const seed = try seed_gen.resolveSeed(&self.seed_input, ctx.allocator);
            const trimmed_name = std.mem.trim(u8, self.name_input.items, " \t\r\n");
            const world_name = if (trimmed_name.len > 0) trimmed_name else "New World";
            log.log.info("World seed: {} | Type: {s} | Name: {s}", .{ seed, registry.getGeneratorInfo(self.selected_generator_index).name, world_name });
            saveNewWorld(ctx.allocator, seed, self.selected_generator_index, world_name) catch |err| {
                log.log.warn("Failed to save level.dat for new world: {}", .{err});
            };
            const world_screen = try WorldScreen.init(ctx.allocator, ctx, seed, self.selected_generator_index);
            errdefer world_screen.deinit(world_screen);
            ctx.screen_manager.setScreen(world_screen.screen());
        }
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn drawCreateWorldBackdrop(ui: *UISystem, screen_w: f32, screen_h: f32, ui_scale: f32) void {
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0.010, 0.018, 0.030, 0.92));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.62, .width = screen_w, .height = screen_h * 0.38 }, Color.rgba(0.075, 0.048, 0.028, 0.72));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.62, .width = screen_w, .height = 2.0 * ui_scale }, Color.rgba(0.92, 0.62, 0.24, 0.54));
    ui.drawRect(.{ .x = 62.0 * ui_scale, .y = screen_h * 0.62 - 72.0 * ui_scale, .width = 92.0 * ui_scale, .height = 72.0 * ui_scale }, Color.rgba(0.07, 0.14, 0.15, 0.34));
    ui.drawRect(.{ .x = screen_w - 180.0 * ui_scale, .y = screen_h * 0.62 - 116.0 * ui_scale, .width = 118.0 * ui_scale, .height = 116.0 * ui_scale }, Color.rgba(0.50, 0.29, 0.12, 0.38));
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
