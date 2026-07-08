//! Render Hardware Interface (RHI) - Abstract rendering layer for GPU operations.
//!
//! This module provides a hardware abstraction layer that decouples the engine's
//! rendering code from the underlying graphics API (currently Vulkan). The RHI
//! exposes a set of segregated interfaces, each handling a specific aspect of
//! rendering, allowing for clean separation of concerns.
//!
//! ## Architecture Overview
//!
//! The RHI is composed of several segregated interfaces (vtable-based polymorphism):
//!
//! - **IResourceFactory**: Creates and manages GPU resources (buffers, textures, shaders)
//! - **IRenderContext**: Frame lifecycle management (begin/end frame, render passes)
//! - **IGraphicsCommandEncoder**: Drawing commands (bind, draw, push constants)
//! - **IRenderStateContext**: Render state configuration (model matrices, uniforms)
//! - **IShadowContext**: Shadow map rendering passes
//! - **IUIContext**: Immediate-mode UI rendering
//! - **ISSAOContext**: Screen-space ambient occlusion computation
//!
//! ## Resource Handle Model
//!
//! GPU resources are referenced through opaque `u32` handles:
//! - `BufferHandle`: Vertex, index, uniform, and storage buffers
//! - `TextureHandle`: 2D/3D textures, depth attachments, shadow maps
//! - `ShaderHandle`: Compiled shader pipelines
//!
//! Invalid handles are represented by 0 (InvalidBufferHandle, etc.). The RHI
//! internally maps these handles to backend-specific resources.
//!
//! ## Frame Synchronization
//!
//! The engine uses double-buffering (MAX_FRAMES_IN_FLIGHT = 2) to prevent GPU/CPU
//! synchronization issues. Each frame, resources are cycled via `getFrameIndex()`.
//!
//! ## Usage
//!
//! **DEPRECATED**: Use focused wrappers instead:
//! - `ResourceManager` for resource lifecycle (`createBuffer`, `createTexture`, etc.)
//! - `RenderContext` for frame rendering (`beginFrame`, `draw`, `bindTexture`, etc.)
//! - `UIRenderer` for UI rendering (`beginPass`, `drawRect`, `drawTexture`, etc.)
//! - `ShadowSystemWrapper` for shadow mapping
//!
//! ```zig
//! const resources = rhi.resourceManager();
//! const ctx = rhi.renderContext();
//! const ui = rhi.uiRenderer();
//! ```
//!
//! ## Backend Implementation
//!
//! The Vulkan backend (`rhi_vulkan.zig`) is the only supported backend. Vulkan
//! native handles and compute objects are intentionally exposed where engine
//! subsystems integrate directly with Vulkan-shaped APIs.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const RenderDevice = @import("render_device.zig").RenderDevice;
const culling = @import("culling.zig");

const rhi_types = @import("rhi_types.zig");

// Re-exports
pub const RhiError = rhi_types.RhiError;
pub const BufferHandle = rhi_types.BufferHandle;
pub const InvalidBufferHandle = rhi_types.InvalidBufferHandle;
pub const ShaderHandle = rhi_types.ShaderHandle;
pub const InvalidShaderHandle = rhi_types.InvalidShaderHandle;
pub const TextureHandle = rhi_types.TextureHandle;
pub const InvalidTextureHandle = rhi_types.InvalidTextureHandle;

pub const MAX_FRAMES_IN_FLIGHT = rhi_types.MAX_FRAMES_IN_FLIGHT;
pub const MAX_SWAPCHAIN_IMAGES = rhi_types.MAX_SWAPCHAIN_IMAGES;
pub const SHADOW_CASCADE_COUNT = rhi_types.SHADOW_CASCADE_COUNT;
pub const BLOOM_MIP_COUNT = 5;

pub const BufferUsage = rhi_types.BufferUsage;
pub const TextureFormat = rhi_types.TextureFormat;
pub const FilterMode = rhi_types.FilterMode;
pub const WrapMode = rhi_types.WrapMode;
pub const TextureConfig = rhi_types.TextureConfig;
pub const TextureAtlasHandles = rhi_types.TextureAtlasHandles;
pub const Vertex = rhi_types.Vertex;
pub const DrawMode = rhi_types.DrawMode;
pub const ShaderStageFlags = rhi_types.ShaderStageFlags;
pub const DrawIndirectCommand = rhi_types.DrawIndirectCommand;
pub const InstanceData = rhi_types.InstanceData;
pub const SkyParams = rhi_types.SkyParams;
pub const SkyPushConstants = rhi_types.SkyPushConstants;
pub const FrameRenderParams = rhi_types.FrameRenderParams;
pub const GlobalUniforms = rhi_types.GlobalUniforms;
pub const ShadowConfig = rhi_types.ShadowConfig;
pub const ShadowParams = rhi_types.ShadowParams;
pub const Color = rhi_types.Color;
pub const Rect = rhi_types.Rect;
pub const UVRect = rhi_types.UVRect;
pub const GpuTimingResults = rhi_types.GpuTimingResults;
pub const ICullingSystem = culling.ICullingSystem;

pub const RenderResolution = struct {
    width: u32,
    height: u32,
};

// --- Segregated Interfaces ---

pub const IResourceFactory = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createBuffer: *const fn (ptr: *anyopaque, size: usize, usage: BufferUsage) RhiError!BufferHandle,
        uploadBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, data: []const u8) RhiError!void,
        updateBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void,
        destroyBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        createTexture: *const fn (ptr: *anyopaque, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle,
        createTexture3D: *const fn (ptr: *anyopaque, width: u32, height: u32, depth: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle,
        destroyTexture: *const fn (ptr: *anyopaque, handle: TextureHandle) void,
        updateTexture: *const fn (ptr: *anyopaque, handle: TextureHandle, data: []const u8) RhiError!void,
        createShader: *const fn (ptr: *anyopaque, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle,
        destroyShader: *const fn (ptr: *anyopaque, handle: ShaderHandle) void,
        mapBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) RhiError!?*anyopaque,
        unmapBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
    };

    /// Forwards `createBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createBuffer(self: IResourceFactory, size: usize, usage: BufferUsage) RhiError!BufferHandle {
        return self.vtable.createBuffer(self.ptr, size, usage);
    }
    /// Forwards `uploadBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn uploadBuffer(self: IResourceFactory, handle: BufferHandle, data: []const u8) RhiError!void {
        return self.vtable.uploadBuffer(self.ptr, handle, data);
    }
    /// Forwards `updateBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn updateBuffer(self: IResourceFactory, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
        return self.vtable.updateBuffer(self.ptr, handle, offset, data);
    }
    /// Forwards `destroyBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn destroyBuffer(self: IResourceFactory, handle: BufferHandle) void {
        self.vtable.destroyBuffer(self.ptr, handle);
    }
    /// Forwards `createTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createTexture(self: IResourceFactory, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle {
        return self.vtable.createTexture(self.ptr, width, height, format, config, data);
    }
    /// Forwards `createTexture3D` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createTexture3D(self: IResourceFactory, width: u32, height: u32, depth: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle {
        return self.vtable.createTexture3D(self.ptr, width, height, depth, format, config, data);
    }
    /// Forwards `destroyTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn destroyTexture(self: IResourceFactory, handle: TextureHandle) void {
        self.vtable.destroyTexture(self.ptr, handle);
    }
    /// Forwards `updateTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn updateTexture(self: IResourceFactory, handle: TextureHandle, data: []const u8) RhiError!void {
        return self.vtable.updateTexture(self.ptr, handle, data);
    }
    /// Forwards `createShader` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createShader(self: IResourceFactory, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle {
        return self.vtable.createShader(self.ptr, vertex_src, fragment_src);
    }
    /// Forwards `destroyShader` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn destroyShader(self: IResourceFactory, handle: ShaderHandle) void {
        self.vtable.destroyShader(self.ptr, handle);
    }
    /// Forwards `mapBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn mapBuffer(self: IResourceFactory, handle: BufferHandle) RhiError!?*anyopaque {
        return self.vtable.mapBuffer(self.ptr, handle);
    }
    /// Forwards `unmapBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn unmapBuffer(self: IResourceFactory, handle: BufferHandle) void {
        self.vtable.unmapBuffer(self.ptr, handle);
    }
};

