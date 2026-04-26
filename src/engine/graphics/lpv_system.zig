const std = @import("std");
const fs = @import("fs");
const c = @import("../../c.zig").c;
const rhi_pkg = @import("rhi.zig");
const log = @import("../core/log.zig");
const Vec3 = @import("../math/vec3.zig").Vec3;
const World = @import("../../world/world.zig").World;
const CHUNK_SIZE_X = @import("../../world/chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("../../world/chunk.zig").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("../../world/chunk.zig").CHUNK_SIZE_Z;
const block_registry = @import("../../world/block_registry.zig");
const VulkanContext = @import("vulkan/rhi_context_types.zig").VulkanContext;
const Utils = @import("vulkan/utils.zig");

const MAX_LIGHTS_PER_UPDATE: usize = 2048;
// Approximate 1/7 spread for 6-neighbor propagation (close to 1/6 with extra damping)
// to keep indirect light stable and avoid runaway amplification.
const DEFAULT_PROPAGATION_FACTOR: f32 = 0.14;
// Retain 82% of center-cell energy so propagation does not over-blur local contrast.
const DEFAULT_CENTER_RETENTION: f32 = 0.82;
const INJECT_SHADER_PATH = "assets/shaders/vulkan/lpv_inject.comp.spv";
const PROPAGATE_SHADER_PATH = "assets/shaders/vulkan/lpv_propagate.comp.spv";

const GpuLight = extern struct {
    pos_radius: [4]f32,
    color: [4]f32,
};

const InjectPush = extern struct {
    grid_origin: [4]f32,
    grid_params: [4]f32,
    light_count: u32,
    _pad0: [3]u32,
};

const PropagatePush = extern struct {
    grid_size: u32,
    _pad0: [3]u32,
    propagation: [4]f32,
};

pub const LPVSystem = struct {
    pub const Stats = struct {
        updated_this_frame: bool = false,
        light_count: u32 = 0,
        cpu_update_ms: f32 = 0.0,
        grid_size: u32 = 0,
        propagation_iterations: u32 = 0,
        update_interval_frames: u32 = 6,
    };

    allocator: std.mem.Allocator,
    rhi: rhi_pkg.RHI,
    vk_ctx: *VulkanContext,

    // SH L1: 3 textures per grid (R, G, B channels), each storing 4 SH coefficients as rgba32f
    grid_textures_a: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
    grid_textures_b: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
    active_grid_textures: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
    debug_overlay_texture: rhi_pkg.TextureHandle = 0,
    grid_size: u32,
    cell_size: f32,
    intensity: f32,
    propagation_iterations: u32,
    propagation_factor: f32,
    center_retention: f32,
    enabled: bool,
    update_interval_frames: u32 = 6,

    origin: Vec3 = Vec3.zero,
    current_frame: u32 = 0,
    was_enabled_last_frame: bool = true,
    debug_overlay_was_enabled: bool = false,

    image_layout_a: c.VkImageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    image_layout_b: c.VkImageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,

    debug_overlay_pixels: []f32,
    stats: Stats,

    light_buffer: Utils.VulkanBuffer = .{},
    occlusion_buffer: Utils.VulkanBuffer = .{},
    occlusion_grid: []u32 = &.{},

    descriptor_pool: c.VkDescriptorPool = null,
    inject_set_layout: c.VkDescriptorSetLayout = null,
    propagate_set_layout: c.VkDescriptorSetLayout = null,
    inject_descriptor_set: c.VkDescriptorSet = null,
    propagate_ab_descriptor_set: c.VkDescriptorSet = null,
    propagate_ba_descriptor_set: c.VkDescriptorSet = null,
    inject_pipeline_layout: c.VkPipelineLayout = null,
    propagate_pipeline_layout: c.VkPipelineLayout = null,
    inject_pipeline: c.VkPipeline = null,
    propagate_pipeline: c.VkPipeline = null,

    const GridResources = struct {
        grid_textures_a: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
        grid_textures_b: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
        active_grid_textures: [3]rhi_pkg.TextureHandle = .{ 0, 0, 0 },
        debug_overlay_texture: rhi_pkg.TextureHandle = 0,
        debug_overlay_pixels: []f32 = &.{},
        image_layout_a: c.VkImageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
        image_layout_b: c.VkImageLayout = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        rhi: rhi_pkg.RHI,
        grid_size: u32,
        cell_size: f32,
        intensity: f32,
        propagation_iterations: u32,
        enabled: bool,
    ) !*LPVSystem {
        const self = try allocator.create(LPVSystem);
        errdefer allocator.destroy(self);

        const vk_ctx: *VulkanContext = @ptrCast(@alignCast(rhi.ptr));
        const clamped_grid = std.math.clamp(grid_size, 16, 64);

        self.* = .{
            .allocator = allocator,
            .rhi = rhi,
            .vk_ctx = vk_ctx,
            .grid_size = clamped_grid,
            .cell_size = @max(cell_size, 0.5),
            .intensity = std.math.clamp(intensity, 0.0, 4.0),
            .propagation_iterations = std.math.clamp(propagation_iterations, 1, 8),
            .propagation_factor = DEFAULT_PROPAGATION_FACTOR,
            .center_retention = DEFAULT_CENTER_RETENTION,
            .enabled = enabled,
            .was_enabled_last_frame = enabled,
            .debug_overlay_pixels = &.{},
            .stats = .{
                .grid_size = clamped_grid,
                .propagation_iterations = std.math.clamp(propagation_iterations, 1, 8),
                .update_interval_frames = 6,
            },
        };

        try self.createGridTextures();
        errdefer self.destroyGridTextures();

        const light_buffer_size = MAX_LIGHTS_PER_UPDATE * @sizeOf(GpuLight);
        self.light_buffer = try Utils.createVulkanBuffer(
            &vk_ctx.vulkan_device,
            light_buffer_size,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        errdefer self.destroyLightBuffer();

        // Occlusion grid buffer: one u32 per cell (1 = opaque, 0 = transparent)
        const occlusion_buffer_size = @as(usize, clamped_grid) * @as(usize, clamped_grid) * @as(usize, clamped_grid) * @sizeOf(u32);
        self.occlusion_buffer = try Utils.createVulkanBuffer(
            &vk_ctx.vulkan_device,
            occlusion_buffer_size,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        errdefer self.destroyOcclusionBuffer();

        try ensureShaderFileExists(INJECT_SHADER_PATH);
        try ensureShaderFileExists(PROPAGATE_SHADER_PATH);

        errdefer self.deinitComputeResources();
        try self.initComputeResources();

        return self;
    }

    pub fn deinit(self: *LPVSystem) void {
        self.deinitComputeResources();
        self.destroyOcclusionBuffer();
        self.destroyLightBuffer();
        self.destroyGridTextures();
        self.allocator.destroy(self);
    }

    pub fn setSettings(self: *LPVSystem, enabled: bool, intensity: f32, cell_size: f32, propagation_iterations: u32, grid_size: u32, update_interval_frames: u32) !void {
        self.enabled = enabled;
        self.intensity = std.math.clamp(intensity, 0.0, 4.0);
        self.cell_size = @max(cell_size, 0.5);
        self.propagation_iterations = std.math.clamp(propagation_iterations, 1, 8);
        self.update_interval_frames = std.math.clamp(update_interval_frames, 1, 16);
        self.stats.propagation_iterations = self.propagation_iterations;
        self.stats.update_interval_frames = self.update_interval_frames;

        const clamped_grid = std.math.clamp(grid_size, 16, 64);
        if (clamped_grid == self.grid_size) return;

        const old_resources = GridResources{
            .grid_textures_a = self.grid_textures_a,
            .grid_textures_b = self.grid_textures_b,
            .active_grid_textures = self.active_grid_textures,
            .debug_overlay_texture = self.debug_overlay_texture,
            .debug_overlay_pixels = self.debug_overlay_pixels,
            .image_layout_a = self.image_layout_a,
            .image_layout_b = self.image_layout_b,
        };
        const old_grid_size = self.grid_size;
        const old_stats_grid_size = self.stats.grid_size;
        const old_origin = self.origin;

        const new_resources = try self.createGridResources(clamped_grid);
        self.applyGridResources(new_resources);
        self.grid_size = clamped_grid;
        self.stats.grid_size = clamped_grid;
        self.origin = Vec3.zero;

        errdefer {
            var failed_new = GridResources{
                .grid_textures_a = self.grid_textures_a,
                .grid_textures_b = self.grid_textures_b,
                .active_grid_textures = self.active_grid_textures,
                .debug_overlay_texture = self.debug_overlay_texture,
                .debug_overlay_pixels = self.debug_overlay_pixels,
                .image_layout_a = self.image_layout_a,
                .image_layout_b = self.image_layout_b,
            };
            self.destroyGridResources(&failed_new);
            self.applyGridResources(old_resources);
            self.grid_size = old_grid_size;
            self.stats.grid_size = old_stats_grid_size;
            self.origin = old_origin;
        }

        self.buildDebugOverlay(&.{}, 0);
        try self.uploadDebugOverlay();
        try self.updateDescriptorSets();

        var old_to_destroy = old_resources;
        self.destroyGridResources(&old_to_destroy);
    }

    pub fn getTextureHandle(self: *const LPVSystem) rhi_pkg.TextureHandle {
        return self.active_grid_textures[0]; // R channel (binding 11)
    }

    pub fn getTextureHandleG(self: *const LPVSystem) rhi_pkg.TextureHandle {
        return self.active_grid_textures[1]; // G channel (binding 12)
    }

    pub fn getTextureHandleB(self: *const LPVSystem) rhi_pkg.TextureHandle {
        return self.active_grid_textures[2]; // B channel (binding 13)
    }

    pub fn getDebugOverlayTextureHandle(self: *const LPVSystem) rhi_pkg.TextureHandle {
        return self.debug_overlay_texture;
    }

    pub fn getStats(self: *const LPVSystem) Stats {
        return self.stats;
    }

    pub fn getOrigin(self: *const LPVSystem) Vec3 {
        return self.origin;
    }

    pub fn getGridSize(self: *const LPVSystem) u32 {
        return self.grid_size;
    }

    pub fn getCellSize(self: *const LPVSystem) f32 {
        return self.cell_size;
    }

    pub fn update(self: *LPVSystem, world: *World, camera_pos: Vec3, debug_overlay_enabled: bool) !void {
        self.current_frame +%= 1;
        const timer_start = std.Io.Clock.awake.now(std.Options.debug_io);
        self.stats.updated_this_frame = false;
        self.stats.grid_size = self.grid_size;
        self.stats.propagation_iterations = self.propagation_iterations;
        self.stats.update_interval_frames = self.update_interval_frames;

        if (!self.enabled) {
            self.active_grid_textures = self.grid_textures_a;
            if (self.was_enabled_last_frame and debug_overlay_enabled) {
                self.buildDebugOverlay(&.{}, 0);
                try self.uploadDebugOverlay();
            }
            self.was_enabled_last_frame = false;
            self.debug_overlay_was_enabled = debug_overlay_enabled;
            self.stats.light_count = 0;
            self.stats.cpu_update_ms = 0.0;
            return;
        }

        const half_extent = (@as(f32, @floatFromInt(self.grid_size)) * self.cell_size) * 0.5;
        const next_origin = Vec3.init(
            quantizeToCell(camera_pos.x - half_extent, self.cell_size),
            quantizeToCell(camera_pos.y - half_extent, self.cell_size),
            quantizeToCell(camera_pos.z - half_extent, self.cell_size),
        );

        const moved = @abs(next_origin.x - self.origin.x) >= self.cell_size or
            @abs(next_origin.y - self.origin.y) >= self.cell_size or
            @abs(next_origin.z - self.origin.z) >= self.cell_size;

        const tick_update = (self.current_frame % self.update_interval_frames) == 0;
        const debug_toggle_on = debug_overlay_enabled and !self.debug_overlay_was_enabled;
        self.debug_overlay_was_enabled = debug_overlay_enabled;

        if (!moved and !tick_update and !debug_toggle_on and self.was_enabled_last_frame) {
            self.stats.cpu_update_ms = 0.0;
            return;
        }

        self.origin = next_origin;
        self.was_enabled_last_frame = true;

        var lights: [MAX_LIGHTS_PER_UPDATE]GpuLight = undefined;
        const light_count = self.collectLights(world, lights[0..]);
        if (self.light_buffer.mapped_ptr) |ptr| {
            const bytes = std.mem.sliceAsBytes(lights[0..light_count]);
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..bytes.len], bytes);
        }

        // Build occlusion grid for opaque block awareness during propagation
        if (!self.buildOcclusionGrid(world)) {
            const elapsed_ns = timer_start.durationTo(std.Io.Clock.awake.now(std.Options.debug_io)).toNanoseconds();
            const delta_ms: f32 = @floatCast(@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms));
            self.stats.light_count = @intCast(light_count);
            self.stats.cpu_update_ms = delta_ms;
            return;
        }

        if (debug_overlay_enabled) {
            // Keep debug overlay generation only when overlay is active.
            self.buildDebugOverlay(lights[0..], light_count);
            try self.uploadDebugOverlay();
        }

        try self.dispatchCompute(light_count);

        const elapsed_ns = timer_start.durationTo(std.Io.Clock.awake.now(std.Options.debug_io)).toNanoseconds();
        const delta_ms: f32 = @floatCast(@as(f64, @floatFromInt(elapsed_ns)) / @as(f64, std.time.ns_per_ms));
        self.stats.updated_this_frame = true;
        self.stats.light_count = @intCast(light_count);
        self.stats.cpu_update_ms = delta_ms;
    }

    fn collectLights(self: *LPVSystem, world: *World, out: []GpuLight) usize {
        const grid_world_size = @as(f32, @floatFromInt(self.grid_size)) * self.cell_size;
        const min_x = self.origin.x;
        const min_y = self.origin.y;
        const min_z = self.origin.z;
        const max_x = min_x + grid_world_size;
        const max_y = min_y + grid_world_size;
        const max_z = min_z + grid_world_size;

        var emitted_lights: usize = 0;

        world.storage.chunks_mutex.lockShared();
        defer world.storage.chunks_mutex.unlockShared();

        var iter = world.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const chunk_data = entry.value_ptr.*;
            const chunk = &chunk_data.chunk;

            const chunk_min_x = @as(f32, @floatFromInt(chunk.chunk_x * CHUNK_SIZE_X));
            const chunk_min_z = @as(f32, @floatFromInt(chunk.chunk_z * CHUNK_SIZE_Z));
            const chunk_max_x = chunk_min_x + @as(f32, @floatFromInt(CHUNK_SIZE_X));
            const chunk_max_z = chunk_min_z + @as(f32, @floatFromInt(CHUNK_SIZE_Z));

            if (chunk_max_x < min_x or chunk_min_x > max_x or chunk_max_z < min_z or chunk_min_z > max_z) {
                continue;
            }

            var y: u32 = 0;
            while (y < CHUNK_SIZE_Y) : (y += 1) {
                var z: u32 = 0;
                while (z < CHUNK_SIZE_Z) : (z += 1) {
                    var x: u32 = 0;
                    while (x < CHUNK_SIZE_X) : (x += 1) {
                        const block = chunk.getBlock(x, y, z);
                        if (block == .air) continue;

                        const def = block_registry.getBlockDefinition(block);
                        const r_u4 = def.light_emission[0];
                        const g_u4 = def.light_emission[1];
                        const b_u4 = def.light_emission[2];
                        if (r_u4 == 0 and g_u4 == 0 and b_u4 == 0) continue;

                        const world_x = chunk_min_x + @as(f32, @floatFromInt(x)) + 0.5;
                        const world_y = @as(f32, @floatFromInt(y)) + 0.5;
                        const world_z = chunk_min_z + @as(f32, @floatFromInt(z)) + 0.5;
                        if (world_x < min_x or world_x >= max_x or world_y < min_y or world_y >= max_y or world_z < min_z or world_z >= max_z) {
                            continue;
                        }

                        const emission_r = @as(f32, @floatFromInt(r_u4)) / 15.0;
                        const emission_g = @as(f32, @floatFromInt(g_u4)) / 15.0;
                        const emission_b = @as(f32, @floatFromInt(b_u4)) / 15.0;
                        const max_emission = @max(emission_r, @max(emission_g, emission_b));
                        const radius_cells = @max(1.0, max_emission * 6.0);

                        out[emitted_lights] = .{
                            .pos_radius = .{ world_x, world_y, world_z, radius_cells },
                            .color = .{ emission_r, emission_g, emission_b, 1.0 },
                        };

                        emitted_lights += 1;
                        if (emitted_lights >= out.len) return emitted_lights;
                    }
                }
            }
        }

        return emitted_lights;
    }

    /// Build a per-cell occlusion grid (1 = opaque, 0 = transparent) for the current LPV volume.
    /// Stored as packed u32 array where each u32 holds the opacity for one cell.
    fn buildOcclusionGrid(self: *LPVSystem, world: *World) bool {
        const gs = @as(usize, self.grid_size);
        const total_cells = gs * gs * gs;

        // Ensure CPU buffer is allocated
        if (self.occlusion_grid.len != total_cells) {
            const new_grid = self.allocator.alloc(u32, total_cells) catch |err| {
                log.log.err("LPV occlusion grid allocation failed ({} cells): {}", .{ total_cells, err });
                return false;
            };
            if (self.occlusion_grid.len > 0) self.allocator.free(self.occlusion_grid);
            self.occlusion_grid = new_grid;
        }

        @memset(self.occlusion_grid, 0);

        world.storage.chunks_mutex.lockShared();
        defer world.storage.chunks_mutex.unlockShared();

        const grid_world_size = @as(f32, @floatFromInt(self.grid_size)) * self.cell_size;
        const min_x = self.origin.x;
        const min_y = self.origin.y;
        const min_z = self.origin.z;
        const max_x = min_x + grid_world_size;
        const max_z = min_z + grid_world_size;

        var iter = world.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const chunk_data = entry.value_ptr.*;
            const chunk = &chunk_data.chunk;

            const chunk_min_x = @as(f32, @floatFromInt(chunk.chunk_x * CHUNK_SIZE_X));
            const chunk_min_z = @as(f32, @floatFromInt(chunk.chunk_z * CHUNK_SIZE_Z));
            const chunk_max_x = chunk_min_x + @as(f32, @floatFromInt(CHUNK_SIZE_X));
            const chunk_max_z = chunk_min_z + @as(f32, @floatFromInt(CHUNK_SIZE_Z));

            if (chunk_max_x < min_x or chunk_min_x > max_x or chunk_max_z < min_z or chunk_min_z > max_z) {
                continue;
            }

            var y: u32 = 0;
            while (y < CHUNK_SIZE_Y) : (y += 1) {
                const world_y = @as(f32, @floatFromInt(y)) + 0.5;
                if (world_y < min_y or world_y >= min_y + grid_world_size) continue;

                var z: u32 = 0;
                while (z < CHUNK_SIZE_Z) : (z += 1) {
                    var x: u32 = 0;
                    while (x < CHUNK_SIZE_X) : (x += 1) {
                        const block = chunk.getBlock(x, y, z);
                        if (block == .air) continue;

                        const def = block_registry.getBlockDefinition(block);
                        if (!def.isOpaque()) continue;

                        const world_x = chunk_min_x + @as(f32, @floatFromInt(x)) + 0.5;
                        const world_z = chunk_min_z + @as(f32, @floatFromInt(z)) + 0.5;

                        // Map world position to grid cell
                        const gx = @as(i32, @intFromFloat(@floor((world_x - self.origin.x) / self.cell_size)));
                        const gy = @as(i32, @intFromFloat(@floor((world_y - self.origin.y) / self.cell_size)));
                        const gz = @as(i32, @intFromFloat(@floor((world_z - self.origin.z) / self.cell_size)));

                        if (gx < 0 or gy < 0 or gz < 0) continue;
                        const ugx = @as(usize, @intCast(gx));
                        const ugy = @as(usize, @intCast(gy));
                        const ugz = @as(usize, @intCast(gz));
                        if (ugx >= gs or ugy >= gs or ugz >= gs) continue;

                        const idx = ugx + ugy * gs + ugz * gs * gs;
                        self.occlusion_grid[idx] = 1;
                    }
                }
            }
        }

        // Upload to GPU
        if (self.occlusion_buffer.mapped_ptr) |ptr| {
            const bytes = std.mem.sliceAsBytes(self.occlusion_grid);
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..bytes.len], bytes);
            return true;
        }

        log.log.err("LPV occlusion upload skipped: buffer is not mapped", .{});
        return false;
    }

    fn createGridResources(self: *LPVSystem, grid_size: u32) !GridResources {
        var resources = GridResources{};
        errdefer self.destroyGridResources(&resources);

        const empty = try self.allocator.alloc(f32, @as(usize, grid_size) * @as(usize, grid_size) * @as(usize, grid_size) * 4);
        defer self.allocator.free(empty);
        @memset(empty, 0.0);
        const bytes = std.mem.sliceAsBytes(empty);

        const tex_config = rhi_pkg.TextureConfig{
            .min_filter = .linear,
            .mag_filter = .linear,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
            .generate_mipmaps = false,
            .is_render_target = false,
        };

        for (0..3) |ch| {
            resources.grid_textures_a[ch] = try self.rhi.factory().createTexture3D(
                grid_size,
                grid_size,
                grid_size,
                .rgba32f,
                tex_config,
                bytes,
            );

            resources.grid_textures_b[ch] = try self.rhi.factory().createTexture3D(
                grid_size,
                grid_size,
                grid_size,
                .rgba32f,
                tex_config,
                bytes,
            );
        }

        const debug_size = @as(usize, grid_size) * @as(usize, grid_size) * 4;
        resources.debug_overlay_pixels = try self.allocator.alloc(f32, debug_size);
        @memset(resources.debug_overlay_pixels, 0.0);

        resources.debug_overlay_texture = try self.rhi.createTexture(
            grid_size,
            grid_size,
            .rgba32f,
            .{
                .min_filter = .linear,
                .mag_filter = .linear,
                .wrap_s = .clamp_to_edge,
                .wrap_t = .clamp_to_edge,
                .generate_mipmaps = false,
                .is_render_target = false,
            },
            std.mem.sliceAsBytes(resources.debug_overlay_pixels),
        );

        resources.active_grid_textures = resources.grid_textures_a;
        resources.image_layout_a = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
        resources.image_layout_b = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

        return resources;
    }

    fn applyGridResources(self: *LPVSystem, resources: GridResources) void {
        self.grid_textures_a = resources.grid_textures_a;
        self.grid_textures_b = resources.grid_textures_b;
        self.active_grid_textures = resources.active_grid_textures;
        self.debug_overlay_texture = resources.debug_overlay_texture;
        self.debug_overlay_pixels = resources.debug_overlay_pixels;
        self.image_layout_a = resources.image_layout_a;
        self.image_layout_b = resources.image_layout_b;
    }

    fn destroyGridResources(self: *LPVSystem, resources: *GridResources) void {
        for (0..3) |ch| {
            if (resources.grid_textures_a[ch] != 0) {
                self.rhi.destroyTexture(resources.grid_textures_a[ch]);
                resources.grid_textures_a[ch] = 0;
            }
            if (resources.grid_textures_b[ch] != 0) {
                self.rhi.destroyTexture(resources.grid_textures_b[ch]);
                resources.grid_textures_b[ch] = 0;
            }
        }

        if (resources.debug_overlay_texture != 0) {
            self.rhi.destroyTexture(resources.debug_overlay_texture);
            resources.debug_overlay_texture = 0;
        }
        if (resources.debug_overlay_pixels.len > 0) {
            self.allocator.free(resources.debug_overlay_pixels);
            resources.debug_overlay_pixels = &.{};
        }

        resources.active_grid_textures = .{ 0, 0, 0 };
    }

    fn dispatchCompute(self: *LPVSystem, light_count: usize) !void {
        const cmd = self.vk_ctx.frames.command_buffers[self.vk_ctx.frames.current_frame];
        if (cmd == null) return;

        // Transition all 6 SH channel textures (3 per grid) to GENERAL for compute access
        for (0..3) |ch| {
            const tex_a = self.vk_ctx.resources.textures.get(self.grid_textures_a[ch]) orelse return;
            const tex_b = self.vk_ctx.resources.textures.get(self.grid_textures_b[ch]) orelse return;
            try self.transitionImage(cmd, tex_a.image.?, self.image_layout_a, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_ACCESS_SHADER_READ_BIT, c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT);
            try self.transitionImage(cmd, tex_b.image.?, self.image_layout_b, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT | c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_ACCESS_SHADER_READ_BIT, c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT);
        }
        self.image_layout_a = c.VK_IMAGE_LAYOUT_GENERAL;
        self.image_layout_b = c.VK_IMAGE_LAYOUT_GENERAL;

        // Ensure host writes to light buffer and occlusion grid are visible to compute shaders.
        // Both buffers use HOST_COHERENT, but we still need an execution dependency to guarantee
        // the memcpy completes before the GPU reads the SSBOs.
        var host_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        host_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        host_barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT;
        host_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_HOST_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &host_barrier, 0, null, 0, null);

        const groups = divCeil(self.grid_size, 4);

        const inject_push = InjectPush{
            .grid_origin = .{ self.origin.x, self.origin.y, self.origin.z, self.cell_size },
            .grid_params = .{ @floatFromInt(self.grid_size), 0.0, 0.0, 0.0 },
            .light_count = @intCast(light_count),
            ._pad0 = .{ 0, 0, 0 },
        };

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.inject_pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.inject_pipeline_layout, 0, 1, &self.inject_descriptor_set, 0, null);
        c.vkCmdPushConstants(cmd, self.inject_pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(InjectPush), &inject_push);
        c.vkCmdDispatch(cmd, groups, groups, groups);

        var mem_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        mem_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        mem_barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        mem_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT;
        c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mem_barrier, 0, null, 0, null);

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.propagate_pipeline);
        const prop_push = PropagatePush{
            .grid_size = self.grid_size,
            ._pad0 = .{ 0, 0, 0 },
            .propagation = .{ self.propagation_factor, self.center_retention, 0, 0 },
        };

        var use_ab = true;
        var i: u32 = 0;
        while (i < self.propagation_iterations) : (i += 1) {
            const descriptor_set = if (use_ab) self.propagate_ab_descriptor_set else self.propagate_ba_descriptor_set;
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.propagate_pipeline_layout, 0, 1, &descriptor_set, 0, null);
            c.vkCmdPushConstants(cmd, self.propagate_pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(PropagatePush), &prop_push);
            c.vkCmdDispatch(cmd, groups, groups, groups);

            c.vkCmdPipelineBarrier(cmd, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, 0, 1, &mem_barrier, 0, null, 0, null);
            use_ab = !use_ab;
        }

        // Transition final textures to SHADER_READ_ONLY for fragment shader sampling
        const final_is_a = (self.propagation_iterations % 2) == 0;
        const final_textures = if (final_is_a) &self.grid_textures_a else &self.grid_textures_b;

        for (0..3) |ch| {
            const final_tex = self.vk_ctx.resources.textures.get(final_textures[ch]) orelse return;
            try self.transitionImage(cmd, final_tex.image.?, c.VK_IMAGE_LAYOUT_GENERAL, c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL, c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT, c.VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, c.VK_ACCESS_SHADER_WRITE_BIT, c.VK_ACCESS_SHADER_READ_BIT);
        }

        if (final_is_a) {
            self.image_layout_a = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            self.active_grid_textures = self.grid_textures_a;
        } else {
            self.image_layout_b = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
            self.active_grid_textures = self.grid_textures_b;
        }
    }

    fn transitionImage(
        self: *LPVSystem,
        cmd: c.VkCommandBuffer,
        image: c.VkImage,
        old_layout: c.VkImageLayout,
        new_layout: c.VkImageLayout,
        src_stage: c.VkPipelineStageFlags,
        dst_stage: c.VkPipelineStageFlags,
        src_access: c.VkAccessFlags,
        dst_access: c.VkAccessFlags,
    ) !void {
        _ = self;
        if (old_layout == new_layout) return;
        var barrier = std.mem.zeroes(c.VkImageMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
        barrier.oldLayout = old_layout;
        barrier.newLayout = new_layout;
        barrier.srcQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.dstQueueFamilyIndex = c.VK_QUEUE_FAMILY_IGNORED;
        barrier.image = image;
        barrier.subresourceRange.aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT;
        barrier.subresourceRange.baseMipLevel = 0;
        barrier.subresourceRange.levelCount = 1;
        barrier.subresourceRange.baseArrayLayer = 0;
        barrier.subresourceRange.layerCount = 1;
        barrier.srcAccessMask = src_access;
        barrier.dstAccessMask = dst_access;

        c.vkCmdPipelineBarrier(cmd, src_stage, dst_stage, 0, 0, null, 0, null, 1, &barrier);
    }

    fn createGridTextures(self: *LPVSystem) !void {
        const resources = try self.createGridResources(self.grid_size);
        self.applyGridResources(resources);

        self.buildDebugOverlay(&.{}, 0);
        try self.uploadDebugOverlay();
    }

    fn destroyGridTextures(self: *LPVSystem) void {
        for (0..3) |ch| {
            if (self.grid_textures_a[ch] != 0) {
                self.rhi.destroyTexture(self.grid_textures_a[ch]);
                self.grid_textures_a[ch] = 0;
            }
            if (self.grid_textures_b[ch] != 0) {
                self.rhi.destroyTexture(self.grid_textures_b[ch]);
                self.grid_textures_b[ch] = 0;
            }
        }
        if (self.debug_overlay_texture != 0) {
            self.rhi.destroyTexture(self.debug_overlay_texture);
            self.debug_overlay_texture = 0;
        }
        if (self.debug_overlay_pixels.len > 0) {
            self.allocator.free(self.debug_overlay_pixels);
            self.debug_overlay_pixels = &.{};
        }
        self.active_grid_textures = .{ 0, 0, 0 };
    }

    fn buildDebugOverlay(self: *LPVSystem, lights: []const GpuLight, light_count: usize) void {
        const gs = @as(usize, self.grid_size);
        var y: usize = 0;
        while (y < gs) : (y += 1) {
            var x: usize = 0;
            while (x < gs) : (x += 1) {
                const idx = (y * gs + x) * 4;
                const checker: f32 = if (((x / 4) + (y / 4)) % 2 == 0) @as(f32, 1.5) else @as(f32, 2.0);
                self.debug_overlay_pixels[idx + 0] = checker;
                self.debug_overlay_pixels[idx + 1] = checker;
                self.debug_overlay_pixels[idx + 2] = checker;
                self.debug_overlay_pixels[idx + 3] = 1.0;

                if (x == 0 or y == 0 or x + 1 == gs or y + 1 == gs) {
                    self.debug_overlay_pixels[idx + 0] = 4.0;
                    self.debug_overlay_pixels[idx + 1] = 4.0;
                    self.debug_overlay_pixels[idx + 2] = 4.0;
                }
            }
        }

        for (lights[0..light_count]) |light| {
            const cx: f32 = ((light.pos_radius[0] - self.origin.x) / self.cell_size);
            const cz: f32 = ((light.pos_radius[2] - self.origin.z) / self.cell_size);
            const radius = @max(light.pos_radius[3], 0.5);

            var ty: usize = 0;
            while (ty < gs) : (ty += 1) {
                var tx: usize = 0;
                while (tx < gs) : (tx += 1) {
                    const dx = @as(f32, @floatFromInt(tx)) - cx;
                    const dz = @as(f32, @floatFromInt(ty)) - cz;
                    const dist = @sqrt(dx * dx + dz * dz);
                    if (dist > radius) continue;

                    const falloff = std.math.pow(f32, 1.0 - (dist / radius), 2.0);
                    const idx = (ty * gs + tx) * 4;
                    self.debug_overlay_pixels[idx + 0] += light.color[0] * falloff * 6.0;
                    self.debug_overlay_pixels[idx + 1] += light.color[1] * falloff * 6.0;
                    self.debug_overlay_pixels[idx + 2] += light.color[2] * falloff * 6.0;
                }
            }
        }

        for (0..gs * gs) |i| {
            const idx = i * 4;
            self.debug_overlay_pixels[idx + 0] = toneMap(self.debug_overlay_pixels[idx + 0]);
            self.debug_overlay_pixels[idx + 1] = toneMap(self.debug_overlay_pixels[idx + 1]);
            self.debug_overlay_pixels[idx + 2] = toneMap(self.debug_overlay_pixels[idx + 2]);
        }
    }

    fn uploadDebugOverlay(self: *LPVSystem) !void {
        if (self.debug_overlay_texture == 0 or self.debug_overlay_pixels.len == 0) return;
        try self.rhi.updateTexture(self.debug_overlay_texture, std.mem.sliceAsBytes(self.debug_overlay_pixels));
    }

    fn destroyLightBuffer(self: *LPVSystem) void {
        if (self.light_buffer.buffer != null) {
            if (self.light_buffer.memory == null) {
                log.log.warn("LPV light buffer has VkBuffer but null VkDeviceMemory during teardown", .{});
            }
            if (self.light_buffer.mapped_ptr != null) {
                c.vkUnmapMemory(self.vk_ctx.vulkan_device.vk_device, self.light_buffer.memory);
                self.light_buffer.mapped_ptr = null;
            }
            c.vkDestroyBuffer(self.vk_ctx.vulkan_device.vk_device, self.light_buffer.buffer, null);
            c.vkFreeMemory(self.vk_ctx.vulkan_device.vk_device, self.light_buffer.memory, null);
            self.light_buffer = .{};
        }
    }

    fn destroyOcclusionBuffer(self: *LPVSystem) void {
        if (self.occlusion_buffer.buffer != null) {
            if (self.occlusion_buffer.mapped_ptr != null) {
                c.vkUnmapMemory(self.vk_ctx.vulkan_device.vk_device, self.occlusion_buffer.memory);
                self.occlusion_buffer.mapped_ptr = null;
            }
            c.vkDestroyBuffer(self.vk_ctx.vulkan_device.vk_device, self.occlusion_buffer.buffer, null);
            if (self.occlusion_buffer.memory != null) {
                c.vkFreeMemory(self.vk_ctx.vulkan_device.vk_device, self.occlusion_buffer.memory, null);
            }
            self.occlusion_buffer = .{};
        }
        if (self.occlusion_grid.len > 0) {
            self.allocator.free(self.occlusion_grid);
            self.occlusion_grid = &.{};
        }
    }

    fn initComputeResources(self: *LPVSystem) !void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        // SH L1: inject needs 3 output images + 1 SSBO = 4 bindings
        // propagate needs 3 src + 3 dst images + 1 occlusion SSBO = 7 bindings
        // Total images: inject(3) + prop_ab(6) + prop_ba(6) = 15
        // Total buffers: inject(1) + prop_ab(1) + prop_ba(1) = 3
        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 16 },
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 4 },
        };

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = 4;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes;
        try Utils.checkVk(c.vkCreateDescriptorPool(vk, &pool_info, null, &self.descriptor_pool));

        // Inject: binding 0,1,2 = output images (R,G,B SH channels), binding 3 = light buffer
        const inject_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };
        var inject_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        inject_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        inject_layout_info.bindingCount = inject_bindings.len;
        inject_layout_info.pBindings = &inject_bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &inject_layout_info, null, &self.inject_set_layout));

        // Propagate: binding 0-2 = src (R,G,B), binding 3-5 = dst (R,G,B), binding 6 = occlusion
        const prop_bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 6, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };
        var prop_layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        prop_layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        prop_layout_info.bindingCount = prop_bindings.len;
        prop_layout_info.pBindings = &prop_bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &prop_layout_info, null, &self.propagate_set_layout));

        try self.allocateDescriptorSets();
        try self.updateDescriptorSets();

        try self.createComputePipelines();
    }

    fn allocateDescriptorSets(self: *LPVSystem) !void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        var inject_alloc = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        inject_alloc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        inject_alloc.descriptorPool = self.descriptor_pool;
        inject_alloc.descriptorSetCount = 1;
        inject_alloc.pSetLayouts = &self.inject_set_layout;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &inject_alloc, &self.inject_descriptor_set));

        const layouts = [_]c.VkDescriptorSetLayout{ self.propagate_set_layout, self.propagate_set_layout };
        var prop_alloc = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        prop_alloc.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        prop_alloc.descriptorPool = self.descriptor_pool;
        prop_alloc.descriptorSetCount = 2;
        prop_alloc.pSetLayouts = &layouts;
        var prop_sets: [2]c.VkDescriptorSet = .{ null, null };
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &prop_alloc, &prop_sets));
        self.propagate_ab_descriptor_set = prop_sets[0];
        self.propagate_ba_descriptor_set = prop_sets[1];
    }

    fn updateDescriptorSets(self: *LPVSystem) !void {
        // Resolve all 6 texture resources (3 channels x 2 grids)
        var imgs_a: [3]c.VkDescriptorImageInfo = undefined;
        var imgs_b: [3]c.VkDescriptorImageInfo = undefined;
        for (0..3) |ch| {
            const tex_a = self.vk_ctx.resources.textures.get(self.grid_textures_a[ch]) orelse return error.ResourceNotFound;
            const tex_b = self.vk_ctx.resources.textures.get(self.grid_textures_b[ch]) orelse return error.ResourceNotFound;
            imgs_a[ch] = c.VkDescriptorImageInfo{ .sampler = null, .imageView = tex_a.view, .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL };
            imgs_b[ch] = c.VkDescriptorImageInfo{ .sampler = null, .imageView = tex_b.view, .imageLayout = c.VK_IMAGE_LAYOUT_GENERAL };
        }
        var light_info = c.VkDescriptorBufferInfo{ .buffer = self.light_buffer.buffer, .offset = 0, .range = @sizeOf(GpuLight) * MAX_LIGHTS_PER_UPDATE };
        const occlusion_size = @as(usize, self.grid_size) * @as(usize, self.grid_size) * @as(usize, self.grid_size) * @sizeOf(u32);
        var occlusion_info = c.VkDescriptorBufferInfo{ .buffer = self.occlusion_buffer.buffer, .offset = 0, .range = @intCast(occlusion_size) };

        // Inject: bindings 0,1,2 = output R,G,B images (grid A), binding 3 = light buffer
        // Propagate A->B: bindings 0-2 = src (A), bindings 3-5 = dst (B), binding 6 = occlusion
        // Propagate B->A: bindings 0-2 = src (B), bindings 3-5 = dst (A), binding 6 = occlusion
        // Total writes: 4 (inject) + 7 (prop_ab) + 7 (prop_ba) = 18
        var writes: [18]c.VkWriteDescriptorSet = undefined;
        var n: usize = 0;

        // --- Inject set ---
        for (0..3) |ch| {
            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.inject_descriptor_set;
            writes[n].dstBinding = @intCast(ch);
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            writes[n].descriptorCount = 1;
            writes[n].pImageInfo = &imgs_a[ch];
            n += 1;
        }
        writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[n].dstSet = self.inject_descriptor_set;
        writes[n].dstBinding = 3;
        writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[n].descriptorCount = 1;
        writes[n].pBufferInfo = &light_info;
        n += 1;

        // --- Propagate A->B set ---
        for (0..3) |ch| {
            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.propagate_ab_descriptor_set;
            writes[n].dstBinding = @intCast(ch);
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            writes[n].descriptorCount = 1;
            writes[n].pImageInfo = &imgs_a[ch];
            n += 1;
        }
        for (0..3) |ch| {
            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.propagate_ab_descriptor_set;
            writes[n].dstBinding = @intCast(ch + 3);
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            writes[n].descriptorCount = 1;
            writes[n].pImageInfo = &imgs_b[ch];
            n += 1;
        }
        writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[n].dstSet = self.propagate_ab_descriptor_set;
        writes[n].dstBinding = 6;
        writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[n].descriptorCount = 1;
        writes[n].pBufferInfo = &occlusion_info;
        n += 1;

        // --- Propagate B->A set ---
        for (0..3) |ch| {
            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.propagate_ba_descriptor_set;
            writes[n].dstBinding = @intCast(ch);
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            writes[n].descriptorCount = 1;
            writes[n].pImageInfo = &imgs_b[ch];
            n += 1;
        }
        for (0..3) |ch| {
            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = self.propagate_ba_descriptor_set;
            writes[n].dstBinding = @intCast(ch + 3);
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_IMAGE;
            writes[n].descriptorCount = 1;
            writes[n].pImageInfo = &imgs_a[ch];
            n += 1;
        }
        writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
        writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
        writes[n].dstSet = self.propagate_ba_descriptor_set;
        writes[n].dstBinding = 6;
        writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
        writes[n].descriptorCount = 1;
        writes[n].pBufferInfo = &occlusion_info;
        n += 1;

        c.vkUpdateDescriptorSets(self.vk_ctx.vulkan_device.vk_device, @intCast(n), &writes[0], 0, null);
    }

    fn createComputePipelines(self: *LPVSystem) !void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        const inject_module = try createShaderModule(vk, INJECT_SHADER_PATH, self.allocator);
        defer c.vkDestroyShaderModule(vk, inject_module, null);
        const propagate_module = try createShaderModule(vk, PROPAGATE_SHADER_PATH, self.allocator);
        defer c.vkDestroyShaderModule(vk, propagate_module, null);

        var inject_pc = std.mem.zeroes(c.VkPushConstantRange);
        inject_pc.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        inject_pc.offset = 0;
        inject_pc.size = @sizeOf(InjectPush);

        var inject_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        inject_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        inject_layout_info.setLayoutCount = 1;
        inject_layout_info.pSetLayouts = &self.inject_set_layout;
        inject_layout_info.pushConstantRangeCount = 1;
        inject_layout_info.pPushConstantRanges = &inject_pc;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &inject_layout_info, null, &self.inject_pipeline_layout));

        var prop_pc = std.mem.zeroes(c.VkPushConstantRange);
        prop_pc.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        prop_pc.offset = 0;
        prop_pc.size = @sizeOf(PropagatePush);

        var prop_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        prop_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        prop_layout_info.setLayoutCount = 1;
        prop_layout_info.pSetLayouts = &self.propagate_set_layout;
        prop_layout_info.pushConstantRangeCount = 1;
        prop_layout_info.pPushConstantRanges = &prop_pc;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &prop_layout_info, null, &self.propagate_pipeline_layout));

        var inject_stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        inject_stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        inject_stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
        inject_stage.module = inject_module;
        inject_stage.pName = "main";

        var inject_info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
        inject_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        inject_info.stage = inject_stage;
        inject_info.layout = self.inject_pipeline_layout;
        try Utils.checkVk(c.vkCreateComputePipelines(vk, null, 1, &inject_info, null, &self.inject_pipeline));

        var prop_stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        prop_stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        prop_stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
        prop_stage.module = propagate_module;
        prop_stage.pName = "main";

        var prop_info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
        prop_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        prop_info.stage = prop_stage;
        prop_info.layout = self.propagate_pipeline_layout;
        try Utils.checkVk(c.vkCreateComputePipelines(vk, null, 1, &prop_info, null, &self.propagate_pipeline));
    }

    fn deinitComputeResources(self: *LPVSystem) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;
        if (self.inject_pipeline != null) c.vkDestroyPipeline(vk, self.inject_pipeline, null);
        if (self.propagate_pipeline != null) c.vkDestroyPipeline(vk, self.propagate_pipeline, null);
        if (self.inject_pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.inject_pipeline_layout, null);
        if (self.propagate_pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.propagate_pipeline_layout, null);
        if (self.inject_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.inject_set_layout, null);
        if (self.propagate_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.propagate_set_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(vk, self.descriptor_pool, null);

        self.inject_pipeline = null;
        self.propagate_pipeline = null;
        self.inject_pipeline_layout = null;
        self.propagate_pipeline_layout = null;
        self.inject_set_layout = null;
        self.propagate_set_layout = null;
        self.descriptor_pool = null;
        self.inject_descriptor_set = null;
        self.propagate_ab_descriptor_set = null;
        self.propagate_ba_descriptor_set = null;
    }
};

fn quantizeToCell(value: f32, cell_size: f32) f32 {
    return @floor(value / cell_size) * cell_size;
}

fn divCeil(v: u32, d: u32) u32 {
    return @divFloor(v + d - 1, d);
}

fn toneMap(v: f32) f32 {
    const x = @max(v, 0.0);
    return x / (1.0 + x);
}

fn createShaderModule(vk: c.VkDevice, path: []const u8, allocator: std.mem.Allocator) !c.VkShaderModule {
    const bytes = try fs.cwd().readFileAlloc(path, allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len % 4 != 0) return error.InvalidState;

    var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = bytes.len;
    info.pCode = @ptrCast(@alignCast(bytes.ptr));

    var module: c.VkShaderModule = null;
    try Utils.checkVk(c.vkCreateShaderModule(vk, &info, null, &module));
    return module;
}

fn ensureShaderFileExists(path: []const u8) !void {
    fs.cwd().access(path, .{}) catch |err| {
        log.log.errWithTrace("LPV shader artifact missing: {s} ({})", .{ path, err });
        log.log.err("Run `nix develop --command zig build` to regenerate Vulkan SPIR-V shaders.", .{});
        return err;
    };
}
