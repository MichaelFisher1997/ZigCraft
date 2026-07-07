//! LOD Renderer - handles culling and drawing of LOD meshes using Multi-Draw Indirect.
//!
//! This module is responsible for rendering distant terrain chunks (LOD1-LOD3)
//! using an instanced rendering approach. It receives prepared mesh and region
//! data from LODManager via the LODGPUBridge abstraction.
//!
//! ## Multi-Draw Indirect (MDI) Rendering
//!
//! The renderer uses instance buffers to batch-draw multiple LOD regions:
//! - Per-frame instance data (position, color, mask radius) is accumulated
//! - Data is uploaded to GPU storage buffers (double-buffered per frame)
//! - RHI renders all visible regions in minimal draw calls
//!
//! ## GPU Data Flow
//!
//! ```
//! LODManager -> MeshMap/RegionMap -> LODRenderer.render() -> InstanceBuffer -> GPU
//! ```
//!
//! The LODGPUBridge and LODRenderInterface types abstract the data transfer,
//! allowing LODManager to remain decoupled from rendering concerns.
//!
//! ## Frustum Culling
//!
//! Visible regions are filtered by frustum culling before adding to the draw
//! list. Each LODChunk has conservative bounds that are tested against the camera frustum.
//! Optional ChunkChecker callback allows additional visibility filtering.

const std = @import("std");
const lod_chunk = @import("lod_chunk.zig");
const ChunkBounds = lod_chunk.ChunkBounds;
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODConfig = lod_chunk.LODConfig;
const ILODConfig = lod_chunk.ILODConfig;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODRegionKeyContext = lod_chunk.LODRegionKeyContext;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const LODMeshResources = @import("lod_mesh.zig").LODMeshResources;
const LODVertexPool = @import("lod_vertex_pool.zig").LODVertexPool;
const CHUNK_SIZE_X = @import("world-core").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("world-core").CHUNK_SIZE_Z;
const worldToChunkFromFloat = @import("world-core").worldToChunkFromFloat;

const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const LODRenderLayer = lod_gpu.LODRenderLayer;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const ChunkChecker = lod_gpu.ChunkChecker;
const LODStats = @import("lod_stats.zig").LODStats;

const Vec3 = @import("engine-math").Vec3;
const Mat4 = @import("engine-math").Mat4;
const Frustum = @import("engine-math").Frustum;
const rhi_types = @import("engine-rhi");
const engine_core = @import("engine-core");
const log = engine_core.log;
const build_options = @import("world_lod_options");

const CHUNK_COVERAGE_PADDING: i32 = 1;
const LOD_UNMASKED_SENTINEL: f32 = 0.5;

const RenderDiag = struct {
    meshes_seen: u32 = 0,
    missing_region: u32 = 0,
    not_ready: u32 = 0,
    bad_state: u32 = 0,
    covered_finer_lod: u32 = 0,
    out_of_range: u32 = 0,
    covered_chunks: u32 = 0,
    frustum_culled: u32 = 0,
    drawn: u32 = 0,
};

const MAX_LOD_MDI_REGIONS: usize = 2048;

