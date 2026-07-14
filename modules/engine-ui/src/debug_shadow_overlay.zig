const std = @import("std");
const rhi = @import("engine-rhi").rhi;
const Mat4 = @import("engine-math").Mat4;
const UISystem = @import("ui_system.zig").UISystem;
const ShadowSystemWrapper = rhi.ShadowSystemWrapper;
const Font = @import("font.zig");

pub const DebugShadowOverlay = struct {
    pub const Config = struct {
        size: f32 = 200.0,
        spacing: f32 = 10.0,
        show_labels: bool = true,
        debug_shadow_cascade_index: bool = false,
        debug_shadow_caster_coverage: bool = false,
        debug_shadow_seam_diag: bool = false,
    };

    /// Submits shadow-map preview draw calls to an active caller-owned UI pass.
    /// The caller must pair `ui.begin()` and `ui.end()` around this call.
    pub fn draw(
        ui: *UISystem,
        shadow: ShadowSystemWrapper,
        _: f32,
        _: f32,
        config: Config,
        cascade_splits: []const f32,
    ) void {
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

        if (config.debug_shadow_cascade_index) {
            Font.drawText(ui, "CASCADE INDEX  R=C0  G=C1  B=C2", legend_x, legend_y, 1.3, .{ .r = 1.0, .g = 1.0, .b = 0.6, .a = 1.0 });
        } else if (config.debug_shadow_caster_coverage) {
            Font.drawText(ui, "CASTER COVERAGE  R=caster  G=shadowed  B=depth", legend_x, legend_y, 1.3, .{ .r = 1.0, .g = 1.0, .b = 0.6, .a = 1.0 });
        } else if (config.debug_shadow_seam_diag) {
            Font.drawText(ui, "SEAM DIAG  R=split boundary  G=distance  B=blend", legend_x, legend_y, 1.3, .{ .r = 1.0, .g = 1.0, .b = 0.6, .a = 1.0 });
        }
    }
};

test "DebugShadowOverlay draws within the caller-owned UI pass" {
    const MockUI = struct {
        begin_count: u32 = 0,
        end_count: u32 = 0,
        depth_texture_count: u32 = 0,

        const VTABLE = rhi.IUIContext.VTable{
            .beginPass = beginPass,
            .endPass = endPass,
            .drawRect = drawRect,
            .drawTexture = drawTexture,
            .drawTextureRegion = drawTextureRegion,
            .drawDepthTexture = drawDepthTexture,
            .bindPipeline = bindPipeline,
        };

        fn renderer(self: *@This()) rhi.UIRenderer {
            return .{ .ctx = .{ .ptr = self, .vtable = &VTABLE } };
        }

        fn beginPass(ptr: *anyopaque, _: f32, _: f32) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.begin_count += 1;
        }

        fn endPass(ptr: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.end_count += 1;
        }

        fn drawRect(_: *anyopaque, _: rhi.Rect, _: rhi.Color) void {}
        fn drawTexture(_: *anyopaque, _: rhi.TextureHandle, _: rhi.Rect) void {}
        fn drawTextureRegion(_: *anyopaque, _: rhi.TextureHandle, _: rhi.Rect, _: rhi.UVRect, _: rhi.Color) void {}
        fn drawDepthTexture(ptr: *anyopaque, _: rhi.TextureHandle, _: rhi.Rect) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.depth_texture_count += 1;
        }
        fn bindPipeline(_: *anyopaque, _: bool) void {}
    };

    const MockShadow = struct {
        const VTABLE = rhi.IShadowContext.VTable{
            .beginPass = beginPass,
            .endPass = endPass,
            .updateUniforms = updateUniforms,
            .getShadowMapHandle = getShadowMapHandle,
        };

        fn wrapper(self: *@This()) ShadowSystemWrapper {
            return .{ .ctx = .{ .ptr = self, .vtable = &VTABLE } };
        }

        fn beginPass(_: *anyopaque, _: u32, _: Mat4) void {}
        fn endPass(_: *anyopaque) void {}
        fn updateUniforms(_: *anyopaque, _: rhi.ShadowParams) anyerror!void {}
        fn getShadowMapHandle(_: *anyopaque, cascade_index: u32) rhi.TextureHandle {
            return cascade_index + 1;
        }
    };

    var mock_ui = MockUI{};
    var ui = try UISystem.init(mock_ui.renderer(), 1280, 720);
    var mock_shadow = MockShadow{};

    ui.begin();
    DebugShadowOverlay.draw(&ui, mock_shadow.wrapper(), 1280, 720, .{ .show_labels = false }, &.{});
    ui.end();

    try std.testing.expectEqual(@as(u32, 1), mock_ui.begin_count);
    try std.testing.expectEqual(@as(u32, 1), mock_ui.end_count);
    try std.testing.expectEqual(@as(u32, rhi.SHADOW_CASCADE_COUNT), mock_ui.depth_texture_count);
}
