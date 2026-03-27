const std = @import("std");
const c = @import("../c.zig").c;
const builtin = @import("builtin");
const build_options = @import("build_options");

const log = @import("../engine/core/log.zig");
const WindowManager = @import("../engine/core/window.zig").WindowManager;
const Input = @import("../engine/input/input.zig").Input;
const Time = @import("../engine/core/time.zig").Time;
const UISystem = @import("../engine/ui/ui_system.zig").UISystem;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const InputMapper = @import("input_mapper.zig").InputMapper;
const rhi_pkg = @import("../engine/graphics/rhi.zig");
const RenderSystem = @import("../engine/graphics/render_system.zig").RenderSystem;
const AudioSystem = @import("../engine/audio/system.zig").AudioSystem;
const TimingOverlay = @import("../engine/ui/timing_overlay.zig").TimingOverlay;

const settings_pkg = @import("settings.zig");
const Settings = settings_pkg.Settings;
const InputSettings = @import("input_settings.zig").InputSettings;

const screen_pkg = @import("screen.zig");
const ScreenManager = screen_pkg.ScreenManager;
const EngineContext = screen_pkg.EngineContext;
const HomeScreen = @import("screens/home.zig").HomeScreen;
const WorldScreen = @import("screens/world.zig").WorldScreen;

pub const App = struct {
    allocator: std.mem.Allocator,
    window_manager: WindowManager,
    render_system: *RenderSystem,
    audio_system: *AudioSystem,
    settings: Settings,
    input: Input,
    input_mapper: InputMapper,
    time: Time,
    ui: ?UISystem,
    timing_overlay: TimingOverlay,
    screen_manager: ScreenManager,
    last_debug_toggle_time: f32 = 0,
    skip_world_update: bool,
    smoke_test_frames: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) !*App {
        log.log.info("Initializing engine systems...", .{});
        settings_pkg.initPresets(allocator) catch |err| {
            log.log.warn("Failed to initialize presets: {}, proceeding with defaults", .{err});
        };
        errdefer settings_pkg.deinitPresets(allocator);

        const settings = settings_pkg.persistence.load(allocator);

        var wm = try WindowManager.init(allocator, true, settings.window_width, settings.window_height);
        errdefer wm.deinit();

        var input = Input.init(allocator);
        errdefer input.deinit();
        input.initWindowSize(wm.window);
        const time = Time.init();

        const render_system = try RenderSystem.init(allocator, wm.window, &settings);
        errdefer render_system.deinit();

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

        const audio_system = try AudioSystem.init(allocator);
        errdefer audio_system.deinit();

        const ui = try UISystem.init(render_system.getRHI().uiRenderer(), input.window_width, input.window_height);
        var ui_mut = ui;
        errdefer ui_mut.deinit();

        const input_mapper = InputSettings.loadAndReturnMapper(allocator);

        const app = try allocator.create(App);
        errdefer allocator.destroy(app);
        app.* = .{
            .allocator = allocator,
            .window_manager = wm,
            .render_system = render_system,
            .audio_system = audio_system,
            .settings = settings,
            .input = input,
            .input_mapper = input_mapper,
            .time = time,
            .ui = ui,
            .timing_overlay = .{ .enabled = build_options.smoke_test },
            .screen_manager = ScreenManager.init(allocator),
            .skip_world_update = skip_world_update,
            .smoke_test_frames = 0,
        };
        errdefer app.screen_manager.deinit();

        if (build_options.smoke_test) {
            app.render_system.getRHI().timing().setTimingEnabled(true);
        }

        const engine_ctx = app.engineContext();
        if (build_options.smoke_test) {
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

        if (self.ui) |*u| u.deinit();

        self.screen_manager.deinit();
        self.audio_system.deinit();
        self.render_system.deinit();
        settings_pkg.persistence.deinit(&self.settings, self.allocator);
        settings_pkg.deinitPresets(self.allocator);

        self.input.deinit();
        self.window_manager.deinit();

        self.allocator.destroy(self);
    }

    pub fn engineContext(self: *App) EngineContext {
        return .{
            .allocator = self.allocator,
            .window_manager = &self.window_manager,
            .render_system = self.render_system,
            .audio_system = self.audio_system,
            .settings = &self.settings,
            .input = self.input.interface(),
            .input_mapper = self.input_mapper.interface(),
            .time = &self.time,
            .screen_manager = &self.screen_manager,
            .skip_world_update = self.skip_world_update,
        };
    }

    pub fn saveAllSettings(self: *const App) void {
        settings_pkg.persistence.save(&self.settings, self.allocator);
        InputSettings.saveFromMapper(self.allocator, self.input_mapper.interface()) catch |err| {
            log.log.err("Failed to save input settings: {}", .{err});
        };
    }

    pub fn runSingleFrame(self: *App) !void {
        self.time.update();
        self.audio_system.update();

        self.input.beginFrame();
        self.input.pollEvents();

        if (self.input_mapper.isActionPressed(self.input.interface(), .toggle_timing_overlay)) {
            const now = self.time.elapsed;
            if (now - self.last_debug_toggle_time > 0.2) {
                self.timing_overlay.toggle();
                self.render_system.getRHI().timing().setTimingEnabled(self.timing_overlay.enabled);
                self.last_debug_toggle_time = now;
            }
        }

        if (self.ui) |*u| u.resize(self.input.interface().getWindowWidth(), self.input.interface().getWindowHeight());

        self.render_system.setViewport(self.input.interface().getWindowWidth(), self.input.interface().getWindowHeight());

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

        if (self.ui) |*u| {
            try self.screen_manager.draw(u);

            if (self.timing_overlay.enabled) {
                u.begin();
                const timing = self.render_system.getRHI().timing();
                const results = timing.getTimingResults();
                self.timing_overlay.draw(u, results);
                u.end();
            }
        }

        self.render_system.endFrame();

        if (build_options.smoke_test) {
            self.smoke_test_frames += 1;
            var target_frames: u32 = 120;
            if (std.posix.getenv("ZIGCRAFT_SMOKE_FRAMES")) |val| {
                if (std.fmt.parseInt(u32, val, 10)) |parsed| {
                    target_frames = parsed;
                } else |_| {}
            }

            if (self.smoke_test_frames >= target_frames) {
                log.log.info("SMOKE TEST COMPLETE: {} frames rendered. Exiting.", .{target_frames});
                self.input.should_quit = true;
            }
        }
    }

    pub fn run(self: *App) !void {
        self.render_system.setViewport(self.input.interface().getWindowWidth(), self.input.interface().getWindowHeight());
        log.log.info("=== ZigCraft ===", .{});
        while (!self.input.interface().shouldQuit()) {
            try self.runSingleFrame();
        }
    }
};
