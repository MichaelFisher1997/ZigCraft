//! RmlUi resource-pack picker with immediate atlas reloads.

const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const log = @import("engine-core").log;
const TextureAtlas = @import("engine-graphics").TextureAtlas;
const BLOCK_TEXTURE_DEFINITIONS = @import("game-core").BLOCK_TEXTURE_DEFINITIONS;
const settings_pkg = @import("game-core").settings;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const ResourcePacksContext = Screen.ResourcePacksContext;
const Page = @import("../rml_page.zig").Page;
const markup = @import("../rml_markup.zig");

pub const RmlResourcePacksScreen = struct {
    context: ResourcePacksContext,
    page: Page,
    status: []const u8 = "READY",

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*RmlResourcePacksScreen {
        const self = try allocator.create(RmlResourcePacksScreen);
        errdefer allocator.destroy(self);

        self.* = .{ .context = context.resourcePacksContext(), .page = undefined };
        self.page = try Page.init(context, "assets/ui/rmlui/resource_packs.rml", self, onDocumentAction);
        errdefer self.page.deinit();
        try self.render();
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.deinit();
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
        } else if (std.mem.eql(u8, target_id, "pack-default")) {
            self.selectPack("default") catch |err| self.reportFailure("Resource pack change failed", err);
        } else if (std.mem.startsWith(u8, target_id, "pack-")) {
            const index = std.fmt.parseInt(usize, target_id["pack-".len..], 10) catch return;
            const packs = self.context.render_system.getResourcePackManager().getPackNames();
            if (index >= packs.len) return;
            self.selectPack(packs[index].name) catch |err| self.reportFailure("Resource pack change failed", err);
        }
    }

    fn selectPack(self: *@This(), name: []const u8) !void {
        if (std.mem.eql(u8, self.context.settings.texture_pack, name)) return;

        self.status = "RELOADING TEXTURE ATLAS...";
        try self.activatePack(name);
        self.context.saveSettings();
        self.status = "TEXTURE PACK RELOADED AND SAVED";
        try self.render();
    }

    fn activatePack(self: *@This(), name: []const u8) !void {
        const previous_name = try self.context.allocator.dupe(u8, self.context.settings.texture_pack);
        defer self.context.allocator.free(previous_name);
        try settings_pkg.persistence.setTexturePack(self.context.settings, self.context.allocator, name);
        errdefer settings_pkg.persistence.setTexturePack(self.context.settings, self.context.allocator, previous_name) catch |err| {
            log.log.err("Failed to restore resource pack setting: {}", .{err});
        };
        try self.context.render_system.getResourcePackManager().setActivePack(name);
        errdefer self.context.render_system.getResourcePackManager().setActivePack(previous_name) catch |err| {
            log.log.err("Failed to restore active resource pack: {}", .{err});
        };
        try self.reloadAtlas();
    }

    fn reloadAtlas(self: *@This()) !void {
        const render_system = self.context.render_system;
        const rhi = render_system.getRHI();
        var replacement = try TextureAtlas.init(
            self.context.allocator,
            rhi.resourceManager(),
            render_system.getResourcePackManager(),
            self.context.settings.max_texture_resolution,
            &BLOCK_TEXTURE_DEFINITIONS,
        );
        errdefer replacement.deinit();

        rhi.waitIdle();
        render_system.getAtlas().deinit();
        render_system.getAtlas().* = replacement;
    }

    fn back(self: *@This()) void {
        self.context.saveSettings();
        self.context.screen_manager.popScreen();
    }

    fn reportFailure(self: *@This(), message: []const u8, err: anyerror) void {
        log.log.err("{s}: {}", .{ message, err });
        self.status = "CHANGE FAILED — SEE LOG";
        self.render() catch |render_err| log.log.err("Failed to refresh RmlUi resource packs: {}", .{render_err});
    }

    fn render(self: *@This()) !void {
        var rows = std.ArrayList(u8).empty;
        defer rows.deinit(self.context.allocator);

        try appendRow(&rows, self.context.allocator, "pack-default", "DEFAULT / BUILT-IN", "Base texture atlas shipped with ZigCraft.", std.mem.eql(u8, self.context.settings.texture_pack, "default"));
        for (self.context.render_system.getResourcePackManager().getPackNames(), 0..) |pack, index| {
            var id_buffer: [48]u8 = undefined;
            const id = try std.fmt.bufPrint(&id_buffer, "pack-{}", .{index});
            try appendRow(&rows, self.context.allocator, id, pack.name, "External pack discovered by the resource manager.", std.mem.eql(u8, self.context.settings.texture_pack, pack.name));
        }

        const row_rml = try markup.sentinel(&rows, self.context.allocator);
        if (!self.page.backend.setInnerRml(self.page.document, "pack-list", row_rml)) return error.RmlUiElementNotFound;

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
