const rhi_pkg = @import("root.zig");
const RHI = rhi_pkg.RHI;
const IRenderSettings = @import("engine-core").interfaces.IRenderSettings;
const LODLevel = @import("engine-core").LODLevel;

pub const RenderDistancePreset = enum(u32) {
    low = 0,
    medium = 1,
    high = 2,
    ultra = 3,
    extreme = 4,

    pub const count = 5;

    pub fn label(self: RenderDistancePreset) []const u8 {
        return switch (self) {
            .low => "LOW",
            .medium => "MEDIUM",
            .high => "HIGH",
            .ultra => "ULTRA",
            .extreme => "EXTREME",
        };
    }
};

pub const RenderDistancePresetConfig = struct {
    lod_radii: [LODLevel.count]i32,
    fog_start_percent: [LODLevel.count]f32,
    active_lod_count: u32,
    qem_targets: [LODLevel.count]u32,
    memory_budget_mb: u32,
    max_uploads_per_frame: u32,
    skip_cutout_lod2: bool,
    skip_lighting_lod3: bool,
    show_warning: bool,
};

pub const RENDER_DISTANCE_PRESETS = [_]RenderDistancePresetConfig{
    .{
        .lod_radii = .{ 8, 16, 16, 16 },
        .fog_start_percent = .{ 0.5, 0.5, 0.0, 0.0 },
        .active_lod_count = 2,
        .qem_targets = .{ 0, 2000, 0, 0 },
        .memory_budget_mb = 128,
        .max_uploads_per_frame = 4,
        .skip_cutout_lod2 = false,
        .skip_lighting_lod3 = false,
        .show_warning = false,
    },
    .{
        .lod_radii = .{ 16, 32, 48, 64 },
        .fog_start_percent = .{ 0.5, 0.5, 0.4, 0.4 },
        .active_lod_count = 4,
        .qem_targets = .{ 0, 2000, 800, 200 },
        .memory_budget_mb = 256,
        .max_uploads_per_frame = 8,
        .skip_cutout_lod2 = false,
        .skip_lighting_lod3 = false,
        .show_warning = false,
    },
    .{
        .lod_radii = .{ 16, 32, 64, 100 },
        .fog_start_percent = .{ 0.5, 0.5, 0.4, 0.3 },
        .active_lod_count = 4,
        .qem_targets = .{ 0, 2000, 800, 200 },
        .memory_budget_mb = 384,
        .max_uploads_per_frame = 8,
        .skip_cutout_lod2 = true,
        .skip_lighting_lod3 = false,
        .show_warning = false,
    },
    .{
        .lod_radii = .{ 16, 32, 64, 256 },
        .fog_start_percent = .{ 0.5, 0.5, 0.4, 0.3 },
        .active_lod_count = 4,
        .qem_targets = .{ 0, 2000, 800, 200 },
        .memory_budget_mb = 512,
        .max_uploads_per_frame = 12,
        .skip_cutout_lod2 = true,
        .skip_lighting_lod3 = true,
        .show_warning = false,
    },
    .{
        .lod_radii = .{ 16, 32, 128, 512 },
        .fog_start_percent = .{ 0.5, 0.5, 0.4, 0.3 },
        .active_lod_count = 4,
        .qem_targets = .{ 0, 2000, 800, 200 },
        .memory_budget_mb = 1024,
        .max_uploads_per_frame = 16,
        .skip_cutout_lod2 = true,
        .skip_lighting_lod3 = true,
        .show_warning = true,
    },
};

pub fn getPresetConfig(preset: RenderDistancePreset) RenderDistancePresetConfig {
    return RENDER_DISTANCE_PRESETS[@intFromEnum(preset)];
}

pub const RenderSettingsAdapter = struct {
    rhi: *RHI,

    pub fn init(rhi: *RHI) RenderSettingsAdapter {
        return .{ .rhi = rhi };
    }

    pub fn interface(self: *RenderSettingsAdapter) IRenderSettings {
        return .{ .ptr = self, .vtable = &VTABLE };
    }

    const VTABLE = IRenderSettings.VTable{
        .setWireframe = setWireframe,
        .setVSync = setVSync,
        .setTexturesEnabled = setTexturesEnabled,
        .setAnisotropicFiltering = setAnisotropicFiltering,
        .setFXAA = setFXAA,
        .setBloom = setBloom,
        .setBloomIntensity = setBloomIntensity,
        .setTAABlendFactor = setTAABlendFactor,
        .setTAAVelocityRejection = setTAAVelocityRejection,
        .setVignetteEnabled = setVignetteEnabled,
        .setVignetteIntensity = setVignetteIntensity,
        .setFilmGrainEnabled = setFilmGrainEnabled,
        .setFilmGrainIntensity = setFilmGrainIntensity,
        .setVolumetricDensity = setVolumetricDensity,
        .setDebugShadowView = setDebugShadowView,
        .setMSAA = setMSAA,
    };

    fn setWireframe(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setWireframe(enabled);
    }

    fn setVSync(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setVSync(enabled);
    }

    fn setTexturesEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setTexturesEnabled(enabled);
    }

    fn setAnisotropicFiltering(ptr: *anyopaque, level: u8) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setAnisotropicFiltering(level);
    }

    fn setFXAA(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setFXAA(enabled);
    }

    fn setBloom(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setBloom(enabled);
    }

    fn setBloomIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setBloomIntensity(intensity);
    }

    fn setTAABlendFactor(ptr: *anyopaque, value: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setTAABlendFactor(value);
    }

    fn setTAAVelocityRejection(ptr: *anyopaque, value: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setTAAVelocityRejection(value);
    }

    fn setVignetteEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setVignetteEnabled(enabled);
    }

    fn setVignetteIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setVignetteIntensity(intensity);
    }

    fn setFilmGrainEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setFilmGrainEnabled(enabled);
    }

    fn setFilmGrainIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setFilmGrainIntensity(intensity);
    }

    fn setVolumetricDensity(ptr: *anyopaque, density: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setVolumetricDensity(density);
    }

    fn setDebugShadowView(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setDebugShadowView(enabled);
    }

    fn setMSAA(ptr: *anyopaque, samples: u8) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.setMSAA(samples);
    }
};
