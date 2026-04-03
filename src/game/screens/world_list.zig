const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Rect = @import("../../engine/ui/ui_system.zig").Rect;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const WorldScreen = @import("world.zig").WorldScreen;
const log = @import("../../engine/core/log.zig");

const PANEL_WIDTH_MAX = 700.0;
const PANEL_HEIGHT_BASE = 500.0;
const BG_COLOR = Color.rgba(0.12, 0.14, 0.18, 0.92);
const BORDER_COLOR = Color.rgba(0.28, 0.33, 0.42, 1.0);
const TITLE_COLOR = Color.rgba(0.92, 0.94, 0.97, 1.0);
const LABEL_COLOR = Color.rgba(0.72, 0.78, 0.86, 1.0);
const SELECTED_BG = Color.rgba(0.18, 0.24, 0.35, 0.95);
const ROW_HOVER_BG = Color.rgba(0.16, 0.20, 0.28, 0.90);
const ROW_BG = Color.rgba(0.10, 0.12, 0.16, 0.85);
const DELETE_COLOR = Color.rgba(0.85, 0.25, 0.25, 1.0);
const CONFIRM_BG = Color.rgba(0.18, 0.10, 0.10, 0.97);
const CONFIRM_BORDER = Color.rgba(0.7, 0.2, 0.2, 1.0);

pub const SAVE_DIR = ".local/share/zigcraft/saves";

pub const WorldEntry = struct {
    name: []const u8,
    seed: u64,
    last_played: i64,
    generator_index: usize,
    dir_path: []const u8,
};

pub const LevelDat = struct {
    name: []const u8,
    seed: u64,
    last_played: i64,
    generator_index: usize,
};

pub fn writeLevelDat(allocator: std.mem.Allocator, save_dir: std.fs.Dir, name: []const u8, seed: u64, generator_index: usize, last_played: i64) !void {
    const payload = .{
        .name = name,
        .seed = seed,
        .last_played = last_played,
        .generator_index = generator_index,
    };
    const json_str = try std.json.Stringify.valueAlloc(allocator, payload, .{ .whitespace = .indent_2 });
    defer allocator.free(json_str);
    const file = try save_dir.createFile("level.dat", .{});
    defer file.close();
    try file.writeAll(json_str);
}

pub fn readLevelDat(allocator: std.mem.Allocator, save_dir: std.fs.Dir) ?LevelDat {
    const content = save_dir.readFileAlloc("level.dat", allocator, @enumFromInt(4096)) catch return null;
    defer allocator.free(content);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch return null;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return null;
    const obj = root.object;
    const name_val = obj.get("name") orelse return null;
    const seed_val = obj.get("seed") orelse return null;
    const gen_val = obj.get("generator_index") orelse return null;
    const last_val = obj.get("last_played");
    const name_str = switch (name_val) {
        .string => |s| s,
        else => return null,
    };
    const seed: u64 = switch (seed_val) {
        .integer => |i| @intCast(i),
        else => return null,
    };
    const last_played: i64 = if (last_val) |lv| switch (lv) {
        .integer => |i| i,
        else => 0,
    } else 0;
    const generator_index: usize = switch (gen_val) {
        .integer => |i| @intCast(i),
        else => 0,
    };
    const name_copy = allocator.dupe(u8, name_str) catch return null;
    errdefer allocator.free(name_copy);
    return .{
        .name = name_copy,
        .seed = seed,
        .last_played = last_played,
        .generator_index = generator_index,
    };
}

pub fn scanWorlds(allocator: std.mem.Allocator) ![]const WorldEntry {
    const home = std.posix.getenv("HOME") orelse return &[_]WorldEntry{};
    var home_dir = std.fs.openDirAbsolute(home, .{}) catch return &[_]WorldEntry{};
    defer home_dir.close();
    home_dir.makePath(SAVE_DIR) catch {};
    var saves_dir = home_dir.openDir(SAVE_DIR, .{ .iterate = true }) catch return &[_]WorldEntry{};
    defer saves_dir.close();
    var entries = std.ArrayList(WorldEntry).empty;
    errdefer {
        for (entries.items) |e| {
            allocator.free(e.name);
            allocator.free(e.dir_path);
        }
        entries.deinit(allocator);
    }
    var iter = saves_dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        const name_alloc = allocator.dupe(u8, entry.name) catch continue;
        errdefer allocator.free(name_alloc);
        const level = readLevelDat(allocator, saves_dir);
        const dir_buf = std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ home, SAVE_DIR, entry.name }) catch {
            allocator.free(name_alloc);
            continue;
        };
        errdefer allocator.free(dir_buf);
        if (level) |ld| {
            try entries.append(allocator, .{
                .name = ld.name,
                .seed = ld.seed,
                .last_played = ld.last_played,
                .generator_index = ld.generator_index,
                .dir_path = dir_buf,
            });
            allocator.free(name_alloc);
        } else {
            try entries.append(allocator, .{
                .name = name_alloc,
                .seed = 0,
                .last_played = 0,
                .generator_index = 0,
                .dir_path = dir_buf,
            });
        }
    }
    std.sort.block(WorldEntry, entries.items, {}, compareWorldsByLastPlayed);
    return try entries.toOwnedSlice(allocator);
}

