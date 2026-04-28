const std = @import("std");
const rhi = @import("engine-rhi");
const RenderContext = rhi.RenderContext;
const TextureAtlas = @import("texture_atlas.zig").TextureAtlas;

pub const MaterialSystem = struct {
    allocator: std.mem.Allocator,
    atlas: *TextureAtlas,

    pub fn init(allocator: std.mem.Allocator, atlas: *TextureAtlas) !*MaterialSystem {
        const self = try allocator.create(MaterialSystem);
        self.* = .{
            .allocator = allocator,
            .atlas = atlas,
        };
        return self;
    }

    pub fn deinit(self: *MaterialSystem) void {
        self.allocator.destroy(self);
    }

    pub fn bindTerrainMaterial(self: *MaterialSystem, ctx: RenderContext, env_map_handle: rhi.TextureHandle) void {
        ctx.bindTexture(self.atlas.texture.handle, 1);
        if (self.atlas.normal_texture) |t| ctx.bindTexture(t.handle, 6);
        if (self.atlas.roughness_texture) |t| ctx.bindTexture(t.handle, 7);
        if (self.atlas.displacement_texture) |t| ctx.bindTexture(t.handle, 8);
        if (env_map_handle != 0) ctx.bindTexture(env_map_handle, 9);
    }

    /// Gets the handles for the current texture atlas
    pub fn getAtlasHandles(self: *MaterialSystem, env_map_handle: rhi.TextureHandle) rhi.TextureAtlasHandles {
        return .{
            .diffuse = self.atlas.texture.handle,
            .normal = if (self.atlas.normal_texture) |t| t.handle else 0,
            .roughness = if (self.atlas.roughness_texture) |t| t.handle else 0,
            .displacement = if (self.atlas.displacement_texture) |t| t.handle else 0,
            .env = env_map_handle,
        };
    }
};
