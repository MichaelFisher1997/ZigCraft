//! RmlUi pause overlay. The shared menu stylesheet supplies its 75% black tint.

const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const log = @import("engine-core").log;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const Page = @import("../rml_page.zig").Page;
const RmlHomeScreen = @import("rml_home.zig").RmlHomeScreen;
const RmlSettingsScreen = @import("rml_settings.zig").RmlSettingsScreen;

pub const RmlPausedScreen = struct {
    context: EngineContext,
    page: Page,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .drawBackground = drawBackground,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*RmlPausedScreen {
        const self = try allocator.create(RmlPausedScreen);
        errdefer allocator.destroy(self);

        self.* = .{ .context = context, .page = undefined };
        self.page = try Page.init(context, "assets/ui/rmlui/paused.rml", self, onDocumentAction);
        errdefer self.page.deinit();
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
        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) self.context.screen_manager.popScreen();
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.context.screen_manager.drawBackgroundFor(ptr, ui);
        self.page.draw(ui);
    }

    fn drawBackground(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        try self.context.screen_manager.drawBackgroundFor(ptr, ui);
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.onEnter();
        _ = self.page.backend.focus(self.page.document, "resume", true);
    }

    pub fn onExit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.page.onExit();
    }

    fn onDocumentAction(context: *anyopaque, _: []const u8, target_id: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        if (std.mem.eql(u8, target_id, "resume")) {
            self.context.screen_manager.popScreen();
        } else if (std.mem.eql(u8, target_id, "settings")) {
            const factory = Screen.makeScreenFactory(SettingsScreenFactory, self.context.allocator, .{ .context = self.context }) catch |err| {
                log.log.err("RmlUi pause Settings request failed: {}", .{err});
                return;
            };
            self.context.screen_manager.pushScreenFactory(factory);
        } else if (std.mem.eql(u8, target_id, "quit-to-title")) {
            const factory = Screen.makeScreenFactory(HomeScreenFactory, self.context.allocator, .{ .context = self.context }) catch |err| {
                log.log.err("RmlUi pause Quit to Title request failed: {}", .{err});
                return;
            };
            self.context.screen_manager.setScreenFactory(factory);
        }
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

const SettingsScreenFactory = struct {
    context: EngineContext,

    pub fn construct(self: *@This()) !IScreen {
        const settings_screen = try RmlSettingsScreen.init(self.context.allocator, self.context);
        return settings_screen.screen();
    }
};

const HomeScreenFactory = struct {
    context: EngineContext,

    pub fn construct(self: *@This()) !IScreen {
        const home_screen = try RmlHomeScreen.init(self.context.allocator, self.context);
        return home_screen.screen();
    }
};
