//! Backend binding for Light Propagation Volumes.
//!
//! LPV compute currently uses Vulkan resources directly. Keep that dependency
//! explicit so LPVSystem does not pretend any RHI backend can satisfy it.

const rhi_pkg = @import("engine-rhi").rhi;
const VulkanContext = @import("vulkan/rhi_context_types.zig").VulkanContext;

pub const LPVBackend = struct {
    vk_ctx: *VulkanContext,

    pub fn fromVulkanRHI(rhi: rhi_pkg.RHI) LPVBackend {
        return .{ .vk_ctx = @ptrCast(@alignCast(rhi.ptr)) };
    }
};
