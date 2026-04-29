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
const log = @import("engine-core").log;
const fs = @import("fs");
const Key = @import("../../engine/core/interfaces.zig").Key;
const IRawInputProvider = @import("../../engine/input/interfaces.zig").IRawInputProvider;

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

const PANEL_WIDTH_MAX = 900.0;
const PANEL_HEIGHT_BASE = 640.0;
const BG_COLOR = Color.rgba(0.025, 0.045, 0.065, 0.95);
const BORDER_COLOR = Color.rgba(0.42, 0.66, 0.82, 0.78);
const TITLE_COLOR = Color.rgba(1.0, 0.93, 0.76, 1.0);
const LABEL_COLOR = Color.rgba(0.72, 0.86, 0.96, 1.0);
const MUTED_COLOR = Color.rgba(0.48, 0.60, 0.70, 0.92);
const SELECTED_BG = Color.rgba(0.18, 0.34, 0.46, 0.92);
const ROW_HOVER_BG = Color.rgba(0.11, 0.21, 0.29, 0.92);
const ROW_BG = Color.rgba(0.035, 0.065, 0.090, 0.88);
const DELETE_COLOR = Color.rgba(0.85, 0.25, 0.25, 1.0);
const CONFIRM_BG = Color.rgba(0.18, 0.10, 0.10, 0.97);
const CONFIRM_BORDER = Color.rgba(0.7, 0.2, 0.2, 1.0);
const RENAME_BG = Color.rgba(0.10, 0.14, 0.20, 0.97);
const RENAME_BORDER = Color.rgba(0.42, 0.66, 0.82, 1.0);

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

