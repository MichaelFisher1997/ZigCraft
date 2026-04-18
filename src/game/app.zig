const std = @import("std");
const build_options = @import("build_options");

const log = @import("../engine/core/log.zig");
const WindowManager = @import("../engine/core/window.zig").WindowManager;
const Input = @import("../engine/input/input.zig").Input;
const Time = @import("../engine/core/time.zig").Time;
const UISystemManager = @import("../engine/ui/ui_system_manager.zig").UISystemManager;
const WorldStats = @import("../engine/ui/timing_overlay.zig").WorldStats;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const InputMapper = @import("input_mapper.zig").InputMapper;
const RenderSystem = @import("../engine/graphics/render_system.zig").RenderSystem;
const AudioSystemManager = @import("audio_system_manager.zig").AudioSystemManager;
const BenchmarkRunner = @import("../benchmark.zig").BenchmarkRunner;
const json_presets = @import("settings/json_presets.zig");

const SettingsManager = @import("settings_manager.zig").SettingsManager;
const Settings = @import("settings.zig").Settings;
const InputSettings = @import("input_settings.zig").InputSettings;

const screen_pkg = @import("screen.zig");
const ScreenManager = screen_pkg.ScreenManager;
const EngineContext = screen_pkg.EngineContext;
const HomeScreen = @import("screens/home.zig").HomeScreen;
const WorldScreen = @import("screens/world.zig").WorldScreen;
const RenderSettingsAdapter = @import("../engine/graphics/render_settings.zig").RenderSettingsAdapter;