/// Expected RHI interface for LODRenderer:
/// - createBuffer(size: usize, usage: BufferUsage) !BufferHandle
/// - destroyBuffer(handle: BufferHandle) void
/// - getFrameIndex() usize
/// - setLODInstanceBuffer(handle: BufferHandle) void
/// - setModelMatrix(model: Mat4, color: Vec3, mask_radius: f32) void
/// - draw(handle: BufferHandle, count: u32, mode: DrawMode) void
pub fn LODRenderer(comptime RHI: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        rhi: RHI,

        // MDI Resources (Moved from LODManager)
        instance_data: std.ArrayListUnmanaged(rhi_types.InstanceData),
        draw_list: std.ArrayListUnmanaged(*LODMesh),
        draw_commands: [LODLevel.count]std.ArrayListUnmanaged(rhi_types.DrawIndirectCommand),
        instance_buffers: [rhi_types.MAX_FRAMES_IN_FLIGHT]rhi_types.BufferHandle,
        indirect_buffers: [rhi_types.MAX_FRAMES_IN_FLIGHT]rhi_types.BufferHandle,
        vertex_pools: [LODLevel.count]LODVertexPool,
        frame_index: usize,
        enable_mdi: bool,
        gpu_culling_requested: bool,
        gpu_culling_fallback_logged: bool,

        pub fn init(allocator: std.mem.Allocator, rhi: RHI) !*Self {
            const renderer = try allocator.create(Self);
            errdefer allocator.destroy(renderer);

            var instance_buffers = [_]rhi_types.BufferHandle{0} ** rhi_types.MAX_FRAMES_IN_FLIGHT;
            var indirect_buffers = [_]rhi_types.BufferHandle{0} ** rhi_types.MAX_FRAMES_IN_FLIGHT;
            const resources = if (@hasDecl(RHI, "resourceManager")) rhi.resourceManager() else rhi;
            errdefer {
                for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |i| {
                    if (instance_buffers[i] != 0) resources.destroyBuffer(instance_buffers[i]);
                    if (indirect_buffers[i] != 0) resources.destroyBuffer(indirect_buffers[i]);
                }
            }
            for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |i| {
                instance_buffers[i] = try resources.createBuffer(MAX_LOD_MDI_REGIONS * @sizeOf(rhi_types.InstanceData), .storage);
                indirect_buffers[i] = try resources.createBuffer(MAX_LOD_MDI_REGIONS * @sizeOf(rhi_types.DrawIndirectCommand), .indirect);
            }

            var draw_commands: [LODLevel.count]std.ArrayListUnmanaged(rhi_types.DrawIndirectCommand) = undefined;
            for (&draw_commands) |*commands| commands.* = .empty;

            var vertex_pools: [LODLevel.count]LODVertexPool = undefined;
            for (0..LODLevel.count) |i| {
                vertex_pools[i] = LODVertexPool.init(allocator, @enumFromInt(@as(u3, @intCast(i))), 8 * 1024 * 1024);
            }

            renderer.* = .{
                .allocator = allocator,
                .rhi = rhi,
                .instance_data = .empty,
                .draw_list = .empty,
                .draw_commands = draw_commands,
                .instance_buffers = instance_buffers,
                .indirect_buffers = indirect_buffers,
                .vertex_pools = vertex_pools,
                .frame_index = 0,
                .enable_mdi = engine_core.envFlag("ZIGCRAFT_ENABLE_LOD_MDI", false),
                .gpu_culling_requested = engine_core.envFlag("ZIGCRAFT_LOD_GPU_CULLING", false),
                .gpu_culling_fallback_logged = false,
            };

            if (!renderer.enable_mdi) {
                log.log.info("LOD MDI disabled by default; set ZIGCRAFT_ENABLE_LOD_MDI=1 to enable indirect LOD batches", .{});
            }

            return renderer;
        }

        pub fn deinit(self: *Self) void {
            self.rhi.waitIdle();
            const resources = if (@hasDecl(RHI, "resourceManager")) self.rhi.resourceManager() else self.rhi;
            for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |i| {
                if (self.instance_buffers[i] != 0) {
                    resources.destroyBuffer(self.instance_buffers[i]);
                }
                if (self.indirect_buffers[i] != 0) {
                    resources.destroyBuffer(self.indirect_buffers[i]);
                }
            }
            const mesh_resources = LODMeshResources.fromProvider(RHI, &self.rhi);
            for (0..LODLevel.count) |i| {
                self.vertex_pools[i].deinit(mesh_resources);
            }
            self.instance_data.deinit(self.allocator);
            self.draw_list.deinit(self.allocator);
            for (&self.draw_commands) |*commands| commands.deinit(self.allocator);
            self.allocator.destroy(self);
        }

        /// Render all LOD meshes using explicitly provided data.
        pub fn render(
            self: *Self,
            meshes: *const [LODLevel.count]MeshMap,
            regions: *const [LODLevel.count]RegionMap,
            config: ILODConfig,
            view_proj: Mat4,
            camera_pos: Vec3,
            chunk_checker: ?ChunkChecker,
            checker_ctx: ?*anyopaque,
            use_frustum: bool,
            max_distance_chunks: ?i32,
            layer: LODRenderLayer,
            stats: ?*LODStats,
        ) void {
            // Update frame index
            const query = if (@hasDecl(RHI, "query")) self.rhi.query() else self.rhi;
            const render_ctx = if (@hasDecl(RHI, "renderContext")) self.rhi.renderContext() else self.rhi;
            self.frame_index = query.getFrameIndex();
            if (self.gpu_culling_requested and !self.gpu_culling_fallback_logged) {
                log.log.warn("ZIGCRAFT_LOD_GPU_CULLING requested, but LOD GPU culling is using CPU fallback until RHI exposes indirect-command compaction", .{});
                self.gpu_culling_fallback_logged = true;
            }

            // Use the LOD descriptor set while issuing LOD draws, then restore
            // normal terrain descriptor mode so the chunk pass keeps its textures.
            defer if (@hasDecl(@TypeOf(render_ctx), "setInstanceBuffer")) render_ctx.setInstanceBuffer(0);
            render_ctx.setLODInstanceBuffer(self.instance_buffers[self.frame_index]);

            const frustum = Frustum.fromViewProj(view_proj);
            // Keep opaque LOD terrain just below full chunks during the masked
            // handoff. Water must stay at the true surface height or shorelines
            // visibly step down at the LOD boundary.
            const lod_y_offset: f32 = if (layer == .fluid) 0.0 else -0.05;

            self.instance_data.clearRetainingCapacity();
            self.draw_list.clearRetainingCapacity();
            for (&self.draw_commands) |*commands| commands.clearRetainingCapacity();
            if (stats) |s| {
                if (layer == .terrain) {
                    s.drawn = [_]u32{0} ** LODLevel.count;
                    s.instances = [_]u32{0} ** LODLevel.count;
                    s.fluid_drawn = [_]u32{0} ** LODLevel.count;
                    s.fluid_instances = [_]u32{0} ** LODLevel.count;
                }
            }

            // Collect visible meshes from coarsest active LOD down so parent
            // fallback draws first and finer children overdraw it as they arrive.
            var i: usize = lod_chunk.activeLODCount(config);
            while (i > 0) {
                i -= 1;
                const lod: LODLevel = @enumFromInt(@as(u3, @intCast(i)));
                self.collectVisibleMeshes(meshes, regions, lod, config, view_proj, camera_pos, frustum, lod_y_offset, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, layer, stats) catch |err| {
                    log.log.errWithTrace("Failed to collect visible meshes for LOD{}: {}", .{ i, err });
                };
            }

            if (self.instance_data.items.len == 0) return;

            if (self.enable_mdi and layer == .terrain and self.renderIndirectBatches(render_ctx, query)) return;

            for (self.draw_list.items, 0..) |mesh, idx| {
                const instance = self.instance_data.items[idx];
                const range = mesh.drawRange(layer) orelse continue;
                render_ctx.setModelMatrix(instance.model, Vec3.one, instance.mask_radius);
                if (@hasDecl(@TypeOf(render_ctx), "drawOffset")) {
                    render_ctx.drawOffset(mesh.bufferHandle(), range.count, .triangles, mesh.vertexOffset() + range.offset);
                } else {
                    render_ctx.draw(mesh.bufferHandle(), range.count, .triangles);
                }
            }
        }

        fn renderIndirectBatches(self: *Self, render_ctx: anytype, query: anytype) bool {
            if (!supports_lod_indirect(@TypeOf(render_ctx), @TypeOf(query), @TypeOf(self.rhi))) return false;
            if (!query.supportsIndirectFirstInstance()) return false;
            if (self.instance_data.items.len == 0) return false;

            const resources = if (@hasDecl(RHI, "resourceManager")) self.rhi.resourceManager() else self.rhi;
            if (!@hasDecl(@TypeOf(resources), "updateBuffer")) return false;

            const fi = self.frame_index;
            if (self.instance_data.items.len > MAX_LOD_MDI_REGIONS) {
                log.log.warn("LOD MDI: instance overflow ({} > {}), falling back to CPU draw", .{ self.instance_data.items.len, MAX_LOD_MDI_REGIONS });
                return false;
            }

            var total_commands: usize = 0;
            for (self.draw_commands) |commands| total_commands += commands.items.len;
            if (total_commands == 0) return false;
            if (total_commands != self.draw_list.items.len) return false;
            if (total_commands > MAX_LOD_MDI_REGIONS) {
                log.log.warn("LOD MDI: command overflow ({} > {}), falling back to CPU draw", .{ total_commands, MAX_LOD_MDI_REGIONS });
                return false;
            }

            for (0..LODLevel.count) |lod_idx| {
                if (self.draw_commands[lod_idx].items.len > 0 and self.vertex_pools[lod_idx].buffer_handle == 0) return false;
            }

            resources.updateBuffer(self.instance_buffers[fi], 0, std.mem.sliceAsBytes(self.instance_data.items)) catch |err| {
                log.log.err("LOD MDI: failed to update instance buffer: {}", .{err});
                return false;
            };

            var merged_commands = std.ArrayListUnmanaged(rhi_types.DrawIndirectCommand).empty;
            defer merged_commands.deinit(self.allocator);
            merged_commands.ensureTotalCapacity(self.allocator, total_commands) catch |err| {
                log.log.err("LOD MDI: failed to reserve command staging: {}", .{err});
                return false;
            };

            var lod_offsets: [LODLevel.count]usize = [_]usize{0} ** LODLevel.count;
            var lod_counts: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count;
            for (0..LODLevel.count) |lod_idx| {
                lod_offsets[lod_idx] = merged_commands.items.len;
                lod_counts[lod_idx] = @intCast(self.draw_commands[lod_idx].items.len);
                merged_commands.appendSliceAssumeCapacity(self.draw_commands[lod_idx].items);
            }

            resources.updateBuffer(self.indirect_buffers[fi], 0, std.mem.sliceAsBytes(merged_commands.items)) catch |err| {
                log.log.err("LOD MDI: failed to update indirect buffer: {}", .{err});
                return false;
            };

            render_ctx.setLODInstanceBuffer(self.instance_buffers[fi]);
            const stride = @sizeOf(rhi_types.DrawIndirectCommand);
            for (0..LODLevel.count) |lod_idx| {
                if (lod_counts[lod_idx] == 0) continue;
                const pool_buffer = self.vertex_pools[lod_idx].buffer_handle;
                render_ctx.drawIndirect(pool_buffer, self.indirect_buffers[fi], lod_offsets[lod_idx] * stride, lod_counts[lod_idx], stride);
            }
            return true;
        }

        fn collectVisibleMeshes(
            self: *Self,
            all_meshes: *const [LODLevel.count]MeshMap,
            all_regions: *const [LODLevel.count]RegionMap,
            lod: LODLevel,
            config: ILODConfig,
            _: Mat4,
            camera_pos: Vec3,
            frustum: Frustum,
            lod_y_offset: f32,
            chunk_checker: ?ChunkChecker,
            checker_ctx: ?*anyopaque,
            use_frustum: bool,
            max_distance_chunks: ?i32,
            layer: LODRenderLayer,
            stats: ?*LODStats,
        ) !void {
            const meshes = &all_meshes[@intFromEnum(lod)];
            const regions = &all_regions[@intFromEnum(lod)];
            const diag_enabled = engine_core.envFlag("ZIGCRAFT_LOD_DIAG", false);
            const disable_frustum = engine_core.envFlag("ZIGCRAFT_LOD_DISABLE_FRUSTUM", false);
            var diag = RenderDiag{};
            var lod_rendered: u32 = 0;
            var lod_covered: u32 = 0;
            var first_missing_cx: i32 = 0;
            var first_missing_cz: i32 = 0;
            var first_missing_in_radius: bool = false;

            const camera_chunk_diag = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
            const pc_x_diag = camera_chunk_diag.chunk_x;
            const pc_z_diag = camera_chunk_diag.chunk_z;

            var iter = meshes.iterator();
            while (iter.next()) |entry| {
                diag.meshes_seen += 1;
                const mesh = entry.value_ptr.*;
                const draw_range = mesh.drawRange(layer) orelse {
                    diag.not_ready += 1;
                    continue;
                };
                if (!mesh.isReady() or draw_range.count == 0) {
                    diag.not_ready += 1;
                    continue;
                }
                if (regions.get(entry.key_ptr.*)) |chunk| {
                    if (!chunk.isRenderable()) {
                        diag.bad_state += 1;
                        continue;
                    }
                    if (self.isCoveredByFinerLOD(chunk, config)) {
                        diag.covered_finer_lod += 1;
                        continue;
                    }

                    const bounds = chunk.worldBounds();
                    const chunk_bounds = chunk.chunkBounds();

                    if (max_distance_chunks) |max_dist| {
                        if (!isRegionInRange(chunk_bounds, camera_pos, max_dist)) {
                            diag.out_of_range += 1;
                            continue;
                        }
                    }

                    var mask_radius = config.calculateMaskRadius();
                    if (chunk_checker) |checker| {
                        if (checker_ctx) |ctx_ptr| {
                            const camera_chunk = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
                            const pc_x = camera_chunk.chunk_x;
                            const pc_z = camera_chunk.chunk_z;
                            const chunk_radius = config.getChunkRenderRadius();
                            const cov = self.isCoveredByChunks(bounds, checker, ctx_ptr, pc_x, pc_z, chunk_radius);
                            if (cov.covered) {
                                lod_covered += 1;
                                diag.covered_chunks += 1;
                                continue;
                            }
                            if (lod_rendered == 0) {
                                first_missing_cx = cov.missing_cx;
                                first_missing_cz = cov.missing_cz;
                                first_missing_in_radius = cov.missing_chunk_in_radius;
                            }
                            if (cov.missing_chunk_in_radius and !cov.has_chunk_coverage_in_radius) {
                                mask_radius = LOD_UNMASKED_SENTINEL;
                            }
                        }
                    }

                    lod_rendered += 1;

                    if (use_frustum and !disable_frustum) {
                        if (!isRegionInFrustum(frustum, bounds, camera_pos)) {
                            diag.frustum_culled += 1;
                            continue;
                        }
                    }

                    const model = Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y + lod_y_offset, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z));

                    // Keep coarser LODs visible until full-detail chunks cover them.
                    // Culling against inner LOD bands creates visible holes while finer
                    // LOD regions are still streaming in.
                    const fade = @min(calculateBandFade(config, lod, chunk_bounds, camera_pos), chunk.transitionFadeProgress());
                    try self.instance_data.append(self.allocator, .{
                        .model = model,
                        .mask_radius = mask_radius,
                        .lod_fade = fade,
                        .padding = .{ 0, 0 },
                    });
                    try self.draw_list.append(self.allocator, mesh);
                    if (mesh.isPooled()) {
                        try self.draw_commands[@intFromEnum(lod)].append(self.allocator, .{
                            .vertexCount = draw_range.count,
                            .instanceCount = 1,
                            .firstVertex = mesh.firstVertex(draw_range),
                            .firstInstance = @intCast(self.instance_data.items.len - 1),
                        });
                    }
                    diag.drawn += 1;
                    if (stats) |s| {
                        const lod_idx = @intFromEnum(lod);
                        if (layer == .fluid) {
                            s.fluid_drawn[lod_idx] += 1;
                            s.fluid_instances[lod_idx] += 1;
                        } else {
                            s.drawn[lod_idx] += 1;
                            s.instances[lod_idx] += 1;
                        }
                    }
                } else {
                    diag.missing_region += 1;
                }
            }

            if (diag_enabled) {
                const S = struct {
                    var counter: [LODLevel.count]u64 = .{0} ** LODLevel.count;
                };
                const lod_idx = @intFromEnum(lod);
                S.counter[lod_idx] += 1;
                if (S.counter[lod_idx] % 120 == 1) {
                    log.log.info("LOD_RENDER_DIAG lod={} meshes={} drawn={} not_ready={} bad_state={} no_region={} finer={} chunk_cov={} frustum={} range={} frustum_disabled={} cam_chunk=({}, {})", .{
                        lod_idx,
                        diag.meshes_seen,
                        diag.drawn,
                        diag.not_ready,
                        diag.bad_state,
                        diag.missing_region,
                        diag.covered_finer_lod,
                        diag.covered_chunks,
                        diag.frustum_culled,
                        diag.out_of_range,
                        disable_frustum,
                        pc_x_diag,
                        pc_z_diag,
                    });
                }
            }

            if (lod_rendered > 0 or lod_covered > 0) {
                const missing_dx = first_missing_cx - pc_x_diag;
                const missing_dz = first_missing_cz - pc_z_diag;
                const missing_dist_sq = missing_dx * missing_dx + missing_dz * missing_dz;
                // Only log every 300 frames to reduce spam
                if (lod_covered == 0 and lod_rendered > 0) {
                    // Track a static counter for throttling
                    const S = struct {
                        var counter: u64 = 0;
                    };
                    S.counter += 1;
                    if (build_options.startup_diagnostic_seconds == 0 and S.counter % 300 == 1) {
                        log.log.debug("LOD_DIAG: rendered={} covered={} first_missing=({},{}) missing_dist2={} in_radius={} cam=({d:.0},{d:.0}) cam_chunk=({},{})", .{
                            lod_rendered,     lod_covered,
                            first_missing_cx, first_missing_cz,
                            missing_dist_sq,  first_missing_in_radius,
                            camera_pos.x,     camera_pos.z,
                            pc_x_diag,        pc_z_diag,
                        });
                    }
                }
            }
        }

        fn isCoveredByFinerLOD(
            _: *Self,
            chunk: *const LODChunk,
            config: ILODConfig,
        ) bool {
            return chunk.isCoveredByFinerLOD(config.getFallbackMissingChildThreshold());
        }

        const CoverageResult = struct {
            covered: bool,
            missing_cx: i32,
            missing_cz: i32,
            missing_chunk_in_radius: bool,
            has_chunk_coverage_in_radius: bool,
        };

        fn isCoveredByChunks(
            _: *Self,
            bounds: LODChunk.WorldBounds,
            checker: ChunkChecker,
            ctx: *anyopaque,
            pc_x: i32,
            pc_z: i32,
            lod0_radius: i32,
        ) CoverageResult {
            const min_cx = @divFloor(bounds.min_x, CHUNK_SIZE_X) - CHUNK_COVERAGE_PADDING;
            const min_cz = @divFloor(bounds.min_z, CHUNK_SIZE_Z) - CHUNK_COVERAGE_PADDING;
            const max_cx = @divFloor(bounds.max_x, CHUNK_SIZE_X) - 1 + CHUNK_COVERAGE_PADDING;
            const max_cz = @divFloor(bounds.max_z, CHUNK_SIZE_Z) - 1 + CHUNK_COVERAGE_PADDING;

            const radius_sq: i64 = @as(i64, lod0_radius) * @as(i64, lod0_radius);

            var first_outside_cx: i32 = 0;
            var first_outside_cz: i32 = 0;
            var has_outside_radius = false;
            var first_missing_cx: i32 = 0;
            var first_missing_cz: i32 = 0;
            var has_missing_in_radius = false;
            var has_chunk_coverage_in_radius = false;

            var cz = min_cz;
            while (cz <= max_cz) : (cz += 1) {
                var cx = min_cx;
                while (cx <= max_cx) : (cx += 1) {
                    const dx: i64 = @as(i64, cx) - @as(i64, pc_x);
                    const dz: i64 = @as(i64, cz) - @as(i64, pc_z);
                    if (dx * dx + dz * dz > radius_sq) {
                        if (!has_outside_radius) {
                            has_outside_radius = true;
                            first_outside_cx = cx;
                            first_outside_cz = cz;
                        }
                        continue;
                    }
                    if (checker(cx, cz, ctx)) {
                        has_chunk_coverage_in_radius = true;
                    } else if (!has_missing_in_radius) {
                        has_missing_in_radius = true;
                        first_missing_cx = cx;
                        first_missing_cz = cz;
                    }
                }
            }

            if (has_missing_in_radius) {
                return .{ .covered = false, .missing_cx = first_missing_cx, .missing_cz = first_missing_cz, .missing_chunk_in_radius = true, .has_chunk_coverage_in_radius = has_chunk_coverage_in_radius };
            }

            if (has_outside_radius) {
                return .{ .covered = false, .missing_cx = first_outside_cx, .missing_cz = first_outside_cz, .missing_chunk_in_radius = false, .has_chunk_coverage_in_radius = has_chunk_coverage_in_radius };
            }
            return .{ .covered = true, .missing_cx = 0, .missing_cz = 0, .missing_chunk_in_radius = false, .has_chunk_coverage_in_radius = has_chunk_coverage_in_radius };
        }

        /// Create a LODGPUBridge that delegates to this renderer's RHI.
        pub fn createGPUBridge(self: *Self) LODGPUBridge {
            const Wrapper = struct {
                fn onUpload(mesh: *LODMesh, ctx: *anyopaque) rhi_types.RhiError!void {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    const resources = LODMeshResources.fromProvider(RHI, &renderer.rhi);
                    if (!renderer.enable_mdi) {
                        return mesh.upload(resources);
                    }
                    return renderer.vertex_pools[@intFromEnum(mesh.lodLevel())].uploadMesh(mesh, resources);
                }
                fn onDestroy(mesh: *LODMesh, ctx: *anyopaque) void {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    const resources = LODMeshResources.fromProvider(RHI, &renderer.rhi);
                    if (mesh.isPooled()) {
                        renderer.vertex_pools[@intFromEnum(mesh.lodLevel())].destroyMesh(mesh);
                    } else {
                        mesh.deinit(resources);
                    }
                }
                fn onWaitIdle(ctx: *anyopaque) void {
                    const renderer: *Self = @ptrCast(@alignCast(ctx));
                    renderer.rhi.waitIdle();
                }
            };
            return .{
                .on_upload = Wrapper.onUpload,
                .on_destroy = Wrapper.onDestroy,
                .on_wait_idle = Wrapper.onWaitIdle,
                .ctx = @ptrCast(self),
            };
        }

        /// Create a type-erased LODRenderInterface from this renderer.
        pub fn toInterface(self: *Self) LODRenderInterface {
            const Wrapper = struct {
                fn renderFn(
                    self_ptr: *anyopaque,
                    meshes: *const [LODLevel.count]MeshMap,
                    regions: *const [LODLevel.count]RegionMap,
                    config: ILODConfig,
                    view_proj: Mat4,
                    camera_pos: Vec3,
                    chunk_checker: ?ChunkChecker,
                    checker_ctx: ?*anyopaque,
                    use_frustum: bool,
                    max_distance_chunks: ?i32,
                    layer: LODRenderLayer,
                    stats: ?*LODStats,
                ) void {
                    const renderer: *Self = @ptrCast(@alignCast(self_ptr));
                    renderer.render(meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks, layer, stats);
                }
                fn deinitFn(self_ptr: *anyopaque) void {
                    const renderer: *Self = @ptrCast(@alignCast(self_ptr));
                    renderer.deinit();
                }
            };
            return .{
                .render_fn = Wrapper.renderFn,
                .deinit_fn = Wrapper.deinitFn,
                .ptr = self,
            };
        }
    };
}

