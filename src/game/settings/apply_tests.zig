const std = @import("std");
const testing = std.testing;
const apply = @import("apply.zig");
const Settings = @import("data.zig").Settings;
const IRenderSettings = @import("../../engine/core/interfaces.zig").IRenderSettings;

const MockRenderSettings = struct {
    vsync_called_with: ?bool = null,
    wireframe_called_with: ?bool = null,
    textures_called_with: ?bool = null,
    debug_shadow_called_with: ?bool = null,
    anisotropic_called_with: ?u8 = null,
    msaa_called_with: ?u8 = null,
    taa_blend_called_with: ?f32 = null,
    taa_velocity_called_with: ?f32 = null,

    pub fn interface(self: *MockRenderSettings) IRenderSettings {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    const VTABLE = IRenderSettings.VTable{
        .setVSync = setVSync,
        .setWireframe = setWireframe,
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

    fn setVSync(ptr: *anyopaque, value: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.vsync_called_with = value;
    }

    fn setWireframe(ptr: *anyopaque, value: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.wireframe_called_with = value;
    }

    fn setTexturesEnabled(ptr: *anyopaque, value: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.textures_called_with = value;
    }

    fn setDebugShadowView(ptr: *anyopaque, value: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.debug_shadow_called_with = value;
    }

    fn setAnisotropicFiltering(ptr: *anyopaque, value: u8) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.anisotropic_called_with = value;
    }

    fn setMSAA(ptr: *anyopaque, value: u8) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.msaa_called_with = value;
    }

    fn setTAABlendFactor(ptr: *anyopaque, value: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.taa_blend_called_with = value;
    }

    fn setTAAVelocityRejection(ptr: *anyopaque, value: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.taa_velocity_called_with = value;
    }

    fn setFXAA(ptr: *anyopaque, value: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = value;
    }

    fn setBloom(ptr: *anyopaque, value: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = value;
    }

    fn setBloomIntensity(ptr: *anyopaque, value: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = value;
    }

    fn setVignetteEnabled(ptr: *anyopaque, value: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = value;
    }

    fn setVignetteIntensity(ptr: *anyopaque, value: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = value;
    }

    fn setFilmGrainEnabled(ptr: *anyopaque, value: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = value;
    }

    fn setFilmGrainIntensity(ptr: *anyopaque, value: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = value;
    }

    fn setVolumetricDensity(ptr: *anyopaque, value: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = value;
    }
};

test "applyToRenderSettings calls vsync, wireframe, textures, debug_shadow, anisotropic, msaa, taa_blend, taa_velocity" {
    var mock = MockRenderSettings{};
    var settings = Settings{
        .vsync = true,
        .wireframe_enabled = true,
        .textures_enabled = false,
        .debug_shadows_active = true,
        .anisotropic_filtering = 16,
        .msaa_samples = 8,
        .taa_blend_factor = 0.95,
        .taa_velocity_rejection = 0.05,
    };

    apply.applyToRenderSettings(&settings, mock.interface());

    try testing.expectEqual(@as(bool, true), mock.vsync_called_with);
    try testing.expectEqual(@as(bool, true), mock.wireframe_called_with);
    try testing.expectEqual(@as(bool, false), mock.textures_called_with);
    try testing.expectEqual(@as(bool, true), mock.debug_shadow_called_with);
    try testing.expectEqual(@as(u8, 16), mock.anisotropic_called_with);
    try testing.expectEqual(@as(u8, 8), mock.msaa_called_with);
    try testing.expectEqual(@as(f32, 0.95), mock.taa_blend_called_with);
    try testing.expectEqual(@as(f32, 0.05), mock.taa_velocity_called_with);
}

test "applyToRenderSettings passes false values correctly" {
    var mock = MockRenderSettings{};
    var settings = Settings{
        .vsync = false,
        .wireframe_enabled = false,
        .textures_enabled = true,
        .debug_shadows_active = false,
    };

    apply.applyToRenderSettings(&settings, mock.interface());

    try testing.expectEqual(@as(bool, false), mock.vsync_called_with);
    try testing.expectEqual(@as(bool, false), mock.wireframe_called_with);
    try testing.expectEqual(@as(bool, true), mock.textures_called_with);
    try testing.expectEqual(@as(bool, false), mock.debug_shadow_called_with);
}

test "applyToRenderSettings handles edge case values" {
    var mock = MockRenderSettings{};
    var settings = Settings{
        .anisotropic_filtering = 1,
        .msaa_samples = 1,
        .taa_blend_factor = 0.5,
        .taa_velocity_rejection = 0.0,
    };

    apply.applyToRenderSettings(&settings, mock.interface());

    try testing.expectEqual(@as(u8, 1), mock.anisotropic_called_with);
    try testing.expectEqual(@as(u8, 1), mock.msaa_called_with);
    try testing.expectEqual(@as(f32, 0.5), mock.taa_blend_called_with);
    try testing.expectEqual(@as(f32, 0.0), mock.taa_velocity_called_with);
}
