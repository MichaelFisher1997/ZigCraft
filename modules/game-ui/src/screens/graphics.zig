const std = @import("std");
const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Font = @import("engine-ui").font;
const Widgets = @import("engine-ui").widgets;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const settings_pkg = @import("game-core").settings;
const Settings = settings_pkg.Settings;
const render_settings_mod = @import("engine-rhi").render_settings;
const RenderDistancePreset = render_settings_mod.RenderDistancePreset;

const PANEL_WIDTH_MAX = 1100.0;
const BG_COLOR = Color.rgba(0.025, 0.045, 0.065, 0.95);
const BORDER_COLOR = Color.rgba(0.42, 0.66, 0.82, 0.78);
const TITLE_COLOR = Color.rgba(1.0, 0.93, 0.76, 1.0);
const LABEL_COLOR = Color.rgba(0.72, 0.86, 0.96, 1.0);
const MUTED_COLOR = Color.rgba(0.48, 0.60, 0.70, 0.92);

pub const GraphicsScreen = struct {
    context: EngineContext,
    scroll_offset: f32,

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
            .scroll_offset = 0.0,
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
        const label_scale: f32 = 1.35 * ui_scale;
        const btn_scale: f32 = 1.25 * ui_scale;
        const title_scale: f32 = 2.8 * ui_scale;
        const row_height: f32 = 44.0 * ui_scale;
        const btn_height: f32 = 32.0 * ui_scale;
        const toggle_width: f32 = 160.0 * ui_scale;
        const arrow_width: f32 = 36.0 * ui_scale;

        const margin: f32 = 40.0 * ui_scale;
        const pw: f32 = @min(screen_w - margin * 2.0, PANEL_WIDTH_MAX * ui_scale);
        const ph: f32 = screen_h - margin * 2.0;
        const px: f32 = (screen_w - pw) * 0.5;
        const py: f32 = margin;

        const header_h: f32 = 72.0 * ui_scale;
        const footer_h: f32 = 64.0 * ui_scale;
        const content_top: f32 = py + header_h;
        const content_bottom: f32 = py + ph - footer_h;

        drawGraphicsBackdrop(ui, screen_w, screen_h, ui_scale);
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = ph }, BG_COLOR);
        ui.drawRect(.{ .x = px, .y = py, .width = 7.0 * ui_scale, .height = ph }, Color.rgba(0.95, 0.62, 0.24, 0.95));
        ui.drawRect(.{ .x = px, .y = py, .width = pw, .height = header_h }, Color.rgba(0.12, 0.22, 0.30, 0.64));
        ui.drawRect(.{ .x = px + pw - 2.0 * ui_scale, .y = py, .width = 2.0 * ui_scale, .height = ph }, Color.rgba(0.48, 0.76, 0.93, 0.62));
        ui.drawRectOutline(.{ .x = px, .y = py, .width = pw, .height = ph }, BORDER_COLOR, 2.0 * ui_scale);
        Font.drawText(ui, "GRAPHICS SETTINGS", px + 34.0 * ui_scale, py + 20.0 * ui_scale, title_scale, TITLE_COLOR);
        Font.drawText(ui, "Renderer quality, post effects, and distance budgets.", px + 38.0 * ui_scale, py + 48.0 * ui_scale, 1.0 * ui_scale, MUTED_COLOR);

        // Content clipping area
        const content_h: f32 = content_bottom - content_top;
        ui.drawRect(.{ .x = px + 18.0 * ui_scale, .y = content_top, .width = pw - 36.0 * ui_scale, .height = content_h }, Color.rgba(0.010, 0.020, 0.030, 0.40));
        ui.drawRectOutline(.{ .x = px + 18.0 * ui_scale, .y = content_top, .width = pw - 36.0 * ui_scale, .height = content_h }, Color.rgba(0.20, 0.36, 0.48, 0.50), 1.0 * ui_scale);

        // Scroll
        const scroll_dy = ctx.input.getScrollDelta().y;
        self.scroll_offset -= scroll_dy * 28.0 * ui_scale;

        // Calculate total content height
        var total_rows: usize = 2; // preset + render distance
        inline for (comptime std.meta.declarations(Settings.metadata)) |decl| {
            if (comptime std.mem.eql(u8, decl.name, "msaa_samples")) continue;
            if (comptime std.mem.eql(u8, decl.name, "render_distance_preset")) continue;
            if (comptime std.mem.eql(u8, decl.name, "render_distance")) continue;
            total_rows += 1;
        }
        const warning_extra: f32 = if (render_settings_mod.getPresetConfig(settings.render_distance_preset).show_warning) 22.0 * ui_scale else 0.0;
        const total_content_h: f32 = @as(f32, @floatFromInt(total_rows)) * row_height + 40.0 * ui_scale + warning_extra;
        const max_scroll = @max(0.0, total_content_h - content_h);
        self.scroll_offset = @max(0.0, @min(self.scroll_offset, max_scroll));

        // Scrollbar
        if (max_scroll > 0.0) {
            const sb_x: f32 = px + pw - 24.0 * ui_scale;
            const sb_w: f32 = 6.0 * ui_scale;
            const sb_track_h: f32 = content_h - 20.0 * ui_scale;
            const sb_track_y: f32 = content_top + 10.0 * ui_scale;
            ui.drawRect(.{ .x = sb_x, .y = sb_track_y, .width = sb_w, .height = sb_track_h }, Color.rgba(0.15, 0.25, 0.35, 0.60));
            const sb_thumb_h: f32 = @max(20.0 * ui_scale, sb_track_h * (content_h / total_content_h));
            const sb_thumb_y: f32 = sb_track_y + (sb_track_h - sb_thumb_h) * (self.scroll_offset / max_scroll);
            ui.drawRect(.{ .x = sb_x, .y = sb_thumb_y, .width = sb_w, .height = sb_thumb_h }, Color.rgba(0.60, 0.80, 0.95, 0.80));
        }

        var sy: f32 = content_top + 10.0 * ui_scale - self.scroll_offset;
        const lx: f32 = px + 40.0 * ui_scale;
        const vx: f32 = px + pw - 240.0 * ui_scale;
        const content_left: f32 = px + 26.0 * ui_scale;
        const content_right: f32 = px + pw - 36.0 * ui_scale;

        // Helper to check if row is visible
        const isVisible = struct {
            fn check(y: f32, h: f32, top: f32, bottom: f32) bool {
                return y + h >= top and y <= bottom;
            }
        }.check;

        // Quality Preset
        if (isVisible(sy, row_height, content_top, content_bottom)) {
            Font.drawText(ui, "OVERALL QUALITY", lx, sy, label_scale, LABEL_COLOR);
            if (settings_pkg.json_presets.graphics_presets.items.len > 0) {
                const preset_idx = settings_pkg.json_presets.getIndex(settings);
                const preset_count = settings_pkg.json_presets.graphics_presets.items.len + 1;
                if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = arrow_width, .height = btn_height }, "<", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                    const prev_idx = if (preset_idx == 0) preset_count - 1 else preset_idx - 1;
                    if (prev_idx < settings_pkg.json_presets.graphics_presets.items.len) {
                        settings_pkg.json_presets.apply(settings, prev_idx);
                        applyPresetSideEffects(settings, rs);
                    }
                }
                Font.drawTextCentered(ui, getPresetLabel(preset_idx), vx + arrow_width + toggle_width * 0.5, sy + (btn_height - 7.0 * btn_scale) * 0.5, btn_scale, TITLE_COLOR);
                if (Widgets.drawButton(ui, .{ .x = vx + arrow_width + toggle_width, .y = sy - 4.0, .width = arrow_width, .height = btn_height }, ">", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                    const next_idx = (preset_idx + 1) % preset_count;
                    if (next_idx < settings_pkg.json_presets.graphics_presets.items.len) {
                        settings_pkg.json_presets.apply(settings, next_idx);
                        applyPresetSideEffects(settings, rs);
                    }
                }
            }
        }
        sy += row_height;

        // Render Distance Preset
        if (isVisible(sy, row_height, content_top, content_bottom)) {
            Font.drawText(ui, "RENDER DISTANCE", lx, sy, label_scale, LABEL_COLOR);
            const current_rdp = @intFromEnum(settings.render_distance_preset);
            const rdp_label = settings.render_distance_preset.label();
            const rdp_count = @as(u32, RenderDistancePreset.count);
            if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = arrow_width, .height = btn_height }, "<", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                const prev = if (current_rdp == 0) rdp_count - 1 else current_rdp - 1;
                settings.render_distance_preset = @enumFromInt(prev);
                const preset_cfg = render_settings_mod.getPresetConfig(settings.render_distance_preset);
                settings.render_distance = preset_cfg.lod_radii[0];
            }
            Font.drawTextCentered(ui, rdp_label, vx + arrow_width + toggle_width * 0.5, sy + (btn_height - 7.0 * btn_scale) * 0.5, btn_scale, TITLE_COLOR);
            if (Widgets.drawButton(ui, .{ .x = vx + arrow_width + toggle_width, .y = sy - 4.0, .width = arrow_width, .height = btn_height }, ">", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                const next = (current_rdp + 1) % rdp_count;
                settings.render_distance_preset = @enumFromInt(next);
                const preset_cfg = render_settings_mod.getPresetConfig(settings.render_distance_preset);
                settings.render_distance = preset_cfg.lod_radii[0];
            }
        }
        sy += row_height;

        // Extreme preset warning
        {
            const preset_cfg = render_settings_mod.getPresetConfig(settings.render_distance_preset);
            if (preset_cfg.show_warning and isVisible(sy, 22.0 * ui_scale, content_top, content_bottom)) {
                ui.drawRect(.{ .x = content_left, .y = sy - 4.0, .width = content_right - content_left, .height = 18.0 * ui_scale }, Color.rgba(0.6, 0.1, 0.1, 0.8));
                Font.drawText(ui, "WARNING: Extreme render distance may cause instability on GPUs with <8GB VRAM", lx, sy, 1.1 * ui_scale, Color.rgba(1.0, 0.7, 0.3, 1.0));
            }
            if (preset_cfg.show_warning) sy += 22.0 * ui_scale;
        }

        var buf: [64]u8 = undefined;

        inline for (comptime std.meta.declarations(Settings.metadata)) |decl| {
            if (comptime std.mem.eql(u8, decl.name, "msaa_samples")) continue;
            if (comptime std.mem.eql(u8, decl.name, "render_distance_preset")) continue;
            if (comptime std.mem.eql(u8, decl.name, "render_distance")) continue;

            const meta = @field(Settings.metadata, decl.name);
            const val_ptr = &@field(settings, decl.name);
            const val_type = @TypeOf(val_ptr.*);
            const old_val = val_ptr.*;

            if (isVisible(sy, row_height, content_top, content_bottom)) {
                Font.drawText(ui, meta.label, lx, sy, label_scale, LABEL_COLOR);

                switch (meta.kind) {
                    .toggle => {
                        const label = if (val_ptr.*) "ENABLED" else "DISABLED";
                        if (Widgets.drawButton(ui, .{ .x = vx + arrow_width, .y = sy - 4.0, .width = toggle_width, .height = btn_height }, label, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
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
                        if (choice.values) |values| {
                            var current_idx: usize = 0;
                            for (values, 0..) |v, i| {
                                if (v == val_ptr.*) {
                                    current_idx = i;
                                    break;
                                }
                            }
                            if (Widgets.drawButton(ui, .{ .x = vx, .y = sy - 4.0, .width = arrow_width, .height = btn_height }, "<", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                                const prev_idx = if (current_idx == 0) values.len - 1 else current_idx - 1;
                                val_ptr.* = @as(val_type, @intCast(values[prev_idx]));
                            }
                            Font.drawTextCentered(ui, current_label, vx + arrow_width + toggle_width * 0.5, sy + (btn_height - 7.0 * btn_scale) * 0.5, btn_scale, TITLE_COLOR);
                            if (Widgets.drawButton(ui, .{ .x = vx + arrow_width + toggle_width, .y = sy - 4.0, .width = arrow_width, .height = btn_height }, ">", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                                const next_idx = (current_idx + 1) % values.len;
                                val_ptr.* = @as(val_type, @intCast(values[next_idx]));
                            }
                        }
                    },
                    .slider => |slider| {
                        const val_str = std.fmt.bufPrint(&buf, "{d:.1}", .{val_ptr.*}) catch "ERR";
                        if (Widgets.drawButton(ui, .{ .x = vx + arrow_width, .y = sy - 4.0, .width = toggle_width, .height = btn_height }, val_str, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                            if (val_ptr.* + slider.step > slider.max + 0.001) {
                                val_ptr.* = slider.max - slider.step;
                            } else {
                                val_ptr.* += slider.step;
                            }
                        } else {
                            const button_rect = .{ .x = vx + arrow_width, .y = sy - 4.0, .width = toggle_width, .height = btn_height };
                            const is_hovered = (mouse_x >= button_rect.x and mouse_x <= button_rect.x + button_rect.width and mouse_y >= button_rect.y and mouse_y <= button_rect.y + button_rect.height);
                            if (is_hovered and mouse_clicked_right) {
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
                        if (Widgets.drawButton(ui, .{ .x = vx + arrow_width, .y = sy - 4.0, .width = toggle_width, .height = btn_height }, val_str, btn_scale, mouse_x, mouse_y, mouse_clicked)) {
                            if (val_ptr.* + range.step > range.max) {
                                val_ptr.* = range.max - range.step;
                            } else {
                                val_ptr.* += range.step;
                            }
                        } else {
                            const button_rect = .{ .x = vx + arrow_width, .y = sy - 4.0, .width = toggle_width, .height = btn_height };
                            const is_hovered = (mouse_x >= button_rect.x and mouse_x <= button_rect.x + button_rect.width and mouse_y >= button_rect.y and mouse_y <= button_rect.y + button_rect.height);
                            if (is_hovered and mouse_clicked_right) {
                                if (val_ptr.* - range.step < range.min) {
                                    val_ptr.* = range.max - range.step;
                                } else {
                                    val_ptr.* -= range.step;
                                }
                            }
                        }
                    },
                }

                if (std.mem.eql(u8, decl.name, "lpv_quality_preset")) {
                    const legend = getLPVQualityLegend(settings.lpv_quality_preset);
                    Font.drawText(ui, legend, vx - 80.0 * ui_scale, sy + row_height - 14.0 * ui_scale, 1.1 * ui_scale, Color.rgba(0.72, 0.86, 0.98, 1.0));
                }
            }

            // Side effects always run (even if not visible)
            if (val_ptr.* != old_val) {
                const sanitized_conflict = settings_pkg.sanitizeRuntimeConflicts(settings);
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
                }
                if (sanitized_conflict) {
                    rs.setFXAA(settings.fxaa_enabled and !settings.taa_enabled);
                }
            }

            sy += row_height;
        }

        // Footer / Back button
        const footer_y: f32 = py + ph - footer_h + 10.0 * ui_scale;
        ui.drawRect(.{ .x = px, .y = py + ph - footer_h, .width = pw, .height = 2.0 * ui_scale }, Color.rgba(0.20, 0.36, 0.48, 0.50));
        if (Widgets.drawButton(ui, .{ .x = px + (pw - 150.0 * ui_scale) * 0.5, .y = footer_y, .width = 150.0 * ui_scale, .height = 42.0 * ui_scale }, "BACK", btn_scale, mouse_x, mouse_y, mouse_clicked)) {
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

fn applyPresetSideEffects(settings: *Settings, rs: anytype) void {
    _ = settings_pkg.sanitizeRuntimeConflicts(settings);
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
}

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
