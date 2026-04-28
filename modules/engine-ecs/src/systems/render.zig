//! Render system for ECS.
//! Currently renders entities as colored wireframe boxes.

const std = @import("std");
const Registry = @import("../manager.zig").Registry;
const components = @import("../components.zig");
const rhi_pkg = @import("engine-rhi").rhi;
const ResourceManager = rhi_pkg.ResourceManager;
const RenderContext = rhi_pkg.RenderContext;
const Mat4 = @import("engine-math").Mat4;
const Vec3 = @import("engine-math").Vec3;
const Vertex = rhi_pkg.Vertex;
const wireframe = @import("engine-graphics").wireframe_cube;

pub const RenderSystem = struct {
    buffer_handle: rhi_pkg.BufferHandle,
    resources: ResourceManager,
    missing_transform_logged: bool,

    pub fn init(resources: ResourceManager) !RenderSystem {
        const buffer = try resources.createBuffer(@sizeOf(@TypeOf(wireframe.line_vertices)), .vertex);
        try resources.uploadBuffer(buffer, std.mem.asBytes(&wireframe.line_vertices));

        return .{
            .buffer_handle = buffer,
            .resources = resources,
            .missing_transform_logged = false,
        };
    }

    pub fn deinit(self: *RenderSystem) void {
        if (self.buffer_handle != rhi_pkg.InvalidBufferHandle) {
            self.resources.destroyBuffer(self.buffer_handle);
            self.buffer_handle = rhi_pkg.InvalidBufferHandle;
        }
    }

    pub fn render(self: *RenderSystem, ctx: RenderContext, registry: *Registry, camera_pos: Vec3) void {
        const logger = @import("engine-core").log.log;

        if (!self.missing_transform_logged) {
            for (registry.meshes.entities.items) |entity_id| {
                if (!registry.transforms.has(entity_id)) {
                    logger.warn("ECS render skip: entity missing Transform (id={})", .{entity_id});
                    self.missing_transform_logged = true;
                    break;
                }
            }
        }

        var q = registry.query(.{ components.Mesh, components.Transform });
        while (q.next()) |row| {
            const mesh = row.components[0];
            const transform = row.components[1];
            const entity_id = row.entity;

            if (!mesh.visible) continue;

            var size = Vec3.one;
            var offset = Vec3.zero;

            if (registry.physics.getPtr(entity_id)) |phys| {
                size = phys.aabb_size;
                offset = Vec3.init(-size.x / 2.0, 0, -size.z / 2.0);
            }

            const rel_pos = transform.position.add(offset).sub(camera_pos);

            const model = Mat4.translate(rel_pos).multiply(Mat4.scale(size));

            if (self.buffer_handle != rhi_pkg.InvalidBufferHandle) {
                ctx.setModelMatrix(model, mesh.color, 0);
                ctx.draw(self.buffer_handle, wireframe.line_vertex_count, .lines);
            }
        }
    }
};
