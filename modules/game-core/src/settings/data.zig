const std = @import("std");
const RenderDistancePreset = @import("engine-rhi").RenderDistancePreset;

pub const ShadowDebugChannel = enum(u32) {
    off = 0,
    shadow_factor = 1,
    cascade_index = 2,
    caster_coverage = 3,
    seam_diagnostics = 4,
    tile_id = 5,
    tex_color = 6,
    direct_key = 7,
    sky_fill = 8,
    block_light = 9,
    outdoor_factor = 10,
    entrance_bounce = 11,
};

pub fn resolveShadowDebugChannel(settings: *const @This().Settings) ShadowDebugChannel {
    if (settings.debug_direct_key_active) return .direct_key;
    if (settings.debug_sky_fill_active) return .sky_fill;
    if (settings.debug_entrance_bounce_active) return .entrance_bounce;
    if (settings.debug_block_light_active) return .block_light;
    if (settings.debug_outdoor_factor_active) return .outdoor_factor;
    if (settings.debug_shadow_seam_diag) return .seam_diagnostics;
    if (settings.debug_shadow_caster_coverage) return .caster_coverage;
    if (settings.debug_shadow_cascade_index) return .cascade_index;
    if (settings.debug_shadows_active) return .shadow_factor;
    return .off;
}

pub fn anyShadowMapDebugActive(settings: *const @This().Settings) bool {
    return settings.debug_shadows_active or settings.debug_shadow_cascade_index or settings.debug_shadow_caster_coverage or settings.debug_shadow_seam_diag;
}

pub fn anyTerrainDebugActive(settings: *const @This().Settings) bool {
    return resolveShadowDebugChannel(settings) != .off;
}

pub fn clearTerrainDebugViews(settings: *@This().Settings) void {
    settings.debug_shadows_active = false;
    settings.debug_shadow_cascade_index = false;
    settings.debug_shadow_caster_coverage = false;
    settings.debug_shadow_seam_diag = false;
    settings.debug_direct_key_active = false;
    settings.debug_sky_fill_active = false;
    settings.debug_entrance_bounce_active = false;
    settings.debug_block_light_active = false;
    settings.debug_outdoor_factor_active = false;
}

pub fn sanitizeRuntimeConflicts(settings: *@This().Settings) bool {
    if (settings.lod_enabled and settings.taa_enabled) {
        settings.taa_enabled = false;
        settings.fxaa_enabled = true;
        return true;
    }
    return false;
}

pub const ShadowQuality = struct {
    resolution: u32,
    label: []const u8,
};

pub const SHADOW_QUALITIES = [_]ShadowQuality{
    .{ .resolution = 1024, .label = "LOW" },
    .{ .resolution = 1536, .label = "MEDIUM" },
    .{ .resolution = 2048, .label = "HIGH" },
    .{ .resolution = 4096, .label = "ULTRA" },
};

pub const Resolution = struct {
    width: u32,
    height: u32,
    label: []const u8,
};

pub const RESOLUTIONS = [_]Resolution{
    .{ .width = 1280, .height = 720, .label = "1280X720" },
    .{ .width = 1600, .height = 900, .label = "1600X900" },
    .{ .width = 1920, .height = 1080, .label = "1920X1080" },
    .{ .width = 2560, .height = 1080, .label = "2560X1080" },
    .{ .width = 2560, .height = 1440, .label = "2560X1440" },
    .{ .width = 3440, .height = 1440, .label = "3440X1440" },
    .{ .width = 3840, .height = 2160, .label = "3840X2160" },
};