/// Concrete wrapper around `IResourceFactory` for GPU resource lifecycle operations.
///
/// Use this when a subsystem only needs buffer/texture/shader creation and
/// destruction, without accessing the full `RHI` composite. Obtain via
/// `rhi.resourceManager()`. Reduces coupling and clarifies intent.
///
/// ```zig
/// const rm = rhi.resourceManager();
/// const buffer = try rm.createBuffer(size, .vertex);
/// defer rm.destroyBuffer(buffer);
/// ```
pub const ResourceManager = struct {
    factory: IResourceFactory,

    /// Forwards `createBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createBuffer(self: ResourceManager, size: usize, usage: BufferUsage) RhiError!BufferHandle {
        return self.factory.createBuffer(size, usage);
    }
    /// Forwards `uploadBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn uploadBuffer(self: ResourceManager, handle: BufferHandle, data: []const u8) RhiError!void {
        return self.factory.uploadBuffer(handle, data);
    }
    /// Forwards `updateBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn updateBuffer(self: ResourceManager, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
        return self.factory.updateBuffer(handle, offset, data);
    }
    /// Forwards `destroyBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn destroyBuffer(self: ResourceManager, handle: BufferHandle) void {
        self.factory.destroyBuffer(handle);
    }
    /// Forwards `createTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createTexture(self: ResourceManager, width: u32, height: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle {
        return self.factory.createTexture(width, height, format, config, data);
    }
    /// Forwards `createTexture3D` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createTexture3D(self: ResourceManager, width: u32, height: u32, depth: u32, format: TextureFormat, config: TextureConfig, data: ?[]const u8) RhiError!TextureHandle {
        return self.factory.createTexture3D(width, height, depth, format, config, data);
    }
    /// Forwards `destroyTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn destroyTexture(self: ResourceManager, handle: TextureHandle) void {
        self.factory.destroyTexture(handle);
    }
    /// Forwards `updateTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn updateTexture(self: ResourceManager, handle: TextureHandle, data: []const u8) RhiError!void {
        return self.factory.updateTexture(handle, data);
    }
    /// Forwards `createShader` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createShader(self: ResourceManager, vertex_src: [*c]const u8, fragment_src: [*c]const u8) RhiError!ShaderHandle {
        return self.factory.createShader(vertex_src, fragment_src);
    }
    /// Forwards `destroyShader` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn destroyShader(self: ResourceManager, handle: ShaderHandle) void {
        self.factory.destroyShader(handle);
    }
    /// Forwards `mapBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn mapBuffer(self: ResourceManager, handle: BufferHandle) RhiError!?*anyopaque {
        return self.factory.mapBuffer(handle);
    }
    /// Forwards `unmapBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn unmapBuffer(self: ResourceManager, handle: BufferHandle) void {
        self.factory.unmapBuffer(handle);
    }
};

/// Concrete wrapper combining `IRenderContext`, `IGraphicsCommandEncoder`, and
/// `IRenderStateContext` for frame lifecycle, draw commands, and render state.
///
/// Use this when a subsystem needs to manage render passes and issue draw calls
/// without accessing the full `RHI` composite. Obtain via `rhi.renderContext()`.
/// Reduces coupling and clarifies intent.
///
/// **Note:** The encoder is resolved at construction time via `getEncoder()`, so
/// this must be constructed per-frame (not cached across frame boundaries).
///
/// ```zig
/// const rc = rhi.renderContext();
/// rc.beginMainPass();
/// rc.draw(buffer, count, .triangles);
/// rc.endMainPass();
/// ```
pub const RenderContext = struct {
    render: IRenderContext,
    passes: IPassOrchestrationContext,
    post_process: IPostProcessContext,
    effects: IRenderEffectsContext,
    vulkan: VulkanNativeHandles,
    encoder: IGraphicsCommandEncoder,
    state: IRenderStateContext,

    // --- IRenderContext delegates ---

    /// Forwards `beginFrame` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginFrame(self: RenderContext) void {
        self.render.beginFrame();
    }
    /// Forwards `endFrame` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endFrame(self: RenderContext) void {
        self.render.endFrame();
    }
    /// Forwards `abortFrame` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn abortFrame(self: RenderContext) void {
        self.render.abortFrame();
    }
    /// Forwards `beginMainPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginMainPass(self: RenderContext) void {
        self.passes.beginMainPass();
    }
    /// Forwards `endMainPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endMainPass(self: RenderContext) void {
        self.passes.endMainPass();
    }
    /// Forwards `beginPostProcessPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginPostProcessPass(self: RenderContext) void {
        self.passes.beginPostProcessPass();
    }
    /// Forwards `endPostProcessPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endPostProcessPass(self: RenderContext) void {
        self.passes.endPostProcessPass();
    }
    /// Forwards `beginGPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginGPass(self: RenderContext) void {
        self.passes.beginGPass();
    }
    /// Forwards `endGPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endGPass(self: RenderContext) void {
        self.passes.endGPass();
    }
    /// Forwards `beginFXAAPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginFXAAPass(self: RenderContext) void {
        self.passes.beginFXAAPass();
    }
    /// Forwards `endFXAAPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endFXAAPass(self: RenderContext) void {
        self.passes.endFXAAPass();
    }
    /// Forwards `computeBloom` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn computeBloom(self: RenderContext) void {
        self.post_process.computeBloom();
    }
    /// Forwards `computeTAA` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn computeTAA(self: RenderContext) void {
        self.post_process.computeTAA();
    }
    /// Forwards `computeDepthPyramid` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn computeDepthPyramid(self: RenderContext) void {
        self.post_process.computeDepthPyramid();
    }
    /// Forwards `drawSky` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawSky(self: RenderContext, params: SkyParams) RhiError!void {
        return self.effects.drawSky(params);
    }
    /// Forwards `beginWaterDraw` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginWaterDraw(self: RenderContext, reflection: TextureHandle, scene_depth: TextureHandle) bool {
        return self.effects.beginWaterDraw(reflection, scene_depth);
    }
    /// Forwards `endWaterDraw` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endWaterDraw(self: RenderContext) void {
        self.effects.endWaterDraw();
    }
    /// Forwards `requestSwapchainRecreate` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn requestSwapchainRecreate(self: RenderContext) void {
        self.render.requestSwapchainRecreate();
    }
    /// Forwards `setClearColor` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setClearColor(self: RenderContext, color: Vec3) void {
        self.render.vtable.setClearColor(self.render.ptr, color);
    }
    /// Forwards `getNativeSwapchainExtent` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getNativeSwapchainExtent(self: RenderContext) [2]u32 {
        return self.vulkan.getSwapchainExtent();
    }
    /// Forwards `getNativeDevice` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getNativeDevice(self: RenderContext) u64 {
        return self.vulkan.getDevice();
    }

    // --- IGraphicsCommandEncoder delegates ---

    /// Forwards `bindTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn bindTexture(self: RenderContext, handle: TextureHandle, slot: u32) void {
        self.encoder.bindTexture(handle, slot);
    }
    /// Forwards `bindBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn bindBuffer(self: RenderContext, handle: BufferHandle, usage: BufferUsage) void {
        self.encoder.bindBuffer(handle, usage);
    }
    /// Forwards `pushConstants` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn pushConstants(self: RenderContext, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
        self.encoder.pushConstants(stages, offset, size, data);
    }
    /// Forwards `draw` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn draw(self: RenderContext, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.encoder.draw(handle, count, mode);
    }
    /// Forwards `drawOffset` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawOffset(self: RenderContext, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void {
        self.encoder.drawOffset(handle, count, mode, offset);
    }
    /// Forwards `drawIndexed` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawIndexed(self: RenderContext, vbo: BufferHandle, ebo: BufferHandle, count: u32) void {
        self.encoder.drawIndexed(vbo, ebo, count);
    }
    /// Forwards `drawIndirect` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawIndirect(self: RenderContext, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
        self.encoder.drawIndirect(handle, command_buffer, offset, draw_count, stride);
    }
    /// Forwards `drawInstance` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawInstance(self: RenderContext, handle: BufferHandle, count: u32, instance_index: u32) void {
        self.encoder.drawInstance(handle, count, instance_index);
    }
    /// Forwards `setViewport` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setViewport(self: RenderContext, width: u32, height: u32) void {
        self.encoder.setViewport(width, height);
    }

    // --- IRenderStateContext delegates ---

    /// Forwards `setModelMatrix` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setModelMatrix(self: RenderContext, model: Mat4, color: Vec3, mask_radius: f32) void {
        self.state.setModelMatrix(model, color, mask_radius);
    }
    /// Forwards `setInstanceBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setInstanceBuffer(self: RenderContext, handle: BufferHandle) void {
        self.state.setInstanceBuffer(handle);
    }
    /// Forwards `setLODInstanceBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setLODInstanceBuffer(self: RenderContext, handle: BufferHandle) void {
        self.state.setLODInstanceBuffer(handle);
    }
    /// Forwards `setTerrainPipelineBound` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setTerrainPipelineBound(self: RenderContext, bound: bool) void {
        self.state.setTerrainPipelineBound(bound);
    }
    /// Forwards `setSelectionMode` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setSelectionMode(self: RenderContext, enabled: bool) void {
        self.state.setSelectionMode(enabled);
    }
    /// Forwards `updateGlobalUniforms` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn updateGlobalUniforms(self: RenderContext, uniforms: GlobalUniforms, frame_params: FrameRenderParams) !void {
        try self.state.updateGlobalUniforms(uniforms, frame_params);
    }
    /// Forwards `setTextureUniforms` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setTextureUniforms(self: RenderContext, texture_enabled: bool, shadow_map_handles: [SHADOW_CASCADE_COUNT]TextureHandle) void {
        self.state.setTextureUniforms(texture_enabled, shadow_map_handles);
    }
};

