const std = @import("std");
const rhi = @import("engine-rhi");
const RenderContext = rhi.RenderContext;

pub const AtmosphereSystem = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !*AtmosphereSystem {
        const self = try allocator.create(AtmosphereSystem);
        self.* = .{
            .allocator = allocator,
        };
        return self;
    }

    pub fn deinit(self: *AtmosphereSystem) void {
        self.allocator.destroy(self);
    }

    pub fn renderSky(_: *AtmosphereSystem, ctx: RenderContext, params: rhi.SkyParams) rhi.RhiError!void {
        try ctx.drawSky(params);
    }
};
