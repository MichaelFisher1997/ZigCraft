//! UI System Manager - Centralized management of UI systems and overlays.
//! Encapsulates UISystem lifecycle, timing overlay, and related input handling.

const std = @import("std");
const UISystem = @import("ui_system.zig").UISystem;
const TimingOverlay = @import("timing_overlay.zig").TimingOverlay;
const Font = @import("font.zig");
const FontAtlas = @import("font_atlas.zig").FontAtlas;
const PerformanceData = @import("timing_overlay.zig").PerformanceData;
const WorldStats = @import("timing_overlay.zig").WorldStats;
const RenderDeviceStats = @import("engine-rhi").render_device.Stats;
const rhi = @import("engine-rhi").rhi;
const Time = @import("engine-core").Time;
const WindowManager = @import("engine-core").WindowManager;
const imgui_backend = @import("imgui/imgui_backend.zig");

pub const UISystemManager = struct {
    ui: ?UISystem,
    font_atlas: ?FontAtlas = null,
    imgui: ?imgui_backend.Backend = null,
    timing_overlay: TimingOverlay,
    last_debug_toggle_time: f32 = 0,

    pub fn init(allocator: std.mem.Allocator, renderer: rhi.UIRenderer, resources: rhi.ResourceManager, rhi_ptr: *rhi.RHI, window_manager: *WindowManager, width: u32, height: u32, smoke_test_enabled: bool) !UISystemManager {
        const ui = try UISystem.init(renderer, width, height);
        const font_atlas = FontAtlas.init(allocator, resources, "assets/fonts/Inter-Regular.ttf") catch null;
        const imgui = if (imgui_backend.available) imgui_backend.Backend.init(window_manager.window, rhi_ptr) catch |err| blk: {
            logImguiInitFailure(err);
            break :blk null;
        } else null;
        return .{
            .ui = ui,
            .font_atlas = font_atlas,
            .imgui = imgui,
            .timing_overlay = .{ .enabled = smoke_test_enabled },
        };
    }

    pub fn deinit(self: *UISystemManager, resources: rhi.ResourceManager) void {
        if (self.imgui) |*backend| backend.deinit();
        Font.setActiveAtlas(null);
        if (self.font_atlas) |*atlas| atlas.deinit(resources);
        if (self.ui) |*u| u.deinit();
    }

    pub fn resize(self: *UISystemManager, width: u32, height: u32) void {
        if (self.ui) |*u| u.resize(width, height);
    }

    pub fn handleTimingToggle(self: *UISystemManager, timing_toggle_pressed: bool, time: *Time, rhi_ptr: *rhi.RHI) void {
        if (timing_toggle_pressed) {
            const now = time.elapsed;
            if (now - self.last_debug_toggle_time > 0.2) {
                self.timing_overlay.toggle();
                rhi_ptr.timing().setTimingEnabled(self.timing_overlay.enabled);
                self.last_debug_toggle_time = now;
            }
        }
    }

    pub fn draw(self: *UISystemManager, screen_manager: anytype, rhi_ptr: *rhi.RHI, world_stats: ?WorldStats, cpu_frame_ms: f32, fps: f32) !void {
        if (self.ui) |*u| {
            if (self.imgui) |*backend| backend.beginFrame();

            if (self.font_atlas) |*atlas| Font.setActiveAtlas(atlas) else Font.setActiveAtlas(null);
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
                    .resolution_scale = rhi_ptr.options().getResolutionScale(),
                    .world = world_stats,
                    .gpu_stats = gpu_stats,
                };
                self.timing_overlay.draw(u, data);
                u.end();
            }

            if (self.imgui) |*backend| {
                if (backend.hasDrawCommands()) {
                    u.begin();
                    backend.endFrame(rhi_ptr.nativeHandles().getCommandBuffer());
                    u.end();
                } else {
                    backend.endFrame(0);
                }
            }
        }
    }

    pub fn getUISystem(self: *UISystemManager) ?*UISystem {
        if (self.ui) |*u| return u;
        return null;
    }

    pub fn getImguiBackend(self: *UISystemManager) ?*imgui_backend.Backend {
        if (self.imgui) |*backend| return backend;
        return null;
    }
};

fn logImguiInitFailure(err: anyerror) void {
    const log = @import("engine-core").log;
    log.log.warn("ImGui backend disabled after init failure: {}", .{err});
}
