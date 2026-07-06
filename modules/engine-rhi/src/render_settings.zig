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

pub const LODMeshPath = enum(u8) {
    /// Stable heightfield mesh path used by current defaults.
    heightfield,
    /// Rich column/span mesh path for vertical detail where source data provides spans.
    column_spans,
    /// Quadric error metric decimation path for experimentation while it stabilizes.
    qem,
};

pub const RenderDistancePresetConfig = struct {
    lod_radii: [LODLevel.count]i32,
    horizon_radius: i32,
    lod_store_size_cap_mb: u32,
    horizontal_detail: [LODLevel.count]u32,
    vertical_span_budget: u8,
    mesh_path: LODMeshPath,
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
        .lod_radii = .{ 6, 64, 156, 256, 256 },
        .horizon_radius = 256,
        .lod_store_size_cap_mb = 512,
        .horizontal_detail = .{ 33, 33, 33, 65, 65 },
        .vertical_span_budget = 2,
        .mesh_path = .column_spans,
        .fog_start_percent = .{ 0.5, 0.5, 0.4, 0.3, 0.22 },
        .active_lod_count = LODLevel.count,
        .qem_targets = .{ 0, 1200, 300, 48, 24 },
        .memory_budget_mb = 128,
        .max_uploads_per_frame = 4,
        .skip_cutout_lod2 = false,
        .skip_lighting_lod3 = false,
        .show_warning = false,
    },
    .{
        .lod_radii = .{ 10, 64, 156, 375, 512 },
        .horizon_radius = 512,
        .lod_store_size_cap_mb = 1024,
        .horizontal_detail = .{ 33, 49, 49, 65, 65 },
        .vertical_span_budget = 2,
        .mesh_path = .column_spans,
        .fog_start_percent = .{ 0.5, 0.5, 0.4, 0.4, 0.24 },
        .active_lod_count = LODLevel.count,
        .qem_targets = .{ 0, 2000, 800, 200, 64 },
        .memory_budget_mb = 256,
        .max_uploads_per_frame = 8,
        .skip_cutout_lod2 = false,
        .skip_lighting_lod3 = false,
        .show_warning = false,
    },
    .{
        .lod_radii = .{ 12, 64, 156, 375, 512 },
        .horizon_radius = 512,
        .lod_store_size_cap_mb = 1536,
        .horizontal_detail = .{ 33, 65, 65, 97, 97 },
        .vertical_span_budget = 3,
        .mesh_path = .column_spans,
        .fog_start_percent = .{ 0.5, 0.5, 0.4, 0.3, 0.22 },
        .active_lod_count = LODLevel.count,
        .qem_targets = .{ 0, 2000, 800, 200, 64 },
        .memory_budget_mb = 384,
        .max_uploads_per_frame = 8,
        .skip_cutout_lod2 = true,
        .skip_lighting_lod3 = false,
        .show_warning = false,
    },
    .{
        .lod_radii = .{ 14, 64, 156, 375, 1024 },
        .horizon_radius = 1024,
        .lod_store_size_cap_mb = 3072,
        .horizontal_detail = .{ 33, 65, 65, 129, 129 },
        .vertical_span_budget = 4,
        .mesh_path = .column_spans,
        .fog_start_percent = .{ 0.5, 0.5, 0.4, 0.3, 0.2 },
        .active_lod_count = LODLevel.count,
        .qem_targets = .{ 0, 2000, 800, 200, 64 },
        .memory_budget_mb = 512,
        .max_uploads_per_frame = 12,
        .skip_cutout_lod2 = true,
        .skip_lighting_lod3 = true,
        .show_warning = false,
    },
    .{
        .lod_radii = .{ 16, 64, 156, 375, 2048 },
        .horizon_radius = 2048,
        .lod_store_size_cap_mb = 4096,
        .horizontal_detail = .{ 33, 65, 65, 129, 129 },
        .vertical_span_budget = 4,
        .mesh_path = .column_spans,
        .fog_start_percent = .{ 0.5, 0.5, 0.4, 0.3, 0.18 },
        .active_lod_count = LODLevel.count,
        .qem_targets = .{ 0, 2000, 800, 200, 64 },
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
        self.rhi.options().setWireframe(enabled);
    }

    fn setVSync(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setVSync(enabled);
    }

    fn setTexturesEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setTexturesEnabled(enabled);
    }

    fn setAnisotropicFiltering(ptr: *anyopaque, level: u8) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setAnisotropicFiltering(level);
    }

    fn setFXAA(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setFXAA(enabled);
    }

    fn setBloom(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setBloom(enabled);
    }

    fn setBloomIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setBloomIntensity(intensity);
    }

    fn setTAABlendFactor(ptr: *anyopaque, value: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setTAABlendFactor(value);
    }

    fn setTAAVelocityRejection(ptr: *anyopaque, value: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setTAAVelocityRejection(value);
    }

    fn setVignetteEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setVignetteEnabled(enabled);
    }

    fn setVignetteIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setVignetteIntensity(intensity);
    }

    fn setFilmGrainEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setFilmGrainEnabled(enabled);
    }

    fn setFilmGrainIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setFilmGrainIntensity(intensity);
    }

    fn setVolumetricDensity(ptr: *anyopaque, density: f32) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setVolumetricDensity(density);
    }

    fn setDebugShadowView(ptr: *anyopaque, enabled: bool) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setDebugShadowView(enabled);
    }

    fn setMSAA(ptr: *anyopaque, samples: u8) void {
        const self: *RenderSettingsAdapter = @ptrCast(@alignCast(ptr));
        self.rhi.options().setMSAA(samples);
    }
};
