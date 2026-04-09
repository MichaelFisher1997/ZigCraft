//! Render Graph - Orchestrates frame rendering through sequential render passes.
//!
//! This module implements a simple render graph that executes a series of render
//! passes in order, managing the main pass lifecycle automatically based on each
//! pass's requirements.
//!
//! ## Pass Execution Model
//!
//! Passes are added via `addPass()` and executed sequentially in `execute()`:
//! ```
//! ShadowPass0 -> ShadowPass1 -> ShadowPass2 -> ShadowPass3 ->
//! GPass -> SSAOPass -> SkyPass -> OpaquePass -> CloudPass -> UIPass
//! ```
//!
//! ## Main Pass Lifecycle
//!
//! The render graph automatically manages the main render pass state machine:
//! - Passes with `needs_main_pass = true` require an active main pass
//! - The graph calls `beginMainPass()` / `endMainPass()` as needed when
//!   transitioning between pass types
//! - This allows mixing pre-pass work (shadows, SSAO) with main pass rendering
//!
//! ## Standard Passes
//!
//! - **ShadowPass**: Renders shadow map cascades (0-3), outside main pass
//! - **GPass**: Geometry pass for SSAO, outputs normals/depth
//! - **SSAOPass**: Screen-space ambient occlusion computation
//! - **SkyPass**: Atmospheric sky rendering, inside main pass
//! - **OpaquePass**: Main world geometry rendering
//! - **CloudPass**: Volumetric cloud rendering
//! - **UIPass**: Immediate-mode UI overlay
//!
//! ## Scene Context
//!
//! All passes receive a `SceneContext` struct containing references to:
//! RHI, World, Camera, shadow scene, atmosphere system, and various configuration
//! parameters. This provides passes with everything needed for rendering.

const std = @import("std");
const c = @import("../../c.zig").c;
const Camera = @import("camera.zig").Camera;
const IWorld = @import("../../world/world.zig").IWorld;
const shadow_scene = @import("shadow_scene.zig");
const rhi_pkg = @import("rhi.zig");
const RenderContext = rhi_pkg.RenderContext;
const ShadowSystemWrapper = rhi_pkg.ShadowSystemWrapper;
const WaterSystemWrapper = rhi_pkg.WaterSystemWrapper;
const ISSAOContext = rhi_pkg.ISSAOContext;
const IDeviceTiming = rhi_pkg.IDeviceTiming;
const Vec3 = @import("../math/vec3.zig").Vec3;
const log = @import("../core/log.zig");
const CSM = @import("csm.zig");
const AtmosphereSystem = @import("atmosphere_system.zig").AtmosphereSystem;
const MaterialSystem = @import("material_system.zig").MaterialSystem;
const GpuMesher = @import("../../world/gpu_mesher.zig").GpuMesher;

pub const SceneContext = struct {
    render_ctx: RenderContext,
    shadow_ctx: ShadowSystemWrapper,
    water_ctx: WaterSystemWrapper,
    ssao_ctx: ISSAOContext,
    timing: IDeviceTiming,
    world: IWorld,
    shadow_scene: shadow_scene.IShadowScene,
    camera: *Camera,
    atmosphere_system: *AtmosphereSystem,
    material_system: *MaterialSystem,
    aspect: f32,
    sky_params: rhi_pkg.SkyParams,
    cloud_params: rhi_pkg.CloudParams,
    taa_enabled: bool,
    viewport_width: f32,
    viewport_height: f32,
    main_shader: rhi_pkg.ShaderHandle,
    env_map_handle: rhi_pkg.TextureHandle,
    shadow: rhi_pkg.ShadowConfig,
    ssao_enabled: bool,
    disable_shadow_draw: bool,
    disable_gpass_draw: bool,
    disable_ssao: bool,
    disable_clouds: bool,
    // Post-processing flags
    fxaa_enabled: bool = true,
    bloom_enabled: bool = true,
    overlay_renderer: ?*const fn (ctx: SceneContext) void = null,
    overlay_ctx: ?*anyopaque = null,
    lpv_texture_handle: rhi_pkg.TextureHandle = 0,
    lpv_texture_handle_g: rhi_pkg.TextureHandle = 0,
    lpv_texture_handle_b: rhi_pkg.TextureHandle = 0,
    // Pointer to frame-local cascade storage, computed once per frame by the first
    // ShadowPass and reused by subsequent cascade passes to guarantee consistency.
    cached_cascades: *?CSM.ShadowCascades,
    gpu_mesher: ?*GpuMesher = null,
};