fn isRegionInRange(bounds: ChunkBounds, camera_pos: Vec3, max_distance_chunks: i32) bool {
    const camera_chunk = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
    return bounds.intersectsRadius(camera_chunk.chunk_x, camera_chunk.chunk_z, max_distance_chunks);
}

fn calculateBandFade(config: ILODConfig, lod: LODLevel, bounds: ChunkBounds, camera_pos: Vec3) f32 {
    const lod_idx = @intFromEnum(lod);
    if (lod_idx == 0) return 1.0;

    const camera_chunk = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
    const dist_sq = bounds.distanceSquaredToPoint(camera_chunk.chunk_x, camera_chunk.chunk_z);
    const dist_chunks = @sqrt(@as(f32, @floatFromInt(dist_sq)));
    const radii = config.getRadii();
    const end = @as(f32, @floatFromInt(@max(radii[lod_idx], 1)));
    const inner = @as(f32, @floatFromInt(@max(radii[lod_idx - 1], 0)));
    const configured_start = end * std.math.clamp(config.getFogStartPercent(lod), 0.0, 1.0);
    const start = @min(@max(inner, configured_start), end - 0.001);
    return std.math.clamp((dist_chunks - start) / @max(end - start, 0.001), 0.0, 1.0);
}

fn supports_lod_indirect(comptime RenderCtx: type, comptime Query: type, comptime RHI: type) bool {
    _ = RHI;
    return @hasDecl(RenderCtx, "drawIndirect") and
        @hasDecl(RenderCtx, "setLODInstanceBuffer") and
        @hasDecl(Query, "supportsIndirectFirstInstance");
}