pub const IShadowContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginPass: *const fn (ptr: *anyopaque, cascade_index: u32, light_space_matrix: Mat4) void,
        endPass: *const fn (ptr: *anyopaque) void,
        updateUniforms: *const fn (ptr: *anyopaque, params: ShadowParams) anyerror!void,
        getShadowMapHandle: *const fn (ptr: *anyopaque, cascade_index: u32) TextureHandle,
    };

    /// Forwards `beginPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginPass(self: IShadowContext, cascade_index: u32, light_space_matrix: Mat4) void {
        self.vtable.beginPass(self.ptr, cascade_index, light_space_matrix);
    }
    /// Forwards `endPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endPass(self: IShadowContext) void {
        self.vtable.endPass(self.ptr);
    }
    /// Forwards `updateUniforms` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn updateUniforms(self: IShadowContext, params: ShadowParams) !void {
        try self.vtable.updateUniforms(self.ptr, params);
    }
    /// Forwards `getShadowMapHandle` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getShadowMapHandle(self: IShadowContext, cascade_index: u32) TextureHandle {
        return self.vtable.getShadowMapHandle(self.ptr, cascade_index);
    }
};

/// Concrete wrapper around `IShadowContext` for shadow mapping operations.
///
/// Use this when a subsystem only needs shadow map rendering without accessing
/// the full `RHI` composite. Obtain via `rhi.shadowSystem()`. Reduces coupling
/// and clarifies intent.
///
/// ```zig
/// const ss = rhi.shadowSystem();
/// ss.beginPass(0, light_space_matrix);
/// // ... render shadow casters ...
/// ss.endPass();
/// const handle = ss.getShadowMapHandle(0);
/// ```
pub const ShadowSystemWrapper = struct {
    ctx: IShadowContext,

    /// Forwards `beginPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginPass(self: ShadowSystemWrapper, cascade_index: u32, light_space_matrix: Mat4) void {
        self.ctx.beginPass(cascade_index, light_space_matrix);
    }
    /// Forwards `endPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endPass(self: ShadowSystemWrapper) void {
        self.ctx.endPass();
    }
    /// Forwards `updateUniforms` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn updateUniforms(self: ShadowSystemWrapper, params: ShadowParams) !void {
        try self.ctx.updateUniforms(params);
    }
    /// Forwards `getShadowMapHandle` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getShadowMapHandle(self: ShadowSystemWrapper, cascade_index: u32) TextureHandle {
        return self.ctx.getShadowMapHandle(cascade_index);
    }
};

pub const IWaterContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginReflectionPass: *const fn (ptr: *anyopaque) void,
        endReflectionPass: *const fn (ptr: *anyopaque) void,
        getReflectionTextureHandle: *const fn (ptr: *anyopaque) TextureHandle,
        getSceneDepthTextureHandle: *const fn (ptr: *anyopaque) TextureHandle,
        computeReflectedViewProj: *const fn (ptr: *anyopaque, view: Mat4, proj: Mat4, camera_pos: Vec3) Mat4,
    };

    /// Forwards `beginReflectionPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginReflectionPass(self: IWaterContext) void {
        self.vtable.beginReflectionPass(self.ptr);
    }
    /// Forwards `endReflectionPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endReflectionPass(self: IWaterContext) void {
        self.vtable.endReflectionPass(self.ptr);
    }
    /// Forwards `getReflectionTextureHandle` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getReflectionTextureHandle(self: IWaterContext) TextureHandle {
        return self.vtable.getReflectionTextureHandle(self.ptr);
    }
    /// Forwards `getSceneDepthTextureHandle` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getSceneDepthTextureHandle(self: IWaterContext) TextureHandle {
        return self.vtable.getSceneDepthTextureHandle(self.ptr);
    }
    /// Forwards `computeReflectedViewProj` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn computeReflectedViewProj(self: IWaterContext, view: Mat4, proj: Mat4, camera_pos: Vec3) Mat4 {
        return self.vtable.computeReflectedViewProj(self.ptr, view, proj, camera_pos);
    }
};

pub const WaterSystemWrapper = struct {
    ctx: IWaterContext,

    /// Forwards `beginReflectionPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginReflectionPass(self: WaterSystemWrapper) void {
        self.ctx.beginReflectionPass();
    }
    /// Forwards `endReflectionPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endReflectionPass(self: WaterSystemWrapper) void {
        self.ctx.endReflectionPass();
    }
    /// Forwards `getReflectionTextureHandle` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getReflectionTextureHandle(self: WaterSystemWrapper) TextureHandle {
        return self.ctx.getReflectionTextureHandle();
    }
    /// Forwards `getSceneDepthTextureHandle` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getSceneDepthTextureHandle(self: WaterSystemWrapper) TextureHandle {
        return self.ctx.getSceneDepthTextureHandle();
    }
    /// Forwards `computeReflectedViewProj` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn computeReflectedViewProj(self: WaterSystemWrapper, view: Mat4, proj: Mat4, camera_pos: Vec3) Mat4 {
        return self.ctx.computeReflectedViewProj(view, proj, camera_pos);
    }
};

pub const IUIContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginPass: *const fn (ptr: *anyopaque, width: f32, height: f32) void,
        endPass: *const fn (ptr: *anyopaque) void,
        drawRect: *const fn (ptr: *anyopaque, rect: Rect, color: Color) void,
        drawTexture: *const fn (ptr: *anyopaque, texture: TextureHandle, rect: Rect) void,
        drawTextureRegion: *const fn (ptr: *anyopaque, texture: TextureHandle, rect: Rect, uv: UVRect, color: Color) void,
        drawDepthTexture: *const fn (ptr: *anyopaque, texture: TextureHandle, rect: Rect) void,
        bindPipeline: *const fn (ptr: *anyopaque, textured: bool) void,
    };

    /// Forwards `beginPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginPass(self: IUIContext, width: f32, height: f32) void {
        self.vtable.beginPass(self.ptr, width, height);
    }
    /// Forwards `endPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endPass(self: IUIContext) void {
        self.vtable.endPass(self.ptr);
    }
    /// Forwards `drawRect` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawRect(self: IUIContext, rect: Rect, color: Color) void {
        self.vtable.drawRect(self.ptr, rect, color);
    }
    /// Forwards `drawTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawTexture(self: IUIContext, texture: TextureHandle, rect: Rect) void {
        self.vtable.drawTexture(self.ptr, texture, rect);
    }
    /// Forwards `drawTextureRegion` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawTextureRegion(self: IUIContext, texture: TextureHandle, rect: Rect, uv: UVRect, color: Color) void {
        self.vtable.drawTextureRegion(self.ptr, texture, rect, uv, color);
    }
    /// Forwards `drawDepthTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawDepthTexture(self: IUIContext, texture: TextureHandle, rect: Rect) void {
        self.vtable.drawDepthTexture(self.ptr, texture, rect);
    }
    /// Forwards `bindPipeline` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn bindPipeline(self: IUIContext, textured: bool) void {
        self.vtable.bindPipeline(self.ptr, textured);
    }
};

pub const IImGuiContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        initBackend: *const fn (ptr: *anyopaque, window: *anyopaque) bool,
        shutdownBackend: *const fn (ptr: *anyopaque) void,
        newFrame: *const fn (ptr: *anyopaque) void,
        renderDrawData: *const fn (ptr: *anyopaque, draw_data: *anyopaque) void,
    };

    /// Forwards `initBackend` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn initBackend(self: IImGuiContext, window: *anyopaque) bool {
        return self.vtable.initBackend(self.ptr, window);
    }
    /// Forwards `shutdownBackend` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn shutdownBackend(self: IImGuiContext) void {
        self.vtable.shutdownBackend(self.ptr);
    }
    /// Forwards `newFrame` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn newFrame(self: IImGuiContext) void {
        self.vtable.newFrame(self.ptr);
    }
    /// Forwards `renderDrawData` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn renderDrawData(self: IImGuiContext, draw_data: *anyopaque) void {
        self.vtable.renderDrawData(self.ptr, draw_data);
    }
};

