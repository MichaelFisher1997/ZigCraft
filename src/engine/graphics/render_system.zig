const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("../../c.zig").c;

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
    sky_pass: render_graph_pkg.SkyPass,
    opaque_pass: render_graph_pkg.OpaquePass,
    cloud_pass: render_graph_pkg.CloudPass,
    entity_pass: render_graph_pkg.EntityPass,
    taa_pass: render_graph_pkg.TAAPass,
    bloom_pass: render_graph_pkg.BloomPass,
    post_process_pass: render_graph_pkg.PostProcessPass,
    fxaa_pass: render_graph_pkg.FXAAPass,
    safe_render_mode: bool,
    disable_shadow_draw: bool,
    disable_gpass_draw: bool,
    disable_ssao: bool,
    disable_clouds: bool,

    pub fn init(allocator: Allocator, window: *c.SDL_Window, settings: *const Settings) !*RenderSystem {
        log.log.info("Initializing RenderSystem...", .{});

        const safe_render_env = std.posix.getenv("ZIGCRAFT_SAFE_RENDER");
        const safe_render_mode = if (safe_render_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_shadow_env = std.posix.getenv("ZIGCRAFT_DISABLE_SHADOWS");
        const disable_shadow_draw = if (disable_shadow_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_gpass_env = std.posix.getenv("ZIGCRAFT_DISABLE_GPASS");
        const disable_gpass_draw = if (disable_gpass_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_ssao_env = std.posix.getenv("ZIGCRAFT_DISABLE_SSAO");
        const disable_ssao = if (disable_ssao_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const disable_clouds_env = std.posix.getenv("ZIGCRAFT_DISABLE_CLOUDS");
        const disable_clouds = if (disable_clouds_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        if (safe_render_mode) {
            log.log.warn("ZIGCRAFT_SAFE_RENDER enabled: skipping world rendering passes", .{});
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

        log.log.info("Initializing Vulkan backend...", .{});
        const rhi = try rhi_vulkan.createRHI(allocator, window, null, settings.getShadowResolution(), settings.msaa_samples, settings.anisotropic_filtering);
        errdefer rhi.deinit();

        try rhi.init(allocator, null);

        var resource_pack_manager = ResourcePackManager.init(allocator);
        errdefer resource_pack_manager.deinit();
        try resource_pack_manager.scanPacks();
        if (resource_pack_manager.packExists(settings.texture_pack)) {
            try resource_pack_manager.setActivePack(settings.texture_pack);
        } else if (resource_pack_manager.packExists("default")) {
            try resource_pack_manager.setActivePack("default");
        }

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

        const atmosphere_system = try AtmosphereSystem.init(allocator, rhi.resourceManager());
        errdefer atmosphere_system.deinit();

        const self = try allocator.create(RenderSystem);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .rhi = rhi,
            .shader = rhi_pkg.InvalidShaderHandle,
            .resource_pack_manager = resource_pack_manager,
            .atlas = atlas,
            .env_map = env_map,
            .render_graph = RenderGraph.init(allocator),
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
            .sky_pass = .{},
            .opaque_pass = .{},
            .cloud_pass = .{},
            .entity_pass = .{},
            .taa_pass = .{ .enabled = true },
            .bloom_pass = .{ .enabled = true },
            .post_process_pass = .{},
            .fxaa_pass = .{ .enabled = true },
            .safe_render_mode = safe_render_mode,
            .disable_shadow_draw = disable_shadow_draw,
            .disable_gpass_draw = disable_gpass_draw,
            .disable_ssao = disable_ssao,
            .disable_clouds = disable_clouds,
        };
        errdefer self.render_graph.deinit();

        self.material_system = try MaterialSystem.init(allocator, &self.atlas);
        errdefer self.material_system.deinit();
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

        self.rhi.setFXAA(settings.fxaa_enabled and !settings.taa_enabled);
        self.rhi.setBloom(settings.bloom_enabled);
        self.rhi.setBloomIntensity(settings.bloom_intensity);

        settings_pkg.apply_logic.applyToRHI(settings, &self.rhi);

        if (!safe_render_mode) {
            try self.render_graph.addPass(self.shadow_passes[0].pass());
            try self.render_graph.addPass(self.shadow_passes[1].pass());
            try self.render_graph.addPass(self.shadow_passes[2].pass());
            try self.render_graph.addPass(self.shadow_passes[3].pass());
            try self.render_graph.addPass(self.g_pass.pass());
            try self.render_graph.addPass(self.ssao_pass.pass());
            try self.render_graph.addPass(self.sky_pass.pass());
            try self.render_graph.addPass(self.opaque_pass.pass());
            try self.render_graph.addPass(self.cloud_pass.pass());
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

    pub fn getEnvMapPtr(self: *RenderSystem) ?*?Texture {
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
};