pub const App = struct {
    allocator: std.mem.Allocator,
    window_manager: WindowManager,
    render_system: *RenderSystem,
    audio_manager: *AudioSystemManager,
    settings_manager: SettingsManager,
    input: Input,
    input_mapper: InputMapper,
    time: Time,
    ui_manager: UISystemManager,
    screen_manager: ScreenManager,
    skip_world_update: bool,
    smoke_test_frames: u32 = 0,
    render_settings_adapter: RenderSettingsAdapter,
    resize_debounce_frames: u32 = 0,
    benchmark_runner: ?*BenchmarkRunner = null,

    pub fn init(allocator: std.mem.Allocator) !*App {
        log.log.info("Initializing engine systems...", .{});

        log.log.info("App.init: initializing SettingsManager", .{});
        var settings_manager = try SettingsManager.init(allocator);
        errdefer settings_manager.deinit();

        if (build_options.benchmark) {
            applyBenchmarkPreset(settings_manager.ptr(), build_options.benchmark_preset);
        }

        const initial_window_width: u32 = if (build_options.benchmark) 1920 else settings_manager.settings.window_width;
        const initial_window_height: u32 = if (build_options.benchmark) 1080 else settings_manager.settings.window_height;
        log.log.info("App.init: initializing WindowManager ({}x{})", .{ initial_window_width, initial_window_height });
        var wm = try WindowManager.init(allocator, true, initial_window_width, initial_window_height);
        errdefer wm.deinit();

        var input = Input.init(allocator);
        errdefer input.deinit();
        input.initWindowSize(wm.window);
        const time = Time.init();

        log.log.info("App.init: initializing RenderSystem", .{});
        const render_system = try RenderSystem.init(allocator, wm.window, &settings_manager.settings);
        errdefer render_system.deinit();

        if (build_options.skip_present) {
            const headless_extent = render_system.getRHI().renderContext().getNativeSwapchainExtent();
            input.window_width = headless_extent[0];
            input.window_height = headless_extent[1];
        }

        const safe_render_env = std.posix.getenv("ZIGCRAFT_SAFE_RENDER");
        const safe_render_mode = if (safe_render_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const skip_world_update_env = std.posix.getenv("ZIGCRAFT_SKIP_WORLD_UPDATE");
        const skip_world_update = safe_render_mode or if (skip_world_update_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        if (skip_world_update and !safe_render_mode) {
            log.log.warn("ZIGCRAFT_SKIP_WORLD_UPDATE enabled", .{});
        }

        log.log.info("App.init: initializing AudioSystemManager", .{});
        const audio_manager = try AudioSystemManager.init(allocator);
        errdefer audio_manager.deinit();

        log.log.info("App.init: initializing UISystemManager", .{});
        var ui_manager = try UISystemManager.init(render_system.getRHI().uiRenderer(), input.window_width, input.window_height, build_options.smoke_test);
        errdefer ui_manager.deinit();

        const input_mapper = InputSettings.loadAndReturnMapper(allocator);

        const app = try allocator.create(App);
        errdefer allocator.destroy(app);

        var benchmark_runner: ?*BenchmarkRunner = null;
        if (build_options.benchmark) {
            const runner = try allocator.create(BenchmarkRunner);
            const benchmark_duration_s: f32 = @as(f32, @floatFromInt(build_options.benchmark_duration));
            runner.* = try BenchmarkRunner.init(allocator, build_options.benchmark_preset, settings_manager.settings.render_distance, benchmark_duration_s, build_options.benchmark_output);
            benchmark_runner = runner;
        }

        app.* = .{
            .allocator = allocator,
            .window_manager = wm,
            .render_system = render_system,
            .audio_manager = audio_manager,
            .settings_manager = settings_manager,
            .input = input,
            .input_mapper = input_mapper,
            .time = time,
            .ui_manager = ui_manager,
            .screen_manager = ScreenManager.init(allocator),
            .skip_world_update = skip_world_update,
            .smoke_test_frames = 0,
            .render_settings_adapter = RenderSettingsAdapter.init(render_system.getRHI()),
            .resize_debounce_frames = 0,
            .benchmark_runner = benchmark_runner,
        };
        errdefer app.screen_manager.deinit();

        if (build_options.smoke_test or build_options.screenshot_path.len > 0 or build_options.benchmark) {
            app.render_system.getRHI().timing().setTimingEnabled(true);
        }

        const engine_ctx = app.engineContext();
        if (build_options.screenshot_path.len > 0) {
            log.log.info("SCREENSHOT MODE: Loading menu for screenshot capture to '{s}'", .{build_options.screenshot_path});
            const home_screen = try HomeScreen.init(allocator, engine_ctx);
            app.screen_manager.setScreen(home_screen.screen());
        } else if (build_options.benchmark) {
            log.log.info("BENCHMARK MODE: Loading world and collecting metrics", .{});
            const world_screen = try WorldScreen.init(allocator, engine_ctx, 12345, 0);
            app.screen_manager.setScreen(world_screen.screen());
        } else if (resolveAutoWorldGenerator()) |generator_index| {
            log.log.info("AUTO WORLD MODE: Loading '{s}' generator", .{build_options.auto_world});
            const world_screen = try WorldScreen.init(allocator, engine_ctx, 12345, generator_index);
            app.screen_manager.setScreen(world_screen.screen());
        } else if (build_options.smoke_test) {
            log.log.info("SMOKE TEST MODE: Bypassing menu and loading world", .{});
            const world_screen = try WorldScreen.init(allocator, engine_ctx, 12345, 0);
            app.screen_manager.setScreen(world_screen.screen());
        } else {
            const home_screen = try HomeScreen.init(allocator, engine_ctx);
            app.screen_manager.setScreen(home_screen.screen());
        }

        return app;
    }

    pub fn deinit(self: *App) void {
        self.render_system.waitIdle();

        self.ui_manager.deinit();

        self.screen_manager.deinit();
        if (self.benchmark_runner) |runner| {
            runner.deinit();
            self.allocator.destroy(runner);
        }
        self.audio_manager.deinit();
        self.render_system.deinit();
        self.settings_manager.deinit();

        self.input.deinit();
        self.window_manager.deinit();

        self.allocator.destroy(self);
    }

    pub fn engineContext(self: *App) EngineContext {
        return .{
            .allocator = self.allocator,
            .window_manager = &self.window_manager,
            .render_system = self.render_system,
            .audio_system = self.audio_manager.audio_system,
            .ui_manager = &self.ui_manager,
            .settings = self.settings_manager.ptr(),
            .input = self.input.interface(),
            .input_mapper = self.input_mapper.interface(),
            .time = &self.time,
            .screen_manager = &self.screen_manager,
            .skip_world_update = self.skip_world_update,
            .render_settings = self.render_settings_adapter.interface(),
            .benchmark_runner = self.benchmark_runner,
        };
    }

    pub fn saveAllSettings(self: *const App) void {
        self.settings_manager.save();
        InputSettings.saveFromMapper(self.allocator, self.input_mapper.interface()) catch |err| {
            log.log.errWithTrace("Failed to save input settings: {}", .{err});
        };
    }

    fn getWorldStats(self: *const App) ?WorldStats {
        if (self.screen_manager.stack.items.len == 0) return null;
        const top = self.screen_manager.stack.getLast();
        return top.getWorldStats();
    }

    pub fn runSingleFrame(self: *App) !void {
        self.time.update();
        if (!build_options.benchmark) {
            self.audio_manager.update();
        }

        self.input.beginFrame();
        self.input.pollEvents();

        const window_width = self.input.interface().getWindowWidth();
        const window_height = self.input.interface().getWindowHeight();
        const swapchain_extent = self.render_system.getRHI().renderContext().getNativeSwapchainExtent();
        if (!build_options.skip_present) {
            if (self.resize_debounce_frames > 0) {
                self.resize_debounce_frames -= 1;
            } else if (window_width > 0 and window_height > 0 and (window_width != swapchain_extent[0] or window_height != swapchain_extent[1])) {
                self.render_system.getRHI().renderContext().requestSwapchainRecreate();
                self.resize_debounce_frames = 2;
            } else if (window_width == swapchain_extent[0] and window_height == swapchain_extent[1]) {
                self.resize_debounce_frames = 0;
            }
        }

        self.ui_manager.handleTimingToggle(self.input.interface(), self.input_mapper.interface(), &self.time, self.render_system.getRHI());

        self.ui_manager.resize(window_width, window_height);

        self.render_system.setViewport(window_width, window_height);

        self.render_system.beginFrame();
        errdefer self.render_system.endFrame();

        try self.render_system.updateGlobalUniforms(Mat4.identity, Vec3.zero, Vec3.init(0, -1, 0), Vec3.one, 0, Vec3.zero, 0, false, 1.0, 0.1, false, .{
            .cam_pos = Vec3.zero,
            .view_proj = Mat4.identity,
            .sun_dir = Vec3.init(0, -1, 0),
            .sun_intensity = 1.0,
            .fog_color = Vec3.zero,
            .fog_density = 0,
            .wind_offset_x = 0,
            .wind_offset_z = 0,
            .cloud_scale = 1.0,
            .cloud_coverage = 0.5,
            .cloud_height = 100,
            .base_color = Vec3.one,
            .pbr_enabled = false,
            .shadow = .{ .distance = 100, .resolution = 1024, .pcf_samples = 1, .cascade_blend = false },
            .cloud_shadows = false,
            .pbr_quality = 0,
            .exposure = 1.0,
            .saturation = 1.0,
            .volumetric_enabled = false,
            .volumetric_density = 0,
            .volumetric_steps = 0,
            .volumetric_scattering = 0,
            .ssao_enabled = false,
            .lpv_enabled = false,
            .lpv_intensity = 0,
            .lpv_cell_size = 2.0,
            .lpv_grid_size = 32,
            .lpv_origin = Vec3.zero,
        });

        try self.screen_manager.update(self.time.delta_time);

        if (self.screen_manager.stack.items.len == 0) {
            self.render_system.endFrame();
            return;
        }

        const world_stats = self.getWorldStats();
        const cpu_ms = self.time.delta_time * 1000.0;
        try self.ui_manager.draw(&self.screen_manager, self.render_system.getRHI(), world_stats, cpu_ms, self.time.fps);

        self.render_system.endFrame();

        if (build_options.benchmark) {
            if (self.benchmark_runner) |runner| {
                const gpu_timing = self.render_system.getRHI().timing().getTimingResults();
                const draw_calls = self.render_system.getRHI().getDrawCallCount();
                try runner.recordFrame(self.time.delta_time, self.time.fps, gpu_timing, world_stats, draw_calls);

                if (runner.isComplete()) {
                    try runner.writeResults();
                    log.log.info("BENCHMARK COMPLETE: {} frames written to '{s}'", .{ runner.samples.items.len, runner.output_path });
                    self.input.should_quit = true;
                }
            }
        }

        if (build_options.smoke_test or build_options.screenshot_path.len > 0) {
            self.smoke_test_frames += 1;
            var target_frames: u32 = 120;
            if (std.posix.getenv("ZIGCRAFT_SMOKE_FRAMES")) |val| {
                if (std.fmt.parseInt(u32, val, 10)) |parsed| {
                    target_frames = parsed;
                } else |_| {}
            }

            if (self.smoke_test_frames >= target_frames) {
                if (build_options.screenshot_path.len > 0) {
                    log.log.info("SCREENSHOT: Capturing frame to '{s}'", .{build_options.screenshot_path});
                    if (!self.render_system.getRHI().captureFrame(build_options.screenshot_path)) {
                        log.log.err("SCREENSHOT: Failed to capture screenshot", .{});
                    }
                }
                log.log.info("SMOKE TEST COMPLETE: {} frames rendered. Exiting.", .{target_frames});
                self.input.should_quit = true;
            }
        }
    }

    pub fn run(self: *App) !void {
        self.render_system.setViewport(self.input.interface().getWindowWidth(), self.input.interface().getWindowHeight());
        log.log.info("=== ZigCraft ===", .{});
        var last_fault_count: u32 = self.render_system.getRHI().getFaultCount();
        var gpu_recovery_attempts: u32 = 0;
        while (!self.input.interface().shouldQuit()) {
            self.runSingleFrame() catch |err| {
                log.log.err("Frame error: {}", .{err});
                return err;
            };
            const current_faults = self.render_system.getRHI().getFaultCount();
            if (current_faults > last_fault_count) {
                gpu_recovery_attempts += 1;
                last_fault_count = current_faults;
                if (gpu_recovery_attempts > 3) {
                    log.log.err("GPU lost after {d} recovery attempts. Exiting.", .{gpu_recovery_attempts});
                    return error.GpuLost;
                }
                log.log.warn("GPU fault detected (total faults: {d}), attempting recovery ({d}/3)...", .{ current_faults, gpu_recovery_attempts });
                self.render_system.getRHI().recover() catch {
                    log.log.err("GPU recovery failed. Exiting.", .{});
                    return error.GpuLost;
                };
                log.log.info("GPU recovery step completed.", .{});
            }
        }
    }
};

fn applyBenchmarkPreset(settings: *Settings, preset_name: []const u8) void {
    for (json_presets.graphics_presets.items, 0..) |preset, i| {
        if (std.ascii.eqlIgnoreCase(preset.name, preset_name) or std.ascii.eqlIgnoreCase(@tagName(preset.render_distance_preset), preset_name)) {
            json_presets.apply(settings, i);
            log.log.info("BENCHMARK: Applied graphics preset '{s}'", .{preset.name});
            return;
        }
    }

    log.log.warn("BENCHMARK: Unknown preset '{s}', keeping loaded settings", .{preset_name});
}

fn resolveAutoWorldGenerator() ?usize {
    if (build_options.auto_world.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(build_options.auto_world, "normal") or std.ascii.eqlIgnoreCase(build_options.auto_world, "overworld")) {
        return 0;
    }
    if (std.ascii.eqlIgnoreCase(build_options.auto_world, "flat")) {
        return 1;
    }

    log.log.warn("Unknown -Dauto-world value '{s}', defaulting to overworld", .{build_options.auto_world});
    return 0;
}
