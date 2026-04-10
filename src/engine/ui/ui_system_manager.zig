//! UI System Manager - Centralized management of UI systems and overlays.
//! Encapsulates UISystem lifecycle, timing overlay, and related input handling.

const std = @import("std");
const UISystem = @import("ui_system.zig").UISystem;
const TimingOverlay = @import("timing_overlay.zig").TimingOverlay;
const PerformanceData = @import("timing_overlay.zig").PerformanceData;
const WorldStats = @import("timing_overlay.zig").WorldStats;
const RenderDeviceStats = @import("../graphics/render_device.zig").Stats;
const rhi = @import("../graphics/rhi.zig");
const IRawInputProvider = @import("../input/interfaces.zig").IRawInputProvider;
const IInputMapper = @import("../../game/input_mapper.zig").IInputMapper;
const ScreenManager = @import("../../game/screen.zig").ScreenManager;
const Time = @import("../core/time.zig").Time;

pub const UISystemManager = struct {
    ui: ?UISystem,
    timing_overlay: TimingOverlay,
    last_debug_toggle_time: f32 = 0,

    pub fn init(renderer: rhi.UIRenderer, width: u32, height: u32, smoke_test_enabled: bool) !UISystemManager {
        const ui = try UISystem.init(renderer, width, height);
        return .{
            .ui = ui,
            .timing_overlay = .{ .enabled = smoke_test_enabled },
        };
    }

    pub fn deinit(self: *UISystemManager) void {
        if (self.ui) |*u| u.deinit();
    }

    pub fn resize(self: *UISystemManager, width: u32, height: u32) void {
        if (self.ui) |*u| u.resize(width, height);
    }

    pub fn handleTimingToggle(self: *UISystemManager, input: IRawInputProvider, input_mapper: IInputMapper, time: *Time, rhi_ptr: *rhi.RHI) void {
        if (input_mapper.isActionPressed(input, .toggle_timing_overlay)) {
            const now = time.elapsed;
            if (now - self.last_debug_toggle_time > 0.2) {
                self.timing_overlay.toggle();
                rhi_ptr.timing().setTimingEnabled(self.timing_overlay.enabled);
                self.last_debug_toggle_time = now;
            }
        }
    }

    pub fn draw(self: *UISystemManager, screen_manager: *ScreenManager, rhi_ptr: *rhi.RHI, world_stats: ?WorldStats, cpu_frame_ms: f32, fps: f32) !void {
        if (self.ui) |*u| {
            try screen_manager.draw(u);

            if (self.timing_overlay.enabled) {
                u.begin();
                const timing = rhi_ptr.timing();
                const gpu_timing = timing.getTimingResults();

                const gpu_stats = if (rhi_ptr.device) |device| device.getStats() else std.mem.zeroes(RenderDeviceStats);

                const data = PerformanceData{
                    .gpu = gpu_timing,
                    .cpu_frame_ms = cpu_frame_ms,
                    .fps = fps,
                    .resolution_scale = rhi_ptr.getResolutionScale(),
                    .world = world_stats,
                    .gpu_stats = gpu_stats,
                };
                self.timing_overlay.draw(u, data);
                u.end();
            }
        }
    }

    pub fn getUISystem(self: *UISystemManager) ?*UISystem {
        if (self.ui) |*u| return u;
        return null;
    }
};
