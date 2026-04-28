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

fn makeWireframeVertex(x: f32, y: f32, z: f32) Vertex {
    return Vertex.init(
        .{ x, y, z },
        .{ 1.0, 1.0, 1.0 },
        .{ 0, 1, 0 },
        .{ 0, 0 },
        0,
        1.0,
        .{ 1.0, 1.0, 1.0 },
        1.0,
        0.0,
    );
}

const wireframe_line_vertices = [_]Vertex{
    makeWireframeVertex(0.0, 0.0, 0.0),
    makeWireframeVertex(1.0, 0.0, 0.0),
    makeWireframeVertex(1.0, 0.0, 0.0),
    makeWireframeVertex(1.0, 0.0, 1.0),
    makeWireframeVertex(1.0, 0.0, 1.0),
    makeWireframeVertex(0.0, 0.0, 1.0),
    makeWireframeVertex(0.0, 0.0, 1.0),
    makeWireframeVertex(0.0, 0.0, 0.0),
    makeWireframeVertex(0.0, 1.0, 0.0),
    makeWireframeVertex(1.0, 1.0, 0.0),
    makeWireframeVertex(1.0, 1.0, 0.0),
    makeWireframeVertex(1.0, 1.0, 1.0),
    makeWireframeVertex(1.0, 1.0, 1.0),
    makeWireframeVertex(0.0, 1.0, 1.0),
    makeWireframeVertex(0.0, 1.0, 1.0),
    makeWireframeVertex(0.0, 1.0, 0.0),
    makeWireframeVertex(0.0, 0.0, 0.0),
    makeWireframeVertex(0.0, 1.0, 0.0),
    makeWireframeVertex(1.0, 0.0, 0.0),
    makeWireframeVertex(1.0, 1.0, 0.0),
    makeWireframeVertex(1.0, 0.0, 1.0),
    makeWireframeVertex(1.0, 1.0, 1.0),
    makeWireframeVertex(0.0, 0.0, 1.0),
    makeWireframeVertex(0.0, 1.0, 1.0),
};

const wireframe_line_vertex_count: u32 = @intCast(wireframe_line_vertices.len);

pub const RenderSystem = struct {
    buffer_handle: rhi_pkg.BufferHandle,
    resources: ResourceManager,
    missing_transform_logged: bool,

    pub fn init(resources: ResourceManager) !RenderSystem {
        const buffer = try resources.createBuffer(@sizeOf(@TypeOf(wireframe_line_vertices)), .vertex);
        try resources.uploadBuffer(buffer, std.mem.asBytes(&wireframe_line_vertices));

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
                ctx.draw(self.buffer_handle, wireframe_line_vertex_count, .lines);
            }
        }
    }
};
