//! Physics system for ECS.

const std = @import("std");
const Registry = @import("../manager.zig").Registry;
const components = @import("../components.zig");
const collision = @import("engine-physics").collision;
const Vec3 = @import("engine-math").Vec3;
const AABB = @import("engine-math").AABB;

pub const PhysicsSystem = struct {
    var missing_transform_logged = false;

    pub fn update(registry: *Registry, world: collision.VoxelCollisionWorld, delta_time: f32) void {
        const logger = @import("engine-core").log.log;

        // Check for entities with Physics but no Transform
        if (!missing_transform_logged) {
            for (registry.physics.entities.items) |entity_id| {
                if (!registry.transforms.has(entity_id)) {
                    logger.warn("ECS physics skip: entity missing Transform (id={})", .{entity_id});
                    missing_transform_logged = true;
                    break;
                }
            }
        }

        var query = registry.query(.{ components.Transform, components.Physics });
        while (query.next()) |row| {
            const transform = row.components[0];
            const phys = row.components[1];

            // Apply gravity
            if (phys.use_gravity) {
                const GRAVITY: f32 = 32.0;
                phys.velocity.y -= GRAVITY * delta_time;
            }

            // Terminal velocity
            const TERMINAL_VELOCITY: f32 = 78.4;
            if (phys.velocity.y < -TERMINAL_VELOCITY) {
                phys.velocity.y = -TERMINAL_VELOCITY;
            }

            // Calculate AABB for collision
            const center = transform.position.add(Vec3.init(0, phys.aabb_size.y * 0.5, 0));
            const size = phys.aabb_size;
            const aabb = AABB.fromCenterSize(center, size);

            // Perform collision
            const result = collision.moveAndCollide(world, aabb, phys.velocity, delta_time, .{});

            // Update position (convert back to feet position)
            transform.position = result.position.sub(Vec3.init(0, phys.aabb_size.y * 0.5, 0));
            phys.velocity = result.velocity;
            phys.grounded = result.grounded;
        }
    }
};
