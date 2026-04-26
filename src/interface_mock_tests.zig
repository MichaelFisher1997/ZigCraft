const std = @import("std");
const testing = std.testing;
const Vec3 = @import("zig-math").Vec3;
const Mat4 = @import("zig-math").Mat4;
const IRenderSettings = @import("engine/core/interfaces.zig").IRenderSettings;
const IChunkStorage = @import("world/chunk_storage.zig").IChunkStorage;
const ChunkStorage = @import("world/chunk_storage.zig").ChunkStorage;
const ChunkData = @import("world/chunk_storage.zig").ChunkData;
const IWorld = @import("world/world.zig").IWorld;
const WorldStatsData = @import("world/world.zig").WorldStatsData;
const RenderStats = @import("world/world_renderer.zig").RenderStats;
const shadow_scene = @import("engine/graphics/shadow_scene.zig");
const ShadowConfig = @import("engine/graphics/rhi_types.zig").ShadowConfig;
const Settings = @import("game/settings/data.zig").Settings;
const settings_apply = @import("game/settings/apply.zig");

pub const std_options: std.Options = .{ .log_level = .err };

const MockChunkStorage = struct {
    get_calls: usize = 0,
    count_calls: usize = 0,
    total_calls: usize = 0,
    renderable_calls: usize = 0,
    count_value: usize = 11,
    total_value: u64 = 22,
    renderable_value: bool = true,

    pub fn interface(self: *MockChunkStorage) IChunkStorage {
        return .{ .ptr = self, .vtable = &VTABLE };
    }

    const VTABLE = IChunkStorage.VTable{
        .get = get,
        .count = count,
        .totalVertexCount = totalVertexCount,
        .isChunkRenderable = isChunkRenderable,
    };

    fn get(ptr: *anyopaque, cx: i32, cz: i32) ?*ChunkData {
        _ = cx;
        _ = cz;
        const self: *MockChunkStorage = @ptrCast(@alignCast(ptr));
        self.get_calls += 1;
        return null;
    }

    fn count(ptr: *anyopaque) usize {
        const self: *MockChunkStorage = @ptrCast(@alignCast(ptr));
        self.count_calls += 1;
        return self.count_value;
    }

    fn totalVertexCount(ptr: *anyopaque) u64 {
        const self: *MockChunkStorage = @ptrCast(@alignCast(ptr));
        self.total_calls += 1;
        return self.total_value;
    }

    fn isChunkRenderable(ptr: *anyopaque, cx: i32, cz: i32) bool {
        _ = cx;
        _ = cz;
        const self: *MockChunkStorage = @ptrCast(@alignCast(ptr));
        self.renderable_calls += 1;
        return self.renderable_value;
    }
};

const MockRenderSettings = struct {
    call_count: usize = 0,
    wireframe: bool = false,
    vsync: bool = false,
    textures_enabled: bool = false,
    anisotropic_filtering: u8 = 0,
    fxaa: bool = false,
    bloom: bool = false,
    bloom_intensity: f32 = 0,
    taa_blend_factor: f32 = 0,
    taa_velocity_rejection: f32 = 0,
    vignette_enabled: bool = false,
    vignette_intensity: f32 = 0,
    film_grain_enabled: bool = false,
    film_grain_intensity: f32 = 0,
    volumetric_density: f32 = 0,
    debug_shadow_view: bool = false,
    msaa_samples: u8 = 0,

    pub fn interface(self: *MockRenderSettings) IRenderSettings {
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
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.wireframe = enabled;
        self.call_count += 1;
    }

    fn setVSync(ptr: *anyopaque, enabled: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.vsync = enabled;
        self.call_count += 1;
    }

    fn setTexturesEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.textures_enabled = enabled;
        self.call_count += 1;
    }

    fn setAnisotropicFiltering(ptr: *anyopaque, level: u8) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.anisotropic_filtering = level;
        self.call_count += 1;
    }

    fn setFXAA(ptr: *anyopaque, enabled: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.fxaa = enabled;
        self.call_count += 1;
    }

    fn setBloom(ptr: *anyopaque, enabled: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.bloom = enabled;
        self.call_count += 1;
    }

    fn setBloomIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.bloom_intensity = intensity;
        self.call_count += 1;
    }

    fn setTAABlendFactor(ptr: *anyopaque, value: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.taa_blend_factor = value;
        self.call_count += 1;
    }

    fn setTAAVelocityRejection(ptr: *anyopaque, value: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.taa_velocity_rejection = value;
        self.call_count += 1;
    }

    fn setVignetteEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.vignette_enabled = enabled;
        self.call_count += 1;
    }

    fn setVignetteIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.vignette_intensity = intensity;
        self.call_count += 1;
    }

    fn setFilmGrainEnabled(ptr: *anyopaque, enabled: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.film_grain_enabled = enabled;
        self.call_count += 1;
    }

    fn setFilmGrainIntensity(ptr: *anyopaque, intensity: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.film_grain_intensity = intensity;
        self.call_count += 1;
    }

    fn setVolumetricDensity(ptr: *anyopaque, density: f32) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.volumetric_density = density;
        self.call_count += 1;
    }

    fn setDebugShadowView(ptr: *anyopaque, enabled: bool) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.debug_shadow_view = enabled;
        self.call_count += 1;
    }

    fn setMSAA(ptr: *anyopaque, samples: u8) void {
        const self: *MockRenderSettings = @ptrCast(@alignCast(ptr));
        self.msaa_samples = samples;
        self.call_count += 1;
    }
};