fn isRegionInFrustum(frustum: Frustum, bounds: LODChunk.WorldBounds, camera_pos: Vec3) bool {
    const min_x: f32 = @floatFromInt(bounds.min_x);
    const min_z: f32 = @floatFromInt(bounds.min_z);
    const max_x: f32 = @floatFromInt(bounds.max_x);
    const max_z: f32 = @floatFromInt(bounds.max_z);
    const min_y = bounds.min_y;
    const max_y = bounds.max_y;

    const center = Vec3.init(
        (min_x + max_x) * 0.5 - camera_pos.x,
        (min_y + max_y) * 0.5 - camera_pos.y,
        (min_z + max_z) * 0.5 - camera_pos.z,
    );
    const half_x = (max_x - min_x) * 0.5;
    const half_y = @max((max_y - min_y) * 0.5, 1.0);
    const half_z = (max_z - min_z) * 0.5;
    const radius = @sqrt(half_x * half_x + half_y * half_y + half_z * half_z);
    return frustum.intersectsSphere(center, radius);
}

// Tests
test "LODRenderer init/deinit lifecycle" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        buffers_created: u32 = 0,
        buffers_destroyed: u32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(self: @This(), _: usize, _: anytype) !u32 {
            self.state.buffers_created += 1;
            return self.state.buffers_created;
        }
        pub fn destroyBuffer(self: @This(), _: u32) void {
            self.state.buffers_destroyed += 1;
        }
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn draw(_: @This(), _: u32, _: u32, _: anytype) void {}
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);

    // Verify init created instance + indirect buffers for each frame in flight.
    try std.testing.expectEqual(@as(u32, rhi_types.MAX_FRAMES_IN_FLIGHT * 2), mock_state.buffers_created);
    try std.testing.expectEqual(@as(u32, 0), mock_state.buffers_destroyed);

    renderer.deinit();

    // Verify deinit destroyed all buffers
    try std.testing.expectEqual(@as(u32, rhi_types.MAX_FRAMES_IN_FLIGHT * 2), mock_state.buffers_destroyed);
}

