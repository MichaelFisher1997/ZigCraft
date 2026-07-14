//! RmlUi menu vertical slice. It intentionally retains the deterministic menu
//! world preview from the legacy HomeScreen and composites the Rml document in
//! the existing UISystem pass.

const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const rmlui = @import("engine-ui").rmlui;
const log = @import("engine-core").log;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const SingleplayerScreen = @import("singleplayer.zig").SingleplayerScreen;
const SettingsScreen = @import("settings.zig").SettingsScreen;
const ResourcePacksScreen = @import("resource_packs.zig").ResourcePacksScreen;
const EnvironmentScreen = @import("environment.zig").EnvironmentScreen;
const WorldScreen = @import("world.zig").WorldScreen;

const MENU_PREVIEW_SEED: u64 = 0x5A49_4743_5241_4654;

pub const RmlHomeScreen = struct {
    context: EngineContext,
    preview: *WorldScreen,
    document: rmlui.Document,
    click_action: ?rmlui.Action = null,
    warned_empty_render: bool = false,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .drawBackground = drawBackground,
        .onEnter = onEnter,
        .onExit = onExit,
        .getWorldStats = getWorldStats,
        .isReadyForPresentation = isReadyForPresentation,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*RmlHomeScreen {
        const backend = context.ui_manager.getRmlUi() orelse return error.RmlUiUnavailable;
        const self = try allocator.create(RmlHomeScreen);
        errdefer allocator.destroy(self);
        const preview = try WorldScreen.initMenuPreview(allocator, context, MENU_PREVIEW_SEED, 0);
        errdefer WorldScreen.deinit(preview);
        const document = try backend.loadDocument("assets/ui/rmlui/home.rml");
        errdefer backend.closeDocument(document);

        self.* = .{ .context = context, .preview = preview, .document = document };
        backend.showDocument(document);
        self.click_action = try backend.addAction(document, "click", onDocumentAction, self);
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        if (self.context.ui_manager.getRmlUi()) |backend| {
            if (self.click_action) |action| backend.removeAction(action);
            backend.closeDocument(self.document);
        }
        WorldScreen.deinit(self.preview);
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try WorldScreen.update(self.preview, dt);
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try drawBackground(ptr, ui);

        const backend = self.context.ui_manager.getRmlUi() orelse return;
        ui.begin();
        defer ui.end();
        if (backend.updateAndRender() == 0 and !self.warned_empty_render) {
            log.log.warn("RmlUi home document produced no geometry", .{});
            self.warned_empty_render = true;
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(@ptrCast(self.context.window_manager.window), false);
        self.context.ui_manager.setRmlUiInputEnabled(true);
    }

    fn drawBackground(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try WorldScreen.draw(self.preview, ui);
    }

    pub fn onExit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.ui_manager.setRmlUiInputEnabled(false);
    }

    fn getWorldStats(ptr: *anyopaque) ?@import("engine-ui").WorldStats {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        return self.preview.getWorldStats();
    }

    fn isReadyForPresentation(ptr: *anyopaque) bool {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const stats = self.preview.getWorldStats() orelse return false;
        return stats.chunks_rendered > 0 and !self.preview.world.telemetry().isStartupBusy();
    }

    fn onDocumentAction(context: *anyopaque, _: []const u8, target_id: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, target_id, "play")) {
            const next_screen = SingleplayerScreen.init(self.context.allocator, self.context) catch |err| {
                log.log.err("RmlUi Play action failed: {}", .{err});
                return;
            };
            self.context.screen_manager.pushScreen(next_screen.screen());
        } else if (std.mem.eql(u8, target_id, "settings")) {
            const next_screen = SettingsScreen.init(self.context.allocator, self.context) catch |err| {
                log.log.err("RmlUi Settings action failed: {}", .{err});
                return;
            };
            self.context.screen_manager.pushScreen(next_screen.screen());
        } else if (std.mem.eql(u8, target_id, "resource-packs")) {
            const next_screen = ResourcePacksScreen.init(self.context.allocator, self.context) catch |err| {
                log.log.err("RmlUi Resource Packs action failed: {}", .{err});
                return;
            };
            self.context.screen_manager.pushScreen(next_screen.screen());
        } else if (std.mem.eql(u8, target_id, "environment")) {
            const next_screen = EnvironmentScreen.init(self.context.allocator, self.context) catch |err| {
                log.log.err("RmlUi Environment action failed: {}", .{err});
                return;
            };
            self.context.screen_manager.pushScreen(next_screen.screen());
        } else if (std.mem.eql(u8, target_id, "exit")) {
            self.context.input.setShouldQuit(true);
        }
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};
