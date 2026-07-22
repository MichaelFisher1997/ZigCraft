const std = @import("std");
const core_interfaces = @import("engine-core").interfaces;
const UISystem = @import("engine-ui").UISystem;
const IRawInputProvider = @import("engine-input").IRawInputProvider;
const input_mapper_pkg = @import("game-core").input_mapper;
const IInputMapper = input_mapper_pkg.IInputMapper;
const Time = @import("engine-core").Time;
const WindowManager = @import("engine-core").WindowManager;
const RenderSystem = @import("engine-graphics").RenderSystem;
const AudioSystem = @import("engine-audio").AudioSystem;
const UISystemManager = @import("engine-ui").UISystemManager;
const WorldStats = @import("engine-ui").WorldStats;
const IRenderSettings = core_interfaces.IRenderSettings;
const settings_pkg = @import("game-core").settings;
const Settings = settings_pkg.Settings;
const BenchmarkRunner = @import("game-core").BenchmarkRunner;
const BuildConfig = @import("game-core").BuildConfig;

pub const EngineContext = struct {
    allocator: std.mem.Allocator,
    window_manager: *WindowManager,
    render_system: *RenderSystem,
    audio_system: *AudioSystem,
    ui_manager: *UISystemManager,
    settings: *Settings,
    input: IRawInputProvider,
    input_mapper: IInputMapper,
    time: *Time,
    screen_manager: *ScreenManager,
    skip_world_update: bool,
    render_settings: IRenderSettings,
    benchmark_runner: ?*BenchmarkRunner = null,
    build_config: BuildConfig = .{},

    pub fn saveSettings(self: EngineContext) void {
        saveSettingsShared(self.allocator, self.settings, self.input_mapper);
    }

    pub fn menuContext(self: EngineContext) MenuContext {
        return .{
            .allocator = self.allocator,
            .window_manager = self.window_manager,
            .settings = self.settings,
            .input = self.input,
            .input_mapper = self.input_mapper,
            .time = self.time,
            .screen_manager = self.screen_manager,
        };
    }

    pub fn settingsContext(self: EngineContext) SettingsContext {
        return .{
            .allocator = self.allocator,
            .window_manager = self.window_manager,
            .settings = self.settings,
            .input = self.input,
            .input_mapper = self.input_mapper,
            .screen_manager = self.screen_manager,
            .render_settings = self.render_settings,
        };
    }

    pub fn environmentContext(self: EngineContext) EnvironmentContext {
        return .{
            .allocator = self.allocator,
            .window_manager = self.window_manager,
            .render_system = self.render_system,
            .settings = self.settings,
            .input = self.input,
            .input_mapper = self.input_mapper,
            .screen_manager = self.screen_manager,
        };
    }

    pub fn resourcePacksContext(self: EngineContext) ResourcePacksContext {
        return .{
            .allocator = self.allocator,
            .window_manager = self.window_manager,
            .render_system = self.render_system,
            .settings = self.settings,
            .input = self.input,
            .input_mapper = self.input_mapper,
            .screen_manager = self.screen_manager,
        };
    }

    pub fn worldContext(self: EngineContext) WorldContext {
        return .{
            .allocator = self.allocator,
            .window_manager = self.window_manager,
            .render_system = self.render_system,
            .audio_system = self.audio_system,
            .ui_manager = self.ui_manager,
            .settings = self.settings,
            .input = self.input,
            .input_mapper = self.input_mapper,
            .time = self.time,
            .screen_manager = self.screen_manager,
            .skip_world_update = self.skip_world_update,
            .benchmark_runner = self.benchmark_runner,
            .build_config = self.build_config,
        };
    }
};

pub const MenuContext = struct {
    allocator: std.mem.Allocator,
    window_manager: *WindowManager,
    settings: *Settings,
    input: IRawInputProvider,
    input_mapper: IInputMapper,
    time: *Time,
    screen_manager: *ScreenManager,
};

pub const SettingsContext = struct {
    allocator: std.mem.Allocator,
    window_manager: *WindowManager,
    settings: *Settings,
    input: IRawInputProvider,
    input_mapper: IInputMapper,
    screen_manager: *ScreenManager,
    render_settings: IRenderSettings,

    pub fn saveSettings(self: SettingsContext) void {
        saveSettingsShared(self.allocator, self.settings, self.input_mapper);
    }
};