test "LODRenderer batches pooled meshes into per-LOD indirect draws" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        next_handle: u32 = 1,
        draw_indirect_calls: u32 = 0,
        direct_draw_calls: u32 = 0,
        instance_updates: u32 = 0,
        indirect_updates: u32 = 0,
        last_draw_count: u32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(self: @This(), _: usize, usage: anytype) !u32 {
            _ = usage;
            const handle = self.state.next_handle;
            self.state.next_handle += 1;
            return handle;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn updateBuffer(self: @This(), _: u32, _: usize, data: []const u8) !void {
            if (data.len % @sizeOf(rhi_types.InstanceData) == 0 and data.len != @sizeOf(rhi_types.DrawIndirectCommand)) {
                self.state.instance_updates += 1;
            } else {
                self.state.indirect_updates += 1;
            }
        }
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn supportsIndirectFirstInstance(_: @This()) bool {
            return true;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(_: @This(), _: u32, _: u32, _: anytype) void {}
        pub fn drawOffset(_: @This(), _: u32, _: u32, _: anytype, _: usize) void {}
        pub fn drawIndirect(self: @This(), _: u32, _: u32, _: usize, draw_count: u32, _: u32) void {
            self.state.draw_indirect_calls += 1;
            self.state.last_draw_count += draw_count;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();
    renderer.enable_mdi = true;

    renderer.vertex_pools[1].buffer_handle = 101;
    renderer.vertex_pools[2].buffer_handle = 102;

    var mesh_lod1 = LODMesh.init(allocator, .lod1);
    mesh_lod1.buffer_handle = 101;
    mesh_lod1.vertex_offset = 0;
    mesh_lod1.vertex_count = 12;
    mesh_lod1.pooled = true;
    mesh_lod1.ready = true;

    var mesh_lod2 = LODMesh.init(allocator, .lod2);
    mesh_lod2.buffer_handle = 102;
    mesh_lod2.vertex_offset = 4 * @sizeOf(rhi_types.Vertex);
    mesh_lod2.vertex_count = 18;
    mesh_lod2.pooled = true;
    mesh_lod2.ready = true;

    var chunk_lod1 = LODChunk.init(4, 0, .lod1);
    chunk_lod1.state = .renderable;
    var chunk_lod2 = LODChunk.init(8, 0, .lod2);
    chunk_lod2.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    try meshes[1].put(.{ .rx = 4, .rz = 0, .lod = .lod1 }, &mesh_lod1);
    try regions[1].put(.{ .rx = 4, .rz = 0, .lod = .lod1 }, &chunk_lod1);
    try meshes[2].put(.{ .rx = 8, .rz = 0, .lod = .lod2 }, &mesh_lod2);
    try regions[2].put(.{ .rx = 8, .rz = 0, .lod = .lod2 }, &chunk_lod2);

    var mock_config = LODConfig{ .radii = .{ 16, 128, 256, 512, 1024 } };
    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null);

    try std.testing.expectEqual(@as(u32, 2), mock_state.draw_indirect_calls);
    try std.testing.expectEqual(@as(u32, 2), mock_state.last_draw_count);
}

test "LODRenderer band fade follows configured fog start percent" {
    var config = LODConfig{
        .radii = .{ 16, 40, 80, 160, 512 },
        .fog_start_percent = .{ 1.0, 0.5, 0.5, 0.5, 0.5 },
    };
    const iface = config.interface();

    const near_bounds = ChunkBounds{ .min_x = 16, .min_z = 0, .max_x = 16, .max_z = 0 };
    try std.testing.expectEqual(@as(f32, 0.0), calculateBandFade(iface, .lod1, near_bounds, Vec3.zero));

    const mid_bounds = ChunkBounds{ .min_x = 30, .min_z = 0, .max_x = 30, .max_z = 0 };
    try std.testing.expect(calculateBandFade(iface, .lod1, mid_bounds, Vec3.zero) > 0.0);
    try std.testing.expect(calculateBandFade(iface, .lod1, mid_bounds, Vec3.zero) < 1.0);

    const far_bounds = ChunkBounds{ .min_x = 40, .min_z = 0, .max_x = 40, .max_z = 0 };
    try std.testing.expectEqual(@as(f32, 1.0), calculateBandFade(iface, .lod1, far_bounds, Vec3.zero));
}

test "LODRenderer transition fade distinguishes child fade-in and parent fade-out" {
    var child = LODChunk.init(0, 0, .lod1);
    child.transition_frames_remaining = lod_chunk.TRANSITION_FADE_FRAMES;
    try std.testing.expectEqual(@as(f32, 0.0), child.transitionFadeProgress());

    child.transition_frames_remaining = 0;
    try std.testing.expectEqual(@as(f32, 1.0), child.transitionFadeProgress());

    var parent = LODChunk.init(0, 0, .lod2);
    parent.ready_children = 4;
    parent.transition_frames_remaining = lod_chunk.TRANSITION_FADE_FRAMES;
    try std.testing.expectEqual(@as(f32, 1.0), parent.transitionFadeProgress());

    parent.transition_frames_remaining = 0;
    try std.testing.expectEqual(@as(f32, 1.0), parent.transitionFadeProgress());
}

test "LODRenderer render draw path" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        set_matrix_calls: u32 = 0,
        last_vertex_count: u32 = 0,
        last_buffer_handle: u32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, _: f32) void {
            self.state.set_matrix_calls += 1;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), handle: u32, count: u32, _: anytype) void {
            self.state.draw_calls += 1;
            self.state.last_buffer_handle = handle;
            self.state.last_vertex_count = count;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    // Create mock mesh
    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 42;
    mesh.vertex_count = 106;
    mesh.opaque_vertex_count = 100;
    mesh.water_vertex_offset = 100 * @sizeOf(rhi_types.Vertex);
    mesh.water_vertex_count = 6;
    mesh.ready = true;

    // Create mock LODChunk in renderable state
    var chunk = LODChunk.init(5, 0, .lod1);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    // Add mesh and region at LOD1
    const key = LODRegionKey{ .rx = 5, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{};

    // Create view-projection matrix that includes origin (where our chunk is)
    // Use identity for simplicity - frustum will include everything
    const view_proj = Mat4.identity;
    const camera_pos = Vec3.zero;

    var stats = LODStats{};

    // Call render with explicit parameters
    renderer.render(&meshes, &regions, mock_config.interface(), view_proj, camera_pos, null, null, false, null, .terrain, &stats);

    // Verify draw was called with correct parameters
    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
    try std.testing.expectEqual(@as(u32, 42), mock_state.last_buffer_handle);
    try std.testing.expectEqual(@as(u32, 100), mock_state.last_vertex_count);
    try std.testing.expectEqual(@as(u32, 1), stats.drawn[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.instances[1]);

    renderer.render(&meshes, &regions, mock_config.interface(), view_proj, camera_pos, null, null, false, null, .fluid, &stats);
    try std.testing.expectEqual(@as(u32, 2), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 6), mock_state.last_vertex_count);
    try std.testing.expectEqual(@as(u32, 1), stats.drawn[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.instances[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.fluid_drawn[1]);
    try std.testing.expectEqual(@as(u32, 1), stats.fluid_instances[1]);
}

test "LODRenderer keeps coarse LOD visible while finer bands stream" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        set_matrix_calls: u32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, _: f32) void {
            self.state.set_matrix_calls += 1;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod2);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    // Region (2,0) at LOD2 covers chunks 16..23. It sits inside the LOD1 radius,
    // so inner-band culling would incorrectly suppress it if no finer LOD exists yet.
    var chunk = LODChunk.init(2, 0, .lod2);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod2 };
    try meshes[2].put(key, &mesh);
    try regions[2].put(key, &chunk);

    var mock_config = LODConfig{
        .radii = .{ 16, 32, 64, 100, 256 },
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
}

test "LODRenderer disables mask when chunks are missing inside chunk render radius" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        last_mask_radius: f32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, mask_radius: f32) void {
            self.state.last_mask_radius = mask_radius;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    var chunk = LODChunk.init(0, 0, .lod1);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };
    var checker_ctx: u8 = 0;
    const Checker = struct {
        fn missingInRadius(_: i32, _: i32, _: *anyopaque) bool {
            return false;
        }
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, Checker.missingInRadius, &checker_ctx, false, null, .terrain, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(LOD_UNMASKED_SENTINEL, mock_state.last_mask_radius);
}