/// Focused wrapper for immediate-mode UI rendering.
///
/// Provides a clean interface for 2D drawing operations (rectangles,
/// textures, depth textures) without exposing the full RHI composite.
///
/// ```zig
/// const ui = rhi.uiRenderer();
/// ui.beginPass(width, height);
/// ui.drawRect(rect, color);
/// ui.drawTexture(tex, rect);
/// ui.endPass();
/// ```
pub const UIRenderer = struct {
    ctx: IUIContext,

    /// Forwards `beginPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginPass(self: UIRenderer, width: f32, height: f32) void {
        self.ctx.beginPass(width, height);
    }
    /// Forwards `endPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endPass(self: UIRenderer) void {
        self.ctx.endPass();
    }
    /// Forwards `drawRect` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawRect(self: UIRenderer, rect: Rect, color: Color) void {
        self.ctx.drawRect(rect, color);
    }
    /// Forwards `drawTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawTexture(self: UIRenderer, texture: TextureHandle, rect: Rect) void {
        self.ctx.drawTexture(texture, rect);
    }
    /// Forwards `drawTextureRegion` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawTextureRegion(self: UIRenderer, texture: TextureHandle, rect: Rect, uv: UVRect, color: Color) void {
        self.ctx.drawTextureRegion(texture, rect, uv, color);
    }
    /// Forwards `drawDepthTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawDepthTexture(self: UIRenderer, texture: TextureHandle, rect: Rect) void {
        self.ctx.drawDepthTexture(texture, rect);
    }
    /// Forwards `bindPipeline` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn bindPipeline(self: UIRenderer, textured: bool) void {
        self.ctx.bindPipeline(textured);
    }
};

pub const IGraphicsCommandEncoder = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        bindTexture: *const fn (ptr: *anyopaque, handle: TextureHandle, slot: u32) void,
        bindBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, usage: BufferUsage) void,
        pushConstants: *const fn (ptr: *anyopaque, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void,
        draw: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: DrawMode) void,
        drawOffset: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void,
        drawIndexed: *const fn (ptr: *anyopaque, vbo: BufferHandle, ebo: BufferHandle, count: u32) void,
        drawIndirect: *const fn (ptr: *anyopaque, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, draw_count: u32, stride: u32) void,
        drawInstance: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, instance_index: u32) void,
        setViewport: *const fn (ptr: *anyopaque, width: u32, height: u32) void,
    };

    /// Forwards `bindTexture` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn bindTexture(self: IGraphicsCommandEncoder, handle: TextureHandle, slot: u32) void {
        self.vtable.bindTexture(self.ptr, handle, slot);
    }
    /// Forwards `bindBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn bindBuffer(self: IGraphicsCommandEncoder, handle: BufferHandle, usage: BufferUsage) void {
        self.vtable.bindBuffer(self.ptr, handle, usage);
    }
    /// Forwards `pushConstants` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn pushConstants(self: IGraphicsCommandEncoder, stages: ShaderStageFlags, offset: u32, size: u32, data: *const anyopaque) void {
        self.vtable.pushConstants(self.ptr, stages, offset, size, data);
    }
    /// Forwards `draw` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn draw(self: IGraphicsCommandEncoder, handle: BufferHandle, count: u32, mode: DrawMode) void {
        self.vtable.draw(self.ptr, handle, count, mode);
    }
    /// Forwards `drawOffset` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawOffset(self: IGraphicsCommandEncoder, handle: BufferHandle, count: u32, mode: DrawMode, offset: usize) void {
        self.vtable.drawOffset(self.ptr, handle, count, mode, offset);
    }
    /// Forwards `drawIndexed` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawIndexed(self: IGraphicsCommandEncoder, vbo: BufferHandle, ebo: BufferHandle, count: u32) void {
        self.vtable.drawIndexed(self.ptr, vbo, ebo, count);
    }
    /// Forwards `drawIndirect` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawIndirect(self: IGraphicsCommandEncoder, handle: BufferHandle, command_buffer: BufferHandle, offset: usize, draw_count: u32, stride: u32) void {
        self.vtable.drawIndirect(self.ptr, handle, command_buffer, offset, draw_count, stride);
    }
    /// Forwards `drawInstance` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawInstance(self: IGraphicsCommandEncoder, handle: BufferHandle, count: u32, instance_index: u32) void {
        self.vtable.drawInstance(self.ptr, handle, count, instance_index);
    }
    /// Forwards `setViewport` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setViewport(self: IGraphicsCommandEncoder, width: u32, height: u32) void {
        self.vtable.setViewport(self.ptr, width, height);
    }
};

pub const IRenderStateContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setModelMatrix: *const fn (ptr: *anyopaque, model: Mat4, color: Vec3, mask_radius: f32) void,
        setInstanceBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        setLODInstanceBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        setTerrainPipelineBound: *const fn (ptr: *anyopaque, bound: bool) void,
        setSelectionMode: *const fn (ptr: *anyopaque, enabled: bool) void,
        updateGlobalUniforms: *const fn (ptr: *anyopaque, uniforms: GlobalUniforms, frame_params: FrameRenderParams) anyerror!void,
        setTextureUniforms: *const fn (ptr: *anyopaque, texture_enabled: bool, shadow_map_handles: [SHADOW_CASCADE_COUNT]TextureHandle) void,
    };

    /// Forwards `setModelMatrix` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setModelMatrix(self: IRenderStateContext, model: Mat4, color: Vec3, mask_radius: f32) void {
        self.vtable.setModelMatrix(self.ptr, model, color, mask_radius);
    }
    /// Forwards `setInstanceBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setInstanceBuffer(self: IRenderStateContext, handle: BufferHandle) void {
        self.vtable.setInstanceBuffer(self.ptr, handle);
    }
    /// Forwards `setLODInstanceBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setLODInstanceBuffer(self: IRenderStateContext, handle: BufferHandle) void {
        self.vtable.setLODInstanceBuffer(self.ptr, handle);
    }
    /// Forwards `setTerrainPipelineBound` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setTerrainPipelineBound(self: IRenderStateContext, bound: bool) void {
        self.vtable.setTerrainPipelineBound(self.ptr, bound);
    }
    /// Forwards `setSelectionMode` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setSelectionMode(self: IRenderStateContext, enabled: bool) void {
        self.vtable.setSelectionMode(self.ptr, enabled);
    }
    /// Forwards `updateGlobalUniforms` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn updateGlobalUniforms(self: IRenderStateContext, uniforms: GlobalUniforms, frame_params: FrameRenderParams) !void {
        try self.vtable.updateGlobalUniforms(self.ptr, uniforms, frame_params);
    }
    /// Forwards `setTextureUniforms` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setTextureUniforms(self: IRenderStateContext, texture_enabled: bool, shadow_map_handles: [SHADOW_CASCADE_COUNT]TextureHandle) void {
        self.vtable.setTextureUniforms(self.ptr, texture_enabled, shadow_map_handles);
    }
};

pub const ISSAOContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Computes SSAO.
        compute: *const fn (ptr: *anyopaque, proj: Mat4, inv_proj: Mat4) void,
    };

    /// Forwards `compute` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn compute(self: ISSAOContext, proj: Mat4, inv_proj: Mat4) void {
        self.vtable.compute(self.ptr, proj, inv_proj);
    }
};

pub const IDebugOverlayContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Draws debug shadow map overlay.
        drawDebugShadowMap: *const fn (ptr: *anyopaque, cascade_index: usize, depth_map_handle: TextureHandle) void,
    };

    /// Forwards `drawDebugShadowMap` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawDebugShadowMap(self: IDebugOverlayContext, cascade_index: usize, depth_map_handle: TextureHandle) void {
        self.vtable.drawDebugShadowMap(self.ptr, cascade_index, depth_map_handle);
    }
};

pub const PipelineStageFlags = u32;
pub const AccessFlags = u32;

pub const PIPELINE_STAGE_HOST_BIT: PipelineStageFlags = 0x00004000;
pub const PIPELINE_STAGE_TRANSFER_BIT: PipelineStageFlags = 0x00001000;
pub const PIPELINE_STAGE_COMPUTE_SHADER_BIT: PipelineStageFlags = 0x00000800;
pub const PIPELINE_STAGE_VERTEX_INPUT_BIT: PipelineStageFlags = 0x00000004;