const MockWorld = struct {
    update_calls: usize = 0,
    render_calls: usize = 0,
    deinit_calls: usize = 0,
    get_render_stats_calls: usize = 0,
    get_stats_calls: usize = 0,
    get_lod_stats_calls: usize = 0,
    is_lod_enabled_calls: usize = 0,
    shadow_scene_calls: usize = 0,
    shadow_pass_calls: usize = 0,
    last_render_lod: bool = false,
    render_stats: RenderStats = .{ .chunks_total = 4, .chunks_rendered = 3, .chunks_culled = 1, .vertices_rendered = 99 },
    stats: WorldStatsData = .{ .chunks_loaded = 8, .total_vertices = 123, .gen_queue = 5, .mesh_queue = 6, .upload_queue = 7 },
    lod_enabled: bool = false,

    pub fn interface(self: *MockWorld) IWorld {
        return .{ .ptr = self, .vtable = &VTABLE };
    }

    const VTABLE = IWorld.VTable{
        .update = update,
        .render = render,
        .renderOpaque = renderOpaque,
        .renderFluid = renderFluid,
        .deinit = deinit,
        .getRenderStats = getRenderStats,
        .getStats = getStats,
        .getLODStats = getLODStats,
        .isLODEnabled = isLODEnabled,
        .shadowScene = shadowScene,
    };

    const SHADOW_VTABLE = shadow_scene.IShadowScene.VTable{
        .renderShadowPass = renderShadowPass,
    };

    fn update(ptr: *anyopaque, player_pos: Vec3, dt: f32) anyerror!void {
        _ = player_pos;
        _ = dt;
        const self: *MockWorld = @ptrCast(@alignCast(ptr));
        self.update_calls += 1;
    }

    fn render(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        _ = view_proj;
        _ = camera_pos;
        const self: *MockWorld = @ptrCast(@alignCast(ptr));
        self.render_calls += 1;
        self.last_render_lod = render_lod;
    }

    fn renderOpaque(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        render(ptr, view_proj, camera_pos, render_lod);
    }

    fn renderFluid(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        render(ptr, view_proj, camera_pos, render_lod);
    }

    fn deinit(ptr: *anyopaque) void {
        const self: *MockWorld = @ptrCast(@alignCast(ptr));
        self.deinit_calls += 1;
    }

    fn getRenderStats(ptr: *anyopaque) RenderStats {
        const self: *MockWorld = @ptrCast(@alignCast(ptr));
        self.get_render_stats_calls += 1;
        return self.render_stats;
    }

    fn getStats(ptr: *anyopaque) WorldStatsData {
        const self: *MockWorld = @ptrCast(@alignCast(ptr));
        self.get_stats_calls += 1;
        return self.stats;
    }

    fn getLODStats(ptr: *anyopaque) ?@import("world/lod_manager.zig").LODStats {
        const self: *MockWorld = @ptrCast(@alignCast(ptr));
        self.get_lod_stats_calls += 1;
        return null;
    }

    fn isLODEnabled(ptr: *anyopaque) bool {
        const self: *MockWorld = @ptrCast(@alignCast(ptr));
        self.is_lod_enabled_calls += 1;
        return self.lod_enabled;
    }

    fn shadowScene(ptr: *anyopaque) shadow_scene.IShadowScene {
        const self: *MockWorld = @ptrCast(@alignCast(ptr));
        self.shadow_scene_calls += 1;
        return .{ .ptr = self, .vtable = &SHADOW_VTABLE };
    }

    fn renderShadowPass(ptr: *anyopaque, light_space_matrix: Mat4, camera_pos: Vec3, shadow_config: ShadowConfig) void {
        _ = light_space_matrix;
        _ = camera_pos;
        _ = shadow_config;
        const self: *MockWorld = @ptrCast(@alignCast(ptr));
        self.shadow_pass_calls += 1;
    }
};