test "LODRenderer chunk mask uses chunk render radius instead of LOD0 radius" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        last_mask_radius: f32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, mask_radius: f32) void {
            self.state.last_mask_radius = mask_radius;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    // Region rx=3 sits inside the LOD0 ring radius below, but outside the
    // configured full-chunk render radius. Missing chunks there must not unmask
    // the inner chunk/LOD handoff.
    var chunk = LODChunk.init(3, 0, .lod1);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 3, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{
        .chunk_render_radius = 4,
        .radii = .{ 16, 32, 64, 100, 256 },
    };
    var checker_ctx: u8 = 0;
    const Checker = struct {
        fn missing(_: i32, _: i32, _: *anyopaque) bool {
            return false;
        }
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, Checker.missing, &checker_ctx, false, null, .terrain, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(mock_config.interface().calculateMaskRadius(), mock_state.last_mask_radius);
}

test "LODRenderer keeps mask when only outside-radius chunks are uncovered" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        last_mask_radius: f32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, mask_radius: f32) void {
            self.state.last_mask_radius = mask_radius;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    var chunk = LODChunk.init(4, 0, .lod1);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 4, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };
    var checker_ctx: u8 = 0;
    const Checker = struct {
        fn loaded(_: i32, _: i32, _: *anyopaque) bool {
            return true;
        }
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, Checker.loaded, &checker_ctx, false, null, .terrain, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(mock_config.interface().calculateMaskRadius(), mock_state.last_mask_radius);
}

