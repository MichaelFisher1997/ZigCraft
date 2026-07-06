//! Segregated RHI interface contracts.
//!
//! The canonical definitions currently live in `rhi.zig` with the RHI composition
//! root; this module provides a focused import surface for interface-only users.

const rhi = @import("rhi.zig");

pub const IResourceFactory = rhi.IResourceFactory;
pub const IShadowContext = rhi.IShadowContext;
pub const IWaterContext = rhi.IWaterContext;
pub const IUIContext = rhi.IUIContext;
pub const IGraphicsCommandEncoder = rhi.IGraphicsCommandEncoder;
pub const IRenderStateContext = rhi.IRenderStateContext;
pub const ISSAOContext = rhi.ISSAOContext;
pub const IDebugOverlayContext = rhi.IDebugOverlayContext;
pub const IComputeContext = rhi.IComputeContext;
pub const IRenderContext = rhi.IRenderContext;
pub const IPassOrchestrationContext = rhi.IPassOrchestrationContext;
pub const IPostProcessContext = rhi.IPostProcessContext;
pub const IRenderEffectsContext = rhi.IRenderEffectsContext;
pub const INativeHandlesContext = rhi.INativeHandlesContext;
pub const IDeviceQuery = rhi.IDeviceQuery;
pub const IDeviceTiming = rhi.IDeviceTiming;
pub const IRenderOptionsContext = rhi.IRenderOptionsContext;