pub const EnvironmentContext = struct {
    allocator: std.mem.Allocator,
    window_manager: *WindowManager,
    render_system: *RenderSystem,
    settings: *Settings,
    input: IRawInputProvider,
    input_mapper: IInputMapper,
    screen_manager: *ScreenManager,

    pub fn saveSettings(self: EnvironmentContext) void {
        saveSettingsShared(self.allocator, self.settings, self.input_mapper);
    }
};

pub const ResourcePacksContext = struct {
    allocator: std.mem.Allocator,
    window_manager: *WindowManager,
    render_system: *RenderSystem,
    settings: *Settings,
    input: IRawInputProvider,
    input_mapper: IInputMapper,
    screen_manager: *ScreenManager,

    pub fn saveSettings(self: ResourcePacksContext) void {
        saveSettingsShared(self.allocator, self.settings, self.input_mapper);
    }
};

pub const WorldContext = struct {
    allocator: std.mem.Allocator,
    window_manager: *WindowManager,
    render_system: *RenderSystem,
    audio_system: *AudioSystem,
    ui_manager: *UISystemManager,
    settings: *Settings,
    input: IRawInputProvider,
    input_mapper: IInputMapper,
    time: *Time,
    screen_manager: *ScreenManager,
    skip_world_update: bool,
    benchmark_runner: ?*BenchmarkRunner = null,
    build_config: BuildConfig = .{},
};

fn saveSettingsShared(allocator: std.mem.Allocator, settings: *Settings, input_mapper: IInputMapper) void {
    settings_pkg.persistence.save(settings, allocator) catch |err| {
        @import("engine-core").log.log.err("Failed to save game settings: {}", .{err});
    };
    @import("game-core").InputSettings.saveFromMapper(allocator, input_mapper) catch |err| {
        @import("engine-core").log.log.err("Failed to save input settings: {}", .{err});
    };
}

pub const IScreen = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        update: ?*const fn (ptr: *anyopaque, dt: f32) anyerror!void = null,
        draw: ?*const fn (ptr: *anyopaque, ui: *UISystem) anyerror!void = null,
        drawBackground: ?*const fn (ptr: *anyopaque, ui: *UISystem) anyerror!void = null,
        onEnter: ?*const fn (ptr: *anyopaque) void = null,
        onExit: ?*const fn (ptr: *anyopaque) void = null,
        getWorldStats: ?*const fn (ptr: *anyopaque) ?WorldStats = null,
        isReadyForPresentation: ?*const fn (ptr: *anyopaque) bool = null,
    };

    pub fn deinit(self: IScreen) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn update(self: IScreen, dt: f32) !void {
        if (self.vtable.update) |update_fn| {
            try update_fn(self.ptr, dt);
        }
    }

    pub fn draw(self: IScreen, ui: *UISystem) !void {
        if (self.vtable.draw) |draw_fn| {
            try draw_fn(self.ptr, ui);
        }
    }

    pub fn drawBackground(self: IScreen, ui: *UISystem) !bool {
        if (self.vtable.drawBackground) |draw_fn| {
            try draw_fn(self.ptr, ui);
            return true;
        }
        return false;
    }

    pub fn onEnter(self: IScreen) void {
        if (self.vtable.onEnter) |onEnter_fn| {
            onEnter_fn(self.ptr);
        }
    }

    pub fn onExit(self: IScreen) void {
        if (self.vtable.onExit) |onExit_fn| {
            onExit_fn(self.ptr);
        }
    }

    pub fn getWorldStats(self: IScreen) ?WorldStats {
        if (self.vtable.getWorldStats) |getStats_fn| {
            return getStats_fn(self.ptr);
        }
        return null;
    }

    pub fn isReadyForPresentation(self: IScreen) bool {
        if (self.vtable.isReadyForPresentation) |ready_fn| {
            return ready_fn(self.ptr);
        }
        return true;
    }

    pub fn handle(self: IScreen) core_interfaces.ScreenHandle {
        return .{
            .ptr = self.ptr,
            .vtable = self.vtable,
        };
    }
};

/// Owns the copied inputs needed to construct a screen at a GPU frame boundary.
/// Screen constructors may allocate RmlUi documents, textures, buffers, or a
/// complete world, so input and draw callbacks must queue one of these instead
/// of constructing the replacement while command recording is active.
pub const ScreenFactory = struct {
    ptr: *anyopaque,
    construct_fn: *const fn (ptr: *anyopaque) anyerror!IScreen,
    deinit_fn: *const fn (ptr: *anyopaque) void,

    pub fn construct(self: ScreenFactory) !IScreen {
        return self.construct_fn(self.ptr);
    }

    pub fn deinit(self: ScreenFactory) void {
        self.deinit_fn(self.ptr);
    }
};