test "LODRenderer keeps mask for partially covered chunk regions" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        last_mask_radius: f32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, mask_radius: f32) void {
            self.state.last_mask_radius = mask_radius;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    var chunk = LODChunk.init(0, 0, .lod1);
    chunk.state = .renderable;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };
    var checker_ctx: u8 = 0;
    const Checker = struct {
        fn partiallyLoaded(cx: i32, cz: i32, _: *anyopaque) bool {
            return cx == 0 and cz == 0;
        }
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, Checker.partiallyLoaded, &checker_ctx, false, null, .terrain, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(mock_config.interface().calculateMaskRadius(), mock_state.last_mask_radius);
}

test "LODRenderer skips coarse LOD when finer coverage is ready" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var coarse_mesh = LODMesh.init(allocator, .lod2);
    coarse_mesh.buffer_handle = 7;
    coarse_mesh.vertex_count = 12;
    coarse_mesh.ready = true;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    var coarse_chunk = LODChunk.init(2, 0, .lod2);
    coarse_chunk.state = .renderable;
    coarse_chunk.ready_children = 4;
    const coarse_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod2 };
    try meshes[2].put(coarse_key, &coarse_mesh);
    try regions[2].put(coarse_key, &coarse_chunk);

    const finer_keys = [_]LODRegionKey{
        .{ .rx = 4, .rz = 0, .lod = .lod1 },
        .{ .rx = 5, .rz = 0, .lod = .lod1 },
        .{ .rx = 4, .rz = 1, .lod = .lod1 },
        .{ .rx = 5, .rz = 1, .lod = .lod1 },
    };
    var finer_chunks: [4]LODChunk = undefined;
    var finer_meshes: [4]LODMesh = undefined;
    for (finer_keys, 0..) |finer_key, idx| {
        finer_chunks[idx] = LODChunk.init(finer_key.rx, finer_key.rz, .lod1);
        finer_chunks[idx].state = .renderable;
        finer_meshes[idx] = LODMesh.init(allocator, .lod1);
        finer_meshes[idx].buffer_handle = @as(u32, @intCast(10 + idx));
        finer_meshes[idx].vertex_count = 24;
        finer_meshes[idx].ready = true;
        try meshes[1].put(finer_key, &finer_meshes[idx]);
        try regions[1].put(finer_key, &finer_chunks[idx]);
    }

    var mock_config = LODConfig{
        .radii = .{ 16, 32, 64, 100, 256 },
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null);

    try std.testing.expectEqual(@as(u32, 4), mock_state.draw_calls);
}

test "LODRenderer always renders ready LOD0 regions" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var mesh = LODMesh.init(allocator, .lod0);
    mesh.buffer_handle = 7;
    mesh.vertex_count = 12;
    mesh.ready = true;

    var chunk = LODChunk.init(2, 0, .lod0);
    chunk.state = .renderable;
    chunk.ready_children = 4;

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    const key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod0 };
    try meshes[0].put(key, &mesh);
    try regions[0].put(key, &chunk);

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };
    var stats = LODStats{};
    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, &stats);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), stats.drawn[0]);
    try std.testing.expectEqual(@as(u32, 1), stats.instances[0]);
}

test "LODRenderer keeps coarse LOD when a finer child is missing" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        handle_sum: u32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), handle: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
            self.state.handle_sum += handle;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    var coarse_mesh = LODMesh.init(allocator, .lod2);
    coarse_mesh.buffer_handle = 100;
    coarse_mesh.vertex_count = 12;
    coarse_mesh.ready = true;
    var coarse_chunk = LODChunk.init(2, 0, .lod2);
    coarse_chunk.state = .renderable;
    coarse_chunk.ready_children = 3;
    const coarse_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod2 };
    try meshes[2].put(coarse_key, &coarse_mesh);
    try regions[2].put(coarse_key, &coarse_chunk);

    const finer_keys = [_]LODRegionKey{
        .{ .rx = 4, .rz = 0, .lod = .lod1 },
        .{ .rx = 5, .rz = 0, .lod = .lod1 },
        .{ .rx = 4, .rz = 1, .lod = .lod1 },
    };
    var finer_chunks: [finer_keys.len]LODChunk = undefined;
    var finer_meshes: [finer_keys.len]LODMesh = undefined;
    for (finer_keys, 0..) |finer_key, idx| {
        finer_chunks[idx] = LODChunk.init(finer_key.rx, finer_key.rz, .lod1);
        finer_chunks[idx].state = .renderable;
        finer_meshes[idx] = LODMesh.init(allocator, .lod1);
        finer_meshes[idx].buffer_handle = @as(u32, @intCast(idx + 1));
        finer_meshes[idx].vertex_count = 24;
        finer_meshes[idx].ready = true;
        try meshes[1].put(finer_key, &finer_meshes[idx]);
        try regions[1].put(finer_key, &finer_chunks[idx]);
    }

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null);

    try std.testing.expectEqual(@as(u32, 4), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 106), mock_state.handle_sum);
}