fn compareWorldsByLastPlayed(_: void, a: WorldEntry, b: WorldEntry) bool {
    return a.last_played > b.last_played;
}

/// Deletes a world directory and frees dir_path.
/// Logs errors but does not return them. Caller must not use dir_path after call.
pub fn deleteWorld(allocator: std.mem.Allocator, dir_path: []const u8) void {
    const parent_path = std.fs.path.dirname(dir_path) orelse return;
    const base = std.fs.path.basename(dir_path);
    var parent = std.fs.openDirAbsolute(parent_path, .{ .iterate = true }) catch |err| {
        log.log.err("Failed to open parent dir for deletion: {}", .{err});
        return;
    };
    defer parent.close();
    parent.deleteTree(base) catch |err| {
        log.log.warn("Failed to remove world directory: {}", .{err});
    };
    allocator.free(dir_path);
}

pub const WorldListScreen = struct {
    context: EngineContext,
    worlds: []const WorldEntry,
    selected: ?usize,
    scroll_offset: f32,
    confirm_delete: bool,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*WorldListScreen {
        const self = try allocator.create(WorldListScreen);
        errdefer allocator.destroy(self);
        const worlds = scanWorlds(allocator) catch &[_]WorldEntry{};
        self.* = .{
            .context = context,
            .worlds = worlds,
            .selected = null,
            .scroll_offset = 0.0,
            .confirm_delete = false,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        for (self.worlds) |e| {
            self.context.allocator.free(e.name);
            if (e.dir_path.len > 0) self.context.allocator.free(e.dir_path);
        }
        self.context.allocator.free(self.worlds);
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;
        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            if (self.confirm_delete) {
                self.confirm_delete = false;
            } else {
                self.context.screen_manager.popScreen();
            }
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        ui.begin();
        defer ui.end();
        const mouse_pos = ctx.input.getMousePosition();
        const mx: f32 = @floatFromInt(mouse_pos.x);
        const my: f32 = @floatFromInt(mouse_pos.y);
        const mc = ctx.input.isMouseButtonPressed(.left);
        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());
        const ui_scale: f32 = @max(1.0, screen_h / 720.0);
        const title_scale: f32 = 3.5 * ui_scale;
        const label_scale: f32 = 2.0 * ui_scale;
        const btn_scale: f32 = 2.0 * ui_scale;
        const row_scale: f32 = 1.8 * ui_scale;
        const pw: f32 = @min(screen_w * 0.75, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = PANEL_HEIGHT_BASE * ui_scale;
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = screen_h * 0.12;
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawTextCentered(ui, "LOAD WORLD", screen_w * 0.5, py + 18.0 * ui_scale, title_scale, TITLE_COLOR);
        const scroll_dy = ctx.input.getScrollDelta().y;
        self.scroll_offset -= scroll_dy * 30.0 * ui_scale;
        const list_top: f32 = py + 65.0 * ui_scale;
        const list_bottom: f32 = py + ph - 90.0 * ui_scale;
        const row_h: f32 = 55.0 * ui_scale;
        const max_scroll = @max(0.0, @as(f32, @floatFromInt(self.worlds.len)) * row_h - (list_bottom - list_top));
        self.scroll_offset = @max(0.0, @min(self.scroll_offset, max_scroll));
        ui.drawRect(.{ .x = px + 2.0, .y = list_top, .width = pw - 4.0, .height = list_bottom - list_top }, Color.rgba(0.05, 0.06, 0.08, 0.6));
        if (self.worlds.len == 0) {
            Font.drawTextCentered(ui, "NO SAVED WORLDS FOUND", screen_w * 0.5, list_top + (list_bottom - list_top) * 0.4, label_scale, LABEL_COLOR);
            Font.drawTextCentered(ui, "CREATE A NEW WORLD FIRST", screen_w * 0.5, list_top + (list_bottom - list_top) * 0.4 + 25.0 * ui_scale, label_scale * 0.7, Color.rgba(0.5, 0.55, 0.6, 1.0));
        }
        var i: usize = 0;
        while (i < self.worlds.len) : (i += 1) {
            const ry: f32 = list_top + @as(f32, @floatFromInt(i)) * row_h - self.scroll_offset;
            if (ry + row_h < list_top or ry > list_bottom) continue;
            const world = self.worlds[i];
            const row_rect = Rect{ .x = px + 6.0 * ui_scale, .y = ry, .width = pw - 12.0 * ui_scale, .height = row_h - 4.0 * ui_scale };
            const row_hovered = row_rect.contains(mx, my);
            const is_selected = self.selected == i;
            if (is_selected) {
                ui.drawRect(row_rect, SELECTED_BG);
            } else if (row_hovered) {
                ui.drawRect(row_rect, ROW_HOVER_BG);
            } else {
                ui.drawRect(row_rect, ROW_BG);
            }
            ui.drawRectOutline(row_rect, if (is_selected) Color.rgba(0.5, 0.7, 0.95, 1.0) else Color.rgba(0.2, 0.25, 0.3, 1.0), 1.0);
            if (mc and row_hovered and !self.confirm_delete) {
                self.selected = i;
            }
            const text_x: f32 = row_rect.x + 12.0 * ui_scale;
            const name_y: f32 = ry + 8.0 * ui_scale;
            Font.drawText(ui, world.name, text_x, name_y, row_scale, TITLE_COLOR);
            var seed_buf: [64]u8 = undefined;
            const seed_text = std.fmt.bufPrint(&seed_buf, "SEED: {}", .{world.seed}) catch "SEED: ???";
            Font.drawText(ui, seed_text, text_x, name_y + 18.0 * ui_scale, row_scale * 0.65, LABEL_COLOR);
            const last_text = formatTimestamp(world.last_played);
            const seed_w = Font.measureTextWidth(seed_text, row_scale * 0.65);
            Font.drawText(ui, last_text, text_x + seed_w + 15.0 * ui_scale, name_y + 18.0 * ui_scale, row_scale * 0.65, Color.rgba(0.5, 0.55, 0.6, 1.0));
        }
        const btn_h: f32 = 46.0 * ui_scale;
        const byy: f32 = py + ph - 70.0 * ui_scale;
        const btn_w: f32 = (pw - 40.0 * ui_scale) / 3.0;
        const bx_base: f32 = px + 10.0 * ui_scale;
        if (Widgets.drawButton(ui, .{ .x = bx_base, .y = byy, .width = btn_w, .height = btn_h }, "BACK", btn_scale, mx, my, mc)) {
            ctx.screen_manager.popScreen();
        }
        const load_enabled = self.selected != null and !self.confirm_delete;
        if (!load_enabled) {
            ui.drawRect(.{ .x = bx_base + btn_w + 10.0 * ui_scale, .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.1, 0.12, 0.16, 0.7));
            ui.drawRectOutline(.{ .x = bx_base + btn_w + 10.0 * ui_scale, .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.2, 0.22, 0.26, 1.0), 2.0);
            Font.drawTextCentered(ui, "LOAD", bx_base + btn_w + 10.0 * ui_scale + btn_w * 0.5, byy + (btn_h - 7.0 * btn_scale) * 0.5, btn_scale, Color.rgba(0.4, 0.42, 0.46, 1.0));
        } else {
            if (Widgets.drawButton(ui, .{ .x = bx_base + btn_w + 10.0 * ui_scale, .y = byy, .width = btn_w, .height = btn_h }, "LOAD", btn_scale, mx, my, mc)) {
                if (self.selected) |idx| {
                    try self.loadWorld(idx);
                }
            }
        }
        const del_enabled = self.selected != null and !self.confirm_delete;
        if (!del_enabled) {
            ui.drawRect(.{ .x = bx_base + 2.0 * (btn_w + 10.0 * ui_scale), .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.1, 0.1, 0.12, 0.7));
            ui.drawRectOutline(.{ .x = bx_base + 2.0 * (btn_w + 10.0 * ui_scale), .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.2, 0.2, 0.22, 1.0), 2.0);
            Font.drawTextCentered(ui, "DELETE", bx_base + 2.0 * (btn_w + 10.0 * ui_scale) + btn_w * 0.5, byy + (btn_h - 7.0 * btn_scale) * 0.5, btn_scale, Color.rgba(0.4, 0.35, 0.35, 1.0));
        } else {
            if (Widgets.drawButton(ui, .{ .x = bx_base + 2.0 * (btn_w + 10.0 * ui_scale), .y = byy, .width = btn_w, .height = btn_h }, "DELETE", btn_scale, mx, my, mc)) {
                self.confirm_delete = true;
            }
        }
        if (self.confirm_delete) {
            if (self.selected) |idx| {
                const cw: f32 = 420.0 * ui_scale;
                const ch: f32 = 160.0 * ui_scale;
                const cx: f32 = (screen_w - cw) * 0.5;
                const cy: f32 = (screen_h - ch) * 0.5;
                ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.6));
                ui.drawRect(.{ .x = cx, .y = cy, .width = cw, .height = ch }, CONFIRM_BG);
                ui.drawRectOutline(.{ .x = cx, .y = cy, .width = cw, .height = ch }, CONFIRM_BORDER, 2.0);
                const msg_scale: f32 = 1.8 * ui_scale;
                Font.drawTextCentered(ui, "DELETE WORLD?", cx + cw * 0.5, cy + 20.0 * ui_scale, msg_scale, DELETE_COLOR);
                var name_buf: [128]u8 = undefined;
                const confirm_msg = std.fmt.bufPrint(&name_buf, "'{s}'", .{self.worlds[idx].name}) catch "'?'";
                Font.drawTextCentered(ui, confirm_msg, cx + cw * 0.5, cy + 50.0 * ui_scale, msg_scale * 0.8, LABEL_COLOR);
                Font.drawTextCentered(ui, "THIS CANNOT BE UNDONE", cx + cw * 0.5, cy + 72.0 * ui_scale, msg_scale * 0.65, Color.rgba(0.7, 0.5, 0.5, 1.0));
                const cbw: f32 = (cw - 30.0 * ui_scale) / 2.0;
                const cby: f32 = cy + ch - 55.0 * ui_scale;
                if (Widgets.drawButton(ui, .{ .x = cx + 10.0 * ui_scale, .y = cby, .width = cbw, .height = 40.0 * ui_scale }, "CANCEL", btn_scale, mx, my, mc)) {
                    self.confirm_delete = false;
                }
                if (Widgets.drawButton(ui, .{ .x = cx + cbw + 20.0 * ui_scale, .y = cby, .width = cbw, .height = 40.0 * ui_scale }, "CONFIRM", btn_scale, mx, my, mc)) {
                    self.confirmDelete(idx) catch {};
                }
            }
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }

    fn loadWorld(self: *@This(), idx: usize) !void {
        const world = self.worlds[idx];
        const world_screen = try WorldScreen.init(self.context.allocator, self.context, world.seed, world.generator_index);
        errdefer world_screen.deinit(world_screen);
        self.context.screen_manager.setScreen(world_screen.screen());
    }

    fn confirmDelete(self: *@This(), idx: usize) !void {
        const allocator = self.context.allocator;
        const dir_path = self.worlds[idx].dir_path;
        deleteWorld(allocator, dir_path);
        for (self.worlds) |e| {
            allocator.free(e.name);
        }
        allocator.free(self.worlds);
        self.worlds = scanWorlds(allocator) catch &[_]WorldEntry{};
        self.selected = null;
        self.confirm_delete = false;
        self.scroll_offset = 0.0;
    }
};

fn formatTimestamp(ts: i64) []const u8 {
    if (ts <= 0) return "NEVER";
    const now: i64 = blk: {
        const t = std.posix.clock_gettime(std.posix.CLOCK.REALTIME) catch return "NEVER";
        break :blk t.sec * 1000 + @divTrunc(t.nsec, 1000000);
    };
    const diff = now - ts;
    if (diff < 0) return "NEVER";
    if (diff < 60000) return "JUST NOW";
    if (diff < 3600000) return "EARLIER";
    if (diff < 86400000) return "TODAY";
    if (diff < 172800000) return "YESTERDAY";
    return "OLDER";
}
