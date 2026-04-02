//! World renderer - handles chunk rendering, culling, and MDI.
//! Integrates GPU compute frustum culling (CullingSystem) with CPU fallback.

const std = @import("std");
const log = @import("../engine/core/log.zig");
const ChunkData = @import("chunk_storage.zig").ChunkData;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const worldToChunk = @import("chunk.zig").worldToChunk;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const CHUNK_SIZE_Y = @import("chunk.zig").CHUNK_SIZE_Y;
const GlobalVertexAllocator = @import("chunk_allocator.zig").GlobalVertexAllocator;
const rhi_mod = @import("../engine/graphics/rhi.zig");
const ResourceManager = rhi_mod.ResourceManager;
const RenderContext = rhi_mod.RenderContext;
const IDeviceQuery = rhi_mod.IDeviceQuery;
const LODManager = @import("lod_manager.zig").LODManager;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const CullingSystem = @import("../engine/graphics/vulkan/culling_system.zig").CullingSystem;
const ChunkCullData = @import("../engine/graphics/vulkan/culling_system.zig").ChunkCullData;

const MAX_MDI_CHUNKS: usize = 16384;

pub const RenderStats = struct {
    chunks_total: u32 = 0,
    chunks_rendered: u32 = 0,
    chunks_culled: u32 = 0,
    vertices_rendered: u64 = 0,
    gpu_culling: bool = false,
};

pub const ShadowStats = struct {
    chunks_rendered: u32 = 0,
    chunks_culled: u32 = 0,
};

