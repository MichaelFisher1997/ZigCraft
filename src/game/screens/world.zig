const std = @import("std");
const UISystem = @import("../../engine/ui/ui_system.zig").UISystem;
const Screen = @import("../screen.zig");
const IScreen = Screen.IScreen;
const EngineContext = Screen.EngineContext;
const GameSession = @import("../session.zig").GameSession;
const Vec3 = @import("../../engine/math/vec3.zig").Vec3;
const rhi_pkg = @import("../../engine/graphics/rhi.zig");
const RenderSystem = @import("../../engine/graphics/render_system.zig").RenderSystem;
const render_graph_pkg = @import("../../engine/graphics/render_graph.zig");
const PausedScreen = @import("paused.zig").PausedScreen;
const DebugShadowOverlay = @import("../../engine/ui/debug_shadow_overlay.zig").DebugShadowOverlay;
const DebugLPVOverlay = @import("../../engine/ui/debug_lpv_overlay.zig").DebugLPVOverlay;
const DebugMenuOverlay = @import("../../engine/ui/debug_menu.zig").DebugMenuOverlay;
const DebugFeature = @import("../../engine/ui/debug_menu.zig").DebugFeature;
const Font = @import("../../engine/ui/font.zig");
const log = @import("../../engine/core/log.zig");

