//! Backend binding for Light Propagation Volumes.
//!
//! LPV compute currently uses Vulkan resources directly. Keep the backend cast
//! local to engine-graphics instead of exposing a generic native-handle escape hatch.

const rhi_pkg = @import("engine-rhi").rhi;
const VulkanContext = @import("vulkan/rhi_context_types.zig").VulkanContext;

pub const LPVBackend = struct {
    vk_ctx: *VulkanContext,

    pub fn fromVulkanRHI(rhi: rhi_pkg.RHI) LPVBackend {
        return .{ .vk_ctx = @ptrCast(@alignCast(rhi.ptr)) };
    }
};