pub const IRenderPass = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        name: []const u8,
        needs_main_pass: bool,
        execute: *const fn (ptr: *anyopaque, ctx: SceneContext) anyerror!void,
    };

    pub fn execute(self: IRenderPass, ctx: SceneContext) !void {
        try self.vtable.execute(self.ptr, ctx);
    }

    pub fn name(self: IRenderPass) []const u8 {
        return self.vtable.name;
    }

    pub fn needsMainPass(self: IRenderPass) bool {
        return self.vtable.needs_main_pass;
    }
};

pub const RenderGraph = struct {
    passes: std.ArrayListUnmanaged(IRenderPass),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RenderGraph {
        return .{
            .passes = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RenderGraph) void {
        self.passes.deinit(self.allocator);
    }

    pub fn addPass(self: *RenderGraph, pass: IRenderPass) !void {
        try self.passes.append(self.allocator, pass);
    }

    pub fn execute(self: *const RenderGraph, ctx: SceneContext) !void {
        var main_pass_started = false;
        for (self.passes.items) |pass| {
            updateMainPassState(ctx, pass, &main_pass_started);

            const pass_name = pass.name();
            ctx.timing.beginPassTiming(pass_name);
            try pass.execute(ctx);
            ctx.timing.endPassTiming(pass_name);
        }

        if (main_pass_started) {
            ctx.render_ctx.endMainPass();
        }
    }

    fn updateMainPassState(ctx: SceneContext, pass: IRenderPass, main_pass_started: *bool) void {
        if (pass.needsMainPass()) {
            if (!main_pass_started.*) {
                ctx.render_ctx.beginMainPass();
                main_pass_started.* = true;
            }
        } else {
            if (main_pass_started.*) {
                ctx.render_ctx.endMainPass();
                main_pass_started.* = false;
            }
        }
    }
};

// --- Standard Pass Implementations ---

const SHADOW_PASS_NAMES = [_][]const u8{ "ShadowPass0", "ShadowPass1", "ShadowPass2", "ShadowPass3" };

pub const ShadowPass = struct {
    cascade_index: u32,

    pub fn init(cascade_index: u32) ShadowPass {
        return .{ .cascade_index = cascade_index };
    }

    const VTABLES = [_]IRenderPass.VTable{
        .{ .name = "ShadowPass0", .needs_main_pass = false, .execute = execute },
        .{ .name = "ShadowPass1", .needs_main_pass = false, .execute = execute },
        .{ .name = "ShadowPass2", .needs_main_pass = false, .execute = execute },
        .{ .name = "ShadowPass3", .needs_main_pass = false, .execute = execute },
    };

    pub fn pass(self: *ShadowPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLES[self.cascade_index],
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *ShadowPass = @ptrCast(@alignCast(ptr));
        // Runtime verification to ensuring pointer safety in debug mode
        std.debug.assert(self.cascade_index < rhi_pkg.SHADOW_CASCADE_COUNT);

        const cascade_idx = self.cascade_index;

        // Compute cascades once per frame and cache via shared pointer so all
        // cascade passes within the same frame use identical matrices.
        const cascades = if (ctx.cached_cascades.*) |cached| cached else blk: {
            const computed = CSM.computeCascades(
                ctx.shadow.resolution,
                ctx.camera.fov,
                ctx.aspect,
                0.1,
                ctx.shadow.distance,
                ctx.sky_params.sun_dir,
                ctx.camera.getViewMatrixOriginCentered(),
                true,
            );
            // Validate cascade data before using
            if (!CSM.validateCascades(computed, log.log)) {
                log.log.err("ShadowPass{}: Invalid cascade data, skipping shadow pass", .{cascade_idx});
                return error.InvalidShadowCascades;
            }
            ctx.cached_cascades.* = computed;
            break :blk computed;
        };

        const light_space_matrix = cascades.light_space_matrices[cascade_idx];

        // Only update uniforms on first cascade pass
        if (cascade_idx == 0) {
            try ctx.shadow_ctx.updateUniforms(.{
                .light_space_matrices = cascades.light_space_matrices,
                .cascade_splits = cascades.cascade_splits,
                .shadow_texel_sizes = cascades.texel_sizes,
            });
        }

        if (ctx.disable_shadow_draw) return;

        ctx.shadow_ctx.beginPass(cascade_idx, light_space_matrix);
        errdefer ctx.shadow_ctx.endPass();
        ctx.shadow_scene.renderShadowPass(light_space_matrix, ctx.camera.position, ctx.shadow);
        ctx.shadow_ctx.endPass();
    }
};

pub const GPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "GPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *GPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        if (!ctx.ssao_enabled or ctx.disable_gpass_draw) return;

        ctx.render_ctx.beginGPass();
        const atlas = ctx.material_system.getAtlasHandles(ctx.env_map_handle);
        ctx.render_ctx.bindTexture(atlas.diffuse, 1);
        const view_proj = ctx.camera.getJitteredProjectionMatrixReverseZ(ctx.aspect, ctx.viewport_width, ctx.viewport_height, ctx.taa_enabled).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.world.render(view_proj, ctx.camera.position, false);
        ctx.render_ctx.endGPass();
    }
};

