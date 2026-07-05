//! Backend binding for Light Propagation Volumes.
//!
//! LPV compute currently uses Vulkan resources directly. The backend context is
//! retrieved through RHI native handles so callers do not downcast `RHI.ptr`.

const rhi_pkg = @import("engine-rhi").rhi;
const VulkanContext = @import("vulkan/rhi_context_types.zig").VulkanContext;

pub const LPVBackend = struct {
    vk_ctx: *VulkanContext,

    pub fn fromVulkanRHI(rhi: rhi_pkg.RHI) LPVBackend {
        return .{ .vk_ctx = @ptrFromInt(rhi.nativeHandles().getBackendContext()) };
    }
};
