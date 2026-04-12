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
const VulkanContext = @import("../engine/graphics/vulkan/rhi_context_types.zig").VulkanContext;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const GpuBlockBuffer = @import("gpu_block_buffer.zig").GpuBlockBuffer;
const GpuMesher = @import("gpu_mesher.zig").GpuMesher;

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

pub const RenderLayer = enum {
    all,
    terrain,
    fluid,
};

pub const WorldRenderer = struct {
    allocator: std.mem.Allocator,
    storage: *ChunkStorage,
    rm: ResourceManager,
    render_ctx: RenderContext,
    query: IDeviceQuery,
    vk_ctx: *VulkanContext,

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
    chunk_lookup: [rhi_mod.MAX_FRAMES_IN_FLIGHT]std.ArrayListUnmanaged(*ChunkData),
    gpu_visible_indices: std.ArrayListUnmanaged(u32),
    use_gpu_culling: bool,

    // GPU Block Buffer (Batch 5 - Issue #389)
    gpu_block_buffer: ?*GpuBlockBuffer,

    // GPU Mesher (Batch 6 - Issue #391)
    gpu_mesher: ?*GpuMesher,

    pub fn init(allocator: std.mem.Allocator, rm: ResourceManager, render_ctx: RenderContext, query: IDeviceQuery, storage: *ChunkStorage, atlas: *const TextureAtlas, rhi: rhi_mod.RHI) !*WorldRenderer {
        const renderer = try allocator.create(WorldRenderer);

        const safe_mode_env = std.posix.getenv("ZIGCRAFT_SAFE_MODE");
        const safe_mode = if (safe_mode_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        const vram_bytes = query.getDeviceLocalVramBytes();
        const vram_mb = vram_bytes / (1024 * 1024);
        const MB: usize = 1024 * 1024;

        const vertex_capacity_mb: usize = if (safe_mode)
            @min(512, @divFloor(vram_mb, 4))
        else blk: {
            const budget_mb = if (vram_mb >= 8192) @as(usize, 2048) else if (vram_mb >= 6144) @as(usize, 1024) else if (vram_mb >= 4096) @as(usize, 512) else @as(usize, 256);
            break :blk budget_mb;
        };

        const gpu_block_capacity: usize = blk: {
            const slot_size = 16 * 16 * 256;
            const block_budget_mb = if (vram_mb >= 8192) @as(usize, 16384) else if (vram_mb >= 6144) @as(usize, 8192) else if (vram_mb >= 4096) @as(usize, 4096) else @as(usize, 2048);
            const budget_bytes = block_budget_mb * MB;
            const max_by_budget = budget_bytes / slot_size;
            break :blk @min(MAX_MDI_CHUNKS, max_by_budget);
        };

        log.log.info("VRAM budget: {}MB | vertex_allocator: {}MB | gpu_block_buffer: {} slots", .{ vram_mb, vertex_capacity_mb, gpu_block_capacity });

        if (safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: reduced GPU buffer sizes", .{});
        }

        const vertex_allocator = try allocator.create(GlobalVertexAllocator);
        vertex_allocator.* = try GlobalVertexAllocator.init(allocator, rm, query, vertex_capacity_mb);

        const vk_ctx: *VulkanContext = @ptrCast(@alignCast(rhi.ptr));

        const safe_mode_enabled = vk_ctx.options.safe_mode;

        const max_chunks = MAX_MDI_CHUNKS;
        var instance_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        var indirect_buffers: [rhi_mod.MAX_FRAMES_IN_FLIGHT]rhi_mod.BufferHandle = undefined;
        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            instance_buffers[i] = try rm.createBuffer(max_chunks * @sizeOf(rhi_mod.InstanceData), .storage);
            indirect_buffers[i] = try rm.createBuffer(max_chunks * @sizeOf(rhi_mod.DrawIndirectCommand) * 3, .indirect);
        }

        var culling_system: ?*CullingSystem = null;
        const use_gpu = false;
        if (!safe_mode_enabled) {
            if (CullingSystem.init(allocator, rhi, max_chunks)) |cs| {
                culling_system = cs;
                log.log.warn("GPU chunk culling initialized but kept disabled due unstable visibility", .{});
            } else |err| {
                log.log.warn("GPU culling init failed ({}), falling back to CPU culling", .{err});
            }
        } else {
            log.log.info("Safe mode: GPU frustum culling disabled, using CPU culling", .{});
        }

        var gpu_block_buffer: ?*GpuBlockBuffer = null;
        errdefer if (gpu_block_buffer) |buf| buf.deinit();
        gpu_block_buffer = try GpuBlockBuffer.init(allocator, rm, gpu_block_capacity);
        log.log.info("GpuBlockBuffer initialized (capacity={})", .{gpu_block_capacity});

        var gpu_mesher: ?*GpuMesher = null;
        errdefer if (gpu_mesher) |m| m.deinit();
        if (!safe_mode_enabled) {
            if (gpu_block_buffer) |buf| {
                gpu_mesher = GpuMesher.init(allocator, rhi, atlas, buf) catch |err| blk: {
                    log.log.warn("GpuMesher init failed ({}), CPU meshing fallback active", .{err});
                    break :blk null;
                };
            }
        } else {
            log.log.info("Safe mode: GPU meshing disabled, using CPU meshing fallback", .{});
        }

        renderer.* = .{
            .allocator = allocator,
            .storage = storage,
            .rm = rm,
            .render_ctx = render_ctx,
            .query = query,
            .vk_ctx = vk_ctx,
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
            .chunk_lookup = undefined,
            .gpu_visible_indices = .empty,
            .use_gpu_culling = use_gpu,
            .gpu_block_buffer = gpu_block_buffer,
            .gpu_mesher = gpu_mesher,
        };

        for (&renderer.chunk_lookup) |*lookup| lookup.* = .empty;

        return renderer;
    }

    pub fn beginFrame(self: *WorldRenderer) void {
        self.resetShadowStats();
        self.vertex_allocator.tick(self.query.getFrameIndex());
    }

    pub fn resetShadowStats(self: *WorldRenderer) void {
        self.last_shadow_stats = .{ .chunks_rendered = 0, .chunks_culled = 0 };
    }

    pub fn getGpuBlockBuffer(self: *WorldRenderer) ?*GpuBlockBuffer {
        return self.gpu_block_buffer;
    }

    pub fn getGpuMesher(self: *WorldRenderer) ?*GpuMesher {
        return self.gpu_mesher;
    }

    pub fn processGpuMeshing(ctx: *anyopaque) void {
        const self: *WorldRenderer = @ptrCast(@alignCast(ctx));
        if (self.gpu_mesher) |mesher| {
            if (self.gpu_block_buffer) |buf| {
                mesher.process(self.vertex_allocator, self.storage, buf);
            }
        }
    }

    pub fn deinit(self: *WorldRenderer) void {
        self.visible_chunks.deinit(self.allocator);
        self.aabb_data.deinit(self.allocator);
        for (&self.chunk_lookup) |*lookup| lookup.deinit(self.allocator);
        self.gpu_visible_indices.deinit(self.allocator);

        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.instance_buffers[i] != 0) self.rm.destroyBuffer(self.instance_buffers[i]);
            if (self.indirect_buffers[i] != 0) self.rm.destroyBuffer(self.indirect_buffers[i]);
        }
        self.instance_data.deinit(self.allocator);
        self.draw_commands.deinit(self.allocator);

        if (self.culling_system) |cs| cs.deinit();

        if (self.gpu_block_buffer) |buf| buf.deinit();

        if (self.gpu_mesher) |mesher| mesher.deinit();

        self.vertex_allocator.deinit();
        self.allocator.destroy(self.vertex_allocator);
        self.allocator.destroy(self);
    }

    pub fn render(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, render_distance: i32, lod_manager: ?*LODManager, render_lod: bool, layer: RenderLayer) void {
        self.last_render_stats = .{ .gpu_culling = self.use_gpu_culling };

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        if (render_lod) {
            if (lod_manager) |lod_mgr| {
                lod_mgr.render(view_proj, camera_pos, ChunkStorage.isChunkRenderable, @ptrCast(self.storage), true, null);
            }
        }

        // LOD rendering uses a separate descriptor set path; switch back before drawing full chunks.
        self.render_ctx.setInstanceBuffer(0);

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
        const supports_indirect_first_instance = self.query.supportsIndirectFirstInstance();

        // Environment override to force MDI fallback for debugging
        const force_mdi_fallback = blk: {
            const env_val = std.posix.getenv("ZIGCRAFT_FORCE_MDI_FALLBACK");
            break :blk if (env_val) |val|
                !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
            else
                false;
        };
        var total_vertices: u64 = 0;

        for (self.visible_chunks.items) |data| {
            self.last_render_stats.chunks_rendered += 1;
            const chunk_world_x: f32 = @floatFromInt(data.chunk.chunk_x * CHUNK_SIZE_X);
            const chunk_world_z: f32 = @floatFromInt(data.chunk.chunk_z * CHUNK_SIZE_Z);
            const rel_x = chunk_world_x - camera_pos.x;
            const rel_z = chunk_world_z - camera_pos.z;
            const rel_y = -camera_pos.y;
            const model = Mat4.translate(Vec3.init(rel_x, rel_y, rel_z));

            if (!supports_indirect_first_instance or force_mdi_fallback) {
                self.render_ctx.setModelMatrix(model, Vec3.one, 0);

                if (layer != .fluid) {
                    if (data.mesh.solid_allocation) |alloc| {
                        total_vertices += alloc.count;
                        self.last_render_stats.vertices_rendered += alloc.count;
                        self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                    }
                    if (data.mesh.cutout_allocation) |alloc| {
                        self.last_render_stats.vertices_rendered += alloc.count;
                        self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                    }
                }
                if (layer != .terrain) {
                    if (data.mesh.fluid_allocation) |alloc| {
                        self.last_render_stats.vertices_rendered += alloc.count;
                        self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                    }
                }
                continue;
            }

            const instance_idx: u32 = @intCast(self.instance_data.items.len);

            self.instance_data.append(self.allocator, .{
                .model = model,
                .mask_radius = 0,
                .padding = .{ 0, 0, 0 },
            }) catch |err| {
                log.log.debug("MDI: instance append failed: {}", .{err});
                continue;
            };

            if (layer != .fluid) {
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
            }
            if (layer != .terrain) {
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

        var not_renderable: u32 = 0;
        var not_in_storage: u32 = 0;
        var missing_in_circle: u32 = 0;
        var missing_cx: i32 = 0;
        var missing_cz: i32 = 0;

        var cz = pc_z - r_dist;
        while (cz <= pc_z + r_dist) : (cz += 1) {
            var cx = pc_x - r_dist;
            while (cx <= pc_x + r_dist) : (cx += 1) {
                const dx = cx - pc_x;
                const dz = cz - pc_z;
                const dist_sq = dx * dx + dz * dz;
                if (self.storage.chunks.get(.{ .x = @as(i32, @intCast(cx)), .z = @as(i32, @intCast(cz)) })) |data| {
                    if (data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.cutout_allocation != null or data.mesh.fluid_allocation != null) {
                        if (!frustum.intersectsChunkRelative(@as(i32, @intCast(cx)), @as(i32, @intCast(cz)), camera_pos.x, camera_pos.y, camera_pos.z)) {
                            self.last_render_stats.chunks_culled += 1;
                            continue;
                        }
                        self.visible_chunks.append(self.allocator, data) catch {};
                    } else {
                        not_renderable += 1;
                        if (dist_sq <= r_dist * r_dist) {
                            missing_in_circle += 1;
                            missing_cx = @intCast(cx);
                            missing_cz = @intCast(cz);
                        }
                    }
                } else {
                    if (dist_sq <= r_dist * r_dist) {
                        missing_in_circle += 1;
                        missing_cx = @intCast(cx);
                        missing_cz = @intCast(cz);
                    }
                    not_in_storage += 1;
                }
            }
        }

        if (missing_in_circle > 0) {
            log.log.debug("CPU_CULL_GAP: missing_in_circle={} last_missing=({},{}) state={} pc=({},{}) rd={}", .{
                missing_in_circle,                                                                                                     missing_cx, missing_cz,
                if (self.storage.chunks.get(.{ .x = missing_cx, .z = missing_cz })) |d| @intFromEnum(d.chunk.state) else @as(u32, 99), pc_x,       pc_z,
                r_dist,
            });
        }
    }

    fn chunkAABB(chunk_x: i32, chunk_z: i32, camera_pos: Vec3) ChunkCullData {
        const world_x: f32 = @floatFromInt(chunk_x * CHUNK_SIZE_X);
        const world_z: f32 = @floatFromInt(chunk_z * CHUNK_SIZE_Z);
        return .{
            .min_point = .{ world_x - camera_pos.x, -camera_pos.y, world_z - camera_pos.z, 0.0 },
            .max_point = .{
                world_x - camera_pos.x + @as(f32, @floatFromInt(CHUNK_SIZE_X)),
                -camera_pos.y + @as(f32, @floatFromInt(CHUNK_SIZE_Y)),
                world_z - camera_pos.z + @as(f32, @floatFromInt(CHUNK_SIZE_Z)),
                0.0,
            },
        };
    }

    fn renderGpuCull(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, pc_x: i64, pc_z: i64, r_dist: i64) void {
        const cs = self.culling_system orelse {
            log.log.err("GPU culling enabled but system is null, falling back to CPU", .{});
            self.use_gpu_culling = false;
            return self.renderCpuCull(view_proj, camera_pos, pc_x, pc_z, r_dist);
        };

        const fi = self.query.getFrameIndex();
        const prev_fi = (fi + rhi_mod.MAX_FRAMES_IN_FLIGHT - 1) % rhi_mod.MAX_FRAMES_IN_FLIGHT;

        const prev_visible_count = cs.readVisibleCount(prev_fi);
        self.gpu_visible_indices.clearRetainingCapacity();
        if (prev_visible_count > 0) {
            self.gpu_visible_indices.resize(self.allocator, prev_visible_count) catch return;
            cs.readVisibleIndices(prev_fi, prev_visible_count, self.gpu_visible_indices.items);

            const limit = @min(@as(usize, @intCast(prev_visible_count)), self.gpu_visible_indices.items.len);
            for (self.gpu_visible_indices.items[0..limit]) |idx| {
                if (idx < self.chunk_lookup[prev_fi].items.len) {
                    self.visible_chunks.append(self.allocator, self.chunk_lookup[prev_fi].items[idx]) catch continue;
                }
            }
        }

        const prev_rendered: u32 = @intCast(self.visible_chunks.items.len);

        self.aabb_data.clearRetainingCapacity();
        self.chunk_lookup[fi].clearRetainingCapacity();

        var cz = pc_z - r_dist;
        while (cz <= pc_z + r_dist) : (cz += 1) {
            var cx = pc_x - r_dist;
            while (cx <= pc_x + r_dist) : (cx += 1) {
                if (self.storage.chunks.get(.{ .x = @as(i32, @intCast(cx)), .z = @as(i32, @intCast(cz)) })) |data| {
                    if (data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.cutout_allocation != null or data.mesh.fluid_allocation != null) {
                        self.aabb_data.append(self.allocator, chunkAABB(data.chunk.chunk_x, data.chunk.chunk_z, camera_pos)) catch continue;
                        self.chunk_lookup[fi].append(self.allocator, data) catch continue;
                    }
                }
            }
        }

        const chunk_count: u32 = @intCast(self.aabb_data.items.len);
        if (chunk_count == 0) return;

        self.last_render_stats.chunks_culled += chunk_count - @min(prev_rendered, chunk_count);

        cs.updateAABBData(fi, self.aabb_data.items);
        const screen_w = @as(f32, @floatFromInt(self.vk_ctx.gpass.g_pass_extent.width));
        const screen_h = @as(f32, @floatFromInt(self.vk_ctx.gpass.g_pass_extent.height));
        // The previous-frame depth pyramid is currently too unstable during camera
        // rotation and causes chunks to be wrongly occluded. Keep GPU frustum
        // culling, but disable temporal occlusion until the reprojection path is fixed.
        cs.dispatch(view_proj, chunk_count, screen_w, screen_h, false);
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
