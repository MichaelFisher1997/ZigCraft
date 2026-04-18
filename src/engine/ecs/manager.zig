//! ECS Registry/Manager.

const std = @import("std");
const EntityId = @import("entity.zig").EntityId;
const ComponentStorage = @import("storage.zig").ComponentStorage;
const components = @import("components.zig");

pub const Registry = struct {
    allocator: std.mem.Allocator,
    next_entity_id: EntityId = 1,

    // Component Storages
    transforms: ComponentStorage(components.Transform),
    physics: ComponentStorage(components.Physics),
    meshes: ComponentStorage(components.Mesh),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .allocator = allocator,
            .transforms = ComponentStorage(components.Transform).init(allocator),
            .physics = ComponentStorage(components.Physics).init(allocator),
            .meshes = ComponentStorage(components.Mesh).init(allocator),
        };
    }

    pub fn deinit(self: *Registry) void {
        self.transforms.deinit();
        self.physics.deinit();
        self.meshes.deinit();
    }

    pub fn create(self: *Registry) EntityId {
        const id = self.next_entity_id;
        // Check for overflow (extremely unlikely but good practice)
        if (self.next_entity_id == std.math.maxInt(EntityId)) {
            @panic("Entity ID overflow");
        }
        self.next_entity_id += 1;
        return id;
    }

    pub fn destroy(self: *Registry, entity: EntityId) void {
        _ = self.transforms.remove(entity);
        _ = self.physics.remove(entity);
        _ = self.meshes.remove(entity);
    }

    pub fn clear(self: *Registry) void {
        self.transforms.clear();
        self.physics.clear();
        self.meshes.clear();
        self.next_entity_id = 1;
    }

    /// Returns a query iterator for the given component types.
    /// Example: registry.query(.{ Transform, Physics })
    pub fn query(self: *Registry, comptime component_types: anytype) Query(component_types) {
        return Query(component_types).init(self);
    }

    pub fn Query(comptime component_types: anytype) type {
        return struct {
            const Self = @This();
            registry: *Registry,
            index: usize = 0,

            pub fn init(registry: *Registry) Self {
                return .{ .registry = registry };
            }

            pub const Row = struct {
                entity: EntityId,
                components: ComponentsTuple,
            };

            const ComponentsTuple = blk: {
                var fields: [component_types.len]std.builtin.Type.StructField = undefined;
                for (component_types, 0..) |T, i| {
                    const field_name = std.fmt.comptimePrint("{}", .{i});
                    fields[i] = .{
                        .name = (field_name ++ "\x00")[0..field_name.len :0],
                        .type = *T,
                        .default_value_ptr = null,
                        .is_comptime = false,
                        .alignment = @alignOf(*T),
                    };
                }
                break :blk @Type(.{
                    .@"struct" = .{
                        .layout = .auto,
                        .backing_integer = null,
                        .fields = &fields,
                        .decls = &.{},
                        .is_tuple = true,
                    },
                });
            };

            pub fn next(self: *Self) ?Row {
                // Use the first component storage as the primary source of entities.
                const PrimaryType = component_types[0];
                const primary_storage = self.registry.getStorage(PrimaryType);

                while (self.index < primary_storage.entities.items.len) {
                    const entity = primary_storage.entities.items[self.index];
                    self.index += 1;

                    var comp_tuple: ComponentsTuple = undefined;
                    var all_present = true;

                    inline for (component_types, 0..) |T, i| {
                        if (self.registry.getStorage(T).getPtr(entity)) |ptr| {
                            comp_tuple[i] = ptr;
                        } else {
                            all_present = false;
                            break;
                        }
                    }

                    if (all_present) {
                        return Row{
                            .entity = entity,
                            .components = comp_tuple,
                        };
                    }
                }

                return null;
            }
        };
    }

    /// Internal helper to get storage by type
    fn getStorage(self: *Registry, comptime T: type) *ComponentStorage(T) {
        if (T == components.Transform) return &self.transforms;
        if (T == components.Physics) return &self.physics;
        if (T == components.Mesh) return &self.meshes;
        @compileError("Unsupported component type for query: " ++ @typeName(T));
    }

    pub const Snapshot = struct {
        next_entity_id: EntityId,
        entities: []const EntityId,
        transforms: []const ?components.Transform,
        physics: []const ?components.Physics,
        meshes: []const ?components.Mesh,

        pub fn deinit(self: Snapshot, allocator: std.mem.Allocator) void {
            allocator.free(self.entities);
            allocator.free(self.transforms);
            allocator.free(self.physics);
            allocator.free(self.meshes);
        }
    };

    pub fn takeSnapshot(self: *Registry, allocator: std.mem.Allocator) !Snapshot {
        // Collect all unique entities
        var entities_map = std.AutoHashMap(EntityId, void).init(allocator);
        defer entities_map.deinit();

        for (self.transforms.entities.items) |id| try entities_map.put(id, {});
        for (self.physics.entities.items) |id| try entities_map.put(id, {});
        for (self.meshes.entities.items) |id| try entities_map.put(id, {});

        const entities = try allocator.alloc(EntityId, entities_map.count());
        var it = entities_map.keyIterator();
        var i: usize = 0;
        while (it.next()) |id| {
            entities[i] = id.*;
            i += 1;
        }

        const transforms = try allocator.alloc(?components.Transform, entities.len);
        const physics = try allocator.alloc(?components.Physics, entities.len);
        const meshes = try allocator.alloc(?components.Mesh, entities.len);

        for (entities, 0..) |id, idx| {
            transforms[idx] = self.transforms.get(id);
            physics[idx] = self.physics.get(id);
            meshes[idx] = self.meshes.get(id);
        }

        return Snapshot{
            .next_entity_id = self.next_entity_id,
            .entities = entities,
            .transforms = transforms,
            .physics = physics,
            .meshes = meshes,
        };
    }

    pub fn loadSnapshot(self: *Registry, snapshot: Snapshot) !void {
        self.clear();
        self.next_entity_id = snapshot.next_entity_id;

        for (snapshot.entities, 0..) |id, idx| {
            if (snapshot.transforms[idx]) |val| try self.transforms.set(id, val);
            if (snapshot.physics[idx]) |val| try self.physics.set(id, val);
            if (snapshot.meshes[idx]) |val| try self.meshes.set(id, val);
        }
    }

    pub fn saveToJson(self: *Registry, allocator: std.mem.Allocator, writer: anytype) !void {
        const snapshot = try self.takeSnapshot(allocator);
        defer snapshot.deinit(allocator);
        try std.json.stringify(snapshot, .{}, writer);
    }

    pub fn loadFromJson(self: *Registry, allocator: std.mem.Allocator, content: []const u8) !void {
        const parsed = try std.json.parseFromSlice(Snapshot, allocator, content, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        try self.loadSnapshot(parsed.value);
    }
};
