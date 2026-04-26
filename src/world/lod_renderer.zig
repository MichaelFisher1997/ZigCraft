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
//! list. Each LODChunk has an AABB that is tested against the camera frustum.
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
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const worldToChunkFromFloat = @import("chunk.zig").worldToChunkFromFloat;

const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const LODRenderInterface = lod_gpu.LODRenderInterface;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const ChunkChecker = lod_gpu.ChunkChecker;

const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const AABB = @import("../engine/math/aabb.zig").AABB;
const rhi_types = @import("../engine/graphics/rhi_types.zig");
const log = @import("../engine/core/log.zig");
const build_options = @import("build_options");

const CHUNK_COVERAGE_PADDING: i32 = 1;

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
        instance_buffers: [rhi_types.MAX_FRAMES_IN_FLIGHT]rhi_types.BufferHandle,
        frame_index: usize,

        pub fn init(allocator: std.mem.Allocator, rhi: RHI) !*Self {
            const renderer = try allocator.create(Self);

            // Init MDI buffers (capacity for ~2048 LOD regions)
            const max_regions = 2048;
            var instance_buffers: [rhi_types.MAX_FRAMES_IN_FLIGHT]rhi_types.BufferHandle = undefined;
            for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |i| {
                instance_buffers[i] = try rhi.createBuffer(max_regions * @sizeOf(rhi_types.InstanceData), .storage);
            }

            renderer.* = .{
                .allocator = allocator,
                .rhi = rhi,
                .instance_data = .empty,
                .draw_list = .empty,
                .instance_buffers = instance_buffers,
                .frame_index = 0,
            };

            return renderer;
        }

        pub fn deinit(self: *Self) void {
            for (0..rhi_types.MAX_FRAMES_IN_FLIGHT) |i| {
                if (self.instance_buffers[i] != 0) {
                    self.rhi.destroyBuffer(self.instance_buffers[i]);
                }
            }
            self.instance_data.deinit(self.allocator);
            self.draw_list.deinit(self.allocator);
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
        ) void {
            // Update frame index
            self.frame_index = self.rhi.getFrameIndex();

            // Use the LOD descriptor set while issuing LOD draws, then restore
            // normal terrain descriptor mode so the chunk pass keeps its textures.
            defer if (@hasDecl(RHI, "setInstanceBuffer")) self.rhi.setInstanceBuffer(0);
            self.rhi.setLODInstanceBuffer(self.instance_buffers[self.frame_index]);

            const frustum = Frustum.fromViewProj(view_proj);
            // Keep LOD terrain slightly below full chunks so the handoff zone does not
            // z-fight when both representations overlap during the transition.
            const lod_y_offset: f32 = -1.0;

            self.instance_data.clearRetainingCapacity();
            self.draw_list.clearRetainingCapacity();

            // Collect visible meshes
            // Process from highest LOD down
            var i: usize = LODLevel.count - 1;
            while (i > 0) : (i -= 1) {
                const lod: LODLevel = @enumFromInt(@as(u3, @intCast(i)));
                self.collectVisibleMeshes(meshes, regions, lod, config, view_proj, camera_pos, frustum, lod_y_offset, chunk_checker, checker_ctx, use_frustum, max_distance_chunks) catch |err| {
                    log.log.errWithTrace("Failed to collect visible meshes for LOD{}: {}", .{ i, err });
                };
            }

            if (self.instance_data.items.len == 0) return;

            for (self.draw_list.items, 0..) |mesh, idx| {
                const instance = self.instance_data.items[idx];
                self.rhi.setModelMatrix(instance.model, Vec3.one, instance.mask_radius);
                self.rhi.draw(mesh.buffer_handle, mesh.vertex_count, .triangles);
            }
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
        ) !void {
            const meshes = &all_meshes[@intFromEnum(lod)];
            const regions = &all_regions[@intFromEnum(lod)];
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
                const mesh = entry.value_ptr.*;
                if (!mesh.ready or mesh.vertex_count == 0) continue;
                if (regions.get(entry.key_ptr.*)) |chunk| {
                    if (chunk.state != .renderable) continue;
                    if (self.isCoveredByFinerLOD(entry.key_ptr.*, all_meshes, all_regions)) continue;

                    const bounds = chunk.worldBounds();
                    const chunk_bounds = chunk.chunkBounds();

                    if (max_distance_chunks) |max_dist| {
                        if (!isRegionInRange(chunk_bounds, camera_pos, max_dist)) continue;
                    }

                    if (chunk_checker) |checker| {
                        if (checker_ctx) |ctx_ptr| {
                            const camera_chunk = worldToChunkFromFloat(camera_pos.x, camera_pos.z);
                            const pc_x = camera_chunk.chunk_x;
                            const pc_z = camera_chunk.chunk_z;
                            const lod0_radius = config.getRadii()[0];
                            const cov = self.isCoveredByChunks(bounds, checker, ctx_ptr, pc_x, pc_z, lod0_radius);
                            if (cov.covered) {
                                lod_covered += 1;
                                continue;
                            }
                            if (lod_rendered == 0) {
                                first_missing_cx = cov.missing_cx;
                                first_missing_cz = cov.missing_cz;
                                first_missing_in_radius = cov.missing_chunk_in_radius;
                            }
                        }
                    }

                    lod_rendered += 1;

                    const aabb_min = Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, 0.0 - camera_pos.y, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z);
                    const aabb_max = Vec3.init(@as(f32, @floatFromInt(bounds.max_x)) - camera_pos.x, 256.0 - camera_pos.y, @as(f32, @floatFromInt(bounds.max_z)) - camera_pos.z);

                    if (use_frustum) {
                        if (!frustum.intersectsAABB(AABB.init(aabb_min, aabb_max))) continue;
                    }

                    const model = Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y + lod_y_offset, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z));

                    // Keep coarser LODs visible until full-detail chunks cover them.
                    // Culling against inner LOD bands creates visible holes while finer
                    // LOD regions are still streaming in.
                    const mask_radius = config.calculateMaskRadius();
                    try self.instance_data.append(self.allocator, .{
                        .model = model,
                        .mask_radius = mask_radius,
                        .padding = .{ 0, 0, 0 },
                    });
                    try self.draw_list.append(self.allocator, mesh);
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
            key: LODRegionKey,
            all_meshes: *const [LODLevel.count]MeshMap,
            all_regions: *const [LODLevel.count]RegionMap,
        ) bool {
            if (key.lod == .lod1) return false;

            const finer_lod: LODLevel = @enumFromInt(@as(u3, @intCast(@intFromEnum(key.lod) - 1)));
            const finer_index = @intFromEnum(finer_lod);
            const finer_scale: i32 = @intCast(finer_lod.chunksPerSide());
            const bounds = key.chunkBounds();
            const finer_min_rx = @divFloor(bounds.min_x, finer_scale);
            const finer_max_rx = @divFloor(bounds.max_x, finer_scale);
            const finer_min_rz = @divFloor(bounds.min_z, finer_scale);
            const finer_max_rz = @divFloor(bounds.max_z, finer_scale);

            var rz = finer_min_rz;
            while (rz <= finer_max_rz) : (rz += 1) {
                var rx = finer_min_rx;
                while (rx <= finer_max_rx) : (rx += 1) {
                    const finer_key = LODRegionKey{ .rx = rx, .rz = rz, .lod = finer_lod };
                    const finer_chunk = all_regions[finer_index].get(finer_key) orelse return false;
                    if (finer_chunk.state != .renderable) return false;

                    const finer_mesh = all_meshes[finer_index].get(finer_key) orelse return false;
                    if (!finer_mesh.ready or finer_mesh.vertex_count == 0) return false;
                }
            }

            return true;
        }

        const CoverageResult = struct {
            covered: bool,
            missing_cx: i32,
            missing_cz: i32,
            missing_chunk_in_radius: bool,
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
                    if (!checker(cx, cz, ctx)) {
                        return .{ .covered = false, .missing_cx = cx, .missing_cz = cz, .missing_chunk_in_radius = true };
                    }
                }
            }

            if (has_outside_radius) {
                return .{ .covered = false, .missing_cx = first_outside_cx, .missing_cz = first_outside_cz, .missing_chunk_in_radius = false };
            }
            return .{ .covered = true, .missing_cx = 0, .missing_cz = 0, .missing_chunk_in_radius = false };
        }

        /// Create a LODGPUBridge that delegates to this renderer's RHI.
        pub fn createGPUBridge(self: *Self) LODGPUBridge {
            const Wrapper = struct {
                fn onUpload(mesh: *LODMesh, ctx: *anyopaque) rhi_types.RhiError!void {
                    const rhi: *RHI = @ptrCast(@alignCast(ctx));
                    return mesh.upload(rhi.*);
                }
                fn onDestroy(mesh: *LODMesh, ctx: *anyopaque) void {
                    const rhi: *RHI = @ptrCast(@alignCast(ctx));
                    mesh.deinit(rhi.*);
                }
                fn onWaitIdle(ctx: *anyopaque) void {
                    const rhi: *RHI = @ptrCast(@alignCast(ctx));
                    rhi.waitIdle();
                }
            };
            return .{
                .on_upload = Wrapper.onUpload,
                .on_destroy = Wrapper.onDestroy,
                .on_wait_idle = Wrapper.onWaitIdle,
                .ctx = @ptrCast(&self.rhi),
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
                ) void {
                    const renderer: *Self = @ptrCast(@alignCast(self_ptr));
                    renderer.render(meshes, regions, config, view_proj, camera_pos, chunk_checker, checker_ctx, use_frustum, max_distance_chunks);
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

    // Verify init created buffers for each frame in flight
    try std.testing.expectEqual(@as(u32, rhi_types.MAX_FRAMES_IN_FLIGHT), mock_state.buffers_created);
    try std.testing.expectEqual(@as(u32, 0), mock_state.buffers_destroyed);

    renderer.deinit();

    // Verify deinit destroyed all buffers
    try std.testing.expectEqual(@as(u32, rhi_types.MAX_FRAMES_IN_FLIGHT), mock_state.buffers_destroyed);
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
    mesh.vertex_count = 100;
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

    // Call render with explicit parameters
    renderer.render(&meshes, &regions, mock_config.interface(), view_proj, camera_pos, null, null, false, null);

    // Verify draw was called with correct parameters
    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
    try std.testing.expectEqual(@as(u32, 42), mock_state.last_buffer_handle);
    try std.testing.expectEqual(@as(u32, 100), mock_state.last_vertex_count);
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
        .radii = .{ 16, 32, 64, 100 },
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null);

    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
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
        .radii = .{ 16, 32, 64, 100 },
    };

    renderer.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null);

    try std.testing.expectEqual(@as(u32, 4), mock_state.draw_calls);
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
    iface.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, false, null);

    // Verify the real renderer's draw was invoked through the interface
    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
}