pub const WorldScreen = struct {
    context: EngineContext,
    session: *GameSession,
    last_debug_toggle_time: f32 = 0,
    debug_menu: DebugMenuOverlay,

    pub const vtable = IScreen.VTable{
        .deinit = deinit,
        .update = update,
        .draw = draw,
        .onEnter = onEnter,
        .onExit = onExit,
    };

    pub fn init(allocator: std.mem.Allocator, context: EngineContext, seed: u64, generator_index: usize) !*WorldScreen {
        const render_system = context.render_system;
        const session = try GameSession.init(allocator, render_system.getRHI(), render_system.getAtlas(), seed, context.settings.render_distance, context.settings.lod_enabled, generator_index);
        errdefer session.deinit();

        const self = try allocator.create(WorldScreen);
        self.* = .{
            .context = context,
            .session = session,
            .last_debug_toggle_time = 0,
            .debug_menu = .{},
        };
        return self;
    }

    pub fn deinit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.session.deinit();
        self.context.allocator.destroy(self);
    }

    pub fn update(ptr: *anyopaque, dt: f32) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        const render_system = ctx.render_system;
        const rhi = render_system.getRHI();
        const now = ctx.time.elapsed;
        const can_toggle_debug = now - self.last_debug_toggle_time > 0.2;

        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_debug_menu)) {
            self.debug_menu.toggle();
            if (self.debug_menu.enabled) {
                ctx.input.setMouseCapture(@ptrCast(@alignCast(ctx.window_manager.window)), false);
            } else {
                ctx.input.setMouseCapture(@ptrCast(@alignCast(ctx.window_manager.window)), true);
            }
            self.last_debug_toggle_time = now;
        }

        if (ctx.input_mapper.isActionPressed(ctx.input, .ui_back)) {
            const paused_screen = try PausedScreen.init(ctx.allocator, ctx);
            errdefer paused_screen.deinit(paused_screen);
            ctx.screen_manager.pushScreen(paused_screen.screen());
            return;
        }

        if (ctx.input_mapper.isActionPressed(ctx.input, .tab_menu)) {
            ctx.input.setMouseCapture(@ptrCast(@alignCast(ctx.window_manager.window)), !ctx.input.isMouseCaptured());
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_wireframe)) {
            ctx.settings.wireframe_enabled = !ctx.settings.wireframe_enabled;
            rhi.setWireframe(ctx.settings.wireframe_enabled);
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_textures)) {
            ctx.settings.textures_enabled = !ctx.settings.textures_enabled;
            rhi.setTexturesEnabled(ctx.settings.textures_enabled);
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_vsync)) {
            ctx.settings.vsync = !ctx.settings.vsync;
            rhi.setVSync(ctx.settings.vsync);
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_shadow_debug_vis)) {
            log.log.info("Toggling shadow debug visualization (G pressed)", .{});
            ctx.settings.debug_shadows_active = !ctx.settings.debug_shadows_active;
            rhi.setDebugShadowView(ctx.settings.debug_shadows_active);
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_lod_render)) {
            if (self.session.world.lod == null) {
                log.log.warn("LOD toggle requested but LOD system is not initialized", .{});
            } else {
                self.session.world.lod_enabled = !self.session.world.lod_enabled;
                log.log.info("LOD rendering {s}", .{if (self.session.world.lod_enabled) "enabled" else "disabled"});
            }
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_gpass_render)) {
            const new_val = !render_system.getDisableGPassDraw();
            render_system.setDisableGPassDraw(new_val);
            log.log.info("G-pass rendering {s}", .{if (new_val) "disabled" else "enabled"});
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_ssao)) {
            const new_val = !render_system.getDisableSSAO();
            render_system.setDisableSSAO(new_val);
            log.log.info("SSAO {s}", .{if (new_val) "disabled" else "enabled"});
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_clouds)) {
            const new_val = !render_system.getDisableClouds();
            render_system.setDisableClouds(new_val);
            log.log.info("Cloud rendering {s}", .{if (new_val) "disabled" else "enabled"});
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_fog)) {
            self.session.atmosphere.fog_enabled = !self.session.atmosphere.fog_enabled;
            log.log.info("Fog {s}", .{if (self.session.atmosphere.fog_enabled) "enabled" else "disabled"});
            self.last_debug_toggle_time = now;
        }
        if (can_toggle_debug and ctx.input_mapper.isActionPressed(ctx.input, .toggle_lpv_overlay)) {
            ctx.settings.debug_lpv_overlay_active = !ctx.settings.debug_lpv_overlay_active;
            log.log.info("LPV overlay {s}", .{if (ctx.settings.debug_lpv_overlay_active) "enabled" else "disabled"});
            self.last_debug_toggle_time = now;
        }

        const cam = &self.session.player.camera;
        ctx.audio_system.setListener(cam.position, cam.forward, cam.up);

        try self.session.update(dt, ctx.time.elapsed, ctx.input, ctx.input_mapper, render_system.getAtlas(), ctx.window_manager.window, false, ctx.skip_world_update);

        if (self.session.world.render_distance != ctx.settings.render_distance) {
            self.session.world.setRenderDistance(ctx.settings.render_distance);
        }
    }

    pub fn draw(ptr: *anyopaque, ui: *UISystem) !void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        const ctx = self.context;
        const render_system = ctx.render_system;
        const rhi = render_system.getRHI();
        const camera = &self.session.player.camera;

        const screen_w: f32 = @floatFromInt(ctx.input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(ctx.input.getWindowHeight());
        const aspect = screen_w / screen_h;

        const taa_enabled = ctx.settings.taa_enabled;
        const view_proj_render = camera.getJitteredProjectionMatrixReverseZ(aspect, screen_w, screen_h, taa_enabled).multiply(camera.getViewMatrixOriginCentered());

        const sky_params = rhi_pkg.SkyParams{
            .cam_pos = camera.position,
            .cam_forward = camera.forward,
            .cam_right = camera.right,
            .cam_up = camera.up,
            .aspect = aspect,
            .tan_half_fov = @tan(camera.fov / 2.0),
            .sun_dir = self.session.atmosphere.celestial.sun_dir,
            .sky_color = self.session.atmosphere.sky_color,
            .horizon_color = self.session.atmosphere.horizon_color,
            .sun_intensity = self.session.atmosphere.sun_intensity,
            .moon_intensity = self.session.atmosphere.moon_intensity,
            .time = self.session.atmosphere.time.time_of_day,
        };

        const ssao_enabled = ctx.settings.ssao_enabled and !render_system.getDisableSSAO() and !render_system.getDisableGPassDraw();
        const cloud_shadows_enabled = ctx.settings.cloud_shadows_enabled and !render_system.getDisableClouds();

        const lpv_quality = resolveLPVQuality(ctx.settings.lpv_quality_preset);
        const lpv_system = render_system.getLPVSystem();
        try lpv_system.setSettings(
            ctx.settings.lpv_enabled,
            ctx.settings.lpv_intensity,
            ctx.settings.lpv_cell_size,
            lpv_quality.propagation_iterations,
            lpv_quality.grid_size,
            lpv_quality.update_interval_frames,
        );
        rhi.timing().beginPassTiming("LPVPass");
        try lpv_system.update(self.session.world, camera.position, ctx.settings.debug_lpv_overlay_active);
        rhi.timing().endPassTiming("LPVPass");

        const lpv_origin = lpv_system.getOrigin();
        const cloud_params: rhi_pkg.CloudParams = blk: {
            const p = self.session.clouds.getShadowParams();
            break :blk .{
                .cam_pos = camera.position,
                .view_proj = view_proj_render,
                .sun_dir = self.session.atmosphere.celestial.sun_dir,
                .sun_intensity = self.session.atmosphere.sun_intensity,
                .fog_color = self.session.atmosphere.fog_color,
                .fog_density = self.session.atmosphere.fog_density,
                .wind_offset_x = p.wind_offset_x,
                .wind_offset_z = p.wind_offset_z,
                .cloud_scale = p.cloud_scale,
                .cloud_coverage = p.cloud_coverage,
                .cloud_height = p.cloud_height,
                .base_color = self.session.clouds.base_color,
                .pbr_enabled = ctx.settings.pbr_enabled and render_system.getAtlas().has_pbr,
                .shadow = .{
                    .distance = ctx.settings.shadow_distance,
                    .resolution = ctx.settings.getShadowResolution(),
                    .pcf_samples = ctx.settings.shadow_pcf_samples,
                    .cascade_blend = ctx.settings.shadow_cascade_blend,
                    .caster_distance = ctx.settings.shadow_caster_distance,
                    .lod_bias = ctx.settings.shadow_lod_bias,
                    .lod_enabled = ctx.settings.shadow_lod_enabled,
                },
                .cloud_shadows = cloud_shadows_enabled,
                .pbr_quality = ctx.settings.pbr_quality,
                .exposure = ctx.settings.exposure,
                .saturation = ctx.settings.saturation,
                .volumetric_enabled = ctx.settings.volumetric_lighting_enabled,
                .volumetric_density = ctx.settings.volumetric_density,
                .volumetric_steps = ctx.settings.volumetric_steps,
                .volumetric_scattering = ctx.settings.volumetric_scattering,
                .ssao_enabled = ssao_enabled,
                .lpv_enabled = ctx.settings.lpv_enabled,
                .lpv_intensity = ctx.settings.lpv_intensity,
                .lpv_cell_size = lpv_system.getCellSize(),
                .lpv_grid_size = lpv_system.getGridSize(),
                .lpv_origin = lpv_origin,
            };
        };

        const skip_world_render = render_system.getSafeRenderMode();
        if (!skip_world_render) {
            try rhi.updateGlobalUniforms(view_proj_render, camera.position, self.session.atmosphere.celestial.sun_dir, self.session.atmosphere.sun_color, self.session.atmosphere.time.time_of_day, self.session.atmosphere.fog_color, self.session.atmosphere.fog_density, self.session.atmosphere.fog_enabled, self.session.atmosphere.sun_intensity, self.session.atmosphere.ambient_intensity, ctx.settings.textures_enabled, cloud_params);

            const env_map_ptr = render_system.getEnvMapPtr();
            const env_map_handle = if (env_map_ptr.*) |t| t.handle else 0;

            var frame_cascades: ?@import("../../engine/graphics/csm.zig").ShadowCascades = null;

            const render_ctx = render_graph_pkg.SceneContext{
                .render_ctx = rhi.renderContext(),
                .shadow_ctx = rhi.shadowSystem(),
                .ssao_ctx = rhi.ssao(),
                .timing = rhi.timing(),
                .world = self.session.world,
                .shadow_scene = self.session.world.shadowScene(),
                .camera = camera,
                .atmosphere_system = render_system.getAtmosphereSystem(),
                .material_system = render_system.getMaterialSystem(),
                .aspect = aspect,
                .taa_enabled = taa_enabled,
                .viewport_width = screen_w,
                .viewport_height = screen_h,
                .sky_params = sky_params,
                .cloud_params = cloud_params,
                .main_shader = render_system.getShader(),
                .env_map_handle = env_map_handle,
                .shadow = cloud_params.shadow,
                .ssao_enabled = ssao_enabled,
                .disable_shadow_draw = render_system.getDisableShadowDraw(),
                .disable_gpass_draw = render_system.getDisableGPassDraw(),
                .disable_ssao = render_system.getDisableSSAO(),
                .disable_clouds = render_system.getDisableClouds(),
                .fxaa_enabled = ctx.settings.fxaa_enabled and !ctx.settings.taa_enabled,
                .bloom_enabled = ctx.settings.bloom_enabled,
                .overlay_renderer = renderOverlay,
                .overlay_ctx = self,
                .cached_cascades = &frame_cascades,
                .lpv_texture_handle = lpv_system.getTextureHandle(),
                .lpv_texture_handle_g = lpv_system.getTextureHandleG(),
                .lpv_texture_handle_b = lpv_system.getTextureHandleB(),
            };
            try render_system.getRenderGraph().execute(render_ctx);
        }

        if (taa_enabled) {
            camera.advanceJitter();
        } else {
            camera.resetJitter();
        }

        ui.begin();
        defer ui.end();

        const mouse_pos = ctx.input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const mouse_clicked = ctx.input.isMouseButtonPressed(.left);
        const hud_clicked = if (self.debug_menu.enabled) false else mouse_clicked;

        try self.session.drawHUD(ui, render_system.getAtlas(), render_system.getResourcePackManager().active_pack, ctx.time.fps, screen_w, screen_h, mouse_x, mouse_y, hud_clicked);

        if (ctx.settings.debug_shadows_active) {
            DebugShadowOverlay.draw(rhi.ui(), rhi.shadowSystem(), screen_w, screen_h, .{});
        }
        if (ctx.settings.debug_lpv_overlay_active) {
            const overlay_size = std.math.clamp(220.0 * ctx.settings.ui_scale, 160.0, screen_h * 0.4);
            const cfg = DebugLPVOverlay.Config{
                .width = overlay_size,
                .height = overlay_size,
                .spacing = 10.0 * ctx.settings.ui_scale,
            };
            const r = DebugLPVOverlay.rect(screen_h, cfg);
            DebugLPVOverlay.draw(rhi.ui(), lpv_system.getDebugOverlayTextureHandle(), screen_w, screen_h, cfg);

            const stats = lpv_system.getStats();
            const timing_results = rhi.timing().getTimingResults();
            var line0_buf: [64]u8 = undefined;
            var line1_buf: [64]u8 = undefined;
            var line2_buf: [64]u8 = undefined;
            var line3_buf: [64]u8 = undefined;
            const line0 = std.fmt.bufPrint(&line0_buf, "LPV GRID:{d} ITER:{d}", .{ stats.grid_size, stats.propagation_iterations }) catch "LPV";
            const line1 = std.fmt.bufPrint(&line1_buf, "LIGHTS:{d} UPDATE:{d:.2}MS", .{ stats.light_count, stats.cpu_update_ms }) catch "LIGHTS";
            const line2 = std.fmt.bufPrint(&line2_buf, "TICK:{d} UPDATED:{d}", .{ stats.update_interval_frames, if (stats.updated_this_frame) @as(u8, 1) else @as(u8, 0) }) catch "TICK";
            const line3 = std.fmt.bufPrint(&line3_buf, "LPV GPU:{d:.2}MS", .{timing_results.lpv_pass_ms}) catch "GPU";

            const text_x = r.x;
            const text_y = r.y - 28.0;
            Font.drawText(ui, line0, text_x, text_y, 1.5, .{ .r = 0.95, .g = 0.98, .b = 1.0, .a = 1.0 });
            Font.drawText(ui, line1, text_x, text_y + 10.0, 1.5, .{ .r = 0.95, .g = 0.98, .b = 1.0, .a = 1.0 });
            Font.drawText(ui, line2, text_x, text_y + 20.0, 1.5, .{ .r = 0.95, .g = 0.98, .b = 1.0, .a = 1.0 });
            Font.drawText(ui, line3, text_x, text_y + 30.0, 1.5, .{ .r = 0.95, .g = 0.98, .b = 1.0, .a = 1.0 });
        }

        if (self.debug_menu.enabled) {
            const feature_states = self.collectDebugStates(ctx, render_system);
            if (self.debug_menu.draw(ui, feature_states, mouse_x, mouse_y, mouse_clicked, ctx.settings.ui_scale)) |click| {
                self.applyDebugFeatureToggle(click.feature, ctx, render_system, rhi, ctx.time.elapsed);
            }
        }
    }

    pub fn onEnter(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, true);
    }

    pub fn onExit(ptr: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        self.context.input.setMouseCapture(self.context.window_manager.window, false);
    }

    pub fn screen(self: *@This()) IScreen {
        return Screen.makeScreen(@This(), self);
    }

    fn collectDebugStates(self: *WorldScreen, ctx: EngineContext, render_system: *RenderSystem) [DebugFeature.count]bool {
        var states: [DebugFeature.count]bool = @splat(false);
        states[@intFromEnum(DebugFeature.wireframe)] = ctx.settings.wireframe_enabled;
        states[@intFromEnum(DebugFeature.textures)] = ctx.settings.textures_enabled;
        states[@intFromEnum(DebugFeature.vsync)] = ctx.settings.vsync;
        states[@intFromEnum(DebugFeature.fps_counter)] = self.session.debug_show_fps;
        states[@intFromEnum(DebugFeature.block_info)] = self.session.debug_show_block_info;
        states[@intFromEnum(DebugFeature.shadow_debug)] = ctx.settings.debug_shadows_active;
        states[@intFromEnum(DebugFeature.timing_overlay)] = ctx.ui_manager.timing_overlay.enabled;
        states[@intFromEnum(DebugFeature.lod_render)] = self.session.world.lod_enabled;
        states[@intFromEnum(DebugFeature.gpass_render)] = !render_system.getDisableGPassDraw();
        states[@intFromEnum(DebugFeature.ssao)] = !render_system.getDisableSSAO();
        states[@intFromEnum(DebugFeature.clouds)] = !render_system.getDisableClouds();
        states[@intFromEnum(DebugFeature.fog)] = self.session.atmosphere.fog_enabled;
        states[@intFromEnum(DebugFeature.lpv_overlay)] = ctx.settings.debug_lpv_overlay_active;
        states[@intFromEnum(DebugFeature.creative_mode)] = self.session.creative_mode;
        states[@intFromEnum(DebugFeature.time_pause)] = self.session.atmosphere.time.time_scale == 0.0;
        return states;
    }

    fn applyDebugFeatureToggle(self: *WorldScreen, feature: DebugFeature, ctx: EngineContext, render_system: *RenderSystem, rhi: *rhi_pkg.RHI, now: f32) void {
        self.last_debug_toggle_time = now;
        switch (feature) {
            .wireframe => {
                ctx.settings.wireframe_enabled = !ctx.settings.wireframe_enabled;
                rhi.setWireframe(ctx.settings.wireframe_enabled);
            },
            .textures => {
                ctx.settings.textures_enabled = !ctx.settings.textures_enabled;
                rhi.setTexturesEnabled(ctx.settings.textures_enabled);
            },
            .vsync => {
                ctx.settings.vsync = !ctx.settings.vsync;
                rhi.setVSync(ctx.settings.vsync);
            },
            .fps_counter => {
                self.session.debug_show_fps = !self.session.debug_show_fps;
            },
            .block_info => {
                self.session.debug_show_block_info = !self.session.debug_show_block_info;
            },
            .shadow_debug => {
                ctx.settings.debug_shadows_active = !ctx.settings.debug_shadows_active;
                rhi.setDebugShadowView(ctx.settings.debug_shadows_active);
            },
            .timing_overlay => {
                ctx.ui_manager.timing_overlay.toggle();
                rhi.timing().setTimingEnabled(ctx.ui_manager.timing_overlay.enabled);
            },
            .lod_render => {
                if (self.session.world.lod == null) {
                    log.log.warn("LOD toggle requested but LOD system is not initialized", .{});
                } else {
                    self.session.world.lod_enabled = !self.session.world.lod_enabled;
                }
            },
            .gpass_render => {
                const new_val = !render_system.getDisableGPassDraw();
                render_system.setDisableGPassDraw(new_val);
            },
            .ssao => {
                const new_val = !render_system.getDisableSSAO();
                render_system.setDisableSSAO(new_val);
            },
            .clouds => {
                const new_val = !render_system.getDisableClouds();
                render_system.setDisableClouds(new_val);
            },
            .fog => {
                self.session.atmosphere.fog_enabled = !self.session.atmosphere.fog_enabled;
            },
            .lpv_overlay => {
                ctx.settings.debug_lpv_overlay_active = !ctx.settings.debug_lpv_overlay_active;
            },
            .creative_mode => {
                self.session.creative_mode = !self.session.creative_mode;
                self.session.player.setCreativeMode(self.session.creative_mode);
            },
            .time_pause => {
                self.session.atmosphere.time.time_scale = if (self.session.atmosphere.time.time_scale > 0) @as(f32, 0.0) else @as(f32, 1.0);
            },
        }
    }

    fn renderOverlay(scene_ctx: render_graph_pkg.SceneContext) void {
        const self: *WorldScreen = @ptrCast(@alignCast(scene_ctx.overlay_ctx.?));
        if (self.session.player.target_block) |target| self.session.block_outline.draw(scene_ctx.render_ctx, target.x, target.y, target.z, scene_ctx.camera.position);
        self.session.renderEntities(scene_ctx.render_ctx, scene_ctx.camera.position);
        self.session.hand_renderer.draw(scene_ctx.render_ctx, scene_ctx.camera.position, scene_ctx.camera.yaw, scene_ctx.camera.pitch);
    }
};

const LPVQualityResolved = struct {
    grid_size: u32,
    propagation_iterations: u32,
    update_interval_frames: u32,
};

fn resolveLPVQuality(preset: u32) LPVQualityResolved {
    return switch (preset) {
        0 => .{ .grid_size = 16, .propagation_iterations = 2, .update_interval_frames = 8 },
        2 => .{ .grid_size = 64, .propagation_iterations = 5, .update_interval_frames = 3 },
        else => .{ .grid_size = 32, .propagation_iterations = 3, .update_interval_frames = 6 },
    };
}
