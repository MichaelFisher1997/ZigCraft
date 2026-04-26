//! Data-only LPV types and constants.

const c = @import("../../c.zig").c;
const rhi_pkg = @import("rhi.zig");

pub const MAX_LIGHTS_PER_UPDATE: usize = 2048;
// Approximate 1/7 spread for 6-neighbor propagation (close to 1/6 with extra damping)
// to keep indirect light stable and avoid runaway amplification.
pub const DEFAULT_PROPAGATION_FACTOR: f32 = 0.14;
// Retain 82% of center-cell energy so propagation does not over-blur local contrast.
pub const DEFAULT_CENTER_RETENTION: f32 = 0.82;
pub const INJECT_SHADER_PATH = "assets/shaders/vulkan/lpv_inject.comp.spv";
pub const PROPAGATE_SHADER_PATH = "assets/shaders/vulkan/lpv_propagate.comp.spv";

pub const GpuLight = extern struct {
    pos_radius: [4]f32,
    color: [4]f32,
};

pub const InjectPush = extern struct {
    grid_origin: [4]f32,
    grid_params: [4]f32,
    light_count: u32,
    _pad0: [3]u32,
};

pub const PropagatePush = extern struct {
    grid_size: u32,
    _pad0: [3]u32,
    propagation: [4]f32,
};

pub const Stats = struct {
    updated_this_frame: bool = false,
    light_count: u32 = 0,
    cpu_update_ms: f32 = 0.0,
    grid_size: u32 = 0,
    propagation_iterations: u32 = 0,
    update_interval_frames: u32 = 6,
};

pub const GridResources = struct {
    grid_textures_a: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
    grid_textures_b: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
    active_grid_textures: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
    debug_overlay_texture: rhi_pkg.TextureHandle = 0,
    debug_overlay_pixels: []f32 = &.{},
    image_layout_a: c.VkImageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    image_layout_b: c.VkImageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
};
