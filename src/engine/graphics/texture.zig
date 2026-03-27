const std = @import("std");
const rhi = @import("rhi.zig");

pub const TextureFormat = rhi.TextureFormat;
pub const FilterMode = rhi.FilterMode;
pub const WrapMode = rhi.WrapMode;
pub const Config = rhi.TextureConfig;

pub const Texture = struct {
    handle: rhi.TextureHandle,
    width: u32,
    height: u32,
    resources: rhi.ResourceManager,

    pub fn init(resources: rhi.ResourceManager, width: u32, height: u32, format: TextureFormat, config: Config, data: ?[]const u8) rhi.RhiError!Texture {
        const handle = try resources.createTexture(width, height, format, config, data);
        return .{
            .handle = handle,
            .width = width,
            .height = height,
            .resources = resources,
        };
    }

    pub fn initEmpty(resources: rhi.ResourceManager, width: u32, height: u32, format: TextureFormat, config: Config) rhi.RhiError!Texture {
        return init(resources, width, height, format, config, null);
    }

    pub fn initFloat(resources: rhi.ResourceManager, width: u32, height: u32, data: []const f32) rhi.RhiError!Texture {
        const bytes = std.mem.sliceAsBytes(data);
        const handle = try resources.createTexture(width, height, .rgba32f, .{
            .min_filter = .linear_mipmap_linear,
            .mag_filter = .linear,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
            .generate_mipmaps = true,
        }, bytes);
        return .{
            .handle = handle,
            .width = width,
            .height = height,
            .resources = resources,
        };
    }

    pub fn initSolidColor(resources: rhi.ResourceManager, r: u8, g: u8, b: u8, a: u8) rhi.RhiError!Texture {
        const data = [_]u8{ r, g, b, a };
        return init(resources, 1, 1, .rgba, .{}, &data);
    }

    pub fn deinit(self: *Texture) void {
        self.resources.destroyTexture(self.handle);
    }

    pub fn update(self: *const Texture, data: []const u8) rhi.RhiError!void {
        try self.resources.updateTexture(self.handle, data);
    }
};