test "LODRenderer resolves finer coverage across negative region boundaries" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        draw_calls: u32 = 0,
        handle_sum: u32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(_: @This(), _: usize, _: anytype) !u32 {
            return 1;
        }
        pub fn destroyBuffer(_: @This(), _: u32) void {}
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn setModelMatrix(_: @This(), _: Mat4, _: Vec3, _: f32) void {}
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn setSelectionMode(_: @This(), _: bool) void {}
        pub fn draw(self: @This(), handle: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
            self.state.handle_sum += handle;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    var coarse_mesh = LODMesh.init(allocator, .lod2);
    coarse_mesh.buffer_handle = 100;
    coarse_mesh.vertex_count = 12;
    coarse_mesh.ready = true;
    var coarse_chunk = LODChunk.init(-1, -1, .lod2);
    coarse_chunk.state = .renderable;
    coarse_chunk.ready_children = 4;
    const coarse_key = LODRegionKey{ .rx = -1, .rz = -1, .lod = .lod2 };
    try meshes[2].put(coarse_key, &coarse_mesh);
    try regions[2].put(coarse_key, &coarse_chunk);

    const finer_keys = [_]LODRegionKey{
        .{ .rx = -2, .rz = -2, .lod = .lod1 },
        .{ .rx = -1, .rz = -2, .lod = .lod1 },
        .{ .rx = -2, .rz = -1, .lod = .lod1 },
        .{ .rx = -1, .rz = -1, .lod = .lod1 },
    };
    var finer_chunks: [finer_keys.len]LODChunk = undefined;
    var finer_meshes: [finer_keys.len]LODMesh = undefined;
    for (finer_keys, 0..) |finer_key, idx| {
        finer_chunks[idx] = LODChunk.init(finer_key.rx, finer_key.rz, .lod1);
        finer_chunks[idx].state = .renderable;
        finer_meshes[idx] = LODMesh.init(allocator, .lod1);
        finer_meshes[idx].buffer_handle = @as(u32, @intCast(idx + 1));
        finer_meshes[idx].vertex_count = 24;
        finer_meshes[idx].ready = true;
        try meshes[1].put(finer_key, &finer_meshes[idx]);
        try regions[1].put(finer_key, &finer_chunks[idx]);
    }

    var mock_config = LODConfig{ .radii = .{ 16, 32, 64, 100, 256 } };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null);

    try std.testing.expectEqual(@as(u32, 4), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 10), mock_state.handle_sum);
}

test "LODRenderer createGPUBridge and toInterface round-trip" {
    const allocator = std.testing.allocator;

    const MockRHIState = struct {
        upload_calls: u32 = 0,
        destroy_calls: u32 = 0,
        wait_idle_calls: u32 = 0,
        draw_calls: u32 = 0,
        set_matrix_calls: u32 = 0,
    };

    const MockRHI = struct {
        state: *MockRHIState,

        pub fn createBuffer(self: @This(), _: usize, _: anytype) !u32 {
            _ = self;
            return 1;
        }
        pub fn destroyBuffer(self: @This(), _: u32) void {
            self.state.destroy_calls += 1;
        }
        pub fn uploadBuffer(self: @This(), _: u32, _: []const u8) !void {
            self.state.upload_calls += 1;
        }
        pub fn getFrameIndex(_: @This()) usize {
            return 0;
        }
        pub fn waitIdle(self: @This()) void {
            self.state.wait_idle_calls += 1;
        }
        pub fn setModelMatrix(self: @This(), _: Mat4, _: Vec3, _: f32) void {
            self.state.set_matrix_calls += 1;
        }
        pub fn setLODInstanceBuffer(_: @This(), _: anytype) void {}
        pub fn draw(self: @This(), _: u32, _: u32, _: anytype) void {
            self.state.draw_calls += 1;
        }
    };

    var mock_state = MockRHIState{};
    const mock_rhi = MockRHI{ .state = &mock_state };

    const Renderer = LODRenderer(MockRHI);
    const renderer = try Renderer.init(allocator, mock_rhi);
    defer renderer.deinit();

    // Test createGPUBridge round-trip
    const bridge = renderer.createGPUBridge();

    // Verify bridge.waitIdle calls through to MockRHI.waitIdle
    bridge.waitIdle();
    try std.testing.expectEqual(@as(u32, 1), mock_state.wait_idle_calls);

    // Verify bridge.destroy calls through to MockRHI.destroyBuffer (via LODMesh.deinit)
    var test_mesh = LODMesh.init(allocator, .lod1);
    test_mesh.buffer_handle = 99;
    bridge.destroy(&test_mesh);
    try std.testing.expectEqual(@as(u32, 1), mock_state.destroy_calls);
    try std.testing.expectEqual(@as(u32, 0), test_mesh.buffer_handle); // deinit zeroes handle

    // Test toInterface round-trip: render through type-erased interface
    const iface = renderer.toInterface();

    // Set up meshes/regions with a renderable chunk
    var meshes: [LODLevel.count]MeshMap = undefined;
    var regions: [LODLevel.count]RegionMap = undefined;
    for (0..LODLevel.count) |i| {
        meshes[i] = MeshMap.init(allocator);
        regions[i] = RegionMap.init(allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            meshes[i].deinit();
            regions[i].deinit();
        }
    }

    var mesh = LODMesh.init(allocator, .lod1);
    mesh.buffer_handle = 42;
    mesh.vertex_count = 50;
    mesh.ready = true;

    var chunk = LODChunk.init(5, 0, .lod1);
    chunk.state = .renderable;

    const key = LODRegionKey{ .rx = 5, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{};

    // Render through the type-erased interface
    iface.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null, .terrain, null);

    // Verify the real renderer's draw was invoked through the interface
    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
}
