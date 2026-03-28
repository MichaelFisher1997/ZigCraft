const std = @import("std");
const rhi = @import("../graphics/rhi.zig");
const UISystem = @import("ui_system.zig").UISystem;
const ShadowSystemWrapper = rhi.ShadowSystemWrapper;
const Font = @import("font.zig");
const Settings = @import("../../game/settings/data.zig").Settings;

pub const DebugShadowOverlay = struct {
    pub const Config = struct {
        size: f32 = 200.0,
        spacing: f32 = 10.0,
        show_labels: bool = true,
    };

    pub fn draw(
        ui: *UISystem,
        shadow: ShadowSystemWrapper,
        _: f32,
        _: f32,
        config: Config,
        cascade_splits: []const f32,
        settings: *const Settings,
    ) void {
        ui.begin();
        defer ui.end();

        const label_height: f32 = 16.0;

        for (0..rhi.SHADOW_CASCADE_COUNT) |i| {
            const handle = shadow.getShadowMapHandle(@intCast(i));
            if (handle == 0) continue;

            const extra_width: f32 = if (config.show_labels) @as(f32, 50.0) else @as(f32, 0.0);
            const cell_width = config.size + extra_width;
            const x = config.spacing + @as(f32, @floatFromInt(i)) * (cell_width + config.spacing);
            const y = config.spacing;

            const tex_rect = rhi.Rect{
                .x = x,
                .y = if (config.show_labels) y + label_height else y,
                .width = config.size,
                .height = config.size,
            };

            ui.drawDepthTexture(handle, tex_rect);

            if (config.show_labels) {
                var idx_buf: [8]u8 = undefined;
                const idx_text = std.fmt.bufPrint(&idx_buf, "C{d}", .{i}) catch "C?";
                Font.drawText(ui, idx_text, x, y, 1.5, .{ .r = 0.95, .g = 0.95, .b = 1.0, .a = 1.0 });

                if (i < cascade_splits.len) {
                    var dist_buf: [16]u8 = undefined;
                    const dist_val = @as(i32, @intFromFloat(@round(cascade_splits[i])));
                    const dist_text = std.fmt.bufPrint(&dist_buf, "{d}m", .{dist_val}) catch "?m";
                    Font.drawText(ui, dist_text, x, y + label_height + config.size, 1.2, .{ .r = 0.6, .g = 0.8, .b = 1.0, .a = 1.0 });
                }
            }
        }

        const legend_x = config.spacing;
        const legend_y = config.spacing + config.size + label_height + 12.0;

        if (settings.debug_shadow_cascade_index) {
            Font.drawText(ui, "CASCADE INDEX  R=C0  G=C1  B=C2", legend_x, legend_y, 1.3, .{ .r = 1.0, .g = 1.0, .b = 0.6, .a = 1.0 });
        } else if (settings.debug_shadow_caster_coverage) {
            Font.drawText(ui, "CASTER COVERAGE  R=caster  G=shadowed  B=depth", legend_x, legend_y, 1.3, .{ .r = 1.0, .g = 1.0, .b = 0.6, .a = 1.0 });
        } else if (settings.debug_shadow_seam_diag) {
            Font.drawText(ui, "SEAM DIAG  R=split boundary  G=distance  B=blend", legend_x, legend_y, 1.3, .{ .r = 1.0, .g = 1.0, .b = 0.6, .a = 1.0 });
        }
    }
};
