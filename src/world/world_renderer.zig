//! World renderer - handles chunk rendering, culling, and MDI.

const std = @import("std");
const log = @import("../engine/core/log.zig");
const ChunkData = @import("chunk_storage.zig").ChunkData;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const worldToChunk = @import("chunk.zig").worldToChunk;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const GlobalVertexAllocator = @import("chunk_allocator.zig").GlobalVertexAllocator;
const rhi_mod = @import("../engine/graphics/rhi.zig");
const ResourceManager = rhi_mod.ResourceManager;
const RenderContext = rhi_mod.RenderContext;
const IDeviceQuery = rhi_mod.IDeviceQuery;
const LODManager = @import("lod_manager.zig").LODManager;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;

pub const RenderStats = struct {
    chunks_total: u32 = 0,
    chunks_rendered: u32 = 0,
    chunks_culled: u32 = 0,
    vertices_rendered: u64 = 0,
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
    solid_commands: std.ArrayListUnmanaged(rhi_mod.DrawIndirectCommand),
    fluid_commands: std.ArrayListUnmanaged(rhi_mod.DrawIndirectCommand),
    instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle,
    indirect_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle,
    frame_index: usize,
    mdi_instance_offset: usize,
    mdi_command_offset: usize,

    pub fn init(allocator: std.mem.Allocator, rm: ResourceManager, render_ctx: RenderContext, query: IDeviceQuery, storage: *ChunkStorage) !*WorldRenderer {
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

        const max_chunks = 16384;
        var instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        var indirect_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            instance_buffers[i] = try rm.createBuffer(max_chunks * @sizeOf(rhi_mod.InstanceData), .storage);
            indirect_buffers[i] = try rm.createBuffer(max_chunks * @sizeOf(rhi_mod.DrawIndirectCommand) * 2, .indirect);
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
            .solid_commands = .empty,
            .fluid_commands = .empty,
            .instance_buffers = instance_buffers,
            .indirect_buffers = indirect_buffers,
            .frame_index = 0,
            .mdi_instance_offset = 0,
            .mdi_command_offset = 0,
        };

        return renderer;
    }

    pub fn beginFrame(self: *WorldRenderer) void {
        self.resetShadowStats();
        self.vertex_allocator.tick(self.query.getFrameIndex());
    }

    /// Reset shadow statistics before a new frame begins.
    ///
    /// `last_shadow_stats` then accumulates across all shadow passes in that frame.
    /// If per-cascade statistics are needed, call this before each shadow pass.
    pub fn resetShadowStats(self: *WorldRenderer) void {
        self.last_shadow_stats = .{};
    }

    pub fn deinit(self: *WorldRenderer) void {
        self.visible_chunks.deinit(self.allocator);

        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.instance_buffers[i] != 0) self.rm.destroyBuffer(self.instance_buffers[i]);
            if (self.indirect_buffers[i] != 0) self.rm.destroyBuffer(self.indirect_buffers[i]);
        }
        self.instance_data.deinit(self.allocator);
        self.solid_commands.deinit(self.allocator);
        self.fluid_commands.deinit(self.allocator);

        self.vertex_allocator.deinit();
        self.allocator.destroy(self.vertex_allocator);
        self.allocator.destroy(self);
    }

    pub fn render(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, render_distance: i32, lod_manager: ?*LODManager, render_lod: bool) void {
        self.last_render_stats = .{};

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        if (render_lod) {
            if (lod_manager) |lod_mgr| {
                lod_mgr.render(view_proj, camera_pos, ChunkStorage.isChunkRenderable, @ptrCast(self.storage), true, null);
            }
        }

        self.visible_chunks.clearRetainingCapacity();

        const frustum = Frustum.fromViewProj(view_proj);

        // Safety: Check for NaN/Inf camera position
        if (!std.math.isFinite(camera_pos.x) or !std.math.isFinite(camera_pos.z)) return;

        // Use i64 for calculations to avoid overflow
        const world_x: i64 = @intFromFloat(camera_pos.x);
        const world_z: i64 = @intFromFloat(camera_pos.z);
        const pc_x = @divFloor(world_x, CHUNK_SIZE_X);
        const pc_z = @divFloor(world_z, CHUNK_SIZE_Z);

        const r_dist_val: i32 = if (lod_manager) |mgr| @min(render_distance, @as(i32, @intCast(mgr.config.getRadii()[0]))) else render_distance;
        const r_dist: i64 = @as(i64, @intCast(r_dist_val));

        var cz = pc_z - r_dist;
        while (cz <= pc_z + r_dist) : (cz += 1) {
            var cx = pc_x - r_dist;
            while (cx <= pc_x + r_dist) : (cx += 1) {
                if (self.storage.chunks.get(.{ .x = @as(i32, @intCast(cx)), .z = @as(i32, @intCast(cz)) })) |data| {
                    if (data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.cutout_allocation != null or data.mesh.fluid_allocation != null) {
                        if (frustum.intersectsChunkRelative(@as(i32, @intCast(cx)), @as(i32, @intCast(cz)), camera_pos.x, camera_pos.y, camera_pos.z)) {
                            self.visible_chunks.append(self.allocator, data) catch {};
                        } else {
                            self.last_render_stats.chunks_culled += 1;
                        }
                    }
                }
            }
        }

        self.last_render_stats.chunks_total = @intCast(self.storage.chunks.count());

        for (self.visible_chunks.items) |data| {
            self.last_render_stats.chunks_rendered += 1;
            const chunk_world_x: f32 = @floatFromInt(data.chunk.chunk_x * CHUNK_SIZE_X);
            const chunk_world_z: f32 = @floatFromInt(data.chunk.chunk_z * CHUNK_SIZE_Z);
            const rel_x = chunk_world_x - camera_pos.x;
            const rel_z = chunk_world_z - camera_pos.z;
            const rel_y = -camera_pos.y;
            const model = Mat4.translate(Vec3.init(rel_x, rel_y, rel_z));

            self.render_ctx.setModelMatrix(model, Vec3.one, 0);

            if (data.mesh.solid_allocation) |alloc| {
                self.last_render_stats.vertices_rendered += alloc.count;
                self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
            }
            if (data.mesh.cutout_allocation) |alloc| {
                self.last_render_stats.vertices_rendered += alloc.count;
                self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
            }
            if (data.mesh.fluid_allocation) |alloc| {
                self.last_render_stats.vertices_rendered += alloc.count;
                self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
            }
        }

        self.mdi_instance_offset = 0;
        self.mdi_command_offset = 0;
    }

    /// Intentionally excludes visual LOD meshes to prevent LOD offset/morphing
    /// artifacts from corrupting shadow maps. Only real chunk geometry is rendered.
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

        self.mdi_instance_offset = 0;
        self.mdi_command_offset = 0;
    }
};
