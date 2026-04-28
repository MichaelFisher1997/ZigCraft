const std = @import("std");
const rhi = @import("engine-rhi").rhi;
const UISystem = @import("ui_system.zig").UISystem;

pub const DebugLPVOverlay = struct {
    pub const Config = struct {
        // Optional explicit size; <= 0 uses screen-relative fallback.
        width: f32 = 0.0,
        height: f32 = 0.0,
        spacing: f32 = 10.0,
    };

    pub fn rect(screen_height: f32, config: Config) rhi.Rect {
        const fallback_size = std.math.clamp(screen_height * 0.28, 160.0, 280.0);
        const width = if (config.width > 0.0) config.width else fallback_size;
        const height = if (config.height > 0.0) config.height else fallback_size;
        return .{
            .x = config.spacing,
            .y = screen_height - height - config.spacing,
            .width = width,
            .height = height,
        };
    }

    pub fn draw(ui: *UISystem, lpv_texture: rhi.TextureHandle, screen_height: f32, config: Config) void {
        if (lpv_texture == 0) return;

        const r = rect(screen_height, config);
        ui.drawTexture(lpv_texture, r);
    }
};