pub const Settings = struct {
    render_distance: i32 = 15,
    horizon_distance: i32 = 512,
    mouse_sensitivity: f32 = 50.0,
    vsync: bool = true,
    fov: f32 = 45.0,
    textures_enabled: bool = true,
    wireframe_enabled: bool = false,
    debug_shadows_active: bool = false,
    debug_shadow_cascade_index: bool = false,
    debug_shadow_caster_coverage: bool = false,
    debug_shadow_seam_diag: bool = false,
    shadow_sandbox_enabled: bool = true,
    shadow_beauty_enabled: bool = true,
    shadow_probe_enabled: bool = false,
    debug_direct_key_active: bool = false,
    debug_sky_fill_active: bool = false,
    debug_entrance_bounce_active: bool = false,
    debug_block_light_active: bool = false,
    debug_outdoor_factor_active: bool = false,
    debug_lpv_overlay_active: bool = false,
    debug_frustum_active: bool = false,
    debug_occlusion_active: bool = false,
    shadow_quality: u32 = 2, // 0=Low, 1=Medium, 2=High, 3=Ultra
    shadow_distance: f32 = 250.0,
    anisotropic_filtering: u8 = 16,
    msaa_samples: u8 = 4,
    taa_enabled: bool = false,
    taa_blend_factor: f32 = 0.9,
    taa_velocity_rejection: f32 = 0.02,
    ui_scale: f32 = 1.0, // Manual UI scale multiplier (0.5 to 2.0)
    window_width: u32 = 1920,
    window_height: u32 = 1080,
    lod_enabled: bool = false,
    render_distance_preset: RenderDistancePreset = .high,
    texture_pack: []const u8 = "default",
    environment_map: []const u8 = "default", // "default" or filename.exr/hdr

    // PBR Settings
    pbr_enabled: bool = false,
    pbr_quality: u8 = 0, // 0=Off, 1=Low (no normal maps), 2=Full
    exposure: f32 = 1.0,
    saturation: f32 = 1.08,

    // Shadow Settings
    shadow_pcf_samples: u8 = 4, // 4, 8, 12, 16
    shadow_cascade_blend: bool = true,
    shadow_caster_distance: f32 = 250.0,

    // Volumetric Lighting Settings (Phase 4)
    volumetric_lighting_enabled: bool = false,
    sun_shafts_enabled: bool = false,
    sun_shafts_intensity: f32 = 0.45,
    volumetric_density: f32 = 0.05, // Fog density
    volumetric_steps: u32 = 16, // Raymarching steps
    volumetric_scattering: f32 = 0.8, // Mie scattering anisotropy (G)
    ssao_enabled: bool = false,

    // LPV Settings (Issue #260)
    lpv_enabled: bool = false,
    lpv_quality_preset: u32 = 1, // 0=Fast, 1=Balanced, 2=Quality
    lpv_intensity: f32 = 0.5,
    lpv_cell_size: f32 = 2.0,
    lpv_grid_size: u32 = 32, // Derived from lpv_quality_preset at runtime
    lpv_propagation_iterations: u32 = 3, // Derived from lpv_quality_preset at runtime
    lpv_update_interval_frames: u32 = 6, // Derived from lpv_quality_preset at runtime

    // FXAA Settings (Phase 3)
    fxaa_enabled: bool = true,

    // Bloom Settings (Phase 3)
    bloom_enabled: bool = false,
    bloom_intensity: f32 = 0.5,

    // Post-Processing Settings (Phase 6)
    vignette_enabled: bool = false,
    vignette_intensity: f32 = 0.3,
    film_grain_enabled: bool = false,
    film_grain_intensity: f32 = 0.15,

    // Texture Settings
    max_texture_resolution: u32 = 512, // 16, 32, 64, 128, 256, 512

    // Water Settings (Issue #390)
    water_quality: u8 = 2, // 0=Low, 1=Medium, 2=High

    // Cloud Settings (Luanti-style CPU mesh clouds)
    clouds_enabled: bool = true,
    clouds_3d_enabled: bool = true,
    cloud_radius: u16 = 25,
    cloud_density: f32 = 0.42,
    cloud_height: f32 = 192.0,
    cloud_thickness: f32 = 16.0,
    cloud_speed_x: f32 = 0.0,
    cloud_speed_z: f32 = -2.0,

    // Dynamic Resolution Settings (Issue #392)
    dynamic_resolution_enabled: bool = false,
    dynamic_resolution_min_scale: f32 = 0.5,
    dynamic_resolution_max_scale: f32 = 1.0,
    target_fps: u32 = 60,

    pub const SettingMetadata = struct {
        label: []const u8,
        description: []const u8 = "",
        kind: union(enum) {
            toggle: void,
            slider: struct { min: f32, max: f32, step: f32 },
            choice: struct { labels: []const []const u8, values: ?[]const u32 = null },
            int_range: struct { min: i32, max: i32, step: i32 },
        },
    };

    pub const metadata = struct {
        pub const render_distance = SettingMetadata{
            .label = "RENDER DISTANCE",
            .kind = .{ .int_range = .{ .min = 2, .max = 32, .step = 1 } },
        };
        pub const horizon_distance = SettingMetadata{
            .label = "HORIZON DISTANCE",
            .description = "Coarsest LOD radius in chunks, independent of full-detail render distance",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "256 CHUNKS", "512 CHUNKS", "1024 CHUNKS", "2048 CHUNKS" },
                .values = &[_]u32{ 256, 512, 1024, 2048 },
            } },
        };
        pub const mouse_sensitivity = SettingMetadata{
            .label = "SENSITIVITY",
            .kind = .{ .slider = .{ .min = 1.0, .max = 200.0, .step = 1.0 } },
        };
        pub const fov = SettingMetadata{
            .label = "FOV",
            .kind = .{ .slider = .{ .min = 30.0, .max = 120.0, .step = 1.0 } },
        };
        pub const vsync = SettingMetadata{
            .label = "VSYNC",
            .kind = .toggle,
        };
        pub const textures_enabled = SettingMetadata{
            .label = "TEXTURES",
            .kind = .toggle,
        };
        pub const shadow_quality = SettingMetadata{
            .label = "SHADOW RESOLUTION",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "LOW", "MEDIUM", "HIGH", "ULTRA" },
                .values = &[_]u32{ 0, 1, 2, 3 },
            } },
        };
        pub const shadow_pcf_samples = SettingMetadata{
            .label = "SHADOW SOFTNESS",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "4 SAMPLES", "8 SAMPLES", "12 SAMPLES", "16 SAMPLES" },
                .values = &[_]u32{ 4, 8, 12, 16 },
            } },
        };
        pub const shadow_cascade_blend = SettingMetadata{
            .label = "CASCADE BLENDING",
            .kind = .toggle,
        };
        pub const shadow_distance = SettingMetadata{
            .label = "SHADOW DISTANCE",
            .description = "Maximum distance for shadow rendering (higher = more shadows but lower performance)",
            .kind = .{ .slider = .{ .min = 100.0, .max = 1000.0, .step = 50.0 } },
        };
        pub const shadow_caster_distance = SettingMetadata{
            .label = "SHADOW CASTER DISTANCE",
            .description = "Distance from camera to render shadow-casting geometry",
            .kind = .{ .slider = .{ .min = 50.0, .max = 500.0, .step = 25.0 } },
        };
        pub const pbr_enabled = SettingMetadata{
            .label = "PBR RENDERING",
            .kind = .toggle,
        };
        pub const pbr_quality = SettingMetadata{
            .label = "PBR QUALITY",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "OFF", "LOW", "FULL" },
                .values = &[_]u32{ 0, 1, 2 },
            } },
        };
        pub const anisotropic_filtering = SettingMetadata{
            .label = "ANISOTROPIC FILTER",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "OFF", "2X", "4X", "8X", "16X" },
                .values = &[_]u32{ 1, 2, 4, 8, 16 },
            } },
        };
        pub const msaa_samples = SettingMetadata{
            .label = "ANTI-ALIASING (LEGACY)",
            .description = "Legacy setting retained for compatibility while TAA rollout completes",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "OFF", "2X", "4X", "8X" },
                .values = &[_]u32{ 1, 2, 4, 8 },
            } },
        };
        pub const taa_enabled = SettingMetadata{
            .label = "TEMPORAL AA (TAA)",
            .description = "Experimental temporal anti-aliasing pipeline",
            .kind = .toggle,
        };
        pub const taa_blend_factor = SettingMetadata{
            .label = "TAA HISTORY BLEND",
            .description = "Higher values favor temporal stability over responsiveness",
            .kind = .{ .slider = .{ .min = 0.50, .max = 0.98, .step = 0.02 } },
        };
        pub const taa_velocity_rejection = SettingMetadata{
            .label = "TAA VELOCITY REJECT",
            .description = "Lower values reject history sooner on motion",
            .kind = .{ .slider = .{ .min = 0.0, .max = 0.25, .step = 0.01 } },
        };
        pub const max_texture_resolution = SettingMetadata{
            .label = "MAX TEXTURE RES",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "16 PX", "32 PX", "64 PX", "128 PX", "256 PX", "512 PX" },
                .values = &[_]u32{ 16, 32, 64, 128, 256, 512 },
            } },
        };
        pub const lod_enabled = SettingMetadata{
            .label = "LOD SYSTEM",
            .description = "Enables high-distance simplified terrain rendering",
            .kind = .toggle,
        };
        pub const ssao_enabled = SettingMetadata{
            .label = "SSAO",
            .kind = .toggle,
        };
        pub const fxaa_enabled = SettingMetadata{
            .label = "FXAA",
            .description = "Fast Approximate Anti-Aliasing",
            .kind = .toggle,
        };
        pub const bloom_enabled = SettingMetadata{
            .label = "BLOOM",
            .description = "HDR glow effect",
            .kind = .toggle,
        };
        pub const bloom_intensity = SettingMetadata{
            .label = "BLOOM INTENSITY",
            .kind = .{ .slider = .{ .min = 0.0, .max = 2.0, .step = 0.1 } },
        };
        pub const vignette_enabled = SettingMetadata{
            .label = "VIGNETTE",
            .description = "Darkens screen edges for cinematic effect",
            .kind = .toggle,
        };
        pub const vignette_intensity = SettingMetadata{
            .label = "VIGNETTE INTENSITY",
            .kind = .{ .slider = .{ .min = 0.0, .max = 1.0, .step = 0.05 } },
        };
        pub const film_grain_enabled = SettingMetadata{
            .label = "FILM GRAIN",
            .description = "Adds subtle noise for film-like appearance",
            .kind = .toggle,
        };
        pub const film_grain_intensity = SettingMetadata{
            .label = "GRAIN INTENSITY",
            .kind = .{ .slider = .{ .min = 0.0, .max = 1.0, .step = 0.05 } },
        };
        pub const volumetric_density = SettingMetadata{
            .label = "FOG DENSITY",
            .kind = .{ .slider = .{ .min = 0.0, .max = 0.5, .step = 0.05 } },
        };
        pub const volumetric_steps = SettingMetadata{
            .label = "VOLUMETRIC STEPS",
            .kind = .{ .int_range = .{ .min = 4, .max = 32, .step = 4 } },
        };
        pub const volumetric_scattering = SettingMetadata{
            .label = "VOLUMETRIC SCATTERING",
            .kind = .{ .slider = .{ .min = 0.0, .max = 1.0, .step = 0.05 } },
        };
        pub const lpv_enabled = SettingMetadata{
            .label = "LPV GI",
            .kind = .toggle,
        };
        pub const lpv_quality_preset = SettingMetadata{
            .label = "LPV QUALITY",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "FAST", "BALANCED", "QUALITY" },
                .values = &[_]u32{ 0, 1, 2 },
            } },
        };
        pub const lpv_intensity = SettingMetadata{
            .label = "LPV INTENSITY",
            .kind = .{ .slider = .{ .min = 0.0, .max = 2.0, .step = 0.1 } },
        };
        pub const lpv_cell_size = SettingMetadata{
            .label = "LPV CELL SIZE",
            .kind = .{ .slider = .{ .min = 1.0, .max = 4.0, .step = 0.25 } },
        };
        pub const water_quality = SettingMetadata{
            .label = "WATER QUALITY",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "LOW", "MEDIUM", "HIGH" },
                .values = &[_]u32{ 0, 1, 2 },
            } },
        };
        pub const dynamic_resolution_enabled = SettingMetadata{
            .label = "DYNAMIC RES",
            .description = "Adjusts render resolution to maintain target frame rate",
            .kind = .toggle,
        };
        pub const dynamic_resolution_min_scale = SettingMetadata{
            .label = "MIN RES SCALE",
            .description = "Minimum resolution scale when under heavy load",
            .kind = .{ .slider = .{ .min = 0.25, .max = 1.0, .step = 0.05 } },
        };
        pub const dynamic_resolution_max_scale = SettingMetadata{
            .label = "MAX RES SCALE",
            .description = "Maximum resolution scale when GPU has headroom",
            .kind = .{ .slider = .{ .min = 0.5, .max = 1.0, .step = 0.05 } },
        };
        pub const target_fps = SettingMetadata{
            .label = "TARGET FPS",
            .description = "Frame rate budget for dynamic resolution",
            .kind = .{ .choice = .{
                .labels = &[_][]const u8{ "30 FPS", "60 FPS", "120 FPS", "144 FPS" },
                .values = &[_]u32{ 30, 60, 120, 144 },
            } },
        };
    };

    pub fn getShadowResolution(self: *const Settings) u32 {
        if (self.shadow_quality < SHADOW_QUALITIES.len) {
            return SHADOW_QUALITIES[self.shadow_quality].resolution;
        }
        return SHADOW_QUALITIES[2].resolution;
    }

    pub fn getResolutionIndex(self: *const Settings) usize {
        for (RESOLUTIONS, 0..) |res, i| {
            if (res.width == self.window_width and res.height == self.window_height) {
                return i;
            }
        }
        return 2; // Default to 1920x1080
    }

    pub fn setResolutionByIndex(self: *Settings, idx: usize) void {
        if (idx < RESOLUTIONS.len) {
            self.window_width = RESOLUTIONS[idx].width;
            self.window_height = RESOLUTIONS[idx].height;
        }
    }
};
