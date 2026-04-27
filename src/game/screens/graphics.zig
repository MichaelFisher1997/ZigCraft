const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Color = @import("../../engine/ui/ui_system.zig").Color;
const Font = @import("../../engine/ui/font.zig");
const Widgets = @import("../../engine/ui/widgets.zig");
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const settings_pkg = @import("../settings.zig");
const Settings = settings_pkg.Settings;
const render_settings_mod = @import("../../engine/graphics/render_settings.zig");
const RenderDistancePreset = render_settings_mod.RenderDistancePreset;

const PANEL_WIDTH_MAX = 850.0;
const PANEL_HEIGHT_BASE = 850.0;
const BG_COLOR = Color.rgba(0.025, 0.045, 0.065, 0.95);
const BORDER_COLOR = Color.rgba(0.42, 0.66, 0.82, 0.78);
const TITLE_COLOR = Color.rgba(1.0, 0.93, 0.76, 1.0);
const LABEL_COLOR = Color.rgba(0.72, 0.86, 0.96, 1.0);
const MUTED_COLOR = Color.rgba(0.48, 0.60, 0.70, 0.92);

pub const GraphicsScreen = struct {
    context: EngineContext,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext) !*GraphicsScreen {
        const self = try allocator.create(GraphicsScreen);
        self.* = .{
            .context = context,
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = dt;

        if (self.context.input_mapper.isActionPressed(self.context.input, .ui_back)) {
            self.context.saveSettings();
            self.context.screen_manager.popScreen();
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        const settings = ctx.settings;
        const rs = ctx.render_settings;

        // Draw background screen if it exists
        try ctx.screen_manager.drawParentScreen(ptr, ui);

        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);
        const mouse_clicked_right = ctx.input.isMouseButtonPressed(.right);

        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());

        const auto_scale: f32 = @max(1.0, screen_h / 720.0);
        const ui_scale: f32 = auto_scale * settings.ui_scale;
        const label_scale: f32 = 1.45 * ui_scale;
        const btn_scale: f32 = 1.35 * ui_scale;
        const title_scale: f32 = 3.0 * ui_scale;
        const row_height: f32 = 48.0 * ui_scale;
        const btn_height: f32 = 34.0 * ui_scale;
        const toggle_width: f32 = 180.0 * ui_scale;

        const pw: f32 = @min(screen_w * 0.8, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = @min(screen_h - 80.0 * ui_scale, PANEL_HEIGHT_BASE * ui_scale);
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = (screen_h - ph) * 0.5;

        drawGraphicsBackdrop(ui, screen_w, screen_h, ui_scale);
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRect(.{ .x = px, .y = py, .width = 7.0 * ui_scale, .height = ph }, Color.rgba(0.95, 0.62, 0.24, 0.95));
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = 72.0 * ui_scale }, Color.rgba(0.12, 0.22, 0.30, 0.64));
        ui.drawRect(.{ .x = px + pw - 2.0 * ui_scale, .y = py, .width = 2.0 * ui_scale, .height = ph }, Color.rgba(0.48, 0.76, 0.93, 0.62));
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawText(ui, "GRAPHICS SETTINGS", px + 34.0 * ui_scale, py + 24.0 * ui_scale, title_scale, TITLE_COLOR);
        Font.drawText(ui, "Renderer quality, post effects, and distance budgets.", px + 38.0 * ui_scale, py + 56.0 * ui_scale, 1.05 * ui_scale, MUTED_COLOR);

        var sy: f32 = py + 96.0 * ui_scale;
        const lx: f32 = px + 40.0 * ui_scale;
        const vx: f32 = px + pw - 220.0 * ui_scale;

        // Quality Preset
        Font.drawText(ui, "OVERALL QUALITY", lx, sy, label_scale, LABEL_COLOR);

        if (settings_pkg.json_presets.graphics_presets.items.len > 0) {
            const preset_idx = settings_pkg.json_presets.getIndex(settings);
            if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, getPresetLabel(preset_idx), btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                const next_idx = (preset_idx + 1) % (settings_pkg.json_presets.graphics_presets.items.len + 1);
                if (next_idx < settings_pkg.json_presets.graphics_presets.items.len) {
                    settings_pkg.json_presets.apply(settings, next_idx);
                    rs.setAnisotropicFiltering(settings.anisotropic_filtering);
                    rs.setTexturesEnabled(settings.textures_enabled);
                    rs.setTAABlendFactor(settings.taa_blend_factor);
                    rs.setTAAVelocityRejection(settings.taa_velocity_rejection);
                    if (settings.taa_enabled) {
                        settings.fxaa_enabled = false;
                        rs.setFXAA(false);
                    } else {
                        rs.setFXAA(settings.fxaa_enabled);
                    }
                } else {
                    // Custom selected, nothing changes in values but UI label updates to CUSTOM (via getPresetIndex next frame)
                }
            }
        } else {
            _ = Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, "ERROR", btn_scale, mouse_x, mouse_y, false);
        }
        sy += row_height + 10.0 * ui_scale;

        // Render Distance Preset
        Font.drawText(ui, "RENDER DISTANCE", lx, sy, label_scale, LABEL_COLOR);
        const current_rdp = @intFromEnum(settings.render_distance_preset);
        const rdp_label = settings.render_distance_preset.label();
        if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, rdp_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            const next = (current_rdp + 1) % @as(u32, RenderDistancePreset.count);
            settings.render_distance_preset = @enumFromInt(next);
            const preset_cfg = render_settings_mod.getPresetConfig(settings.render_distance_preset);
            settings.render_distance = preset_cfg.lod_radii[0];
        }
        sy += row_height;

        // Extreme preset warning
        {
            const preset_cfg = render_settings_mod.getPresetConfig(settings.render_distance_preset);
            if (preset_cfg.show_warning) {
                ui.drawRect(.{ .x = lx, .y = sy - 5.0, .width = pw - 80.0 * ui_scale, .height = 20.0 * ui_scale }, Color.rgba(0.6, 0.1, 0.1, 0.8));
                Font.drawText(ui, "WARNING: Extreme render distance may cause instability on GPUs with <8GB VRAM", lx + 5.0, sy, 1.2 * ui_scale, Color.rgba(1.0, 0.7, 0.3, 1.0));
                sy += 25.0 * ui_scale;
            }
        }

        var buf: [64]u8 = undefined;

        // Auto-generated UI from metadata
        inline for (comptime std.meta.declarations(Settings.metadata)) |decl| {
            if (comptime std.mem.eql(u8, decl.name, "msaa_samples")) continue;
            if (comptime std.mem.eql(u8, decl.name, "render_distance_preset")) continue;

            const meta = @field(Settings.metadata, decl.name);
            const val_ptr = &@field(settings, decl.name);
            const val_type = @TypeOf(val_ptr.*);
            const old_val = val_ptr.*;

            Font.drawText(ui, meta.label, lx, sy, label_scale, LABEL_COLOR);

            switch (meta.kind) {
                .toggle => {
                    const label = if (val_ptr.*) "ENABLED" else "DISABLED";
                    if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                        val_ptr.* = !val_ptr.*;
                    }
                },
                .choice => |choice| {
                    var current_label: []const u8 = "UNKNOWN";
                    if (choice.values) |values| {
                        for (values, 0..) |v, i| {
                            if (v == val_ptr.*) {
                                if (i < choice.labels.len) current_label = choice.labels[i];
                                break;
                            }
                        }
                    }
                    if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, current_label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                        if (choice.values) |values| {
                            var current_idx: usize = 0;
                            for (values, 0..) |v, i| {
                                if (v == val_ptr.*) {
                                    current_idx = i;
                                    break;
                                }
                            }
                            // Cycle: Left click forward, Right click backward (if we had right click)
                            // For now, standard cycle
                            const next_idx = (current_idx + 1) % values.len;
                            val_ptr.* = @as(val_type, @intCast(values[next_idx]));
                        }
                    }
                },
                .slider => |slider| {
                    const val_str = std.fmt.bufPrint(&buf, "{d:.1}", .{val_ptr.*}) catch "ERR";

                    if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, val_str, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                        // Left-click: increment with wrap to max-step for step alignment
                        if (val_ptr.* + slider.step > slider.max + 0.001) {
                            val_ptr.* = slider.max - slider.step;
                        } else {
                            val_ptr.* += slider.step;
                        }
                    } else {
                        const button_rect = .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height };
                        const is_hovered = (mouse_x >= button_rect.x and mouse_x <= button_rect.x + button_rect.width and mouse_y >= button_rect.y and mouse_y <= button_rect.y + button_rect.height);
                        if (is_hovered and mouse_clicked_right) {
                            // Right-click: decrement with wrap to max-step for step alignment
                            if (val_ptr.* - slider.step < slider.min - 0.001) {
                                val_ptr.* = slider.max - slider.step;
                            } else {
                                val_ptr.* -= slider.step;
                            }
                        }
                    }
                },
                .int_range => |range| {
                    const val_str = std.fmt.bufPrint(&buf, "{d}", .{val_ptr.*}) catch "ERR";

                    if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height }, val_str, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                        // Left-click: increment with wrap to max-step for step alignment
                        if (val_ptr.* + range.step > range.max) {
                            val_ptr.* = range.max - range.step;
                        } else {
                            val_ptr.* += range.step;
                        }
                    } else {
                        const button_rect = .{ .x = vx, .y = sy - 5.0, .width = toggle_width, .height = btn_height };
                        const is_hovered = (mouse_x >= button_rect.x and mouse_x <= button_rect.x + button_rect.width and mouse_y >= button_rect.y and mouse_y <= button_rect.y + button_rect.height);
                        if (is_hovered and mouse_clicked_right) {
                            // Right-click: decrement with wrap to max-step for step alignment
                            if (val_ptr.* - range.step < range.min) {
                                val_ptr.* = range.max - range.step;
                            } else {
                                val_ptr.* -= range.step;
                            }
                        }
                    }
                },
            }

            // Handle side effects
            if (val_ptr.* != old_val) {
                if (std.mem.eql(u8, decl.name, "anisotropic_filtering")) {
                    rs.setAnisotropicFiltering(settings.anisotropic_filtering);
                } else if (std.mem.eql(u8, decl.name, "textures_enabled")) {
                    rs.setTexturesEnabled(settings.textures_enabled);
                } else if (std.mem.eql(u8, decl.name, "vsync")) {
                    rs.setVSync(settings.vsync);
                } else if (std.mem.eql(u8, decl.name, "volumetric_density")) {
                    rs.setVolumetricDensity(settings.volumetric_density);
                } else if (std.mem.eql(u8, decl.name, "taa_enabled")) {
                    if (settings.taa_enabled) {
                        settings.fxaa_enabled = false;
                        rs.setFXAA(false);
                    }
                } else if (std.mem.eql(u8, decl.name, "taa_blend_factor")) {
                    rs.setTAABlendFactor(settings.taa_blend_factor);
                } else if (std.mem.eql(u8, decl.name, "taa_velocity_rejection")) {
                    rs.setTAAVelocityRejection(settings.taa_velocity_rejection);
                } else if (std.mem.eql(u8, decl.name, "fxaa_enabled")) {
                    if (settings.taa_enabled and settings.fxaa_enabled) {
                        settings.fxaa_enabled = false;
                        rs.setFXAA(false);
                    } else {
                        rs.setFXAA(settings.fxaa_enabled);
                    }
                } else if (std.mem.eql(u8, decl.name, "bloom_enabled")) {
                    rs.setBloom(settings.bloom_enabled);
                } else if (std.mem.eql(u8, decl.name, "bloom_intensity")) {
                    rs.setBloomIntensity(settings.bloom_intensity);
                } else if (std.mem.eql(u8, decl.name, "vignette_enabled")) {
                    rs.setVignetteEnabled(settings.vignette_enabled);
                } else if (std.mem.eql(u8, decl.name, "vignette_intensity")) {
                    rs.setVignetteIntensity(settings.vignette_intensity);
                } else if (std.mem.eql(u8, decl.name, "film_grain_enabled")) {
                    rs.setFilmGrainEnabled(settings.film_grain_enabled);
                } else if (std.mem.eql(u8, decl.name, "film_grain_intensity")) {
                    rs.setFilmGrainIntensity(settings.film_grain_intensity);
                } else if (std.mem.eql(u8, decl.name, "render_distance_preset")) {
                    const preset_cfg = render_settings_mod.getPresetConfig(settings.render_distance_preset);
                    settings.render_distance = preset_cfg.lod_radii[0];
                    settings.lod_enabled = true;
                }
            }

            if (std.mem.eql(u8, decl.name, "lpv_quality_preset")) {
                const legend = getLPVQualityLegend(settings.lpv_quality_preset);
                Font.drawText(ui, legend, vx - 90.0 * ui_scale, sy + row_height - 10.0 * ui_scale, 1.2 * ui_scale, Color.rgba(0.72, 0.86, 0.98, 1.0));
            }

            if (std.mem.eql(u8, decl.name, "render_distance_preset")) {
                const preset_cfg = render_settings_mod.getPresetConfig(settings.render_distance_preset);
                var info_buf: [64]u8 = undefined;
                const info = std.fmt.bufPrint(&info_buf, "LOD: {} {} {} {}", .{
                    preset_cfg.lod_radii[0],
                    preset_cfg.lod_radii[1],
                    preset_cfg.lod_radii[2],
                    preset_cfg.lod_radii[3],
                }) catch "LOD: ?";
                Font.drawText(ui, info, vx - 170.0 * ui_scale, sy + row_height - 10.0 * ui_scale, 1.2 * ui_scale, Color.rgba(0.5, 0.8, 1.0, 1.0));
            }

            sy += row_height;
        }

        // Back button
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 150.0 * ui_scale) * 0.5, .y = py + ph - 60.0 * ui_scale, .width = 150.0 * ui_scale, .height = 45.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
            ctx.saveSettings();
            ctx.screen_manager.popScreen();
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }
};

fn drawGraphicsBackdrop(ui: *UISystem, screen_w: f32, screen_h: f32, ui_scale: f32) void {
    ui.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0.010, 0.018, 0.030, 0.82));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.64, .width = screen_w, .height = screen_h * 0.36 }, Color.rgba(0.075, 0.048, 0.028, 0.52));
    ui.drawRect(.{ .x = 0, .y = screen_h * 0.64, .width = screen_w, .height = 2.0 * ui_scale }, Color.rgba(0.92, 0.62, 0.24, 0.40));
}

fn getPresetLabel(idx: usize) []const u8 {
    if (idx >= settings_pkg.json_presets.graphics_presets.items.len) return "CUSTOM";
    return settings_pkg.json_presets.graphics_presets.items[idx].name;
}

fn getLPVQualityLegend(preset: u32) []const u8 {
    return switch (preset) {
        0 => "GRID16  ITER2  TICK8",
        2 => "GRID64  ITER5  TICK3",
        else => "GRID32  ITER3  TICK6",
    };
}