pub const ACCESS_HOST_READ_BIT: AccessFlags = 0x00002000;
pub const ACCESS_TRANSFER_READ_BIT: AccessFlags = 0x00000800;
pub const ACCESS_TRANSFER_WRITE_BIT: AccessFlags = 0x00001000;
pub const ACCESS_SHADER_READ_BIT: AccessFlags = 0x00000020;
pub const ACCESS_SHADER_WRITE_BIT: AccessFlags = 0x00000040;
pub const ACCESS_VERTEX_ATTRIBUTE_READ_BIT: AccessFlags = 0x00000004;

pub const ComputeBuffer = struct {
    handle: u32 = 0,
    mapped_ptr: ?*anyopaque = null,
};

pub const ComputePipeline = struct {
    handle: u32 = 0,
};

pub const IComputeContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        bindComputePipeline: *const fn (ptr: *anyopaque, pipeline: ComputePipeline) void,
        bindDescriptorSet: *const fn (ptr: *anyopaque, pipeline: ComputePipeline, frame_index: usize) void,
        createComputeBuffer: *const fn (ptr: *anyopaque, size: usize, host_visible: bool) RhiError!ComputeBuffer,
        destroyComputeBuffer: *const fn (ptr: *anyopaque, buffer: *ComputeBuffer) void,
        createComputePipeline: *const fn (ptr: *anyopaque, allocator: Allocator, shader_path: []const u8, storage_binding_count: u32, push_constant_size: u32) anyerror!ComputePipeline,
        updateComputeDescriptors: *const fn (ptr: *anyopaque, pipeline: ComputePipeline, frame_index: usize, storage_buffers: []const ComputeBufferBinding) void,
        destroyComputePipeline: *const fn (ptr: *anyopaque, pipeline: *ComputePipeline) void,
        dispatch: *const fn (ptr: *anyopaque, group_count_x: u32, group_count_y: u32, group_count_z: u32) void,
        pushConstants: *const fn (ptr: *anyopaque, pipeline: ComputePipeline, offset: u32, size: u32, data: *const anyopaque) void,
        fillBuffer: *const fn (ptr: *anyopaque, buffer: ComputeBuffer, offset: u64, size: u64, data: u32) void,
        copyBuffer: *const fn (ptr: *anyopaque, src_buffer: ComputeBufferBinding, dst_buffer: ComputeBufferBinding, src_offset: u64, dst_offset: u64, size: u64) void,
        pipelineBarrier: *const fn (ptr: *anyopaque, src_stage: PipelineStageFlags, dst_stage: PipelineStageFlags, src_access: AccessFlags, dst_access: AccessFlags) void,
        bufferBarrier: *const fn (ptr: *anyopaque, buffer: ComputeBufferBinding, src_stage: PipelineStageFlags, dst_stage: PipelineStageFlags, src_access: AccessFlags, dst_access: AccessFlags, offset: u64, size: u64) void,
        waitForFrameFence: *const fn (ptr: *anyopaque, frame_index: usize) bool,
        hasCommandBuffer: *const fn (ptr: *anyopaque) bool,
    };

    /// Forwards `bindComputePipeline` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn bindComputePipeline(self: IComputeContext, pipeline: ComputePipeline) void {
        self.vtable.bindComputePipeline(self.ptr, pipeline);
    }
    /// Forwards `bindDescriptorSet` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn bindDescriptorSet(self: IComputeContext, pipeline: ComputePipeline, frame_index: usize) void {
        self.vtable.bindDescriptorSet(self.ptr, pipeline, frame_index);
    }
    /// Forwards `createComputeBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createComputeBuffer(self: IComputeContext, size: usize, host_visible: bool) RhiError!ComputeBuffer {
        return self.vtable.createComputeBuffer(self.ptr, size, host_visible);
    }
    /// Forwards `destroyComputeBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn destroyComputeBuffer(self: IComputeContext, buffer: *ComputeBuffer) void {
        self.vtable.destroyComputeBuffer(self.ptr, buffer);
    }
    /// Forwards `createComputePipeline` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createComputePipeline(self: IComputeContext, allocator: Allocator, shader_path: []const u8, storage_binding_count: u32, push_constant_size: u32) anyerror!ComputePipeline {
        return self.vtable.createComputePipeline(self.ptr, allocator, shader_path, storage_binding_count, push_constant_size);
    }
    /// Forwards `updateComputeDescriptors` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn updateComputeDescriptors(self: IComputeContext, pipeline: ComputePipeline, frame_index: usize, storage_buffers: []const ComputeBufferBinding) void {
        self.vtable.updateComputeDescriptors(self.ptr, pipeline, frame_index, storage_buffers);
    }
    /// Forwards `destroyComputePipeline` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn destroyComputePipeline(self: IComputeContext, pipeline: *ComputePipeline) void {
        self.vtable.destroyComputePipeline(self.ptr, pipeline);
    }
    /// Forwards `dispatch` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn dispatch(self: IComputeContext, group_count_x: u32, group_count_y: u32, group_count_z: u32) void {
        self.vtable.dispatch(self.ptr, group_count_x, group_count_y, group_count_z);
    }
    /// Forwards `pushConstants` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn pushConstants(self: IComputeContext, pipeline: ComputePipeline, offset: u32, size: u32, data: *const anyopaque) void {
        self.vtable.pushConstants(self.ptr, pipeline, offset, size, data);
    }
    /// Forwards `fillBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn fillBuffer(self: IComputeContext, buffer: ComputeBuffer, offset: u64, size: u64, data: u32) void {
        self.vtable.fillBuffer(self.ptr, buffer, offset, size, data);
    }
    /// Forwards `copyBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn copyBuffer(self: IComputeContext, src_buffer: ComputeBufferBinding, dst_buffer: ComputeBufferBinding, src_offset: u64, dst_offset: u64, size: u64) void {
        self.vtable.copyBuffer(self.ptr, src_buffer, dst_buffer, src_offset, dst_offset, size);
    }
    /// Forwards `pipelineBarrier` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn pipelineBarrier(self: IComputeContext, src_stage: PipelineStageFlags, dst_stage: PipelineStageFlags, src_access: AccessFlags, dst_access: AccessFlags) void {
        self.vtable.pipelineBarrier(self.ptr, src_stage, dst_stage, src_access, dst_access);
    }
    /// Forwards `bufferBarrier` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn bufferBarrier(self: IComputeContext, buffer: ComputeBufferBinding, src_stage: PipelineStageFlags, dst_stage: PipelineStageFlags, src_access: AccessFlags, dst_access: AccessFlags, offset: u64, size: u64) void {
        self.vtable.bufferBarrier(self.ptr, buffer, src_stage, dst_stage, src_access, dst_access, offset, size);
    }
    /// Forwards `waitForFrameFence` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn waitForFrameFence(self: IComputeContext, frame_index: usize) bool {
        return self.vtable.waitForFrameFence(self.ptr, frame_index);
    }
    /// Forwards `hasCommandBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn hasCommandBuffer(self: IComputeContext) bool {
        return self.vtable.hasCommandBuffer(self.ptr);
    }
};

pub const ComputeBufferBinding = union(enum) {
    compute: ComputeBuffer,
    buffer: BufferHandle,
};

pub const IRenderContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginFrame: *const fn (ptr: *anyopaque) void,
        endFrame: *const fn (ptr: *anyopaque) void,
        abortFrame: *const fn (ptr: *anyopaque) void,
        requestSwapchainRecreate: *const fn (ptr: *anyopaque) void,
        getEncoder: *const fn (ptr: *anyopaque) IGraphicsCommandEncoder,
        getStateContext: *const fn (ptr: *anyopaque) IRenderStateContext,
        setClearColor: *const fn (ptr: *anyopaque, color: Vec3) void,
    };

    /// Forwards `beginFrame` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginFrame(self: IRenderContext) void {
        self.vtable.beginFrame(self.ptr);
    }
    /// Forwards `endFrame` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endFrame(self: IRenderContext) void {
        self.vtable.endFrame(self.ptr);
    }
    /// Forwards `abortFrame` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn abortFrame(self: IRenderContext) void {
        self.vtable.abortFrame(self.ptr);
    }
    /// Forwards `requestSwapchainRecreate` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn requestSwapchainRecreate(self: IRenderContext) void {
        self.vtable.requestSwapchainRecreate(self.ptr);
    }
    /// Forwards `getEncoder` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getEncoder(self: IRenderContext) IGraphicsCommandEncoder {
        return self.vtable.getEncoder(self.ptr);
    }
    /// Forwards `getState` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getState(self: IRenderContext) IRenderStateContext {
        return self.vtable.getStateContext(self.ptr);
    }
};