test "IChunkStorage mock dispatch" {
    var storage = MockChunkStorage{};
    const storage_if = storage.interface();

    try testing.expect(storage_if.get(1, 2) == null);
    try testing.expectEqual(@as(usize, 11), storage_if.count());
    try testing.expectEqual(@as(u64, 22), storage_if.totalVertexCount());
    try testing.expect(storage_if.isChunkRenderable(4, 5));
    try testing.expectEqual(@as(usize, 1), storage.get_calls);
    try testing.expectEqual(@as(usize, 1), storage.count_calls);
    try testing.expectEqual(@as(usize, 1), storage.total_calls);
    try testing.expectEqual(@as(usize, 1), storage.renderable_calls);
}

test "ChunkStorage interface forwards empty storage" {
    var storage = ChunkStorage.init(testing.allocator);
    defer storage.deinitWithoutRHI();

    const storage_if = storage.interface();
    try testing.expect(storage_if.get(0, 0) == null);
    try testing.expectEqual(@as(usize, 0), storage_if.count());
    try testing.expectEqual(@as(u64, 0), storage_if.totalVertexCount());
}

test "Render settings interface applies settings" {
    var settings = Settings{};
    settings.vsync = false;
    settings.wireframe_enabled = true;
    settings.textures_enabled = false;
    settings.debug_shadows_active = true;
    settings.anisotropic_filtering = 8;
    settings.msaa_samples = 2;
    settings.taa_blend_factor = 0.75;
    settings.taa_velocity_rejection = 0.11;

    var mock = MockRenderSettings{};
    settings_apply.applyToRenderSettings(&settings, mock.interface());

    try testing.expectEqual(false, mock.vsync);
    try testing.expectEqual(true, mock.wireframe);
    try testing.expectEqual(false, mock.textures_enabled);
    try testing.expectEqual(true, mock.debug_shadow_view);
    try testing.expectEqual(@as(u8, 8), mock.anisotropic_filtering);
    try testing.expectEqual(@as(u8, 2), mock.msaa_samples);
    try testing.expectApproxEqAbs(@as(f32, 0.75), mock.taa_blend_factor, 0.0001);
    try testing.expectApproxEqAbs(@as(f32, 0.11), mock.taa_velocity_rejection, 0.0001);
    try testing.expectEqual(@as(usize, 8), mock.call_count);
}

test "IWorld mock dispatch" {
    var world = MockWorld{};
    const world_if = world.interface();

    try world_if.update(Vec3.init(1, 2, 3), 0.25);
    world_if.render(Mat4.identity, Vec3.zero, true);
    try testing.expect(world.last_render_lod);

    const render_stats = world_if.getRenderStats();
    const stats = world_if.getStats();
    try testing.expectEqual(@as(u32, 4), render_stats.chunks_total);
    try testing.expectEqual(@as(u32, 3), render_stats.chunks_rendered);
    try testing.expectEqual(@as(usize, 8), stats.chunks_loaded);
    try testing.expectEqual(@as(u64, 123), stats.total_vertices);
    try testing.expect(world_if.getLODStats() == null);
    try testing.expect(!world_if.isLODEnabled());

    const shadow = world_if.shadowScene();
    shadow.renderShadowPass(Mat4.identity, Vec3.zero, .{});
    world_if.deinit();

    try testing.expectEqual(@as(usize, 1), world.update_calls);
    try testing.expectEqual(@as(usize, 1), world.render_calls);
    try testing.expectEqual(@as(usize, 1), world.get_render_stats_calls);
    try testing.expectEqual(@as(usize, 1), world.get_stats_calls);
    try testing.expectEqual(@as(usize, 1), world.get_lod_stats_calls);
    try testing.expectEqual(@as(usize, 1), world.is_lod_enabled_calls);
    try testing.expectEqual(@as(usize, 1), world.shadow_scene_calls);
    try testing.expectEqual(@as(usize, 1), world.shadow_pass_calls);
    try testing.expectEqual(@as(usize, 1), world.deinit_calls);
}
