const world_core = @import("world-core");
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const block_registry = world_core.block_registry;
const ChunkStorage = @import("world-meshing").ChunkStorage;
const Vec3 = @import("engine-math").Vec3;
const GpuLight = @import("engine-rhi").GpuLight;
const ILPVWorld = @import("engine-rhi").ILPVWorld;

pub const LpvGridBuilder = struct {
    storage: *ChunkStorage,

    pub fn init(storage: *ChunkStorage) LpvGridBuilder {
        return .{ .storage = storage };
    }

    pub fn interface(self: *LpvGridBuilder) ILPVWorld {
        return .{ .ptr = self, .vtable = &VTABLE };
    }

    pub fn collectLights(self: *LpvGridBuilder, origin: Vec3, grid_size: u32, cell_size: f32, out: []GpuLight) usize {
        const grid_world_size = @as(f32, @floatFromInt(grid_size)) * cell_size;
        const min_x = origin.x;
        const min_y = origin.y;
        const min_z = origin.z;
        const max_x = min_x + grid_world_size;
        const max_y = min_y + grid_world_size;
        const max_z = min_z + grid_world_size;

        var emitted_lights: usize = 0;

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const chunk = &entry.value_ptr.*.chunk;
            const chunk_min_x = @as(f32, @floatFromInt(chunk.chunk_x * CHUNK_SIZE_X));
            const chunk_min_z = @as(f32, @floatFromInt(chunk.chunk_z * CHUNK_SIZE_Z));
            const chunk_max_x = chunk_min_x + @as(f32, @floatFromInt(CHUNK_SIZE_X));
            const chunk_max_z = chunk_min_z + @as(f32, @floatFromInt(CHUNK_SIZE_Z));

            if (chunk_max_x < min_x or chunk_min_x > max_x or chunk_max_z < min_z or chunk_min_z > max_z) continue;

            var y: u32 = 0;
            while (y < CHUNK_SIZE_Y) : (y += 1) {
                var z: u32 = 0;
                while (z < CHUNK_SIZE_Z) : (z += 1) {
                    var x: u32 = 0;
                    while (x < CHUNK_SIZE_X) : (x += 1) {
                        const block = chunk.getBlock(x, y, z);
                        if (block == .air) continue;

                        const def = block_registry.getBlockDefinition(block);
                        const r_u4 = def.light_emission[0];
                        const g_u4 = def.light_emission[1];
                        const b_u4 = def.light_emission[2];
                        if (r_u4 == 0 and g_u4 == 0 and b_u4 == 0) continue;

                        const world_x = chunk_min_x + @as(f32, @floatFromInt(x)) + 0.5;
                        const world_y = @as(f32, @floatFromInt(y)) + 0.5;
                        const world_z = chunk_min_z + @as(f32, @floatFromInt(z)) + 0.5;
                        if (world_x < min_x or world_x >= max_x or world_y < min_y or world_y >= max_y or world_z < min_z or world_z >= max_z) continue;

                        const emission_r = @as(f32, @floatFromInt(r_u4)) / 15.0;
                        const emission_g = @as(f32, @floatFromInt(g_u4)) / 15.0;
                        const emission_b = @as(f32, @floatFromInt(b_u4)) / 15.0;
                        const max_emission = @max(emission_r, @max(emission_g, emission_b));

                        out[emitted_lights] = .{
                            .pos_radius = .{ world_x, world_y, world_z, @max(1.0, max_emission * 6.0) },
                            .color = .{ emission_r, emission_g, emission_b, 1.0 },
                        };
                        emitted_lights += 1;
                        if (emitted_lights >= out.len) return emitted_lights;
                    }
                }
            }
        }
        return emitted_lights;
    }

    pub fn buildOcclusionGrid(self: *LpvGridBuilder, origin: Vec3, grid_size: u32, cell_size: f32, out: []u32) void {
        const gs = @as(usize, grid_size);
        const grid_world_size = @as(f32, @floatFromInt(grid_size)) * cell_size;
        const min_x = origin.x;
        const min_y = origin.y;
        const min_z = origin.z;
        const max_x = min_x + grid_world_size;
        const max_z = min_z + grid_world_size;

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const chunk = &entry.value_ptr.*.chunk;
            const chunk_min_x = @as(f32, @floatFromInt(chunk.chunk_x * CHUNK_SIZE_X));
            const chunk_min_z = @as(f32, @floatFromInt(chunk.chunk_z * CHUNK_SIZE_Z));
            const chunk_max_x = chunk_min_x + @as(f32, @floatFromInt(CHUNK_SIZE_X));
            const chunk_max_z = chunk_min_z + @as(f32, @floatFromInt(CHUNK_SIZE_Z));

            if (chunk_max_x < min_x or chunk_min_x > max_x or chunk_max_z < min_z or chunk_min_z > max_z) continue;

            var y: u32 = 0;
            while (y < CHUNK_SIZE_Y) : (y += 1) {
                const world_y = @as(f32, @floatFromInt(y)) + 0.5;
                if (world_y < min_y or world_y >= min_y + grid_world_size) continue;

                var z: u32 = 0;
                while (z < CHUNK_SIZE_Z) : (z += 1) {
                    var x: u32 = 0;
                    while (x < CHUNK_SIZE_X) : (x += 1) {
                        const block = chunk.getBlock(x, y, z);
                        if (block == .air) continue;
                        if (!block_registry.getBlockDefinition(block).isOpaque()) continue;

                        const world_x = chunk_min_x + @as(f32, @floatFromInt(x)) + 0.5;
                        const world_z = chunk_min_z + @as(f32, @floatFromInt(z)) + 0.5;
                        const gx = @as(i32, @intFromFloat(@floor((world_x - origin.x) / cell_size)));
                        const gy = @as(i32, @intFromFloat(@floor((world_y - origin.y) / cell_size)));
                        const gz = @as(i32, @intFromFloat(@floor((world_z - origin.z) / cell_size)));
                        if (gx < 0 or gy < 0 or gz < 0) continue;
                        const ugx = @as(usize, @intCast(gx));
                        const ugy = @as(usize, @intCast(gy));
                        const ugz = @as(usize, @intCast(gz));
                        if (ugx >= gs or ugy >= gs or ugz >= gs) continue;
                        out[ugx + ugy * gs + ugz * gs * gs] = 1;
                    }
                }
            }
        }
    }

    const VTABLE = ILPVWorld.VTable{
        .collectLights = collectLightsWrapper,
        .buildOcclusionGrid = buildOcclusionGridWrapper,
    };

    fn collectLightsWrapper(ptr: *anyopaque, origin: Vec3, grid_size: u32, cell_size: f32, out: []GpuLight) usize {
        const self: *LpvGridBuilder = @ptrCast(@alignCast(ptr));
        return self.collectLights(origin, grid_size, cell_size, out);
    }

    fn buildOcclusionGridWrapper(ptr: *anyopaque, origin: Vec3, grid_size: u32, cell_size: f32, out: []u32) void {
        const self: *LpvGridBuilder = @ptrCast(@alignCast(ptr));
        self.buildOcclusionGrid(origin, grid_size, cell_size, out);
    }
};