pub const IPassOrchestrationContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginMainPass: *const fn (ptr: *anyopaque) void,
        endMainPass: *const fn (ptr: *anyopaque) void,
        beginPostProcessPass: *const fn (ptr: *anyopaque) void,
        endPostProcessPass: *const fn (ptr: *anyopaque) void,
        beginGPass: *const fn (ptr: *anyopaque) void,
        endGPass: *const fn (ptr: *anyopaque) void,
        beginFXAAPass: *const fn (ptr: *anyopaque) void,
        endFXAAPass: *const fn (ptr: *anyopaque) void,
    };

    /// Forwards `beginMainPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginMainPass(self: IPassOrchestrationContext) void {
        self.vtable.beginMainPass(self.ptr);
    }
    /// Forwards `endMainPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endMainPass(self: IPassOrchestrationContext) void {
        self.vtable.endMainPass(self.ptr);
    }
    /// Forwards `beginPostProcessPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginPostProcessPass(self: IPassOrchestrationContext) void {
        self.vtable.beginPostProcessPass(self.ptr);
    }
    /// Forwards `endPostProcessPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endPostProcessPass(self: IPassOrchestrationContext) void {
        self.vtable.endPostProcessPass(self.ptr);
    }
    /// Forwards `beginGPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginGPass(self: IPassOrchestrationContext) void {
        self.vtable.beginGPass(self.ptr);
    }
    /// Forwards `endGPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endGPass(self: IPassOrchestrationContext) void {
        self.vtable.endGPass(self.ptr);
    }
    /// Forwards `beginFXAAPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginFXAAPass(self: IPassOrchestrationContext) void {
        self.vtable.beginFXAAPass(self.ptr);
    }
    /// Forwards `endFXAAPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endFXAAPass(self: IPassOrchestrationContext) void {
        self.vtable.endFXAAPass(self.ptr);
    }
};

pub const IPostProcessContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        computeBloom: *const fn (ptr: *anyopaque) void,
        computeTAA: *const fn (ptr: *anyopaque) void,
        computeDepthPyramid: *const fn (ptr: *anyopaque) void,
    };

    /// Forwards `computeBloom` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn computeBloom(self: IPostProcessContext) void {
        self.vtable.computeBloom(self.ptr);
    }
    /// Forwards `computeTAA` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn computeTAA(self: IPostProcessContext) void {
        self.vtable.computeTAA(self.ptr);
    }
    /// Forwards `computeDepthPyramid` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn computeDepthPyramid(self: IPostProcessContext) void {
        self.vtable.computeDepthPyramid(self.ptr);
    }
};

pub const IRenderEffectsContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        drawSky: *const fn (ptr: *anyopaque, params: SkyParams) RhiError!void,
        beginWaterDraw: *const fn (ptr: *anyopaque, reflection: TextureHandle, scene_depth: TextureHandle) bool,
        endWaterDraw: *const fn (ptr: *anyopaque) void,
    };

    /// Forwards `drawSky` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn drawSky(self: IRenderEffectsContext, params: SkyParams) RhiError!void {
        return self.vtable.drawSky(self.ptr, params);
    }
    /// Forwards `beginWaterDraw` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginWaterDraw(self: IRenderEffectsContext, reflection: TextureHandle, scene_depth: TextureHandle) bool {
        return self.vtable.beginWaterDraw(self.ptr, reflection, scene_depth);
    }
    /// Forwards `endWaterDraw` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endWaterDraw(self: IRenderEffectsContext) void {
        self.vtable.endWaterDraw(self.ptr);
    }
};

/// Vulkan-only native handles used by ImGui, LPV, and other integrations that
/// need concrete Vulkan objects. This intentionally is not an abstract native
/// handle interface for portable render backends.
pub const VulkanNativeHandles = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getCommandBuffer: *const fn (ptr: *anyopaque) u64,
        getSwapchainExtent: *const fn (ptr: *anyopaque) [2]u32,
        getDevice: *const fn (ptr: *anyopaque) u64,
        getInstance: *const fn (ptr: *anyopaque) u64,
        getPhysicalDevice: *const fn (ptr: *anyopaque) u64,
        getQueue: *const fn (ptr: *anyopaque) u64,
        getQueueFamily: *const fn (ptr: *anyopaque) u32,
        getDescriptorPool: *const fn (ptr: *anyopaque) u64,
        getUiRenderPass: *const fn (ptr: *anyopaque) u64,
        getSwapchainImageCount: *const fn (ptr: *anyopaque) u32,
    };

    /// Forwards `getCommandBuffer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getCommandBuffer(self: VulkanNativeHandles) u64 {
        return self.vtable.getCommandBuffer(self.ptr);
    }
    /// Forwards `getSwapchainExtent` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getSwapchainExtent(self: VulkanNativeHandles) [2]u32 {
        return self.vtable.getSwapchainExtent(self.ptr);
    }
    /// Forwards `getDevice` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getDevice(self: VulkanNativeHandles) u64 {
        return self.vtable.getDevice(self.ptr);
    }
    /// Forwards `getInstance` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getInstance(self: VulkanNativeHandles) u64 {
        return self.vtable.getInstance(self.ptr);
    }
    /// Forwards `getPhysicalDevice` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getPhysicalDevice(self: VulkanNativeHandles) u64 {
        return self.vtable.getPhysicalDevice(self.ptr);
    }
    /// Forwards `getQueue` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getQueue(self: VulkanNativeHandles) u64 {
        return self.vtable.getQueue(self.ptr);
    }
    /// Forwards `getQueueFamily` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getQueueFamily(self: VulkanNativeHandles) u32 {
        return self.vtable.getQueueFamily(self.ptr);
    }
    /// Forwards `getDescriptorPool` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getDescriptorPool(self: VulkanNativeHandles) u64 {
        return self.vtable.getDescriptorPool(self.ptr);
    }
    /// Forwards `getUiRenderPass` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getUiRenderPass(self: VulkanNativeHandles) u64 {
        return self.vtable.getUiRenderPass(self.ptr);
    }
    /// Forwards `getSwapchainImageCount` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getSwapchainImageCount(self: VulkanNativeHandles) u32 {
        return self.vtable.getSwapchainImageCount(self.ptr);
    }
};

pub const IDeviceQuery = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        getFrameIndex: *const fn (ptr: *anyopaque) usize,
        supportsIndirectFirstInstance: *const fn (ptr: *anyopaque) bool,
        getMaxAnisotropy: *const fn (ptr: *anyopaque) u8,
        getMaxMSAASamples: *const fn (ptr: *anyopaque) u8,
        getFaultCount: *const fn (ptr: *anyopaque) u32,
        getValidationErrorCount: *const fn (ptr: *anyopaque) u32,
        getDrawCallCount: *const fn (ptr: *anyopaque) u32,
        getDeviceLocalVramBytes: *const fn (ptr: *anyopaque) u64,
        getRenderResolution: *const fn (ptr: *anyopaque) RenderResolution,
        waitIdle: *const fn (ptr: *anyopaque) void,
    };

    /// Forwards `getFrameIndex` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getFrameIndex(self: IDeviceQuery) usize {
        return self.vtable.getFrameIndex(self.ptr);
    }
    /// Forwards `supportsIndirectFirstInstance` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn supportsIndirectFirstInstance(self: IDeviceQuery) bool {
        return self.vtable.supportsIndirectFirstInstance(self.ptr);
    }
    /// Forwards `getFaultCount` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getFaultCount(self: IDeviceQuery) u32 {
        return self.vtable.getFaultCount(self.ptr);
    }
    /// Forwards `getValidationErrorCount` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getValidationErrorCount(self: IDeviceQuery) u32 {
        return self.vtable.getValidationErrorCount(self.ptr);
    }

    /// Forwards `getDrawCallCount` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getDrawCallCount(self: IDeviceQuery) u32 {
        return self.vtable.getDrawCallCount(self.ptr);
    }

    /// Forwards `getDeviceLocalVramBytes` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getDeviceLocalVramBytes(self: IDeviceQuery) u64 {
        return self.vtable.getDeviceLocalVramBytes(self.ptr);
    }

    /// Forwards `getRenderResolution` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getRenderResolution(self: IDeviceQuery) RenderResolution {
        return self.vtable.getRenderResolution(self.ptr);
    }
    /// Forwards `waitIdle` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn waitIdle(self: IDeviceQuery) void {
        self.vtable.waitIdle(self.ptr);
    }
};

