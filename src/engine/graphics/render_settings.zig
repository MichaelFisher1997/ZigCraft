const rhi_pkg = @import("rhi.zig");
const RHI = rhi_pkg.RHI;
const IRenderSettings = @import("../core/interfaces.zig").IRenderSettings;

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
