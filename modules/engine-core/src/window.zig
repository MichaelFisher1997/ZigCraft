const std = @import("std");
const c = @import("c").c;
const log = @import("log.zig");

pub const WindowConfig = struct {
    monitor_index: i32 = -1,
    monitor_name: []const u8 = "",
    video_driver: []const u8 = "",
    no_focus: bool = false,
    hidden: bool = false,
};

pub const WindowManager = struct {
    window: *c.SDL_Window,
    is_vulkan: bool = true,

    pub fn init(allocator: std.mem.Allocator, use_vulkan: bool, width: u32, height: u32, config: WindowConfig) !WindowManager {
        _ = use_vulkan;
        applyVideoDriverHint(config.video_driver);
        if (c.SDL_Init(c.SDL_INIT_VIDEO) == false) {
            std.debug.print("SDL Init Failed: {s}\n", .{c.SDL_GetError()});
            return error.SDLInitializationFailed;
        }
        if (c.SDL_GetCurrentVideoDriver()) |driver| {
            log.log.info("SDL video driver: {s}", .{driver});
        }

        var window_flags: c.SDL_WindowFlags = c.SDL_WINDOW_RESIZABLE | c.SDL_WINDOW_HIGH_PIXEL_DENSITY | c.SDL_WINDOW_VULKAN;
        if (config.no_focus) {
            window_flags |= c.SDL_WINDOW_NOT_FOCUSABLE;
        }
        if (config.hidden) {
            window_flags |= c.SDL_WINDOW_HIDDEN;
        }

        var placed_on_hyprland_monitor = false;
        const window = blk: {
            if (config.monitor_name.len > 0) {
                if (createWindowOnHyprlandMonitor(allocator, width, height, window_flags, config.monitor_name, config.no_focus, config.hidden)) |created| {
                    placed_on_hyprland_monitor = true;
                    break :blk created;
                }
            }

            if (config.monitor_index >= 0) {
                break :blk createWindowOnMonitor(width, height, window_flags, config.monitor_index, config.no_focus, config.hidden);
            }

            break :blk createWindowWithProperties(@intCast(width), @intCast(height), window_flags, null, null, config.no_focus, config.hidden);
        };
        if (window == null) {
            log.log.err("Window Creation Failed: {s}", .{c.SDL_GetError()});
            return error.WindowCreationFailed;
        }
        if (config.no_focus and c.SDL_SetWindowFocusable(window.?, false) == false) {
            log.log.warn("SDL_SetWindowFocusable(false) failed: {s}", .{c.SDL_GetError()});
        }
        if (config.monitor_name.len > 0 and !placed_on_hyprland_monitor) {
            moveToHyprlandMonitor(allocator, config.monitor_name);
        }
        log.log.info("Window created at {}x{}", .{ width, height });

        return WindowManager{
            .window = window.?,
        };
    }

    const HyprlandMonitor = struct {
        width: c_int,
        height: c_int,
        x: c_int,
        y: c_int,
    };

    const HyprlandMonitorJson = struct {
        name: []const u8,
        width: c_int,
        height: c_int,
        x: c_int,
        y: c_int,
    };

    fn createWindowOnHyprlandMonitor(allocator: std.mem.Allocator, width: u32, height: u32, window_flags: c.SDL_WindowFlags, monitor_name: []const u8, window_no_focus: bool, window_hidden: bool) ?*c.SDL_Window {
        const monitor = getHyprlandMonitor(allocator, monitor_name) catch |err| {
            log.log.warn("Could not query Hyprland monitor-name='{s}': {}", .{ monitor_name, err });
            return null;
        } orelse {
            log.log.warn("Hyprland monitor-name='{s}' was not found", .{monitor_name});
            return null;
        };

        const target_w: c_int = @min(@as(c_int, @intCast(width)), monitor.width);
        const target_h: c_int = @min(@as(c_int, @intCast(height)), monitor.height);
        const x = monitor.x + @max(@divTrunc(monitor.width - target_w, 2), 0);
        const y = monitor.y + @max(@divTrunc(monitor.height - target_h, 2), 0);

        const window = createWindowWithProperties(target_w, target_h, window_flags, x, y, window_no_focus, window_hidden) orelse return null;
        log.log.info("Window placed on Hyprland monitor-name='{s}' at {},{} size={}x{} (monitor {}x{} @ {},{})", .{ monitor_name, x, y, target_w, target_h, monitor.width, monitor.height, monitor.x, monitor.y });
        return window;
    }

    fn getHyprlandMonitor(allocator: std.mem.Allocator, monitor_name: []const u8) !?HyprlandMonitor {
        const result = try std.process.run(allocator, std.Options.debug_io, .{
            .argv = &.{ "hyprctl", "monitors", "-j" },
            .stdout_limit = .limited(128 * 1024),
            .stderr_limit = .limited(4096),
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) return error.HyprctlFailed,
            else => return error.HyprctlFailed,
        }

        const parsed = try std.json.parseFromSlice([]HyprlandMonitorJson, allocator, result.stdout, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();

        for (parsed.value) |monitor| {
            if (std.mem.eql(u8, monitor.name, monitor_name)) {
                return .{
                    .width = monitor.width,
                    .height = monitor.height,
                    .x = monitor.x,
                    .y = monitor.y,
                };
            }
        }

        return null;
    }

    fn applyVideoDriverHint(video_driver: []const u8) void {
        if (video_driver.len == 0) return;

        const value = if (std.ascii.eqlIgnoreCase(video_driver, "x11"))
            "x11"
        else if (std.ascii.eqlIgnoreCase(video_driver, "wayland"))
            "wayland"
        else {
            log.log.warn("Unsupported window-video-driver '{s}' (expected x11 or wayland)", .{video_driver});
            return;
        };

        if (c.SDL_SetHintWithPriority(c.SDL_HINT_VIDEO_DRIVER, value, c.SDL_HINT_OVERRIDE) == false) {
            log.log.warn("SDL_SetHintWithPriority(SDL_HINT_VIDEO_DRIVER={s}) failed: {s}", .{ value, c.SDL_GetError() });
        }
    }

    fn createWindowOnMonitor(width: u32, height: u32, window_flags: c.SDL_WindowFlags, monitor_index: i32, window_no_focus: bool, window_hidden: bool) ?*c.SDL_Window {
        const display = getDisplayForMonitorIndex(monitor_index) orelse {
            return c.SDL_CreateWindow("ZigCraft", @intCast(width), @intCast(height), @intCast(window_flags));
        };

        const target_w: c_int = @min(@as(c_int, @intCast(width)), display.bounds.w);
        const target_h: c_int = @min(@as(c_int, @intCast(height)), display.bounds.h);
        const x = display.bounds.x + @max(@divTrunc(display.bounds.w - target_w, 2), 0);
        const y = display.bounds.y + @max(@divTrunc(display.bounds.h - target_h, 2), 0);

        const window = createWindowWithProperties(target_w, target_h, window_flags, x, y, window_no_focus, window_hidden) orelse return null;

        log.log.info("Window placed on monitor-index={} display_id={} at {},{} size={}x{} (display {}x{} @ {},{})", .{ monitor_index, display.id, x, y, target_w, target_h, display.bounds.w, display.bounds.h, display.bounds.x, display.bounds.y });
        return window;
    }

    fn createWindowWithProperties(width: c_int, height: c_int, window_flags: c.SDL_WindowFlags, x: ?c_int, y: ?c_int, window_no_focus: bool, window_hidden: bool) ?*c.SDL_Window {
        const props = c.SDL_CreateProperties();
        if (props == 0) {
            log.log.warn("SDL_CreateProperties failed: {s}", .{c.SDL_GetError()});
            return c.SDL_CreateWindow("ZigCraft", width, height, @intCast(window_flags));
        }
        defer c.SDL_DestroyProperties(props);

        _ = c.SDL_SetStringProperty(props, c.SDL_PROP_WINDOW_CREATE_TITLE_STRING, "ZigCraft");
        _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_WIDTH_NUMBER, width);
        _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_HEIGHT_NUMBER, height);
        _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_FLAGS_NUMBER, @intCast(window_flags));
        if (x) |window_x| _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_X_NUMBER, window_x);
        if (y) |window_y| _ = c.SDL_SetNumberProperty(props, c.SDL_PROP_WINDOW_CREATE_Y_NUMBER, window_y);
        _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_HIDDEN_BOOLEAN, window_hidden or x != null or y != null);
        if (window_no_focus) {
            _ = c.SDL_SetBooleanProperty(props, c.SDL_PROP_WINDOW_CREATE_FOCUSABLE_BOOLEAN, false);
        }

        const window = c.SDL_CreateWindowWithProperties(props);
        if (window == null) {
            log.log.warn("SDL_CreateWindowWithProperties failed: {s}", .{c.SDL_GetError()});
            return c.SDL_CreateWindow("ZigCraft", width, height, @intCast(window_flags));
        }

        if (x != null and y != null and c.SDL_SetWindowPosition(window, x.?, y.?) == false) {
            log.log.warn("SDL_SetWindowPosition failed at {},{}: {s}", .{ x.?, y.?, c.SDL_GetError() });
        }
        if (!window_hidden) {
            _ = c.SDL_ShowWindow(window);
            _ = c.SDL_SyncWindow(window);
        }
        return window;
    }

    const DisplaySelection = struct {
        id: c.SDL_DisplayID,
        bounds: c.SDL_Rect,
    };

    fn getDisplayForMonitorIndex(monitor_index: i32) ?DisplaySelection {
        var display_count: c_int = 0;
        const displays = c.SDL_GetDisplays(&display_count);
        if (displays == null or display_count <= 0) {
            log.log.warn("Could not query SDL displays for monitor-index={}: {s}", .{ monitor_index, c.SDL_GetError() });
            return null;
        }
        defer c.SDL_free(displays);

        logDisplayLayout(displays, display_count);

        if (monitor_index >= display_count) {
            log.log.warn("monitor-index={} is out of range; SDL reported {} display(s)", .{ monitor_index, display_count });
            return null;
        }

        const display_id = displays[@intCast(monitor_index)];
        var bounds: c.SDL_Rect = undefined;
        if (c.SDL_GetDisplayBounds(display_id, &bounds) == false) {
            log.log.warn("SDL_GetDisplayBounds failed for monitor-index={}: {s}", .{ monitor_index, c.SDL_GetError() });
            return null;
        }

        return .{ .id = display_id, .bounds = bounds };
    }

    fn logDisplayLayout(displays: [*]c.SDL_DisplayID, display_count: c_int) void {
        var i: c_int = 0;
        while (i < display_count) : (i += 1) {
            const display_id = displays[@intCast(i)];
            var bounds: c.SDL_Rect = undefined;
            if (c.SDL_GetDisplayBounds(display_id, &bounds)) {
                if (c.SDL_GetDisplayName(display_id)) |name| {
                    log.log.info("SDL display[{}]: id={} name='{s}' bounds={}x{} @ {},{}", .{ i, display_id, name, bounds.w, bounds.h, bounds.x, bounds.y });
                } else {
                    log.log.info("SDL display[{}]: id={} name='unknown' bounds={}x{} @ {},{}", .{ i, display_id, bounds.w, bounds.h, bounds.x, bounds.y });
                }
            }
        }
    }

    fn moveToHyprlandMonitor(allocator: std.mem.Allocator, monitor_name: []const u8) void {
        if (monitor_name.len == 0) return;

        const arg = std.fmt.allocPrint(allocator, "mon:{s}", .{monitor_name}) catch |err| {
            log.log.warn("Could not allocate hyprctl monitor argument: {}", .{err});
            return;
        };
        defer allocator.free(arg);

        const result = std.process.run(allocator, std.Options.debug_io, .{
            .argv = &.{ "hyprctl", "dispatch", "movewindow", arg },
            .stdout_limit = .limited(0),
            .stderr_limit = .limited(0),
        }) catch |err| {
            log.log.warn("hyprctl movewindow failed for monitor-name='{s}': {}", .{ monitor_name, err });
            return;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| if (code != 0) {
                log.log.warn("hyprctl movewindow monitor-name='{s}' failed", .{monitor_name});
                return;
            },
            else => {
                log.log.warn("hyprctl movewindow monitor-name='{s}' failed", .{monitor_name});
                return;
            },
        }

        log.log.info("Hyprland moved window to monitor '{s}'", .{monitor_name});
    }

    /// Resize the window to a new resolution
    pub fn setSize(self: *WindowManager, width: u32, height: u32) void {
        // Check if window is maximized or fullscreen - resize won't work in those states
        const flags = c.SDL_GetWindowFlags(self.window);
        if ((flags & c.SDL_WINDOW_MAXIMIZED) != 0) {
            log.log.info("Restoring maximized window before resize", .{});
            _ = c.SDL_RestoreWindow(self.window);
            _ = c.SDL_SyncWindow(self.window);
        }
        if ((flags & c.SDL_WINDOW_FULLSCREEN) != 0) {
            log.log.info("Exiting fullscreen before resize", .{});
            _ = c.SDL_SetWindowFullscreen(self.window, false);
            _ = c.SDL_SyncWindow(self.window);
        }

        if (c.SDL_SetWindowSize(self.window, @intCast(width), @intCast(height)) == false) {
            log.log.warn("SDL_SetWindowSize failed: {s}", .{c.SDL_GetError()});
            return;
        }
        // On Wayland, window resize is asynchronous. SDL_SyncWindow blocks until complete.
        if (c.SDL_SyncWindow(self.window) == false) {
            log.log.warn("SDL_SyncWindow failed: {s}", .{c.SDL_GetError()});
        }
        log.log.info("Window resized to {}x{}", .{ width, height });
    }

    pub fn deinit(self: *WindowManager) void {
        c.SDL_DestroyWindow(self.window);
        c.SDL_Quit();
    }
};