pub const SSAOPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "SSAOPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *SSAOPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        if (!ctx.ssao_enabled or ctx.disable_ssao) return;
        const proj = ctx.camera.getJitteredProjectionMatrixReverseZ(ctx.aspect, ctx.viewport_width, ctx.viewport_height, ctx.taa_enabled);
        const inv_proj = proj.inverse();
        ctx.ssao_ctx.compute(proj, inv_proj);
    }
};

pub const DepthPyramidPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "DepthPyramidPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *DepthPyramidPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        ctx.render_ctx.computeDepthPyramid();
    }
};

pub const MeshBuildPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "MeshBuildPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *MeshBuildPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        const mesher = ctx.gpu_mesher orelse return;
        mesher.beginFrame();

        ctx.world.gpuMeshDispatch(mesher);

        mesher.dispatchPending(0);
        mesher.dispatchPending(1);
        mesher.dispatchPending(2);
        mesher.endFrame();
    }
};

pub const SkyPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "SkyPass",
        .needs_main_pass = true,
        .execute = execute,
    };
    pub fn pass(self: *SkyPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        ctx.atmosphere_system.renderSky(ctx.render_ctx, ctx.sky_params) catch |err| {
            if (err != error.ResourceNotReady and
                err != error.SkyPipelineNotReady and
                err != error.SkyPipelineLayoutNotReady and
                err != error.CommandBufferNotReady)
            {
                log.log.errWithTrace("SkyPass: rendering failed: {}", .{err});
            }
        };
    }
};

pub const OpaquePass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "OpaquePass",
        .needs_main_pass = true,
        .execute = execute,
    };
    pub fn pass(self: *OpaquePass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        ctx.render_ctx.bindShader(ctx.main_shader);
        ctx.material_system.bindTerrainMaterial(ctx.render_ctx, ctx.env_map_handle);
        ctx.render_ctx.bindTexture(ctx.lpv_texture_handle, 11);
        ctx.render_ctx.bindTexture(ctx.lpv_texture_handle_g, 12);
        ctx.render_ctx.bindTexture(ctx.lpv_texture_handle_b, 13);
        const view_proj = ctx.camera.getJitteredProjectionMatrixReverseZ(ctx.aspect, ctx.viewport_width, ctx.viewport_height, ctx.taa_enabled).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.world.render(view_proj, ctx.camera.position, true);
    }
};

pub const CloudPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "CloudPass",
        .needs_main_pass = true,
        .execute = execute,
    };
    pub fn pass(self: *CloudPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        if (ctx.disable_clouds) return;
        const view_proj = ctx.camera.getJitteredProjectionMatrixReverseZ(ctx.aspect, ctx.viewport_width, ctx.viewport_height, ctx.taa_enabled).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.atmosphere_system.renderClouds(ctx.render_ctx, ctx.cloud_params, view_proj) catch |err| {
            if (err != error.ResourceNotReady and
                err != error.CloudPipelineNotReady and
                err != error.CloudPipelineLayoutNotReady and
                err != error.CommandBufferNotReady)
            {
                log.log.errWithTrace("CloudPass: rendering failed: {}", .{err});
            }
        };
    }
};

pub const EntityPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "EntityPass",
        .needs_main_pass = true,
        .execute = execute,
    };
    pub fn pass(self: *EntityPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        if (ctx.overlay_renderer) |render| {
            render(ctx);
        }
    }
};

pub const PostProcessPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "PostProcessPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *PostProcessPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        ctx.render_ctx.beginPostProcessPass();
        ctx.render_ctx.draw(rhi_pkg.InvalidBufferHandle, 3, .triangles);
        ctx.render_ctx.endPostProcessPass();
    }
};

