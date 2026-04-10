const std = @import("std");
const c = @import("../../../c.zig").c;

const ROLLING_WINDOW_SIZE = 8;

pub const DynamicResolutionState = struct {
    enabled: bool = false,
    min_scale: f32 = 0.5,
    max_scale: f32 = 1.0,
    target_fps: u32 = 60,
    current_scale: f32 = 1.0,
    render_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    swapchain_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },

    frame_times: [ROLLING_WINDOW_SIZE]f32 = .{0.0} ** ROLLING_WINDOW_SIZE,
    frame_time_index: usize = 0,
    frame_time_count: usize = 0,
    rolling_avg_ms: f32 = 0.0,

    upscale_image: c.VkImage = null,
    upscale_memory: c.VkDeviceMemory = null,
    upscale_view: c.VkImageView = null,
    upscale_extent: c.VkExtent2D = .{ .width = 0, .height = 0 },

    pub fn update(self: *DynamicResolutionState, gpu_time_ms: f32) void {
        if (!self.enabled) {
            self.current_scale = 1.0;
            self.render_extent = self.swapchain_extent;
            return;
        }

        self.frame_times[self.frame_time_index] = gpu_time_ms;
        self.frame_time_index = (self.frame_time_index + 1) % ROLLING_WINDOW_SIZE;
        if (self.frame_time_count < ROLLING_WINDOW_SIZE) {
            self.frame_time_count += 1;
        }

        var sum: f32 = 0.0;
        var count: usize = 0;
        for (self.frame_times) |t| {
            if (t > 0.0) {
                sum += t;
                count += 1;
            }
        }
        self.rolling_avg_ms = if (count > 0) sum / @as(f32, @floatFromInt(count)) else 0.0;

        if (self.frame_time_count < 4) {
            self.computeRenderExtent();
            return;
        }

        const target_ms = 1000.0 / @as(f32, @floatFromInt(self.target_fps));

        if (self.rolling_avg_ms > target_ms * 1.1) {
            self.current_scale = @max(self.current_scale - 0.02, self.min_scale);
        } else if (self.rolling_avg_ms < target_ms * 0.8) {
            self.current_scale = @min(self.current_scale + 0.01, self.max_scale);
        }

        self.computeRenderExtent();
    }

    fn computeRenderExtent(self: *DynamicResolutionState) void {
        const w = @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(self.swapchain_extent.width)) * self.current_scale)));
        const h = @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(self.swapchain_extent.height)) * self.current_scale)));
        self.render_extent = .{
            .width = @max(w, 1),
            .height = @max(h, 1),
        };
    }

    pub fn setSwapchainExtent(self: *DynamicResolutionState, extent: c.VkExtent2D) void {
        self.swapchain_extent = extent;
        if (!self.enabled) {
            self.render_extent = extent;
            self.current_scale = 1.0;
        } else {
            self.computeRenderExtent();
        }
    }

    pub fn isActive(self: *const DynamicResolutionState) bool {
        return self.enabled and self.current_scale < 0.999;
    }

    pub fn getRenderExtent(self: *const DynamicResolutionState) c.VkExtent2D {
        if (self.enabled) {
            return self.render_extent;
        }
        return self.swapchain_extent;
    }
};
