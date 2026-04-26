const std = @import("std");
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;
const IRawInputProvider = @import("../engine/input/interfaces.zig").IRawInputProvider;
const input_mapper_pkg = @import("input_mapper.zig");
const IInputMapper = input_mapper_pkg.IInputMapper;
const Time = @import("../engine/core/time.zig").Time;
const WindowManager = @import("../engine/core/window.zig").WindowManager;
const RenderSystem = @import("../engine/graphics/render_system.zig").RenderSystem;
const AudioSystem = @import("../engine/audio/system.zig").AudioSystem;
const UISystemManager = @import("../engine/ui/ui_system_manager.zig").UISystemManager;
const WorldStats = @import("../engine/ui/timing_overlay.zig").WorldStats;
const IRenderSettings = @import("../engine/core/interfaces.zig").IRenderSettings;
const settings_pkg = @import("settings.zig");
const Settings = settings_pkg.Settings;
const BenchmarkRunner = @import("../benchmark.zig").BenchmarkRunner;

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
};

fn saveSettingsShared(allocator: std.mem.Allocator, settings: *Settings, input_mapper: IInputMapper) void {
    settings_pkg.persistence.save(settings, allocator);
    @import("input_settings.zig").InputSettings.saveFromMapper(allocator, input_mapper) catch |err| {
        @import("../engine/core/log.zig").log.err("Failed to save input settings: {}", .{err});
    };
}

pub const IScreen = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        deinit: *const fn (ptr: *anyopaque) void,
        update: ?*const fn (ptr: *anyopaque, dt: f32) anyerror!void = null,
        draw: ?*const fn (ptr: *anyopaque, ui: *UISystem) anyerror!void = null,
        onEnter: ?*const fn (ptr: *anyopaque) void = null,
        onExit: ?*const fn (ptr: *anyopaque) void = null,
        getWorldStats: ?*const fn (ptr: *anyopaque) ?WorldStats = null,
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
};

pub const ScreenManager = struct {
    allocator: std.mem.Allocator,
    stack: std.ArrayListUnmanaged(IScreen),
    next_screen: ?union(enum) {
        push: IScreen,
        pop: void,
        replace: IScreen,
    } = null,

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
            switch (next) {
                .push => |s| s.deinit(),
                .replace => |s| s.deinit(),
                .pop => {},
            }
        }
        self.stack.deinit(self.allocator);
    }

    pub fn pushScreen(self: *ScreenManager, screen: IScreen) void {
        if (self.next_screen) |next| {
            switch (next) {
                .push => |s| s.deinit(),
                .replace => |s| s.deinit(),
                .pop => {},
            }
        }
        self.next_screen = .{ .push = screen };
    }

    pub fn popScreen(self: *ScreenManager) void {
        if (self.next_screen) |next| {
            switch (next) {
                .push => |s| s.deinit(),
                .replace => |s| s.deinit(),
                .pop => {},
            }
        }
        self.next_screen = .pop;
    }

    pub fn setScreen(self: *ScreenManager, screen: IScreen) void {
        if (self.next_screen) |next| {
            switch (next) {
                .push => |s| s.deinit(),
                .replace => |s| s.deinit(),
                .pop => {},
            }
        }
        self.next_screen = .{ .replace = screen };
    }

    pub fn update(self: *ScreenManager, dt: f32) !void {
        while (self.next_screen != null) {
            const next = self.next_screen.?;
            self.next_screen = null;
            switch (next) {
                .push => |screen| {
                    if (self.stack.items.len > 0) {
                        self.stack.items[self.stack.items.len - 1].onExit();
                    }
                    try self.stack.append(self.allocator, screen);
                    screen.onEnter();
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
                    while (self.stack.items.len > 0) {
                        const s = self.stack.pop().?;
                        s.onExit();
                        s.deinit();
                    }
                    try self.stack.append(self.allocator, screen);
                    screen.onEnter();
                },
            }
        }

        if (self.stack.items.len > 0) {
            try self.stack.items[self.stack.items.len - 1].update(dt);
        }
    }

    pub fn draw(self: *ScreenManager, ui: *UISystem) !void {
        if (self.stack.items.len > 0) {
            try self.stack.items[self.stack.items.len - 1].draw(ui);
        }
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
};

pub fn makeScreen(comptime T: type, ptr: *T) IScreen {
    return .{
        .ptr = ptr,
        .vtable = &T.vtable,
    };
}