pub const IDeviceTiming = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        beginPassTiming: *const fn (ptr: *anyopaque, pass_name: []const u8) void,
        endPassTiming: *const fn (ptr: *anyopaque, pass_name: []const u8) void,
        getTimingResults: *const fn (ptr: *anyopaque) GpuTimingResults,
        isTimingEnabled: *const fn (ptr: *anyopaque) bool,
        setTimingEnabled: *const fn (ptr: *anyopaque, enabled: bool) void,
    };

    /// Forwards `beginPassTiming` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn beginPassTiming(self: IDeviceTiming, pass_name: []const u8) void {
        self.vtable.beginPassTiming(self.ptr, pass_name);
    }
    /// Forwards `endPassTiming` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn endPassTiming(self: IDeviceTiming, pass_name: []const u8) void {
        self.vtable.endPassTiming(self.ptr, pass_name);
    }
    /// Forwards `getTimingResults` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getTimingResults(self: IDeviceTiming) GpuTimingResults {
        return self.vtable.getTimingResults(self.ptr);
    }
    /// Forwards `isTimingEnabled` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn isTimingEnabled(self: IDeviceTiming) bool {
        return self.vtable.isTimingEnabled(self.ptr);
    }
    /// Forwards `setTimingEnabled` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setTimingEnabled(self: IDeviceTiming, enabled: bool) void {
        self.vtable.setTimingEnabled(self.ptr, enabled);
    }
};

pub const IRenderQualityOptions = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setWireframe: *const fn (ctx: *anyopaque, enabled: bool) void,
        setTexturesEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setDebugShadowView: *const fn (ctx: *anyopaque, enabled: bool) void,
        setShadowDebugChannel: *const fn (ctx: *anyopaque, channel: u32) void,
        setVSync: *const fn (ctx: *anyopaque, enabled: bool) void,
        setAnisotropicFiltering: *const fn (ctx: *anyopaque, level: u8) void,
        setVolumetricDensity: *const fn (ctx: *anyopaque, density: f32) void,
        setMSAA: *const fn (ctx: *anyopaque, samples: u8) void,
        setFXAA: *const fn (ctx: *anyopaque, enabled: bool) void,
        setBloom: *const fn (ctx: *anyopaque, enabled: bool) void,
        setBloomIntensity: *const fn (ctx: *anyopaque, intensity: f32) void,
        setVignetteEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setVignetteIntensity: *const fn (ctx: *anyopaque, intensity: f32) void,
        setFilmGrainEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setFilmGrainIntensity: *const fn (ctx: *anyopaque, intensity: f32) void,
        setColorGradingEnabled: *const fn (ctx: *anyopaque, enabled: bool) void,
        setColorGradingIntensity: *const fn (ctx: *anyopaque, intensity: f32) void,
        setTAABlendFactor: *const fn (ctx: *anyopaque, value: f32) void,
        setTAAVelocityRejection: *const fn (ctx: *anyopaque, value: f32) void,
        setDynamicResolution: *const fn (ctx: *anyopaque, enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void,
        getResolutionScale: *const fn (ctx: *anyopaque) f32,
    };

    /// Forwards `setWireframe` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setWireframe(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setWireframe(self.ptr, enabled);
    }
    /// Forwards `setTexturesEnabled` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setTexturesEnabled(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setTexturesEnabled(self.ptr, enabled);
    }
    /// Forwards `setDebugShadowView` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setDebugShadowView(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setDebugShadowView(self.ptr, enabled);
    }
    /// Forwards `setShadowDebugChannel` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setShadowDebugChannel(self: IRenderQualityOptions, channel: u32) void {
        self.vtable.setShadowDebugChannel(self.ptr, channel);
    }
    /// Forwards `setVSync` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setVSync(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setVSync(self.ptr, enabled);
    }
    /// Forwards `setAnisotropicFiltering` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setAnisotropicFiltering(self: IRenderQualityOptions, level: u8) void {
        self.vtable.setAnisotropicFiltering(self.ptr, level);
    }
    /// Forwards `setVolumetricDensity` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setVolumetricDensity(self: IRenderQualityOptions, density: f32) void {
        self.vtable.setVolumetricDensity(self.ptr, density);
    }
    /// Forwards `setMSAA` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setMSAA(self: IRenderQualityOptions, samples: u8) void {
        self.vtable.setMSAA(self.ptr, samples);
    }
    /// Forwards `setFXAA` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setFXAA(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setFXAA(self.ptr, enabled);
    }
    /// Forwards `setBloom` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setBloom(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setBloom(self.ptr, enabled);
    }
    /// Forwards `setBloomIntensity` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setBloomIntensity(self: IRenderQualityOptions, intensity: f32) void {
        self.vtable.setBloomIntensity(self.ptr, intensity);
    }
    /// Forwards `setVignetteEnabled` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setVignetteEnabled(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setVignetteEnabled(self.ptr, enabled);
    }
    /// Forwards `setVignetteIntensity` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setVignetteIntensity(self: IRenderQualityOptions, intensity: f32) void {
        self.vtable.setVignetteIntensity(self.ptr, intensity);
    }
    /// Forwards `setFilmGrainEnabled` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setFilmGrainEnabled(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setFilmGrainEnabled(self.ptr, enabled);
    }
    /// Forwards `setFilmGrainIntensity` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setFilmGrainIntensity(self: IRenderQualityOptions, intensity: f32) void {
        self.vtable.setFilmGrainIntensity(self.ptr, intensity);
    }
    /// Forwards `setColorGradingEnabled` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setColorGradingEnabled(self: IRenderQualityOptions, enabled: bool) void {
        self.vtable.setColorGradingEnabled(self.ptr, enabled);
    }
    /// Forwards `setColorGradingIntensity` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setColorGradingIntensity(self: IRenderQualityOptions, intensity: f32) void {
        self.vtable.setColorGradingIntensity(self.ptr, intensity);
    }
    /// Forwards `setTAABlendFactor` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setTAABlendFactor(self: IRenderQualityOptions, value: f32) void {
        self.vtable.setTAABlendFactor(self.ptr, value);
    }
    /// Forwards `setTAAVelocityRejection` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setTAAVelocityRejection(self: IRenderQualityOptions, value: f32) void {
        self.vtable.setTAAVelocityRejection(self.ptr, value);
    }
    /// Forwards `setDynamicResolution` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn setDynamicResolution(self: IRenderQualityOptions, enabled: bool, min_scale: f32, max_scale: f32, target_fps: u32) void {
        self.vtable.setDynamicResolution(self.ptr, enabled, min_scale, max_scale, target_fps);
    }
    /// Forwards `getResolutionScale` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn getResolutionScale(self: IRenderQualityOptions) f32 {
        return self.vtable.getResolutionScale(self.ptr);
    }
};

pub const IDeviceRecovery = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        recover: *const fn (ctx: *anyopaque) anyerror!void,
    };

    /// Forwards `recover` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn recover(self: IDeviceRecovery) !void {
        return self.vtable.recover(self.ptr);
    }
};

pub const ICullingSystemFactory = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createCullingSystem: *const fn (ctx: *anyopaque, allocator: Allocator, max_chunks: usize) anyerror!?ICullingSystem,
    };

    /// Forwards `createCullingSystem` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createCullingSystem(self: ICullingSystemFactory, allocator: Allocator, max_chunks: usize) anyerror!?ICullingSystem {
        return self.vtable.createCullingSystem(self.ptr, allocator, max_chunks);
    }
};

pub const IScreenshotContext = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        captureFrame: *const fn (ctx: *anyopaque, path: []const u8) bool,
    };

    /// Forwards `captureFrame` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn captureFrame(self: IScreenshotContext, path: []const u8) bool {
        return self.vtable.captureFrame(self.ptr, path);
    }
};

