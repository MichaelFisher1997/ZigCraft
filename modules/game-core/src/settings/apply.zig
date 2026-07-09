const Settings = @import("data.zig").Settings;
const anyTerrainDebugActive = @import("data.zig").anyTerrainDebugActive;
const resolveShadowDebugChannel = @import("data.zig").resolveShadowDebugChannel;
const RHI = @import("engine-rhi").RHI;
const IRenderSettings = @import("engine-core").interfaces.IRenderSettings;

/// Applies settings that have direct RHI setters. Call this after any settings change.
///
/// ## Settings Applied Immediately (via RHI setters):
/// - `vsync` - Swap chain presentation mode
/// - `wireframe_enabled` - Rasterizer fill mode
/// - `textures_enabled` - Texture sampling toggle
/// - `anisotropic_filtering` - Sampler anisotropy level
/// - `msaa_samples` - Multisample anti-aliasing sample count
/// - `taa_blend_factor` - TAA history accumulation factor
/// - `taa_velocity_rejection` - TAA motion rejection threshold
/// - `fxaa_enabled` - FXAA post-process toggle
///
/// ## Settings NOT Applied Here (consumed elsewhere):
/// These settings take effect without requiring this function because they are
/// read directly from the Settings struct each frame or during resource creation:
///
/// | Setting                     | Consumed By                          | When Applied           |
/// |-----------------------------|--------------------------------------|------------------------|
/// | `shadow_quality`            | RHI shadow resource manager          | Next frame boundary    |
/// | `shadow_pcf_samples`        | Shadow shader uniforms               | Next frame             |
/// | `shadow_cascade_blend`      | Shadow shader uniforms               | Next frame             |
/// | `pbr_enabled`, `pbr_quality`| updateGlobalUniforms() in App        | Next frame             |
/// | `volumetric_*`              | AtmosphereSystem / VolumetricPass    | Next frame             |
/// | `ssao_enabled`              | SSAOPass                             | Next frame             |
/// | `render_distance`           | World / ChunkManager                 | Next frame             |
/// | `max_texture_resolution`    | TextureLoader on texture load        | On asset reload        |
/// | `fov`, `mouse_sensitivity`  | Camera / InputMapper                 | Next frame             |
/// | `window_*`, `fullscreen`    | WindowManager                        | On explicit apply      |
/// | `taa_enabled`               | TAA render graph stage toggle        | Next frame             |
///
/// This separation exists because RHI exposes setters only for GPU pipeline state,
/// while other settings are architectural concerns handled by their respective systems.
pub fn applyToRHI(settings: *const Settings, rhi: *RHI) void {
    const options = rhi.options();
    options.setVSync(settings.vsync);
    options.setWireframe(settings.wireframe_enabled);
    options.setTexturesEnabled(settings.textures_enabled);
    options.setDebugShadowView(anyTerrainDebugActive(settings));
    options.setShadowDebugChannel(@intFromEnum(resolveShadowDebugChannel(settings)));
    options.setAnisotropicFiltering(settings.anisotropic_filtering);
    options.setShadowResolution(settings.getShadowResolution());
    options.setMSAA(settings.msaa_samples);
    options.setFXAA(settings.fxaa_enabled and !settings.taa_enabled);
    options.setTAABlendFactor(settings.taa_blend_factor);
    options.setTAAVelocityRejection(settings.taa_velocity_rejection);
    options.setDynamicResolution(settings.dynamic_resolution_enabled, settings.dynamic_resolution_min_scale, settings.dynamic_resolution_max_scale, settings.target_fps);
}

pub fn applyToRenderSettings(settings: *const Settings, rs: IRenderSettings) void {
    rs.setVSync(settings.vsync);
    rs.setWireframe(settings.wireframe_enabled);
    rs.setTexturesEnabled(settings.textures_enabled);
    rs.setDebugShadowView(anyTerrainDebugActive(settings));
    rs.setAnisotropicFiltering(settings.anisotropic_filtering);
    rs.setMSAA(settings.msaa_samples);
    rs.setFXAA(settings.fxaa_enabled and !settings.taa_enabled);
    rs.setTAABlendFactor(settings.taa_blend_factor);
    rs.setTAAVelocityRejection(settings.taa_velocity_rejection);
}