/// Allocates an owned factory payload. `T.construct` must copy everything the
/// returned screen retains; the payload is destroyed immediately after the
/// boundary-time constructor returns.
pub fn makeScreenFactory(comptime T: type, allocator: std.mem.Allocator, payload: T) !ScreenFactory {
    const Owned = struct {
        allocator: std.mem.Allocator,
        payload: T,
    };
    const owned = try allocator.create(Owned);
    owned.* = .{ .allocator = allocator, .payload = payload };

    const Adapter = struct {
        fn construct(ptr: *anyopaque) anyerror!IScreen {
            const self: *Owned = @ptrCast(@alignCast(ptr));
            return self.payload.construct();
        }

        fn deinit(ptr: *anyopaque) void {
            const self: *Owned = @ptrCast(@alignCast(ptr));
            if (@hasDecl(T, "deinit")) self.payload.deinit();
            self.allocator.destroy(self);
        }
    };

    return .{
        .ptr = owned,
        .construct_fn = Adapter.construct,
        .deinit_fn = Adapter.deinit,
    };
}

pub const ScreenManager = struct {
    const PendingTransition = union(enum) {
        push: IScreen,
        push_factory: ScreenFactory,
        pop: void,
        replace: IScreen,
        replace_factory: ScreenFactory,
    };

    allocator: std.mem.Allocator,
    stack: std.ArrayListUnmanaged(IScreen),
    next_screen: ?PendingTransition = null,

    pub fn init(allocator: std.mem.Allocator) ScreenManager {
        return .{
            .allocator = allocator,
            .stack = .empty,
        };
    }

    pub fn deinit(self: *ScreenManager) void {
        while (self.stack.items.len > 0) {
            const screen = self.stack.pop().?;
            screen.onExit();
            screen.deinit();
        }
        if (self.next_screen) |next| {
            discardPendingTransition(next);
        }
        self.stack.deinit(self.allocator);
    }

    pub fn pushScreen(self: *ScreenManager, screen: IScreen) void {
        self.discardPending();
        self.next_screen = .{ .push = screen };
    }

    pub fn pushScreenFactory(self: *ScreenManager, factory: ScreenFactory) void {
        self.discardPending();
        self.next_screen = .{ .push_factory = factory };
    }

    pub fn popScreen(self: *ScreenManager) void {
        self.discardPending();
        self.next_screen = .pop;
    }

    pub fn setScreen(self: *ScreenManager, screen: IScreen) void {
        self.discardPending();
        self.next_screen = .{ .replace = screen };
    }

    pub fn setScreenFactory(self: *ScreenManager, factory: ScreenFactory) void {
        self.discardPending();
        self.next_screen = .{ .replace_factory = factory };
    }

    pub fn hasPendingTransition(self: *const ScreenManager) bool {
        return self.next_screen != null;
    }

    fn discardPending(self: *ScreenManager) void {
        if (self.next_screen) |next| discardPendingTransition(next);
        self.next_screen = null;
    }

    fn discardPendingTransition(next: PendingTransition) void {
        switch (next) {
            .push, .replace => |screen| screen.deinit(),
            .push_factory, .replace_factory => |factory| factory.deinit(),
            .pop => {},
        }
    }

    /// Applies ownership-changing screen transitions. Call this only outside a
    /// recording frame. If screens own GPU resources, the caller must also wait
    /// for submitted work to complete before constructors or destructors run.
    pub fn applyPendingTransitions(self: *ScreenManager) !void {
        while (self.next_screen != null) {
            const next = self.next_screen.?;
            self.next_screen = null;
            switch (next) {
                .push => |screen| {
                    try self.applyPush(screen);
                },
                .push_factory => |factory| {
                    defer factory.deinit();
                    const screen = try factory.construct();
                    errdefer screen.deinit();
                    try self.applyPush(screen);
                },
                .pop => {
                    if (self.stack.items.len > 0) {
                        const screen = self.stack.pop().?;
                        screen.onExit();
                        screen.deinit();
                        if (self.stack.items.len > 0) {
                            self.stack.items[self.stack.items.len - 1].onEnter();
                        }
                    }
                },
                .replace => |screen| {
                    try self.applyReplace(screen);
                },
                .replace_factory => |factory| {
                    defer factory.deinit();
                    // Replacement factories commonly create a complete world.
                    // The caller has already drained GPU work, so release the
                    // old stack first instead of temporarily retaining two
                    // worlds and two sets of RmlUi resources.
                    self.clearStack();
                    const screen = try factory.construct();
                    errdefer screen.deinit();
                    try self.applyPush(screen);
                },
            }
        }
    }

    fn applyPush(self: *ScreenManager, screen: IScreen) !void {
        if (self.stack.items.len > 0) {
            self.stack.items[self.stack.items.len - 1].onExit();
        }
        try self.stack.append(self.allocator, screen);
        screen.onEnter();
    }

    fn applyReplace(self: *ScreenManager, screen: IScreen) !void {
        self.clearStack();
        try self.stack.append(self.allocator, screen);
        screen.onEnter();
    }

    fn clearStack(self: *ScreenManager) void {
        while (self.stack.items.len > 0) {
            const current = self.stack.pop().?;
            current.onExit();
            current.deinit();
        }
    }

    pub fn updateCurrent(self: *ScreenManager, dt: f32) !void {
        if (self.stack.items.len > 0) {
            try self.stack.items[self.stack.items.len - 1].update(dt);
        }
    }

    pub fn update(self: *ScreenManager, dt: f32) !void {
        try self.applyPendingTransitions();
        try self.updateCurrent(dt);
    }

    pub fn draw(self: *ScreenManager, ui: *UISystem) !void {
        if (self.stack.items.len > 0) {
            try self.stack.items[self.stack.items.len - 1].draw(ui);
        }
    }

    pub fn isReadyForPresentation(self: *const ScreenManager) bool {
        if (self.stack.items.len == 0) return false;
        return self.stack.items[self.stack.items.len - 1].isReadyForPresentation();
    }

    pub fn drawParentScreen(self: *ScreenManager, current_ptr: *anyopaque, ui: *UISystem) !void {
        for (self.stack.items, 0..) |screen, i| {
            if (screen.ptr == current_ptr) {
                if (i > 0) {
                    try self.stack.items[i - 1].draw(ui);
                }
                return;
            }
        }
    }

    /// Draws the nearest background provider below the current screen without
    /// rendering intermediate menu pages. This keeps one shared world preview
    /// behind nested menus such as Create World -> My Worlds.
    pub fn drawBackgroundFor(self: *ScreenManager, current_ptr: *anyopaque, ui: *UISystem) !void {
        for (self.stack.items, 0..) |screen, current_index| {
            if (screen.ptr != current_ptr) continue;
            var index = current_index;
            while (index > 0) {
                index -= 1;
                if (try self.stack.items[index].drawBackground(ui)) return;
            }
            return;
        }
    }

    pub fn interface(self: *ScreenManager) core_interfaces.IScreenManager {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    const VTABLE = core_interfaces.IScreenManager.VTable{
        .pushScreen = impl_pushScreen,
        .popScreen = impl_popScreen,
        .setScreen = impl_setScreen,
        .drawParentScreen = impl_drawParentScreen,
    };

    fn screenFromHandle(handle: core_interfaces.ScreenHandle) IScreen {
        return .{
            .ptr = handle.ptr,
            .vtable = @ptrCast(@alignCast(handle.vtable)),
        };
    }

    fn impl_pushScreen(ptr: *anyopaque, screen: core_interfaces.ScreenHandle) void {
        const self: *ScreenManager = @ptrCast(@alignCast(ptr));
        self.pushScreen(screenFromHandle(screen));
    }

    fn impl_popScreen(ptr: *anyopaque) void {
        const self: *ScreenManager = @ptrCast(@alignCast(ptr));
        self.popScreen();
    }

    fn impl_setScreen(ptr: *anyopaque, screen: core_interfaces.ScreenHandle) void {
        const self: *ScreenManager = @ptrCast(@alignCast(ptr));
        self.setScreen(screenFromHandle(screen));
    }

    fn impl_drawParentScreen(ptr: *anyopaque, current_ptr: *anyopaque, ui: *anyopaque) !void {
        const self: *ScreenManager = @ptrCast(@alignCast(ptr));
        const typed_ui: *UISystem = @ptrCast(@alignCast(ui));
        try self.drawParentScreen(current_ptr, typed_ui);
    }
};

pub fn makeScreen(comptime T: type, ptr: *T) IScreen {
    return .{
        .ptr = ptr,
        .vtable = &T.vtable,
    };
}