pub fn writeLevelDat(allocator: std.mem.Allocator, save_dir: fs.Dir, name: []const u8, seed: u64, generator_index: usize, last_played: i64) !void {
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

pub fn readLevelDat(allocator: std.mem.Allocator, save_dir: fs.Dir) ?LevelDat {
    const content = save_dir.readFileAlloc("level.dat", allocator, 4096) catch return null;
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

pub fn scanWorlds(allocator: std.mem.Allocator) ![]WorldEntry {
    const home = getenv("HOME") orelse return allocator.alloc(WorldEntry, 0);
    return scanWorldsInHome(allocator, home);
}

pub fn scanWorldsInHome(allocator: std.mem.Allocator, home: []const u8) ![]WorldEntry {
    var home_dir = fs.openDirAbsolute(home, .{}) catch return allocator.alloc(WorldEntry, 0);
    defer home_dir.close();
    home_dir.makePath(SAVE_DIR) catch {};
    var saves_dir = home_dir.openDir(SAVE_DIR, .{ .iterate = true }) catch return allocator.alloc(WorldEntry, 0);
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
        const level = blk: {
            var world_dir = saves_dir.openDir(entry.name, .{}) catch break :blk null;
            defer world_dir.close();
            break :blk readLevelDat(allocator, world_dir);
        };
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
    const parent_path = fs.path.dirname(dir_path) orelse return;
    const base = fs.path.basename(dir_path);
    var parent = fs.openDirAbsolute(parent_path, .{ .iterate = true }) catch |err| {
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
    worlds: []WorldEntry,
    selected: ?usize,
    scroll_offset: f32,
    confirm_delete: bool,
    confirm_clear_all: bool,
    confirm_rename: bool,
    rename_buffer: std.ArrayListUnmanaged(u8),
    rename_focused: bool,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*WorldListScreen {
        const self = try allocator.create(WorldListScreen);
        errdefer allocator.destroy(self);
        const worlds = scanWorlds(allocator) catch try allocator.alloc(WorldEntry, 0);
        self.* = .{
            .context = context,
            .worlds = worlds,
            .selected = null,
            .scroll_offset = 0.0,
            .confirm_delete = false,
            .confirm_clear_all = false,
            .confirm_rename = false,
            .rename_buffer = std.ArrayListUnmanaged(u8).empty,
            .rename_focused = false,
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
        self.rename_buffer.deinit(self.context.allocator);
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;
        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            if (self.confirm_rename) {
                self.confirm_rename = false;
                self.rename_buffer.clearRetainingCapacity();
            } else if (self.confirm_delete) {
                self.confirm_delete = false;
            } else if (self.confirm_clear_all) {
                self.confirm_clear_all = false;
            } else {
                self.context.screen_manager.popScreen();
            }
        }
        if (self.confirm_rename and self.rename_focused) {
            try handleTextTyping(&self.rename_buffer, self.context.allocator, self.context.input, 32);
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
        const title_scale: f32 = 3.0 * ui_scale;
        const label_scale: f32 = 1.55 * ui_scale;
        const btn_scale: f32 = 1.45 * ui_scale;
        const row_scale: f32 = 1.45 * ui_scale;
        const pw: f32 = @min(screen_w * 0.85, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = @min(screen_h - 80.0 * ui_scale, PANEL_HEIGHT_BASE * ui_scale);
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = (screen_h - ph) * 0.5;
        const modal_open = self.confirm_delete or self.confirm_clear_all or self.confirm_rename;
        drawListBackdrop(ui, screen_w, screen_h, ui_scale);
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRect(.{ .x = px, .y = py, .width = 7.0 * ui_scale, .height = ph }, Color.rgba(0.95, 0.62, 0.24, 0.95));
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = 72.0 * ui_scale }, Color.rgba(0.12, 0.22, 0.30, 0.64));
        ui.drawRect(.{ .x = px + pw - 2.0 * ui_scale, .y = py, .width = 2.0 * ui_scale, .height = ph }, Color.rgba(0.48, 0.76, 0.93, 0.62));
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawText(ui, "LOAD WORLD", px + 34.0 * ui_scale, py + 24.0 * ui_scale, title_scale, TITLE_COLOR);
        Font.drawText(ui, "Select a saved world snapshot.", px + 38.0 * ui_scale, py + 56.0 * ui_scale, 1.05 * ui_scale, MUTED_COLOR);
        var count_buf: [64]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_buf, "{} WORLDS", .{self.worlds.len}) catch "?";
        const count_w = Font.measureTextWidth(count_text, 1.05 * ui_scale);
        Font.drawText(ui, count_text, px + pw - 34.0 * ui_scale - count_w, py + 56.0 * ui_scale, 1.05 * ui_scale, MUTED_COLOR);
        const scroll_dy = ctx.input.getScrollDelta().y;
        self.scroll_offset -= scroll_dy * 30.0 * ui_scale;
        const list_top: f32 = py + 92.0 * ui_scale;
        const list_bottom: f32 = py + ph - 100.0 * ui_scale;
        const row_h: f32 = 55.0 * ui_scale;
        const max_scroll = @max(0.0, @as(f32, @floatFromInt(self.worlds.len)) * row_h - (list_bottom - list_top));
        self.scroll_offset = @max(0.0, @min(self.scroll_offset, max_scroll));
        ui.drawRect(.{ .x = px + 18.0 * ui_scale, .y = list_top, .width = pw - 36.0 * ui_scale, .height = list_bottom - list_top }, Color.rgba(0.010, 0.020, 0.030, 0.54));
        ui.drawRectOutline(.{ .x = px + 18.0 * ui_scale, .y = list_top, .width = pw - 36.0 * ui_scale, .height = list_bottom - list_top }, Color.rgba(0.20, 0.36, 0.48, 0.72), 1.0 * ui_scale);
        if (self.worlds.len == 0) {
            Font.drawTextCentered(ui, "NO SAVED WORLDS FOUND", screen_w * 0.5, list_top + (list_bottom - list_top) * 0.4, label_scale, LABEL_COLOR);
            Font.drawTextCentered(ui, "CREATE A NEW WORLD FIRST", screen_w * 0.5, list_top + (list_bottom - list_top) * 0.4 + 25.0 * ui_scale, label_scale * 0.7, MUTED_COLOR);
        }
        var i: usize = 0;
        while (i < self.worlds.len) : (i += 1) {
            const ry: f32 = list_top + @as(f32, @floatFromInt(i)) * row_h - self.scroll_offset;
            if (ry + row_h < list_top or ry > list_bottom) continue;
            const world = self.worlds[i];
            const row_rect = Rect{ .x = px + 26.0 * ui_scale, .y = ry, .width = pw - 52.0 * ui_scale, .height = row_h - 5.0 * ui_scale };
            const row_hovered = row_rect.contains(mx, my);
            const is_selected = self.selected == i;
            if (is_selected) {
                ui.drawRect(row_rect, SELECTED_BG);
            } else if (row_hovered) {
                ui.drawRect(row_rect, ROW_HOVER_BG);
            } else {
                ui.drawRect(row_rect, ROW_BG);
            }
            ui.drawRect(.{ .x = row_rect.x, .y = row_rect.y, .width = 4.0 * ui_scale, .height = row_rect.height }, if (is_selected) Color.rgba(0.95, 0.62, 0.24, 0.95) else Color.rgba(0.30, 0.50, 0.64, 0.64));
            ui.drawRectOutline(row_rect, if (is_selected) Color.rgba(0.70, 0.92, 1.0, 1.0) else Color.rgba(0.20, 0.36, 0.48, 0.74), 1.0);
            if (mc and row_hovered and !modal_open) {
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
            Font.drawText(ui, last_text, text_x + seed_w + 15.0 * ui_scale, name_y + 18.0 * ui_scale, row_scale * 0.65, MUTED_COLOR);
        }
        // Bottom buttons: BACK, LOAD, RENAME, DELETE, CLEAR ALL
        const btn_h: f32 = 44.0 * ui_scale;
        const byy: f32 = py + ph - 68.0 * ui_scale;
        const btn_gap: f32 = 10.0 * ui_scale;
        const btn_w: f32 = (pw - 20.0 * ui_scale - 4.0 * btn_gap) / 5.0;
        const bx_base: f32 = px + 10.0 * ui_scale;
        // BACK
        if (Widgets.drawButton(ui, .{ .x = bx_base, .y = byy, .width = btn_w, .height = btn_h }, "BACK", btn_scale, mx, my, mc)) {
            ctx.screen_manager.popScreen();
        }
        // LOAD
        const load_enabled = self.selected != null and !modal_open;
        if (!load_enabled) {
            ui.drawRect(.{ .x = bx_base + btn_w + btn_gap, .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.1, 0.12, 0.16, 0.7));
            ui.drawRectOutline(.{ .x = bx_base + btn_w + btn_gap, .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.2, 0.22, 0.26, 1.0), 2.0);
            Font.drawTextCentered(ui, "LOAD", bx_base + btn_w + btn_gap + btn_w * 0.5, byy + (btn_h - 7.0 * btn_scale) * 0.5, btn_scale, Color.rgba(0.4, 0.42, 0.46, 1.0));
        } else {
            if (Widgets.drawButton(ui, .{ .x = bx_base + btn_w + btn_gap, .y = byy, .width = btn_w, .height = btn_h }, "LOAD", btn_scale, mx, my, mc)) {
                if (self.selected) |idx| {
                    try self.loadWorld(idx);
                }
            }
        }
        // RENAME
        const rename_enabled = self.selected != null and !modal_open;
        if (!rename_enabled) {
            ui.drawRect(.{ .x = bx_base + 2.0 * (btn_w + btn_gap), .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.1, 0.12, 0.16, 0.7));
            ui.drawRectOutline(.{ .x = bx_base + 2.0 * (btn_w + btn_gap), .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.2, 0.22, 0.26, 1.0), 2.0);
            Font.drawTextCentered(ui, "RENAME", bx_base + 2.0 * (btn_w + btn_gap) + btn_w * 0.5, byy + (btn_h - 7.0 * btn_scale) * 0.5, btn_scale, Color.rgba(0.4, 0.42, 0.46, 1.0));
        } else {
            if (Widgets.drawButton(ui, .{ .x = bx_base + 2.0 * (btn_w + btn_gap), .y = byy, .width = btn_w, .height = btn_h }, "RENAME", btn_scale, mx, my, mc)) {
                if (self.selected) |idx| {
                    self.rename_buffer.clearRetainingCapacity();
                    try self.rename_buffer.appendSlice(self.context.allocator, self.worlds[idx].name);
                    self.confirm_rename = true;
                    self.rename_focused = true;
                }
            }
        }
        // DELETE
        const del_enabled = self.selected != null and !modal_open;
        if (!del_enabled) {
            ui.drawRect(.{ .x = bx_base + 3.0 * (btn_w + btn_gap), .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.1, 0.1, 0.12, 0.7));
            ui.drawRectOutline(.{ .x = bx_base + 3.0 * (btn_w + btn_gap), .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.2, 0.2, 0.22, 1.0), 2.0);
            Font.drawTextCentered(ui, "DELETE", bx_base + 3.0 * (btn_w + btn_gap) + btn_w * 0.5, byy + (btn_h - 7.0 * btn_scale) * 0.5, btn_scale, Color.rgba(0.4, 0.35, 0.35, 1.0));
        } else {
            if (Widgets.drawButton(ui, .{ .x = bx_base + 3.0 * (btn_w + btn_gap), .y = byy, .width = btn_w, .height = btn_h }, "DELETE", btn_scale, mx, my, mc)) {
                self.confirm_delete = true;
            }
        }
        // CLEAR ALL
        const clear_enabled = self.worlds.len > 0 and !modal_open;
        if (!clear_enabled) {
            ui.drawRect(.{ .x = bx_base + 4.0 * (btn_w + btn_gap), .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.1, 0.1, 0.12, 0.7));
            ui.drawRectOutline(.{ .x = bx_base + 4.0 * (btn_w + btn_gap), .y = byy, .width = btn_w, .height = btn_h }, Color.rgba(0.2, 0.2, 0.22, 1.0), 2.0);
            Font.drawTextCentered(ui, "CLEAR ALL", bx_base + 4.0 * (btn_w + btn_gap) + btn_w * 0.5, byy + (btn_h - 7.0 * btn_scale) * 0.5, btn_scale, Color.rgba(0.4, 0.35, 0.35, 1.0));
        } else {
            if (Widgets.drawButton(ui, .{ .x = bx_base + 4.0 * (btn_w + btn_gap), .y = byy, .width = btn_w, .height = btn_h }, "CLEAR ALL", btn_scale, mx, my, mc)) {
                self.confirm_clear_all = true;
            }
        }
        // Delete confirmation dialog
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
        // Clear all confirmation dialog
        if (self.confirm_clear_all) {
            const cw: f32 = 460.0 * ui_scale;
            const ch: f32 = 170.0 * ui_scale;
            const cx: f32 = (screen_w - cw) * 0.5;
            const cy: f32 = (screen_h - ch) * 0.5;
            ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.6));
            ui.drawRect(.{ .x = cx, .y = cy, .width = cw, .height = ch }, CONFIRM_BG);
            ui.drawRectOutline(.{ .x = cx, .y = cy, .width = cw, .height = ch }, CONFIRM_BORDER, 2.0);
            const msg_scale: f32 = 1.8 * ui_scale;
            Font.drawTextCentered(ui, "CLEAR ALL WORLDS?", cx + cw * 0.5, cy + 20.0 * ui_scale, msg_scale, DELETE_COLOR);
            var count_buf2: [64]u8 = undefined;
            const count_msg = std.fmt.bufPrint(&count_buf2, "THIS WILL DELETE {} WORLDS", .{self.worlds.len}) catch "?";
            Font.drawTextCentered(ui, count_msg, cx + cw * 0.5, cy + 50.0 * ui_scale, msg_scale * 0.75, LABEL_COLOR);
            Font.drawTextCentered(ui, "THIS CANNOT BE UNDONE", cx + cw * 0.5, cy + 72.0 * ui_scale, msg_scale * 0.65, Color.rgba(0.7, 0.5, 0.5, 1.0));
            const cbw: f32 = (cw - 30.0 * ui_scale) / 2.0;
            const cby: f32 = cy + ch - 55.0 * ui_scale;
            if (Widgets.drawButton(ui, .{ .x = cx + 10.0 * ui_scale, .y = cby, .width = cbw, .height = 40.0 * ui_scale }, "CANCEL", btn_scale, mx, my, mc)) {
                self.confirm_clear_all = false;
            }
            if (Widgets.drawButton(ui, .{ .x = cx + cbw + 20.0 * ui_scale, .y = cby, .width = cbw, .height = 40.0 * ui_scale }, "CONFIRM", btn_scale, mx, my, mc)) {
                self.clearAllWorlds() catch {};
            }
        }
        // Rename dialog
        if (self.confirm_rename) {
            if (self.selected) |idx| {
                const cw: f32 = 460.0 * ui_scale;
                const ch: f32 = 180.0 * ui_scale;
                const cx: f32 = (screen_w - cw) * 0.5;
                const cy: f32 = (screen_h - ch) * 0.5;
                ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0, 0, 0, 0.6));
                ui.drawRect(.{ .x = cx, .y = cy, .width = cw, .height = ch }, RENAME_BG);
                ui.drawRectOutline(.{ .x = cx, .y = cy, .width = cw, .height = ch }, RENAME_BORDER, 2.0);
                const msg_scale: f32 = 1.8 * ui_scale;
                Font.drawTextCentered(ui, "RENAME WORLD", cx + cw * 0.5, cy + 20.0 * ui_scale, msg_scale, TITLE_COLOR);
                var name_buf2: [128]u8 = undefined;
                const current_msg = std.fmt.bufPrint(&name_buf2, "CURRENT: '{s}'", .{self.worlds[idx].name}) catch "'?'";
                Font.drawTextCentered(ui, current_msg, cx + cw * 0.5, cy + 48.0 * ui_scale, msg_scale * 0.7, MUTED_COLOR);
                const input_h: f32 = 40.0 * ui_scale;
                const input_y: f32 = cy + 72.0 * ui_scale;
                const input_rect = Rect{ .x = cx + 20.0 * ui_scale, .y = input_y, .width = cw - 40.0 * ui_scale, .height = input_h };
                const cursor_visible = @as(u32, @truncate(@as(u64, @intFromFloat(ctx.time.elapsed * 2.0)))) % 2 == 0;
                if (mc) {
                    self.rename_focused = input_rect.contains(mx, my);
                }
                Widgets.drawTextInput(ui, input_rect, self.rename_buffer.items, "ENTER NEW NAME", 1.4 * ui_scale, self.rename_focused, cursor_visible);
                const cbw: f32 = (cw - 30.0 * ui_scale) / 2.0;
                const cby: f32 = cy + ch - 55.0 * ui_scale;
                if (Widgets.drawButton(ui, .{ .x = cx + 10.0 * ui_scale, .y = cby, .width = cbw, .height = 40.0 * ui_scale }, "CANCEL", btn_scale, mx, my, mc)) {
                    self.confirm_rename = false;
                    self.rename_buffer.clearRetainingCapacity();
                }
                if (Widgets.drawButton(ui, .{ .x = cx + cbw + 20.0 * ui_scale, .y = cby, .width = cbw, .height = 40.0 * ui_scale }, "OK", btn_scale, mx, my, mc)) {
                    self.renameWorld(idx) catch {};
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
        const old_worlds = self.worlds;
        const empty_worlds = try allocator.alloc(WorldEntry, 0);
        self.worlds = empty_worlds;
        for (old_worlds, 0..) |e, i| {
            allocator.free(e.name);
            if (i != idx and e.dir_path.len > 0) allocator.free(e.dir_path);
        }
        allocator.free(old_worlds);
        if (scanWorlds(allocator)) |new_worlds| {
            allocator.free(empty_worlds);
            self.worlds = new_worlds;
        } else |_| {}
        self.selected = null;
        self.confirm_delete = false;
        self.scroll_offset = 0.0;
    }

    fn renameWorld(self: *@This(), idx: usize) !void {
        const allocator = self.context.allocator;
        if (self.rename_buffer.items.len == 0) return;
        const world = self.worlds[idx];
        var save_dir = fs.openDirAbsolute(world.dir_path, .{}) catch return;
        defer save_dir.close();
        writeLevelDat(allocator, save_dir, self.rename_buffer.items, world.seed, world.generator_index, world.last_played) catch |err| {
            log.log.warn("Failed to write level.dat for rename: {}", .{err});
            return;
        };
        const new_name = try allocator.dupe(u8, self.rename_buffer.items);
        allocator.free(self.worlds[idx].name);
        self.worlds[idx].name = new_name;
        self.confirm_rename = false;
        self.rename_buffer.clearRetainingCapacity();
    }

    fn clearAllWorlds(self: *@This()) !void {
        const allocator = self.context.allocator;
        for (self.worlds) |e| {
            deleteWorld(allocator, e.dir_path);
            allocator.free(e.name);
        }
        allocator.free(self.worlds);
        self.worlds = try allocator.alloc(WorldEntry, 0);
        self.selected = null;
        self.confirm_clear_all = false;
        self.scroll_offset = 0.0;
    }
};

fn handleTextTyping(text_input: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, input: IRawInputProvider, max_len: usize) !void {
    if (input.isKeyPressed(.backspace)) {
        if (text_input.items.len > 0) _ = text_input.pop();
    }
    const shift = input.isKeyDown(.left_shift) or input.isKeyDown(.right_shift);
    const letters = [_]Key{ .a, .b, .c, .d, .e, .f, .g, .h, .i, .j, .k, .l, .m, .n, .o, .p, .q, .r, .s, .t, .u, .v, .w, .x, .y, .z };
    inline for (letters) |key| if (input.isKeyPressed(key) and text_input.items.len < max_len) {
        var ch: u8 = @intCast(@intFromEnum(key));
        if (shift) ch = std.ascii.toUpper(ch);
        try text_input.append(allocator, ch);
    };
    const digits = [_]Key{ .@"0", .@"1", .@"2", .@"3", .@"4", .@"5", .@"6", .@"7", .@"8", .@"9" };
    inline for (digits) |key| if (input.isKeyPressed(key) and text_input.items.len < max_len) try text_input.append(allocator, @intCast(@intFromEnum(key)));
    if (input.isKeyPressed(.space) and text_input.items.len < max_len) try text_input.append(allocator, ' ');
}

fn drawListBackdrop(ui: *UISystem, screen_w: f32, screen_h: f32, ui_scale: f32) void {
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0.010, 0.018, 0.030, 0.90));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.64, .width = screen_w, .height = screen_h * 0.36 }, Color.rgba(0.075, 0.048, 0.028, 0.64));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.64, .width = screen_w, .height = 2.0 * ui_scale }, Color.rgba(0.92, 0.62, 0.24, 0.48));
    ui.drawRect(.{ .x = 42.0 * ui_scale, .y = screen_h * 0.64 - 86.0 * ui_scale, .width = 94.0 * ui_scale, .height = 86.0 * ui_scale }, Color.rgba(0.07, 0.14, 0.15, 0.32));
    ui.drawRect(.{ .x = screen_w - 156.0 * ui_scale, .y = screen_h * 0.64 - 124.0 * ui_scale, .width = 104.0 * ui_scale, .height = 124.0 * ui_scale }, Color.rgba(0.50, 0.29, 0.12, 0.34));
}

fn formatTimestamp(ts: i64) []const u8 {
    if (ts <= 0) return "NEVER";
    const now = std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
    const diff = now - ts;
    if (diff < 0) return "NEVER";
    if (diff < 60000) return "JUST NOW";
    if (diff < 3600000) return "EARLIER";
    if (diff < 86400000) return "TODAY";
    if (diff < 172800000) return "YESTERDAY";
    return "OLDER";
}