/// DEPRECATED: This struct is retained as a composition root during the RHI
/// modularization refactoring (issue #291 / #272). New code should use focused
/// wrappers: `ResourceManager`, `RenderContext`, `UIRenderer`, `ShadowSystemWrapper`.
///
/// Migration guide:
/// - Resource operations -> `rhi.resourceManager()`
/// - Frame rendering -> `rhi.renderContext()`
/// - UI rendering -> `rhi.uiRenderer()`
/// - Shadow mapping -> `rhi.shadowSystem()`
/// - Device timing -> `rhi.timing()`
/// - Device query -> `rhi.query()`
pub const RHI = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    device: ?*RenderDevice,

    pub const VTable = struct {
        init: *const fn (ctx: *anyopaque, allocator: Allocator, device: ?*RenderDevice) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,

        resources: ?*const IResourceFactory.VTable = null,
        render: ?*const IRenderContext.VTable = null,
        passes: ?*const IPassOrchestrationContext.VTable = null,
        post_process: ?*const IPostProcessContext.VTable = null,
        effects: ?*const IRenderEffectsContext.VTable = null,
        vulkan: ?*const VulkanNativeHandles.VTable = null,
        ssao: ?*const ISSAOContext.VTable = null,
        debug_overlay: ?*const IDebugOverlayContext.VTable = null,
        shadow: ?*const IShadowContext.VTable = null,
        water: ?*const IWaterContext.VTable = null,
        compute: ?*const IComputeContext.VTable = null,
        ui: ?*const IUIContext.VTable = null,
        imgui: ?*const IImGuiContext.VTable = null,
        query: ?*const IDeviceQuery.VTable = null,
        timing: ?*const IDeviceTiming.VTable = null,
        quality: ?*const IRenderQualityOptions.VTable = null,
        recovery: ?*const IDeviceRecovery.VTable = null,
        culling_factory: ?*const ICullingSystemFactory.VTable = null,
        screenshot: ?*const IScreenshotContext.VTable = null,
    };

    pub const Lifecycle = struct {
        init: *const fn (ctx: *anyopaque, allocator: Allocator, device: ?*RenderDevice) anyerror!void,
        deinit: *const fn (ctx: *anyopaque) void,
    };

    pub const Interfaces = struct {
        resources: ?*const IResourceFactory.VTable = null,
        render: ?*const IRenderContext.VTable = null,
        passes: ?*const IPassOrchestrationContext.VTable = null,
        post_process: ?*const IPostProcessContext.VTable = null,
        effects: ?*const IRenderEffectsContext.VTable = null,
        vulkan: ?*const VulkanNativeHandles.VTable = null,
        ssao: ?*const ISSAOContext.VTable = null,
        debug_overlay: ?*const IDebugOverlayContext.VTable = null,
        shadow: ?*const IShadowContext.VTable = null,
        water: ?*const IWaterContext.VTable = null,
        compute: ?*const IComputeContext.VTable = null,
        ui: ?*const IUIContext.VTable = null,
        imgui: ?*const IImGuiContext.VTable = null,
        query: ?*const IDeviceQuery.VTable = null,
        timing: ?*const IDeviceTiming.VTable = null,
        quality: ?*const IRenderQualityOptions.VTable = null,
        recovery: ?*const IDeviceRecovery.VTable = null,
        culling_factory: ?*const ICullingSystemFactory.VTable = null,
        screenshot: ?*const IScreenshotContext.VTable = null,
    };

    /// Forwards `composeVTable` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn composeVTable(lifecycle: Lifecycle, interfaces: Interfaces) VTable {
        return .{
            .init = lifecycle.init,
            .deinit = lifecycle.deinit,
            .resources = interfaces.resources,
            .render = interfaces.render,
            .passes = interfaces.passes,
            .post_process = interfaces.post_process,
            .effects = interfaces.effects,
            .vulkan = interfaces.vulkan,
            .ssao = interfaces.ssao,
            .debug_overlay = interfaces.debug_overlay,
            .shadow = interfaces.shadow,
            .water = interfaces.water,
            .compute = interfaces.compute,
            .ui = interfaces.ui,
            .imgui = interfaces.imgui,
            .query = interfaces.query,
            .timing = interfaces.timing,
            .quality = interfaces.quality,
            .recovery = interfaces.recovery,
            .culling_factory = interfaces.culling_factory,
            .screenshot = interfaces.screenshot,
        };
    }

    /// Forwards `factory` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn factory(self: RHI) IResourceFactory {
        return .{ .ptr = self.ptr, .vtable = self.vtable.resources orelse unreachable };
    }
    /// Forwards `resourceManager` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn resourceManager(self: RHI) ResourceManager {
        return .{ .factory = self.factory() };
    }
    /// Forwards `context` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn context(self: RHI) IRenderContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.render orelse unreachable };
    }
    /// Forwards `renderContext` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn renderContext(self: RHI) RenderContext {
        const rc = self.context();
        return .{
            .render = rc,
            .passes = self.passOrchestration(),
            .post_process = self.postProcess(),
            .effects = self.renderEffects(),
            .vulkan = self.vulkanHandles(),
            .encoder = rc.getEncoder(),
            .state = rc.getState(),
        };
    }
    /// Forwards `passOrchestration` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn passOrchestration(self: RHI) IPassOrchestrationContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.passes orelse unreachable };
    }
    /// Forwards `postProcess` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn postProcess(self: RHI) IPostProcessContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.post_process orelse unreachable };
    }
    /// Forwards `renderEffects` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn renderEffects(self: RHI) IRenderEffectsContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.effects orelse unreachable };
    }
    /// Returns the Vulkan native-handle facet used by ImGui, LPV, and other
    /// Vulkan-shaped integrations. This is a documented backend seam, not a
    /// portability guarantee for non-Vulkan renderers.
    pub fn vulkanHandles(self: RHI) VulkanNativeHandles {
        return .{ .ptr = self.ptr, .vtable = self.vtable.vulkan orelse unreachable };
    }
    /// Forwards `encoder` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn encoder(self: RHI) IGraphicsCommandEncoder {
        return self.context().getEncoder();
    }
    /// Forwards `state` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn state(self: RHI) IRenderStateContext {
        return self.context().getState();
    }
    /// Forwards `ssao` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn ssao(self: RHI) ISSAOContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.ssao orelse unreachable };
    }
    /// Forwards `debugOverlay` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn debugOverlay(self: RHI) IDebugOverlayContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.debug_overlay orelse unreachable };
    }
    /// Forwards `shadow` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn shadow(self: RHI) IShadowContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.shadow orelse unreachable };
    }
    /// Forwards `shadowSystem` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn shadowSystem(self: RHI) ShadowSystemWrapper {
        return .{ .ctx = self.shadow() };
    }
    /// Forwards `waterSystem` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn waterSystem(self: RHI) WaterSystemWrapper {
        return .{ .ctx = self.water() };
    }
    /// Forwards `water` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn water(self: RHI) IWaterContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.water orelse unreachable };
    }
    /// Forwards `compute` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn compute(self: RHI) IComputeContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.compute orelse unreachable };
    }
    /// Forwards `ui` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn ui(self: RHI) IUIContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.ui orelse unreachable };
    }
    /// Forwards `imgui` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn imgui(self: RHI) IImGuiContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.imgui orelse unreachable };
    }
    /// Forwards `uiRenderer` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn uiRenderer(self: RHI) UIRenderer {
        return .{ .ctx = self.ui() };
    }
    /// Forwards `query` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn query(self: RHI) IDeviceQuery {
        return .{ .ptr = self.ptr, .vtable = self.vtable.query orelse unreachable };
    }
    /// Forwards `timing` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn timing(self: RHI) IDeviceTiming {
        return .{ .ptr = self.ptr, .vtable = self.vtable.timing orelse unreachable };
    }
    /// Forwards `options` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn options(self: RHI) IRenderQualityOptions {
        return self.renderQualityOptions();
    }
    /// Forwards `renderQualityOptions` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn renderQualityOptions(self: RHI) IRenderQualityOptions {
        return .{ .ptr = self.ptr, .vtable = self.vtable.quality orelse unreachable };
    }
    /// Forwards `recovery` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn recovery(self: RHI) IDeviceRecovery {
        return .{ .ptr = self.ptr, .vtable = self.vtable.recovery orelse unreachable };
    }
    /// Forwards `cullingFactory` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn cullingFactory(self: RHI) ICullingSystemFactory {
        return .{ .ptr = self.ptr, .vtable = self.vtable.culling_factory orelse unreachable };
    }
    /// Forwards `screenshot` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn screenshot(self: RHI) IScreenshotContext {
        return .{ .ptr = self.ptr, .vtable = self.vtable.screenshot orelse unreachable };
    }
    /// Forwards `createCullingSystem` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn createCullingSystem(self: RHI, allocator: Allocator, max_chunks: usize) anyerror!?ICullingSystem {
        return self.cullingFactory().createCullingSystem(allocator, max_chunks);
    }

    // Lifecycle
    /// Forwards `init` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn init(self: RHI, allocator: Allocator, device: ?*RenderDevice) !void {
        return self.vtable.init(self.ptr, allocator, device);
    }
    /// Forwards `deinit` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn deinit(self: RHI) void {
        self.vtable.deinit(self.ptr);
    }
    /// Forwards `waitIdle` to the active RHI backend. Callers must provide valid handles and preserve backend render-thread sequencing.
    pub fn waitIdle(self: RHI) void {
        (self.vtable.query orelse unreachable).waitIdle(self.ptr);
    }
};
