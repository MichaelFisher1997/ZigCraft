const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("../../c.zig").c;
const build_options = @import("build_options");

const log = @import("../core/log.zig");
const rhi_pkg = @import("rhi.zig");
const RHI = rhi_pkg.RHI;
const rhi_vulkan = @import("rhi_vulkan.zig");
const TextureAtlas = @import("texture_atlas.zig").TextureAtlas;
const Texture = @import("texture.zig").Texture;
const render_graph_pkg = @import("render_graph.zig");
const RenderGraph = render_graph_pkg.RenderGraph;
const AtmosphereSystem = @import("atmosphere_system.zig").AtmosphereSystem;
const MaterialSystem = @import("material_system.zig").MaterialSystem;
const LPVSystem = @import("lpv_system.zig").LPVSystem;
const ResourcePackManager = @import("resource_pack.zig").ResourcePackManager;
const Mat4 = @import("../math/mat4.zig").Mat4;
const Vec3 = @import("../math/vec3.zig").Vec3;

const settings_pkg = @import("../../game/settings.zig");
const Settings = settings_pkg.Settings;
const runtime_env = @import("../core/runtime_env.zig");

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

pub const RenderSystem = struct {
    allocator: Allocator,
    rhi: RHI,
    shader: rhi_pkg.ShaderHandle,
    resource_pack_manager: ResourcePackManager,
    atlas: TextureAtlas,
    env_map: ?Texture,
    render_graph: RenderGraph,
    atmosphere_system: *AtmosphereSystem,
    material_system: *MaterialSystem,
    lpv_system: *LPVSystem,
    shadow_passes: [4]render_graph_pkg.ShadowPass,
    g_pass: render_graph_pkg.GPass,
    ssao_pass: render_graph_pkg.SSAOPass,
    depth_pyramid_pass: render_graph_pkg.DepthPyramidPass,
    mesh_build_pass: render_graph_pkg.MeshBuildPass,
    sky_pass: render_graph_pkg.SkyPass,
    opaque_pass: render_graph_pkg.OpaquePass,
    cloud_pass: render_graph_pkg.CloudPass,
    entity_pass: render_graph_pkg.EntityPass,
    taa_pass: render_graph_pkg.TAAPass,
    bloom_pass: render_graph_pkg.BloomPass,
    post_process_pass: render_graph_pkg.PostProcessPass,
    fxaa_pass: render_graph_pkg.FXAAPass,
    water_reflection_pass: render_graph_pkg.WaterReflectionPass,
    water_pass: render_graph_pkg.WaterPass,
    safe_mode: bool,
    safe_render_mode: bool,
    disable_shadow_draw: bool,
    disable_gpass_draw: bool,
    disable_ssao: bool,
    disable_clouds: bool,
    disable_water: bool,
    disable_taa: bool,
    disable_fxaa: bool,
    disable_bloom: bool,

    pub fn init(allocator: Allocator, window: *c.SDL_Window, settings: *const Settings) !*RenderSystem {
        log.log.info("Initializing RenderSystem...", .{});

        const safe_render_env = getenv("ZIGCRAFT_SAFE_RENDER");
        const safe_render_mode = if (safe_render_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const safe_mode_explicit = getenv("ZIGCRAFT_SAFE_MODE") != null;
        const safe_mode = runtime_env.safeModeEnabled();

        const disable_shadow_env = getenv("ZIGCRAFT_DISABLE_SHADOWS");
        const temporary_disable_shadows = false;
        const disable_shadow_draw = temporary_disable_shadows or if (disable_shadow_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_gpass_env = getenv("ZIGCRAFT_DISABLE_GPASS");
        const disable_gpass_draw = if (disable_gpass_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_ssao_env = getenv("ZIGCRAFT_DISABLE_SSAO");
        const disable_ssao = if (disable_ssao_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const chunk_debug_restore_clouds = chunkDebugRestoreEnabled("clouds");
        const disable_clouds_env = getenv("ZIGCRAFT_DISABLE_CLOUDS");
        const disable_clouds = (build_options.chunk_debug_mode and !chunk_debug_restore_clouds) or if (disable_clouds_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const chunk_debug_restore_water = chunkDebugRestoreEnabled("water") or chunkDebugRestoreEnabled("waterrender");
        const disable_water_env = getenv("ZIGCRAFT_DISABLE_WATER");
        const disable_water = (build_options.chunk_debug_mode and !chunk_debug_restore_water) or if (disable_water_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_taa_env = getenv("ZIGCRAFT_DISABLE_TAA");
        const disable_taa = if (disable_taa_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_fxaa_env = getenv("ZIGCRAFT_DISABLE_FXAA");
        const disable_fxaa = if (disable_fxaa_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_bloom_env = getenv("ZIGCRAFT_DISABLE_BLOOM");
        const disable_bloom = if (disable_bloom_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        if (build_options.chunk_debug_mode) {
            log.log.warn("CHUNK DEBUG MODE enabled: restore='{s}'", .{build_options.chunk_debug_enable});
        }
        if (safe_render_mode) {
            log.log.warn("ZIGCRAFT_SAFE_RENDER enabled: skipping world rendering passes", .{});
        }
        if (!safe_mode_explicit and runtime_env.strictSafeModeAutoEnabled()) {
            log.log.warn("Wayland direct-world launch detected: enabling strict ZIGCRAFT_SAFE_MODE defaults for stability. Set ZIGCRAFT_SAFE_MODE=0 to override", .{});
        } else if (!safe_mode_explicit and safe_mode) {
            log.log.warn("Wayland session detected: enabling ZIGCRAFT_SAFE_MODE by default for stability. Set ZIGCRAFT_SAFE_MODE=0 to override", .{});
        }
        if (safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: disabling depth pyramid and LPV compute passes", .{});
        }
        if (disable_shadow_draw) {
            log.log.warn("ZIGCRAFT_DISABLE_SHADOWS enabled", .{});
        }
        if (disable_gpass_draw) {
            log.log.warn("ZIGCRAFT_DISABLE_GPASS enabled", .{});
        }
        if (disable_ssao) {
            log.log.warn("ZIGCRAFT_DISABLE_SSAO enabled", .{});
        }
        if (disable_clouds) {
            log.log.warn("ZIGCRAFT_DISABLE_CLOUDS enabled", .{});
        }
        if (disable_water) {
            log.log.warn("ZIGCRAFT_DISABLE_WATER enabled", .{});
        }
        if (disable_taa) {
            log.log.warn("ZIGCRAFT_DISABLE_TAA enabled", .{});
        }
        if (disable_fxaa) {
            log.log.warn("ZIGCRAFT_DISABLE_FXAA enabled", .{});
        }
        if (disable_bloom) {
            log.log.warn("ZIGCRAFT_DISABLE_BLOOM enabled", .{});
        }

        log.log.info("Initializing Vulkan backend...", .{});
        const rhi = try rhi_vulkan.createRHI(allocator, window, null, settings.getShadowResolution(), settings.msaa_samples, settings.anisotropic_filtering);
        errdefer rhi.deinit();

        log.log.info("RenderSystem.init: initializing RHI device", .{});
        try rhi.init(allocator, null);

        log.log.info("RenderSystem.init: scanning resource packs", .{});
        var resource_pack_manager = ResourcePackManager.init(allocator);
        errdefer resource_pack_manager.deinit();
        try resource_pack_manager.scanPacks();
        if (resource_pack_manager.packExists(settings.texture_pack)) {
            try resource_pack_manager.setActivePack(settings.texture_pack);
        } else if (resource_pack_manager.packExists("default")) {
            try resource_pack_manager.setActivePack("default");
        }

        log.log.info("RenderSystem.init: creating texture atlas (max_resolution={})", .{settings.max_texture_resolution});
        const atlas = try TextureAtlas.init(allocator, rhi.resourceManager(), &resource_pack_manager, settings.max_texture_resolution);
        var atlas_mut = atlas;
        errdefer atlas_mut.deinit();

        var env_map: ?Texture = null;
        if (!std.mem.eql(u8, settings.environment_map, "default")) {
            if (resource_pack_manager.loadImageFileFloat(settings.environment_map)) |tex_data| {
                env_map = try Texture.initFloat(rhi.resourceManager(), tex_data.width, tex_data.height, tex_data.pixels);
                log.log.info("Loaded Environment Map: {s}", .{settings.environment_map});
                var td = tex_data;
                td.deinit(allocator);
            } else {
                log.log.warn("Could not load environment map: {s}", .{settings.environment_map});
                const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
                env_map = try Texture.initFloat(rhi.resourceManager(), 1, 1, &white_pixel);
            }
        } else {
            const white_pixel = [_]f32{ 1.0, 1.0, 1.0, 1.0 };
            env_map = try Texture.initFloat(rhi.resourceManager(), 1, 1, &white_pixel);
        }
        errdefer if (env_map) |*t| t.deinit();

        log.log.info("RenderSystem.init: initializing AtmosphereSystem", .{});
        const atmosphere_system = try AtmosphereSystem.init(allocator, rhi.resourceManager());
        errdefer atmosphere_system.deinit();

        var render_graph = RenderGraph.init(allocator);
        errdefer render_graph.deinit();

        const self = try allocator.create(RenderSystem);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .rhi = rhi,
            .shader = rhi_pkg.InvalidShaderHandle,
            .resource_pack_manager = resource_pack_manager,
            .atlas = atlas,
            .env_map = env_map,
            .render_graph = render_graph,
            .atmosphere_system = atmosphere_system,
            .material_system = undefined,
            .lpv_system = undefined,
            .shadow_passes = .{
                render_graph_pkg.ShadowPass.init(0),
                render_graph_pkg.ShadowPass.init(1),
                render_graph_pkg.ShadowPass.init(2),
                render_graph_pkg.ShadowPass.init(3),
            },
            .g_pass = .{},
            .ssao_pass = .{},
            .depth_pyramid_pass = .{},
            .mesh_build_pass = .{},
            .sky_pass = .{},
            .opaque_pass = .{},
            .cloud_pass = .{},
            .entity_pass = .{},
            .taa_pass = .{ .enabled = !disable_taa and settings.taa_enabled },
            .bloom_pass = .{ .enabled = !disable_bloom and settings.bloom_enabled },
            .post_process_pass = .{},
            .fxaa_pass = .{ .enabled = !disable_fxaa and settings.fxaa_enabled },
            .water_reflection_pass = .{},
            .water_pass = .{ .enabled = true },
            .safe_mode = safe_mode,
            .safe_render_mode = safe_render_mode,
            .disable_shadow_draw = disable_shadow_draw,
            .disable_gpass_draw = disable_gpass_draw,
            .disable_ssao = disable_ssao,
            .disable_clouds = disable_clouds,
            .disable_water = disable_water,
            .disable_taa = disable_taa,
            .disable_fxaa = disable_fxaa,
            .disable_bloom = disable_bloom,
        };

        log.log.info("RenderSystem.init: initializing MaterialSystem", .{});
        self.material_system = try MaterialSystem.init(allocator, &self.atlas);
        errdefer self.material_system.deinit();
        log.log.info("RenderSystem.init: initializing LPVSystem (grid_size={}, cell_size={})", .{ settings.lpv_grid_size, settings.lpv_cell_size });
        self.lpv_system = try LPVSystem.init(
            allocator,
            rhi,
            settings.lpv_grid_size,
            settings.lpv_cell_size,
            settings.lpv_intensity,
            settings.lpv_propagation_iterations,
            settings.lpv_enabled,
        );
        errdefer self.lpv_system.deinit();

        self.rhi.setFXAA((settings.fxaa_enabled and !settings.taa_enabled) and !disable_fxaa);
        self.rhi.setBloom(settings.bloom_enabled and !disable_bloom);
        self.rhi.setBloomIntensity(settings.bloom_intensity);

        settings_pkg.apply_logic.applyToRHI(settings, &self.rhi);

        if (!safe_render_mode) {
            if (!disable_shadow_draw) {
                try self.render_graph.addPass(self.shadow_passes[0].pass());
                try self.render_graph.addPass(self.shadow_passes[1].pass());
                try self.render_graph.addPass(self.shadow_passes[2].pass());
                try self.render_graph.addPass(self.shadow_passes[3].pass());
            }
            try self.render_graph.addPass(self.mesh_build_pass.pass());
            try self.render_graph.addPass(self.g_pass.pass());
            try self.render_graph.addPass(self.ssao_pass.pass());
            if (!safe_mode) {
                try self.render_graph.addPass(self.depth_pyramid_pass.pass());
            }
            if (!disable_water) {
                try self.render_graph.addPass(self.water_reflection_pass.pass());
            }
            try self.render_graph.addPass(self.sky_pass.pass());
            try self.render_graph.addPass(self.opaque_pass.pass());
            if (!disable_water) {
                try self.render_graph.addPass(self.water_pass.pass());
            } else {
                log.log.warn("ZIGCRAFT_DISABLE_WATER enabled", .{});
            }
            try self.render_graph.addPass(self.entity_pass.pass());
            try self.render_graph.addPass(self.taa_pass.pass());
            try self.render_graph.addPass(self.bloom_pass.pass());
            try self.render_graph.addPass(self.post_process_pass.pass());
            try self.render_graph.addPass(self.fxaa_pass.pass());
        } else {
            log.log.warn("ZIGCRAFT_SAFE_RENDER: render graph disabled (UI only)", .{});
        }

        log.log.info("RenderSystem initialized successfully", .{});
        return self;
    }

    pub fn deinit(self: *RenderSystem) void {
        self.rhi.waitIdle();

        self.render_graph.deinit();
        self.atmosphere_system.deinit();
        self.material_system.deinit();
        self.lpv_system.deinit();
        self.atlas.deinit();
        if (self.env_map) |*t| t.deinit();
        self.resource_pack_manager.deinit();
        if (self.shader != rhi_pkg.InvalidShaderHandle) self.rhi.destroyShader(self.shader);
        self.rhi.deinit();

        self.allocator.destroy(self);
    }

    pub fn beginFrame(self: *RenderSystem) void {
        self.rhi.beginFrame();
    }

    pub fn endFrame(self: *RenderSystem) void {
        self.rhi.endFrame();
    }

    pub fn waitIdle(self: *RenderSystem) void {
        self.rhi.waitIdle();
    }

    pub fn setViewport(self: *RenderSystem, width: u32, height: u32) void {
        self.rhi.setViewport(width, height);
    }

    pub fn updateGlobalUniforms(
        self: *RenderSystem,
        view_proj: Mat4,
        cam_pos: Vec3,
        sun_dir: Vec3,
        sun_color: Vec3,
        time: f32,
        fog_color: Vec3,
        fog_density: f32,
        fog_enabled: bool,
        sun_intensity: f32,
        ambient: f32,
        use_texture: bool,
        cloud_params: rhi_pkg.CloudParams,
    ) !void {
        try self.rhi.updateGlobalUniforms(view_proj, cam_pos, sun_dir, sun_color, time, fog_color, fog_density, fog_enabled, sun_intensity, ambient, use_texture, cloud_params);
    }

    pub fn applySettings(self: *RenderSystem, settings: *const Settings) void {
        self.rhi.setFXAA(settings.fxaa_enabled and !settings.taa_enabled);
        self.rhi.setBloom(settings.bloom_enabled);
        self.rhi.setBloomIntensity(settings.bloom_intensity);
        settings_pkg.apply_logic.applyToRHI(settings, &self.rhi);
    }

    pub fn getRHI(self: *RenderSystem) *RHI {
        return &self.rhi;
    }

    pub fn getRenderGraph(self: *RenderSystem) *RenderGraph {
        return &self.render_graph;
    }

    pub fn getAtmosphereSystem(self: *RenderSystem) *AtmosphereSystem {
        return self.atmosphere_system;
    }

    pub fn getMaterialSystem(self: *RenderSystem) *MaterialSystem {
        return self.material_system;
    }

    pub fn getLPVSystem(self: *RenderSystem) *LPVSystem {
        return self.lpv_system;
    }

    pub fn getAtlas(self: *RenderSystem) *TextureAtlas {
        return &self.atlas;
    }

    pub fn getEnvMapPtr(self: *RenderSystem) *?Texture {
        return &self.env_map;
    }

    pub fn getShader(self: *const RenderSystem) rhi_pkg.ShaderHandle {
        return self.shader;
    }

    pub fn setShader(self: *RenderSystem, handle: rhi_pkg.ShaderHandle) void {
        self.shader = handle;
    }

    pub fn getResourcePackManager(self: *RenderSystem) *ResourcePackManager {
        return &self.resource_pack_manager;
    }

    pub fn getSafeRenderMode(self: *const RenderSystem) bool {
        return self.safe_render_mode;
    }

    pub fn getSafeMode(self: *const RenderSystem) bool {
        return self.safe_mode;
    }

    pub fn getDisableShadowDraw(self: *const RenderSystem) bool {
        return self.disable_shadow_draw;
    }

    pub fn getDisableGPassDraw(self: *const RenderSystem) bool {
        return self.disable_gpass_draw;
    }

    pub fn getDisableSSAO(self: *const RenderSystem) bool {
        return self.disable_ssao;
    }

    pub fn getDisableClouds(self: *const RenderSystem) bool {
        return self.disable_clouds;
    }

    pub fn setDisableGPassDraw(self: *RenderSystem, value: bool) void {
        self.disable_gpass_draw = value;
    }

    pub fn setDisableSSAO(self: *RenderSystem, value: bool) void {
        self.disable_ssao = value;
    }

    pub fn setDisableClouds(self: *RenderSystem, value: bool) void {
        self.disable_clouds = value;
    }
};

fn chunkDebugRestoreEnabled(name: []const u8) bool {
    if (!build_options.chunk_debug_mode) return false;

    var it = std.mem.tokenizeScalar(u8, build_options.chunk_debug_enable, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }
    return false;
}
