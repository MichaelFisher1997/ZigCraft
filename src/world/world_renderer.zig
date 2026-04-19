const std = @import("std");
const log = @import("../engine/core/log.zig");
const ChunkData = @import("chunk_storage.zig").ChunkData;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const worldToChunkFromFloat = @import("chunk.zig").worldToChunkFromFloat;
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
const build_options = @import("build_options");
const runtime_env = @import("../engine/core/runtime_env.zig");

const MAX_MDI_CHUNKS: usize = 16384;

fn getenv(name: [:0]const u8) ?[]const u8 {
    return runtime_env.getenv(name);
}

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
    force_mdi_fallback: bool,

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

    // Diagnostic frame counter
    render_frame_count: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, rm: ResourceManager, render_ctx: RenderContext, query: IDeviceQuery, storage: *ChunkStorage, atlas: *const TextureAtlas, rhi: rhi_mod.RHI) !*WorldRenderer {
        const renderer = try allocator.create(WorldRenderer);

        const safe_mode = runtime_env.safeModeEnabled();
        const strict_safe_mode = runtime_env.strictSafeModeEnabled();

        const vram_bytes = query.getDeviceLocalVramBytes();
        const vram_mb = vram_bytes / (1024 * 1024);
        const MB: usize = 1024 * 1024;

        const vertex_capacity_mb: usize = if (strict_safe_mode)
            @min(@as(usize, 256), @max(@as(usize, 128), @divFloor(vram_mb, 8)))
        else blk: {
            const budget_mb = if (vram_mb >= 8192) @as(usize, 512) else if (vram_mb >= 6144) @as(usize, 384) else if (vram_mb >= 4096) @as(usize, 256) else @as(usize, 128);
            break :blk budget_mb;
        };

        const gpu_block_capacity: usize = blk: {
            const slot_size = 16 * 16 * 256;
            const block_budget_mb = if (vram_mb >= 8192) @as(usize, 512) else if (vram_mb >= 6144) @as(usize, 384) else if (vram_mb >= 4096) @as(usize, 256) else @as(usize, 128);
            const budget_bytes = block_budget_mb * MB;
            const max_by_budget = budget_bytes / slot_size;
            break :blk @min(MAX_MDI_CHUNKS, max_by_budget);
        };

        log.log.info("VRAM budget: {}MB | vertex_allocator: {}MB | gpu_block_buffer: {} slots", .{ vram_mb, vertex_capacity_mb, gpu_block_capacity });

        if (strict_safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: reduced GPU buffer sizes", .{});
        } else if (safe_mode) {
            log.log.warn("Wayland stability profile active: keeping normal GPU buffer budgets while using CPU chunk path", .{});
        }

        const vertex_allocator = try allocator.create(GlobalVertexAllocator);
        vertex_allocator.* = try GlobalVertexAllocator.init(allocator, rm, query, vertex_capacity_mb);

        const vk_ctx: *VulkanContext = @ptrCast(@alignCast(rhi.ptr));

        const safe_mode_enabled = vk_ctx.options.safe_mode;
        const gpu_meshing_env = getenv("ZIGCRAFT_ENABLE_GPU_MESHING");
        const gpu_meshing_enabled = if (gpu_meshing_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

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
        if (!safe_mode_enabled and gpu_meshing_enabled) {
            gpu_block_buffer = try GpuBlockBuffer.init(allocator, rm, gpu_block_capacity);
            log.log.info("GpuBlockBuffer initialized (capacity={})", .{gpu_block_capacity});
        }

        var gpu_mesher: ?*GpuMesher = null;
        errdefer if (gpu_mesher) |m| m.deinit();
        if (!safe_mode_enabled and gpu_meshing_enabled) {
            if (gpu_block_buffer) |buf| {
                gpu_mesher = GpuMesher.init(allocator, rhi, atlas, buf) catch |err| blk: {
                    log.log.warn("GpuMesher init failed ({}), CPU meshing fallback active", .{err});
                    break :blk null;
                };
            }
        } else if (!safe_mode_enabled) {
            log.log.warn("GPU meshing disabled by default due stale block-upload sync causing incorrect chunk texturing; set ZIGCRAFT_ENABLE_GPU_MESHING=1 to re-enable for testing", .{});
        } else {
            log.log.info("Safe mode: GPU meshing disabled, using CPU meshing fallback", .{});
        }

        const force_mdi_fallback = blk: {
            const env_val = getenv("ZIGCRAFT_FORCE_MDI_FALLBACK");
            break :blk if (env_val) |val|
                !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
            else
                true;
        };
        if (force_mdi_fallback) {
            log.log.warn("MDI chunk rendering disabled by default due missing-near-chunk artifacts; set ZIGCRAFT_FORCE_MDI_FALLBACK=0 to test indirect draws", .{});
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
            .force_mdi_fallback = force_mdi_fallback,
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

        if (render_lod) {
            if (lod_manager) |lod_mgr| {
                lod_mgr.render(view_proj, camera_pos, ChunkStorage.isChunkRenderable, @ptrCast(self.storage), true, null);
            }
        }

        // LOD rendering uses a separate descriptor set path; switch back before drawing full chunks.
        self.render_ctx.setInstanceBuffer(0);

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        self.visible_chunks.clearRetainingCapacity();
        self.instance_data.clearRetainingCapacity();
        self.draw_commands.clearRetainingCapacity();

        if (!std.math.isFinite(camera_pos.x) or !std.math.isFinite(camera_pos.z)) return;

        const pc = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
        const pc_x: i64 = pc.chunk_x;
        const pc_z: i64 = pc.chunk_z;

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

        const force_mdi_fallback = self.force_mdi_fallback;
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

        self.drawGuaranteedNearChunks(@intCast(pc_x), @intCast(pc_z), camera_pos, layer);
    }

    fn drawGuaranteedNearChunks(self: *WorldRenderer, pc_x: i32, pc_z: i32, camera_pos: Vec3, layer: RenderLayer) void {
        var dz: i32 = -1;
        while (dz <= 1) : (dz += 1) {
            var dx: i32 = -1;
            while (dx <= 1) : (dx += 1) {
                const cx = pc_x + dx;
                const cz = pc_z + dz;
                const data = self.storage.chunks.get(.{ .x = cx, .z = cz }) orelse continue;

                const chunk_world_x: f32 = @floatFromInt(cx * CHUNK_SIZE_X);
                const chunk_world_z: f32 = @floatFromInt(cz * CHUNK_SIZE_Z);
                const model = Mat4.translate(Vec3.init(chunk_world_x - camera_pos.x, -camera_pos.y, chunk_world_z - camera_pos.z));
                self.render_ctx.setModelMatrix(model, Vec3.one, 0);

                if (layer != .fluid) {
                    if (data.mesh.solid_allocation) |alloc| {
                        self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                    }
                    if (data.mesh.cutout_allocation) |alloc| {
                        self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                    }
                }
                if (layer != .terrain) {
                    if (data.mesh.fluid_allocation) |alloc| {
                        self.render_ctx.drawOffset(self.vertex_allocator.buffer, alloc.count, .triangles, alloc.offset);
                    }
                }
            }
        }
    }

    fn renderCpuCull(self: *WorldRenderer, view_proj: Mat4, camera_pos: Vec3, pc_x: i64, pc_z: i64, r_dist: i64) void {
        self.render_frame_count += 1;
        const frustum = Frustum.fromViewProj(view_proj);

        var not_renderable: u32 = 0;
        var not_in_storage: u32 = 0;
        var missing_in_circle: u32 = 0;
        var missing_cx: i32 = 0;
        var missing_cz: i32 = 0;
        var frustum_culled: u32 = 0;
        var visible_no_mesh: u32 = 0;
        var visible_zero_verts: u32 = 0;
        var first_no_mesh_cx: i32 = 0;
        var first_no_mesh_cz: i32 = 0;
        var first_zero_verts_cx: i32 = 0;
        var first_zero_verts_cz: i32 = 0;

        // Parse diagnostic region from environment variable
        // Format: ZIGCRAFT_DIAGNOSE_REGION=min_x,min_z,max_x,max_z
        var diag_min_x: i32 = 0;
        var diag_min_z: i32 = 0;
        var diag_max_x: i32 = 0;
        var diag_max_z: i32 = 0;
        var diag_region_enabled = false;
        if (getenv("ZIGCRAFT_DIAGNOSE_REGION")) |region_str| {
            var parts = std.mem.splitScalar(u8, region_str, ',');
            if (parts.next()) |x1| diag_min_x = std.fmt.parseInt(i32, x1, 10) catch 0;
            if (parts.next()) |z1| diag_min_z = std.fmt.parseInt(i32, z1, 10) catch 0;
            if (parts.next()) |x2| diag_max_x = std.fmt.parseInt(i32, x2, 10) catch 0;
            if (parts.next()) |z2| diag_max_z = std.fmt.parseInt(i32, z2, 10) catch 0;
            diag_region_enabled = true;
        }

        var cz = pc_z - r_dist;
        while (cz <= pc_z + r_dist) : (cz += 1) {
            var cx = pc_x - r_dist;
            while (cx <= pc_x + r_dist) : (cx += 1) {
                const dx = cx - pc_x;
                const dz = cz - pc_z;
                const dist_sq = dx * dx + dz * dz;
                if (self.storage.chunks.get(.{ .x = @as(i32, @intCast(cx)), .z = @as(i32, @intCast(cz)) })) |data| {
                    if (data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.cutout_allocation != null or data.mesh.fluid_allocation != null) {
                        const is_camera_neighborhood = @abs(cx - pc_x) <= 1 and @abs(cz - pc_z) <= 1;
                        if (!is_camera_neighborhood and !frustum.intersectsChunkRelative(@as(i32, @intCast(cx)), @as(i32, @intCast(cz)), camera_pos.x, camera_pos.y, camera_pos.z)) {
                            frustum_culled += 1;
                            self.last_render_stats.chunks_culled += 1;
                            continue;
                        }
                        self.visible_chunks.append(self.allocator, data) catch {};

                        // Diagnostic: Log block types for chunks in the diagnostic region
                        if (diag_region_enabled and cx >= diag_min_x and cx <= diag_max_x and cz >= diag_min_z and cz <= diag_max_z) {
                            var block_type_counts = std.mem.zeroes([256]u32);
                            for (data.chunk.blocks) |block| {
                                block_type_counts[@intFromEnum(block)] += 1;
                            }
                            var buf: [4096]u8 = undefined;
                            var len: usize = 0;
                            for (block_type_counts, 0..) |count, i| {
                                if (count > 0 and len < buf.len - 30) {
                                    const written = std.fmt.bufPrint(buf[len..], "{}:{},", .{ i, count }) catch unreachable;
                                    len += written.len;
                                }
                            }
                            log.log.warn("DIAGNOSE_CHUNK ({},{}): block_counts=[{s}] verts={}", .{
                                cx, cz, buf[0..len],
                                (if (data.mesh.solid_allocation) |a| a.count else 0) +
                                    (if (data.mesh.cutout_allocation) |a| a.count else 0) +
                                    (if (data.mesh.fluid_allocation) |a| a.count else 0),
                            });
                        }

                        if (data.mesh.solid_allocation == null and data.mesh.cutout_allocation == null and data.mesh.fluid_allocation == null) {
                            visible_no_mesh += 1;
                            if (visible_no_mesh == 1) {
                                first_no_mesh_cx = @intCast(cx);
                                first_no_mesh_cz = @intCast(cz);
                            }
                        } else {
                            const solid_verts = if (data.mesh.solid_allocation) |a| a.count else 0;
                            const cutout_verts = if (data.mesh.cutout_allocation) |a| a.count else 0;
                            const fluid_verts = if (data.mesh.fluid_allocation) |a| a.count else 0;
                            if (solid_verts + cutout_verts + fluid_verts == 0) {
                                visible_zero_verts += 1;
                                if (visible_zero_verts == 1) {
                                    first_zero_verts_cx = @intCast(cx);
                                    first_zero_verts_cz = @intCast(cz);
                                }
                            }
                        }
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

        if (build_options.startup_diagnostic_seconds == 0 and missing_in_circle > 0 and self.render_frame_count % 60 == 0) {
            if (self.storage.chunks.get(.{ .x = missing_cx, .z = missing_cz })) |d| {
                log.log.debug("CPU_CULL_GAP: missing_in_circle={} last_missing=({},{}) state={} has_alloc={} pc=({},{}) rd={}", .{
                    missing_in_circle,           missing_cx,                                                                                             missing_cz,
                    @intFromEnum(d.chunk.state), d.mesh.solid_allocation != null or d.mesh.cutout_allocation != null or d.mesh.fluid_allocation != null, pc_x,
                    pc_z,                        r_dist,
                });
            } else {
                log.log.debug("CPU_CULL_GAP: missing_in_circle={} last_missing=({},{}) NOT_IN_STORAGE pc=({},{}) rd={}", .{
                    missing_in_circle, missing_cx, missing_cz, pc_x, pc_z, r_dist,
                });
            }
        }

        if (build_options.startup_diagnostic_seconds == 0 and self.render_frame_count % 300 == 0) {
            log.log.info("CPU_CULL: visible={} with_mesh={} no_mesh={} zero_verts={} frustum_culled={} not_renderable={} not_in_storage={} missing_circle={}", .{
                self.visible_chunks.items.len,
                self.visible_chunks.items.len - visible_no_mesh,
                visible_no_mesh,
                visible_zero_verts,
                frustum_culled,
                not_renderable,
                not_in_storage,
                missing_in_circle,
            });
            if (visible_no_mesh > 0) {
                log.log.warn("  {} visible chunks have NO mesh data! first=({},{})", .{ visible_no_mesh, first_no_mesh_cx, first_no_mesh_cz });
            }
            if (visible_zero_verts > 0) {
                log.log.warn("  {} visible chunks have ZERO vertices! first=({},{})", .{ visible_zero_verts, first_zero_verts_cx, first_zero_verts_cz });
            }

            // Dump boundary chunks at distance r_dist to find the missing slice
            var boundary_renderable: u32 = 0;
            var boundary_missing: u32 = 0;
            var boundary_buf: [4096]u8 = undefined;
            var boundary_len: usize = 0;
            var bz: i64 = pc_z - r_dist;
            while (bz <= pc_z + r_dist) : (bz += 1) {
                var bx: i64 = pc_x - r_dist;
                while (bx <= pc_x + r_dist) : (bx += 1) {
                    const bdx = bx - pc_x;
                    const bdz = bz - pc_z;
                    const bdist = bdx * bdx + bdz * bdz;
                    if (bdist >= (r_dist - 1) * (r_dist - 1) and bdist <= r_dist * r_dist) {
                        if (self.storage.chunks.get(.{ .x = @as(i32, @intCast(bx)), .z = @as(i32, @intCast(bz)) })) |data| {
                            if (data.mesh.solid_allocation != null or data.mesh.cutout_allocation != null or data.mesh.fluid_allocation != null) {
                                boundary_renderable += 1;
                            } else {
                                boundary_missing += 1;
                                if (boundary_len < boundary_buf.len - 20) {
                                    const written = std.fmt.bufPrint(boundary_buf[boundary_len..], "({},{}) ", .{ bx, bz }) catch unreachable;
                                    boundary_len += written.len;
                                }
                            }
                        } else {
                            boundary_missing += 1;
                            if (boundary_len < boundary_buf.len - 20) {
                                const written = std.fmt.bufPrint(boundary_buf[boundary_len..], "({},{})! ", .{ bx, bz }) catch unreachable;
                                boundary_len += written.len;
                            }
                        }
                    }
                }
            }
            if (boundary_missing > 0) {
                log.log.warn("  BOUNDARY: {}/{} boundary chunks have NO mesh. Missing: {s}", .{ boundary_missing, boundary_renderable + boundary_missing, boundary_buf[0..boundary_len] });
            }
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
        _ = light_space_matrix;

        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        if (!std.math.isFinite(camera_pos.x) or !std.math.isFinite(camera_pos.z)) return;

        const pc = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
        const pc_x: i64 = pc.chunk_x;
        const pc_z: i64 = pc.chunk_z;

        const r_dist: i64 = @as(i64, @intFromFloat(shadow_caster_distance / CHUNK_SIZE_X));

        var cz = pc_z - r_dist;
        while (cz <= pc_z + r_dist) : (cz += 1) {
            var cx = pc_x - r_dist;
            while (cx <= pc_x + r_dist) : (cx += 1) {
                if (self.storage.chunks.get(.{ .x = @as(i32, @intCast(cx)), .z = @as(i32, @intCast(cz)) })) |data| {
                    if (data.chunk.state == .renderable or data.mesh.solid_allocation != null or data.mesh.cutout_allocation != null or data.mesh.fluid_allocation != null) {
                        const chunk_world_x: f32 = @floatFromInt(data.chunk.chunk_x * CHUNK_SIZE_X);
                        const chunk_world_z: f32 = @floatFromInt(data.chunk.chunk_z * CHUNK_SIZE_Z);

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
