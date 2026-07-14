//! RmlUi environment-map picker with immediate lighting reloads.

const std = @import("std");
const fs = @import("fs");
const UISystem = @import("engine-ui").UISystem;
const log = @import("engine-core").log;
const Texture = @import("engine-rhi").Texture;
const settings_pkg = @import("game-core").settings;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const EnvironmentContext = Screen.EnvironmentContext;
const Page = @import("../rml_page.zig").Page;
const markup = @import("../rml_markup.zig");

pub const RmlEnvironmentScreen = struct {
    context: EnvironmentContext,
    page: Page,
    environment_maps: std.ArrayListUnmanaged([]const u8) = .empty,
    status: []const u8 = "READY",

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*RmlEnvironmentScreen {
        const self = try allocator.create(RmlEnvironmentScreen);
        errdefer allocator.destroy(self);

        self.* = .{ .context = context.environmentContext(), .page = undefined };
        errdefer {
            self.clearEnvironmentMaps();
            self.environment_maps.deinit(allocator);
        }
        try self.refreshEnvironmentMaps();
        self.page = try Page.init(context, "assets/ui/rmlui/environment.rml", self, onDocumentAction);
        errdefer self.page.deinit();
        try self.render();
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.deinit();
        self.clearEnvironmentMaps();
        self.environment_maps.deinit(self.context.allocator);
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;
        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) self.back();
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.context.screen_manager.drawBackgroundFor(ptr, ui);
        self.page.draw(ui);
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.onEnter();
        self.refreshEnvironmentMaps() catch |err| {
            log.log.warn("Failed to refresh environment map list: {}", .{err});
            self.status = "FAILED TO REFRESH ENVIRONMENTS";
        };
        self.render() catch |err| log.log.err("Failed to refresh RmlUi environment: {}", .{err});
        _ = self.page.backend.focus(self.page.document, "back", false);
    }

    pub fn onExit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.onExit();
    }

    fn onDocumentAction(context: *anyopaque, _: []const u8, target_id: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, target_id, "back")) {
            self.back();
        } else if (std.mem.eql(u8, target_id, "environment-default")) {
            self.selectEnvironment("default") catch |err| self.reportFailure(err);
        } else if (std.mem.startsWith(u8, target_id, "environment-")) {
            const index = std.fmt.parseInt(usize, target_id["environment-".len..], 10) catch return;
            if (index >= self.environment_maps.items.len) return;
            self.selectEnvironment(self.environment_maps.items[index]) catch |err| self.reportFailure(err);
        }
    }

    fn selectEnvironment(self: *@This(), name: []const u8) !void {
        if (std.mem.eql(u8, self.context.settings.environment_map, name)) return;

        self.status = "RELOADING ENVIRONMENT...";
        try self.activateEnvironment(name);
        self.context.saveSettings();
        self.status = "ENVIRONMENT RELOADED AND SAVED";
        try self.render();
    }

    fn activateEnvironment(self: *@This(), name: []const u8) !void {
        var replacement = try self.loadEnvironmentMap(name);
        errdefer replacement.deinit();
        try settings_pkg.persistence.setEnvironmentMap(self.context.settings, self.context.allocator, name);

        const render_system = self.context.render_system;
        const env_ptr = render_system.getEnvMapPtr();
        render_system.getRHI().waitIdle();
        if (env_ptr.*) |*texture| texture.deinit();
        env_ptr.* = replacement;
    }

    fn loadEnvironmentMap(self: *@This(), name: []const u8) !Texture {
        const render_system = self.context.render_system;
        const rhi = render_system.getRHI();
        if (!std.mem.eql(u8, name, "default")) {
            var data = render_system.getResourcePackManager().loadImageFileFloat(name) orelse {
                log.log.warn("Could not load environment map: {s}", .{name});
                return error.InvalidEnvironmentMap;
            };
            defer data.deinit(self.context.allocator);
            const texture = try Texture.initFloat(rhi.resourceManager(), data.width, data.height, data.pixels);
            log.log.info("Loaded Environment Map: {s}", .{name});
            return texture;
        }

        const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
        return Texture.initFloat(rhi.resourceManager(), 1, 1, &white_pixel);
    }

    fn back(self: *@This()) void {
        self.context.saveSettings();
        self.context.screen_manager.popScreen();
    }

    fn reportFailure(self: *@This(), err: anyerror) void {
        log.log.err("Environment change failed: {}", .{err});
        self.status = "CHANGE FAILED — SEE LOG";
        self.render() catch |render_err| log.log.err("Failed to refresh RmlUi environment: {}", .{render_err});
    }

    fn clearEnvironmentMaps(self: *@This()) void {
        for (self.environment_maps.items) |name| self.context.allocator.free(name);
        self.environment_maps.clearRetainingCapacity();
    }

    fn refreshEnvironmentMaps(self: *@This()) !void {
        self.clearEnvironmentMaps();
        var directory = fs.cwd().openDir(".", .{ .iterate = true }) catch return;
        defer directory.close();

        var iterator = directory.iterate();
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

    fn render(self: *@This()) !void {
        var rows = std.ArrayList(u8).empty;
        defer rows.deinit(self.context.allocator);

        try appendRow(&rows, self.context.allocator, "environment-default", "DEFAULT SKY", "Neutral white environment texture.", std.mem.eql(u8, self.context.settings.environment_map, "default"));
        for (self.environment_maps.items, 0..) |name, index| {
            var id_buffer: [56]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buffer, "environment-{}", .{index});
            try appendRow(&rows, self.context.allocator, id, name, "HDR/EXR sky probe from the working directory.", std.mem.eql(u8, self.context.settings.environment_map, name));
        }

        const row_rml = try markup.sentinel(&rows, self.context.allocator);
        if (!self.page.backend.setInnerRml(self.page.document, "environment-list", row_rml)) return error.RmlUiElementNotFound;

        var status = std.ArrayList(u8).empty;
        defer status.deinit(self.context.allocator);
        try markup.appendEscaped(&status, self.context.allocator, self.status);
        const status_rml = try markup.sentinel(&status, self.context.allocator);
        if (!self.page.backend.setInnerRml(self.page.document, "status", status_rml)) return error.RmlUiElementNotFound;
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn appendRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, id: []const u8, title: []const u8, description: []const u8, active: bool) !void {
    try out.appendSlice(allocator, "<button id=\"");
    try out.appendSlice(allocator, id);
    try out.appendSlice(allocator, "\" class=\"row");
    if (active) try out.appendSlice(allocator, " selected");
    try out.appendSlice(allocator, "\"><strong>");
    try markup.appendEscaped(out, allocator, title);
    try out.appendSlice(allocator, "</strong><span>");
    try markup.appendEscaped(out, allocator, description);
    try out.appendSlice(allocator, "</span>");
    if (active) try out.appendSlice(allocator, "<em>ACTIVE</em>");
    try out.appendSlice(allocator, "</button>");
}
