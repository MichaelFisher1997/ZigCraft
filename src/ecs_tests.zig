const std = @import("std");
const testing = std.testing;
const ecs_manager = @import("engine-ecs").manager;
const ECSRegistry = ecs_manager.Registry;
const ecs_components = @import("engine-ecs").components;
const Vec3 = @import("zig-math").Vec3;

test "ECS registry basic operations" {
    const allocator = testing.allocator;
    var registry = ECSRegistry.init(allocator);
    defer registry.deinit();

    const e1 = registry.create();
    const e2 = registry.create();

    try registry.transforms.set(e1, .{ .position = Vec3.init(1, 2, 3) });
    try registry.physics.set(e1, .{ .aabb_size = Vec3.init(1, 1, 1) });
    try registry.transforms.set(e2, .{ .position = Vec3.init(4, 5, 6) });

    try testing.expect(registry.transforms.has(e1));
    try testing.expect(registry.physics.has(e1));
    try testing.expect(registry.transforms.has(e2));
    try testing.expect(!registry.physics.has(e2));

    const t1 = registry.transforms.get(e1).?;
    try testing.expectEqual(@as(f32, 1), t1.position.x);
}

test "ECS Query API" {
    const allocator = testing.allocator;
    var registry = ECSRegistry.init(allocator);
    defer registry.deinit();

    const e1 = registry.create();
    const e2 = registry.create();
    const e3 = registry.create();

    try registry.transforms.set(e1, .{ .position = Vec3.init(1, 0, 0) });
    try registry.physics.set(e1, .{ .aabb_size = Vec3.one });

    try registry.transforms.set(e2, .{ .position = Vec3.init(2, 0, 0) });
    // e2 has no Physics

    try registry.transforms.set(e3, .{ .position = Vec3.init(3, 0, 0) });
    try registry.physics.set(e3, .{ .aabb_size = Vec3.one });

    var count: usize = 0;
    var query = registry.query(.{ ecs_components.Transform, ecs_components.Physics });
    while (query.next()) |row| {
        count += 1;
        // Check if components are correct
        try testing.expect(row.components[0].position.x == 1.0 or row.components[0].position.x == 3.0);
    }

    try testing.expectEqual(@as(usize, 2), count);
}

test "ECS Serialization" {
    const allocator = testing.allocator;
    var registry = ECSRegistry.init(allocator);
    defer registry.deinit();

    const e1 = registry.create();
    try registry.transforms.set(e1, .{ .position = Vec3.init(10, 20, 30) });
    try registry.meshes.set(e1, .{ .color = Vec3.init(1, 0, 0) });

    // Take snapshot
    const snapshot = try registry.takeSnapshot(allocator);
    defer snapshot.deinit(allocator);

    try testing.expectEqual(@as(usize, 1), snapshot.entities.len);
    try testing.expectEqual(e1, snapshot.entities[0]);

    // Load into new registry
    var registry2 = ECSRegistry.init(allocator);
    defer registry2.deinit();
    try registry2.loadSnapshot(snapshot);

    try testing.expect(registry2.transforms.has(e1));
    try testing.expect(registry2.meshes.has(e1));
    try testing.expectEqual(@as(f32, 10), registry2.transforms.get(e1).?.position.x);

    // Test JSON
    const json_str = try std.json.Stringify.valueAlloc(allocator, snapshot, .{});
    defer allocator.free(json_str);

    var registry3 = ECSRegistry.init(allocator);
    defer registry3.deinit();
    try registry3.loadFromJson(allocator, json_str);

    try testing.expect(registry3.transforms.has(e1));
    try testing.expectEqual(@as(f32, 10), registry3.transforms.get(e1).?.position.x);
}
