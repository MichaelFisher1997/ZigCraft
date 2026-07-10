const rhi_pkg = @import("engine-rhi");
const Vec3 = @import("engine-math").Vec3;
const Camera = @import("engine-camera").Camera;
const RenderSystem = @import("engine-graphics").RenderSystem;
const Settings = @import("game-core").settings.data.Settings;

pub const BuildInput = struct {
    camera: *Camera,
    settings: *Settings,
    render_system: *RenderSystem,
    screen_w: f32,
    screen_h: f32,
    render_sun_dir: Vec3,
    sky_color: Vec3,
    horizon_color: Vec3,
    sun_intensity: f32,
    moon_intensity: f32,
    time_of_day: f32,
    fog_color: Vec3,
    fog_density: f32,
    safe_mode: bool,
    startup_light_render: bool,
    shadow_sandbox_active: bool,
    shadow_beauty_active: bool,
    shadow_distance_active: f32,
    shadow_caster_distance_active: f32,
    lpv_cell_size: f32,
    lpv_grid_size: u32,
    lpv_origin: Vec3,
};

pub const BuiltParams = struct {
    aspect: f32,
    taa_enabled: bool,
    view_proj_render: @import("engine-math").Mat4,
    sky: rhi_pkg.SkyParams,
    frame: rhi_pkg.FrameRenderParams,
    ssao_enabled: bool,
};

pub fn build(input: BuildInput) BuiltParams {
    const aspect = input.screen_w / input.screen_h;
    const taa_enabled = input.settings.taa_enabled;
    const view_proj_render = input.camera.getJitteredProjectionMatrixReverseZ(aspect, input.screen_w, input.screen_h, taa_enabled).multiply(input.camera.getViewMatrixOriginCentered());
    const ssao_enabled = input.settings.ssao_enabled and !input.render_system.getDisableSSAO() and !input.render_system.getDisableGPassDraw() and !input.safe_mode and !input.startup_light_render;

    return .{
        .aspect = aspect,
        .taa_enabled = taa_enabled,
        .view_proj_render = view_proj_render,
        .sky = .{
            .cam_pos = input.camera.position,
            .cam_forward = input.camera.forward,
            .cam_right = input.camera.right,
            .cam_up = input.camera.up,
            .aspect = aspect,
            .tan_half_fov = @tan(input.camera.fov / 2.0),
            .sun_dir = input.render_sun_dir,
            .sky_color = input.sky_color,
            .horizon_color = input.horizon_color,
            .sun_intensity = input.sun_intensity,
            .moon_intensity = input.moon_intensity,
            .time = input.time_of_day,
        },
        .frame = .{
            .cam_pos = input.camera.position,
            .view_proj = view_proj_render,
            .sun_dir = input.render_sun_dir,
            .sun_intensity = input.sun_intensity,
            .fog_color = input.fog_color,
            .fog_density = input.fog_density,
            .pbr_enabled = input.settings.pbr_enabled and input.render_system.getAtlas().has_pbr and !input.safe_mode,
            .shadow_apply_to_beauty = input.shadow_beauty_active,
            .shadow = .{
                .distance = input.shadow_distance_active,
                .resolution = input.settings.getShadowResolution(),
                .pcf_samples = input.settings.shadow_pcf_samples,
                .cascade_blend = input.settings.shadow_cascade_blend,
                .caster_distance = input.shadow_caster_distance_active,
                .strength = if (input.safe_mode or !input.shadow_sandbox_active) 0.0 else 0.20,
            },
            .pbr_quality = input.settings.pbr_quality,
            .exposure = input.settings.exposure,
            .saturation = input.settings.saturation,
            .volumetric_enabled = input.settings.volumetric_lighting_enabled and !input.safe_mode and !input.startup_light_render,
            .sun_shafts_enabled = input.settings.sun_shafts_enabled and input.shadow_sandbox_active and !input.safe_mode,
            .sun_shafts_intensity = input.settings.sun_shafts_intensity,
            .volumetric_density = input.settings.volumetric_density,
            .volumetric_steps = input.settings.volumetric_steps,
            .volumetric_scattering = input.settings.volumetric_scattering,
            .ssao_enabled = ssao_enabled,
            .lpv_enabled = input.settings.lpv_enabled and !input.safe_mode and !input.startup_light_render,
            .lpv_intensity = input.settings.lpv_intensity,
            .lpv_cell_size = input.lpv_cell_size,
            .lpv_grid_size = input.lpv_grid_size,
            .lpv_origin = input.lpv_origin,
        },
        .ssao_enabled = ssao_enabled,
    };
}