pub const WorldRenderer = struct {
    allocator: std.mem.Allocator,
    storage: *ChunkStorage,
    rm: ResourceManager,
    render_ctx: RenderContext,
    query: IDeviceQuery,

    vertex_allocator: *GlobalVertexAllocator,
    visible_chunks: std.ArrayListUnmanaged(*ChunkData),
    last_render_stats: RenderStats,
    last_shadow_stats: ShadowStats,

    // MDI Resources
    instance_data: std.ArrayListUnmanaged(rhi_mod.InstanceData),
    draw_commands: std.ArrayListUnmanaged(rhi_mod.DrawIndirectCommand),
    instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle,
    indirect_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle,

    // GPU Culling
    culling_system: ?*CullingSystem,
    aabb_data: std.ArrayListUnmanaged(ChunkCullData),
    chunk_lookup: std.ArrayListUnmanaged(*ChunkData),
    gpu_visible_indices: std.ArrayListUnmanaged(u32),
    use_gpu_culling: bool,

    pub fn init(allocator: std.mem.Allocator, rm: ResourceManager, render_ctx: RenderContext, query: IDeviceQuery, storage: *ChunkStorage, rhi: rhi_mod.RHI) !*WorldRenderer {
        const renderer = try allocator.create(WorldRenderer);

        const safe_mode_env = std.posix.getenv("ZIGCRAFT_SAFE_MODE");
        const safe_mode = if (safe_mode_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;
        const vertex_capacity_mb: usize = if (safe_mode) 1024 else 2048;

        if (safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: GlobalVertexAllocator reduced to {}MB", .{vertex_capacity_mb});
        }

        const vertex_allocator = try allocator.create(GlobalVertexAllocator);
        vertex_allocator.* = try GlobalVertexAllocator.init(allocator, rm, query, vertex_capacity_mb);

        const max_chunks = MAX_MDI_CHUNKS;
        var instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        var indirect_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            instance_buffers[i] = try rm.createBuffer(max_chunks * @sizeOf(rhi_mod.InstanceData), .storage);
            indirect_buffers[i] = try rm.createBuffer(max_chunks * @sizeOf(rhi_mod.DrawIndirectCommand) * 3, .indirect);
        }

        var culling_system: ?*CullingSystem = null;
        var use_gpu = false;
        if (CullingSystem.init(allocator, rhi, max_chunks)) |cs| {
            culling_system = cs;
            use_gpu = true;
            log.log.info("GPU frustum culling initialized (max_chunks={})", .{max_chunks});
        } else |_| {
            log.log.warn("GPU culling init failed, falling back to CPU culling", .{});
        }

        renderer.* = .{
            .allocator = allocator,
            .storage = storage,
            .rm = rm,
            .render_ctx = render_ctx,
            .query = query,
            .vertex_allocator = vertex_allocator,
            .visible_chunks = .empty,
            .last_render_stats = .{},
            .last_shadow_stats = .{},
            .instance_data = .empty,
            .draw_commands = .empty,
            .instance_buffers = instance_buffers,
            .indirect_buffers = indirect_buffers,
            .culling_system = culling_system,
            .aabb_data = .empty,
            .chunk_lookup = .empty,
            .gpu_visible_indices = .empty,
            .use_gpu_culling = use_gpu,
        };

        return renderer;
    }

    pub fn beginFrame(self: *WorldRenderer) void {
        self.resetShadowStats();
        self.vertex_allocator.tick(self.query.getFrameIndex());
    }

    pub fn resetShadowStats(self: *WorldRenderer) void {
        self.last_shadow_stats = .{};
    }

    pub fn deinit(self: *WorldRenderer) void {
        self.visible_chunks.deinit(self.allocator);
        self.aabb_data.deinit(self.allocator);
        self.chunk_lookup.deinit(self.allocator);
        self.gpu_visible_indices.deinit(self.allocator);

        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.instance_buffers[i] != 0) self.rm.destroyBuffer(self.instance_buffers[i]);
            if (self.indirect_buffers[i] != 0) self.rm.destroyBuffer(self.indirect_buffers[i]);
        }
        self.instance_data.deinit(self.allocator);
        self.draw_commands.deinit(self.allocator);

        if (self.culling_system) |cs| cs.deinit();

        self.vertex_allocator.deinit();
        self.allocator.destroy(self.vertex_allocator);
        self.allocator.destroy(self);
    }

    pub fn render(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, render_distance: i32, lod_manager: ?*LODManager, render_lod: bool) void {
        self.last_render_stats = .{ .gpu_culling = self.use_gpu_culling };

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        if (render_lod) {
            if (lod_manager) |lod_mgr| {
                lod_mgr.render(view_proj, camera_pos, ChunkStorage.isChunkRenderable, @ptrCast(self.storage), true, null);
            }
        }

        self.visible_chunks.clearRetainingCapacity();
        self.instance_data.clearRetainingCapacity();
        self.draw_commands.clearRetainingCapacity();

        if (!std.math.isFinite(camera_pos.x) or !std.math.isFinite(camera_pos.z)) return;

        const world_x: i64 = @intFromFloat(camera_pos.x);
        const world_z: i64 = @intFromFloat(camera_pos.z);
        const pc_x = @divFloor(world_x, CHUNK_SIZE_X);
        const pc_z = @divFloor(world_z, CHUNK_SIZE_Z);

        const r_dist_val: i32 = if (lod_manager) |mgr| @min(render_distance, @as(i32, @intCast(mgr.config.getRadii()[0]))) else render_distance;
        const r_dist: i64 = @as(i64, @intCast(r_dist_val));

        if (self.use_gpu_culling) {
            self.renderGpuCull(view_proj, camera_pos, pc_x, pc_z, r_dist);
        } else {
            self.renderCpuCull(view_proj, camera_pos, pc_x, pc_z, r_dist);
        }

        self.last_render_stats.chunks_total = @intCast(self.storage.chunks.count());

        const vertex_size = @sizeOf(rhi_mod.Vertex);

        for (self.visible_chunks.items) |data| {
            self.last_render_stats.chunks_rendered += 1;
            const chunk_world_x: f32 = @floatFromInt(data.chunk.chunk_x * CHUNK_SIZE_X);
            const chunk_world_z: f32 = @floatFromInt(data.chunk.chunk_z * CHUNK_SIZE_Z);
            const rel_x = chunk_world_x - camera_pos.x;
            const rel_z = chunk_world_z - camera_pos.z;
            const rel_y = -camera_pos.y;
            const model = Mat4.translate(Vec3.init(rel_x, rel_y, rel_z));

            const instance_idx: u32 = @intCast(self.instance_data.items.len);

            self.instance_data.append(self.allocator, .{
                .model = model,
                .mask_radius = 0,
                .padding = .{ 0, 0, 0 },
            }) catch |err| {
                log.log.debug("MDI: instance append failed: {}", .{err});
                continue;
            };

            if (data.mesh.solid_allocation) |alloc| {
                self.last_render_stats.vertices_rendered += alloc.count;
                self.draw_commands.append(self.allocator, .{
                    .vertexCount = alloc.count,
                    .instanceCount = 1,
                    .firstVertex = @intCast(alloc.offset / vertex_size),
                    .firstInstance = instance_idx,
                }) catch |err| log.log.debug("MDI: solid cmd append failed: {}", .{err});
            }
            if (data.mesh.cutout_allocation) |alloc| {
                self.last_render_stats.vertices_rendered += alloc.count;
                self.draw_commands.append(self.allocator, .{
                    .vertexCount = alloc.count,
                    .instanceCount = 1,
                    .firstVertex = @intCast(alloc.offset / vertex_size),
                    .firstInstance = instance_idx,
                }) catch |err| log.log.debug("MDI: cutout cmd append failed: {}", .{err});
            }
            if (data.mesh.fluid_allocation) |alloc| {
                self.last_render_stats.vertices_rendered += alloc.count;
                self.draw_commands.append(self.allocator, .{
                    .vertexCount = alloc.count,
                    .instanceCount = 1,
                    .firstVertex = @intCast(alloc.offset / vertex_size),
                    .firstInstance = instance_idx,
                }) catch |err| log.log.debug("MDI: fluid cmd append failed: {}", .{err});
            }
        }

        if (self.instance_data.items.len > 0 and self.draw_commands.items.len > 0) {
            const fi = self.query.getFrameIndex();

            const max_instances: usize = MAX_MDI_CHUNKS;
            const max_commands: usize = MAX_MDI_CHUNKS * 3;

            if (self.instance_data.items.len > max_instances) {
                log.log.warn("MDI: instance overflow ({} > {}), truncating", .{ self.instance_data.items.len, max_instances });
                self.instance_data.shrinkRetainingCapacity(max_instances);
            }
            if (self.draw_commands.items.len > max_commands) {
                log.log.warn("MDI: command overflow ({} > {}), truncating", .{ self.draw_commands.items.len, max_commands });
                self.draw_commands.shrinkRetainingCapacity(max_commands);
            }

            const instance_bytes = std.mem.sliceAsBytes(self.instance_data.items);
            self.rm.updateBuffer(self.instance_buffers[fi], 0, instance_bytes) catch |err| {
                log.log.err("MDI: failed to update instance buffer: {}", .{err});
                return;
            };

            const cmd_bytes = std.mem.sliceAsBytes(self.draw_commands.items);
            self.rm.updateBuffer(self.indirect_buffers[fi], 0, cmd_bytes) catch |err| {
                log.log.err("MDI: failed to update indirect buffer: {}", .{err});
                return;
            };

            self.render_ctx.setInstanceBuffer(self.instance_buffers[fi]);

            self.render_ctx.drawIndirect(
                self.vertex_allocator.buffer,
                self.indirect_buffers[fi],
                0,
                @intCast(self.draw_commands.items.len),
                @sizeOf(rhi_mod.DrawIndirectCommand),
            );
        }
    }

    fn renderCpuCull(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, pc_x: i64, pc_z: i64, r_dist: i64) void {
        const frustum = Frustum.fromViewProj(view_proj);

        var cz = pc_z - r_dist;
        while (cz <= pc_z + r_dist) : (cz += 1) {
            var cx = pc_x - r_dist;
            while (cx <= pc_x + r_dist) : (cx += 1) {
                if (self.storage.chunks.get(.{ .x = @as(i32, @intCast(cx)), .z = @as(i32, @intCast(cz)) })) |data| {
                    if (data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.cutout_allocation != null or data.mesh.fluid_allocation != null) {
                        if (frustum.intersectsChunkRelative(@as(i32, @intCast(cx)), @as(i32, @intCast(cz)), camera_pos.x, camera_pos.y, camera_pos.z)) {
                            self.visible_chunks.append(self.allocator, data) catch |err| {
                                log.log.debug("MDI: visible_chunks append failed: {}", .{err});
                            };
                        } else {
                            self.last_render_stats.chunks_culled += 1;
                        }
                    }
                }
            }
        }
    }

    fn renderGpuCull(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, pc_x: i64, pc_z: i64, r_dist: i64) void {
        const cs = self.culling_system orelse unreachable;

        self.aabb_data.clearRetainingCapacity();
        self.chunk_lookup.clearRetainingCapacity();

        var cz = pc_z - r_dist;
        while (cz <= pc_z + r_dist) : (cz += 1) {
            var cx = pc_x - r_dist;
            while (cx <= pc_x + r_dist) : (cx += 1) {
                if (self.storage.chunks.get(.{ .x = @as(i32, @intCast(cx)), .z = @as(i32, @intCast(cz)) })) |data| {
                    if (data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.cutout_allocation != null or data.mesh.fluid_allocation != null) {
                        const chunk_world_x: f32 = @floatFromInt(data.chunk.chunk_x * CHUNK_SIZE_X);
                        const chunk_world_z: f32 = @floatFromInt(data.chunk.chunk_z * CHUNK_SIZE_Z);

                        self.aabb_data.append(self.allocator, .{
                            .min_point = .{ chunk_world_x - camera_pos.x, -camera_pos.y, chunk_world_z - camera_pos.z, 0.0 },
                            .max_point = .{ chunk_world_x - camera_pos.x + @as(f32, @floatFromInt(CHUNK_SIZE_X)), -camera_pos.y + @as(f32, @floatFromInt(CHUNK_SIZE_Y)), chunk_world_z - camera_pos.z + @as(f32, @floatFromInt(CHUNK_SIZE_Z)), 0.0 },
                        }) catch continue;
                        self.chunk_lookup.append(self.allocator, data) catch continue;
                    }
                }
            }
        }

        const chunk_count: u32 = @intCast(self.aabb_data.items.len);
        if (chunk_count == 0) return;

        const fi = self.query.getFrameIndex();
        cs.updateAABBData(fi, self.aabb_data.items);
        cs.dispatch(view_proj, chunk_count);

        const visible_count = cs.readVisibleCount(fi);
        self.gpu_visible_indices.clearRetainingCapacity();
        if (visible_count > 0) {
            self.gpu_visible_indices.resize(self.allocator, visible_count) catch return;
            cs.readVisibleIndices(fi, visible_count, self.gpu_visible_indices.items);

            for (self.gpu_visible_indices.items[0..@min(@as(usize, @intCast(visible_count)), self.gpu_visible_indices.items.len)]) |idx| {
                if (idx < self.chunk_lookup.items.len) {
                    self.visible_chunks.append(self.allocator, self.chunk_lookup.items[idx]) catch continue;
                }
            }
        }

        self.last_render_stats.chunks_culled += @intCast(chunk_count - @min(@as(u32, @intCast(self.visible_chunks.items.len)), chunk_count));
    }

    pub fn renderShadowPass(self: *WorldRenderer, light_space_matrix: Mat4, camera_pos: Vec3, shadow_caster_distance: f32) void {
        const frustum = Frustum.fromViewProj(light_space_matrix);

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        if (!std.math.isFinite(camera_pos.x) or !std.math.isFinite(camera_pos.z)) return;

        const world_x: i64 = @intFromFloat(camera_pos.x);
        const world_z: i64 = @intFromFloat(camera_pos.z);
        const pc_x = @divFloor(world_x, CHUNK_SIZE_X);
        const pc_z = @divFloor(world_z, CHUNK_SIZE_Z);

        const r_dist: i64 = @as(i64, @intFromFloat(shadow_caster_distance / CHUNK_SIZE_X));

        var cz = pc_z - r_dist;
        while (cz <= pc_z + r_dist) : (cz += 1) {
            var cx = pc_x - r_dist;
            while (cx <= pc_x + r_dist) : (cx += 1) {
                if (self.storage.chunks.get(.{ .x = @as(i32, @intCast(cx)), .z = @as(i32, @intCast(cz)) })) |data| {
                    if (data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.cutout_allocation != null or data.mesh.fluid_allocation != null) {
                        const chunk_world_x: f32 = @floatFromInt(data.chunk.chunk_x * CHUNK_SIZE_X);
                        const chunk_world_z: f32 = @floatFromInt(data.chunk.chunk_z * CHUNK_SIZE_Z);

                        if (!frustum.intersectsChunkRelative(@as(i32, @intCast(cx)), @as(i32, @intCast(cz)), camera_pos.x, camera_pos.y, camera_pos.z)) {
                            self.last_shadow_stats.chunks_culled += 1;
                            continue;
                        }

                        self.last_shadow_stats.chunks_rendered += 1;

                        const rel_x = chunk_world_x - camera_pos.x;
                        const rel_z = chunk_world_z - camera_pos.z;
                        const rel_y = -camera_pos.y;
                        const model = Mat4.translate(Vec3.init(rel_x, rel_y, rel_z));

                        if (data.mesh.solid_allocation) |alloc| {
                            self.render_ctx.setModelMatrix(model, Vec3.one, 0);

                            self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                        }
                        if (data.mesh.cutout_allocation) |alloc| {
                            self.render_ctx.setModelMatrix(model, Vec3.one, 0);
                            self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                        }
                    }
                }
            }
        }
    }
};
