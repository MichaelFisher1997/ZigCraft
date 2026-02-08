const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");

pub const TAASystem = struct {
    history_textures: [2]rhi.TextureHandle = .{ 0, 0 },
    output_texture: rhi.TextureHandle = 0,
    extent: c.VkExtent2D = .{ .width = 0, .height = 0 },
    history_index: usize = 0,

    pub fn ensureResources(self: *TAASystem, resources: anytype, extent: c.VkExtent2D) !void {
        if (extent.width == 0 or extent.height == 0) return;
        if (self.extent.width == extent.width and self.extent.height == extent.height and self.history_textures[0] != 0 and self.history_textures[1] != 0 and self.output_texture != 0) {
            return;
        }

        self.deinit(resources);

        const config = rhi.TextureConfig{
            .min_filter = .linear,
            .mag_filter = .linear,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
            .generate_mipmaps = false,
            .is_render_target = true,
        };

        self.history_textures[0] = try resources.createTexture(extent.width, extent.height, .rgba32f, config, null);
        errdefer self.deinit(resources);
        self.history_textures[1] = try resources.createTexture(extent.width, extent.height, .rgba32f, config, null);
        errdefer self.deinit(resources);
        self.output_texture = try resources.createTexture(extent.width, extent.height, .rgba32f, config, null);

        self.extent = extent;
        self.history_index = 0;
    }

    pub fn deinit(self: *TAASystem, resources: anytype) void {
        for (self.history_textures) |handle| {
            if (handle != 0) {
                resources.destroyTexture(handle);
            }
        }
        self.history_textures = .{ 0, 0 };

        if (self.output_texture != 0) {
            resources.destroyTexture(self.output_texture);
            self.output_texture = 0;
        }

        self.extent = .{ .width = 0, .height = 0 };
        self.history_index = 0;
    }

    pub fn compute(self: *TAASystem) void {
        self.history_index = (self.history_index + 1) % 2;
    }
};