// Bloom pass - computes bloom mip chain from HDR buffer
pub const BloomPass = struct {
    enabled: bool = true,
    const VTABLE = IRenderPass.VTable{
        .name = "BloomPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *BloomPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *BloomPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.bloom_enabled) return;
        ctx.render_ctx.computeBloom();
    }
};

// TAA pass - reserved temporal AA stage between scene rendering and bloom/post.
pub const TAAPass = struct {
    enabled: bool = true,
    const VTABLE = IRenderPass.VTable{
        .name = "TAAPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *TAAPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *TAAPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.taa_enabled) return;
        ctx.render_ctx.computeTAA();
    }
};

// FXAA pass - applies anti-aliasing to LDR output
pub const FXAAPass = struct {
    enabled: bool = true,
    const VTABLE = IRenderPass.VTable{
        .name = "FXAAPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *FXAAPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *FXAAPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled or !ctx.fxaa_enabled) return;
        ctx.render_ctx.beginFXAAPass();
        ctx.render_ctx.endFXAAPass();
    }
};

pub const WaterReflectionPass = struct {
    const VTABLE = IRenderPass.VTable{
        .name = "WaterReflectionPass",
        .needs_main_pass = false,
        .execute = execute,
    };
    pub fn pass(self: *WaterReflectionPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        _ = ptr;
        ctx.water_ctx.beginReflectionPass();
        defer ctx.water_ctx.endReflectionPass();

        const view = ctx.camera.getViewMatrixOriginCentered();
        const proj = ctx.camera.getJitteredProjectionMatrixReverseZ(ctx.aspect, ctx.viewport_width, ctx.viewport_height, ctx.taa_enabled);
        const reflected_vp = ctx.water_ctx.computeReflectedViewProj(view, proj, ctx.camera.position);

        ctx.render_ctx.bindShader(ctx.main_shader);
        ctx.material_system.bindTerrainMaterial(ctx.render_ctx, ctx.env_map_handle);
        ctx.render_ctx.bindTexture(ctx.lpv_texture_handle, 11);
        ctx.render_ctx.bindTexture(ctx.lpv_texture_handle_g, 12);
        ctx.render_ctx.bindTexture(ctx.lpv_texture_handle_b, 13);

        ctx.world.renderOpaque(reflected_vp, ctx.camera.position, true);
    }
};

pub const WaterPass = struct {
    enabled: bool = true,
    const VTABLE = IRenderPass.VTable{
        .name = "WaterPass",
        .needs_main_pass = true,
        .execute = execute,
    };
    pub fn pass(self: *WaterPass) IRenderPass {
        return .{
            .ptr = self,
            .vtable = &VTABLE,
        };
    }

    fn execute(ptr: *anyopaque, ctx: SceneContext) anyerror!void {
        const self: *WaterPass = @ptrCast(@alignCast(ptr));
        if (!self.enabled) return;

        const pipeline_u64 = ctx.render_ctx.getNativeWaterPipeline();
        const layout_u64 = ctx.render_ctx.getNativeWaterPipelineLayout();
        const descriptor_set_u64 = ctx.render_ctx.getNativeMainDescriptorSet();
        const cmd_u64 = ctx.render_ctx.getNativeCommandBuffer();
        const reflection_handle = ctx.water_ctx.getReflectionTextureHandle();
        const scene_depth_handle = ctx.water_ctx.getSceneDepthTextureHandle();

        if (pipeline_u64 == 0 or layout_u64 == 0 or cmd_u64 == 0 or reflection_handle == 0 or scene_depth_handle == 0) return;

        const pipeline = @as(c.VkPipeline, @ptrFromInt(pipeline_u64));
        const layout = @as(c.VkPipelineLayout, @ptrFromInt(layout_u64));
        const descriptor_set = @as(c.VkDescriptorSet, @ptrFromInt(descriptor_set_u64));
        const cmd = @as(c.VkCommandBuffer, @ptrFromInt(cmd_u64));

        ctx.render_ctx.bindTexture(reflection_handle, 14);
        ctx.render_ctx.bindTexture(scene_depth_handle, 15);
        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        if (descriptor_set_u64 != 0) {
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &descriptor_set, 0, null);
        }

        const view_proj = ctx.camera.getJitteredProjectionMatrixReverseZ(ctx.aspect, ctx.viewport_width, ctx.viewport_height, ctx.taa_enabled).multiply(ctx.camera.getViewMatrixOriginCentered());
        ctx.world.renderFluid(view_proj, ctx.camera.position, true);
    }
};
