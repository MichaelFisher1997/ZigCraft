const std = @import("std");
const rhi = @import("rhi.zig");
const ResourceManager = rhi.ResourceManager;
const RenderContext = rhi.RenderContext;
const c = @import("../../c.zig").c;
const log = @import("../core/log.zig");

pub const AtmosphereSystem = struct {
    allocator: std.mem.Allocator,
    resources: ResourceManager,

    pub fn init(allocator: std.mem.Allocator, resources: ResourceManager) !*AtmosphereSystem {
        const self = try allocator.create(AtmosphereSystem);
        self.* = .{
            .allocator = allocator,
            .resources = resources,
        };
        return self;
    }

    pub fn deinit(self: *AtmosphereSystem) void {
        self.allocator.destroy(self);
    }

    pub fn renderSky(_: *AtmosphereSystem, ctx: RenderContext, params: rhi.SkyParams) rhi.RhiError!void {
        const pipeline_u64 = ctx.getNativeSkyPipeline();
        const layout_u64 = ctx.getNativeSkyPipelineLayout();
        const descriptor_set_u64 = ctx.getNativeMainDescriptorSet();
        const cmd_u64 = ctx.getNativeCommandBuffer();

        if (pipeline_u64 == 0 or layout_u64 == 0 or cmd_u64 == 0) {
            log.log.warn("AtmosphereSystem: Sky rendering skipped, native handles missing (pipeline={}, layout={}, cmd={})", .{ pipeline_u64 != 0, layout_u64 != 0, cmd_u64 != 0 });
            if (pipeline_u64 == 0) return error.SkyPipelineNotReady;
            if (layout_u64 == 0) return error.SkyPipelineLayoutNotReady;
            if (cmd_u64 == 0) return error.CommandBufferNotReady;
            return error.ResourceNotReady;
        }

        const pipeline = @as(c.VkPipeline, @ptrFromInt(pipeline_u64));
        const layout = @as(c.VkPipelineLayout, @ptrFromInt(layout_u64));
        const descriptor_set = @as(c.VkDescriptorSet, @ptrFromInt(descriptor_set_u64));
        const cmd = @as(c.VkCommandBuffer, @ptrFromInt(cmd_u64));

        const pc = rhi.SkyPushConstants{
            .cam_forward = .{ params.cam_forward.x, params.cam_forward.y, params.cam_forward.z, 0.0 },
            .cam_right = .{ params.cam_right.x, params.cam_right.y, params.cam_right.z, 0.0 },
            .cam_up = .{ params.cam_up.x, params.cam_up.y, params.cam_up.z, 0.0 },
            .sun_dir = .{ params.sun_dir.x, params.sun_dir.y, params.sun_dir.z, 0.0 },
            .sky_color = .{ params.sky_color.x, params.sky_color.y, params.sky_color.z, 1.0 },
            .horizon_color = .{ params.horizon_color.x, params.horizon_color.y, params.horizon_color.z, 1.0 },
            .params = .{ params.aspect, params.tan_half_fov, params.sun_intensity, params.moon_intensity },
            .time = .{ params.time, params.cam_pos.x, params.cam_pos.y, params.cam_pos.z },
        };

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        if (descriptor_set_u64 != 0) {
            c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_GRAPHICS, layout, 0, 1, &descriptor_set, 0, null);
        }
        c.vkCmdPushConstants(cmd, layout, c.VK_SHADER_STAGE_VERTEX_BIT | c.VK_SHADER_STAGE_FRAGMENT_BIT, 0, @sizeOf(rhi.SkyPushConstants), &pc);
        c.vkCmdDraw(cmd, 3, 1, 0, 0);
    }
};
