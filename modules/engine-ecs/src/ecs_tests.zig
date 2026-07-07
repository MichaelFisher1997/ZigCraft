const std = @import("std");
const testing = std.testing;
const ecs_manager = @import("engine-ecs").manager;
const ECSRegistry = ecs_manager.Registry;
const ecs_components = @import("engine-ecs").components;
const ComponentStorage = @import("engine-ecs").ComponentStorage;
const EntityId = @import("engine-ecs").EntityId;
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

test "ComponentStorage.remove returns false on empty storage" {
    const allocator = testing.allocator;
    var storage = ComponentStorage(ecs_components.Transform).init(allocator);
    defer storage.deinit();

    // Removing from a fresh (empty) storage must not crash and must report
    // nothing was removed.
    try testing.expect(!storage.remove(123));
}

test "ComponentStorage.remove handles stale map entry with empty arrays (desync)" {
    // Simulate a desync condition where the sparse map still references an
    // entity but the dense arrays have been drained. Previously this triggered
    // a usize underflow on `len - 1` followed by an out-of-bounds access.
    const allocator = testing.allocator;
    var storage = ComponentStorage(ecs_components.Transform).init(allocator);
    defer storage.deinit();

    const entity: EntityId = 42;
    // Inject a stale map entry while leaving the dense arrays empty.
    try storage.map.put(entity, 0);
    try testing.expect(storage.has(entity));
    try testing.expectEqual(@as(usize, 0), storage.components.items.len);

    // Should gracefully report not-found and repair the stale map entry.
    try testing.expect(!storage.remove(entity));
    try testing.expect(!storage.has(entity));
}

test "ComponentStorage.remove handles stale map entry with out-of-bounds index (desync)" {
    // Simulate a desync where the stored index is beyond the dense array
    // length. The defensive guard should drop the stale entry and return
    // false instead of indexing out of bounds.
    const allocator = testing.allocator;
    var storage = ComponentStorage(ecs_components.Transform).init(allocator);
    defer storage.deinit();

    const entity: EntityId = 7;
    try storage.set(entity, .{ .position = Vec3.init(1, 2, 3) });
    // Corrupt the stored index to point past the end of the dense arrays.
    try storage.map.put(entity, 999);

    try testing.expect(!storage.remove(entity));
    try testing.expect(!storage.has(entity));
}

test "ComponentStorage.remove keeps dense arrays consistent under normal use" {
    // Regression coverage to ensure the defensive guard does not interfere
    // with the normal swap-remove behavior.
    const allocator = testing.allocator;
    var storage = ComponentStorage(ecs_components.Transform).init(allocator);
    defer storage.deinit();

    const a: EntityId = 1;
    const b: EntityId = 2;
    const c: EntityId = 3;
    try storage.set(a, .{ .position = Vec3.init(1, 0, 0) });
    try storage.set(b, .{ .position = Vec3.init(2, 0, 0) });
    try storage.set(c, .{ .position = Vec3.init(3, 0, 0) });

    // Remove the middle entity; the remaining two must still be retrievable.
    try testing.expect(storage.remove(b));
    try testing.expect(!storage.has(b));
    try testing.expect(storage.has(a));
    try testing.expect(storage.has(c));
    try testing.expectEqual(@as(f32, 1), storage.get(a).?.position.x);
    try testing.expectEqual(@as(f32, 3), storage.get(c).?.position.x);
    try testing.expectEqual(@as(usize, 2), storage.components.items.len);
}
