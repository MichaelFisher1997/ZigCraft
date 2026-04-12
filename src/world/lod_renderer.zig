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
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODConfig = lod_chunk.LODConfig;
const ILODConfig = lod_chunk.ILODConfig;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODRegionKeyContext = lod_chunk.LODRegionKeyContext;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;

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
            const lod_y_offset: f32 = -0.5;

            self.instance_data.clearRetainingCapacity();
            self.draw_list.clearRetainingCapacity();

            // Collect visible meshes
            // Process from highest LOD down
            var i: usize = LODLevel.count - 1;
            while (i > 0) : (i -= 1) {
                self.collectVisibleMeshes(&meshes[i], &regions[i], config, view_proj, camera_pos, frustum, lod_y_offset, chunk_checker, checker_ctx, use_frustum, max_distance_chunks) catch |err| {
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
            meshes: *const MeshMap,
            regions: *const RegionMap,
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
            var iter = meshes.iterator();
            while (iter.next()) |entry| {
                const mesh = entry.value_ptr.*;
                if (!mesh.ready or mesh.vertex_count == 0) continue;
                if (regions.get(entry.key_ptr.*)) |chunk| {
                    if (chunk.state != .renderable) continue;
                    const bounds = chunk.worldBounds();

                    if (max_distance_chunks) |max_dist| {
                        if (!isRegionInRange(bounds, camera_pos, max_dist)) continue;
                    }

                    // Skip the LOD region only when the entire covered chunk area is loaded.
                    if (chunk_checker) |checker| {
                        if (checker_ctx) |ctx_ptr| {
                            if (self.isCoveredByChunks(bounds, checker, ctx_ptr)) continue;
                        }
                    }

                    const aabb_min = Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, 0.0 - camera_pos.y, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z);
                    const aabb_max = Vec3.init(@as(f32, @floatFromInt(bounds.max_x)) - camera_pos.x, 256.0 - camera_pos.y, @as(f32, @floatFromInt(bounds.max_z)) - camera_pos.z);

                    if (use_frustum) {
                        if (!frustum.intersectsAABB(AABB.init(aabb_min, aabb_max))) continue;
                    }

                    const model = Mat4.translate(Vec3.init(@as(f32, @floatFromInt(bounds.min_x)) - camera_pos.x, -camera_pos.y + lod_y_offset, @as(f32, @floatFromInt(bounds.min_z)) - camera_pos.z));

                    const mask_radius = config.calculateMaskRadius();
                    try self.instance_data.append(self.allocator, .{
                        .model = model,
                        .mask_radius = mask_radius,
                        .padding = .{ 0, 0, 0 },
                    });
                    try self.draw_list.append(self.allocator, mesh);
                }
            }
        }

        fn isCoveredByChunks(
            _: *Self,
            bounds: LODChunk.WorldBounds,
            checker: ChunkChecker,
            ctx: *anyopaque,
        ) bool {
            // Convert world bounds to chunk coordinates (inclusive)
            // Use divFloor consistently for both min and max to handle negative coords symmetrically
            const min_cx = @divFloor(bounds.min_x, CHUNK_SIZE_X) - CHUNK_COVERAGE_PADDING;
            const min_cz = @divFloor(bounds.min_z, CHUNK_SIZE_Z) - CHUNK_COVERAGE_PADDING;
            // For max bounds, subtract 1 only after converting to chunk coords to maintain symmetry
            // This ensures that a region ending at world boundary 32 includes chunks up to cx=1, not cx=2
            const max_cx = @divFloor(bounds.max_x, CHUNK_SIZE_X) - 1 + CHUNK_COVERAGE_PADDING;
            const max_cz = @divFloor(bounds.max_z, CHUNK_SIZE_Z) - 1 + CHUNK_COVERAGE_PADDING;

            var cz = min_cz;
            while (cz <= max_cz) : (cz += 1) {
                var cx = min_cx;
                while (cx <= max_cx) : (cx += 1) {
                    if (!checker(cx, cz, ctx)) return false;
                }
            }
            return true;
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

fn isRegionInRange(bounds: LODChunk.WorldBounds, camera_pos: Vec3, max_distance_chunks: i32) bool {
    const cam_cx: i32 = @divFloor(@as(i32, @intFromFloat(camera_pos.x)), CHUNK_SIZE_X);
    const cam_cz: i32 = @divFloor(@as(i32, @intFromFloat(camera_pos.z)), CHUNK_SIZE_Z);

    const min_cx = @divFloor(bounds.min_x, CHUNK_SIZE_X);
    const max_cx = @divFloor(bounds.max_x - 1, CHUNK_SIZE_X);
    const min_cz = @divFloor(bounds.min_z, CHUNK_SIZE_Z);
    const max_cz = @divFloor(bounds.max_z - 1, CHUNK_SIZE_Z);

    const dx: i32 = if (cam_cx < min_cx)
        min_cx - cam_cx
    else if (cam_cx > max_cx)
        cam_cx - max_cx
    else
        0;

    const dz: i32 = if (cam_cz < min_cz)
        min_cz - cam_cz
    else if (cam_cz > max_cz)
        cam_cz - max_cz
    else
        0;

    return @max(dx, dz) <= max_distance_chunks;
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

    // Add mesh and region at LOD1
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{};

    // Create view-projection matrix that includes origin (where our chunk is)
    // Use identity for simplicity - frustum will include everything
    const view_proj = Mat4.identity;
    const camera_pos = Vec3.zero;

    // Call render with explicit parameters
    renderer.render(&meshes, &regions, mock_config.interface(), view_proj, camera_pos, null, null, true, null);

    // Verify draw was called with correct parameters
    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
    try std.testing.expectEqual(@as(u32, 42), mock_state.last_buffer_handle);
    try std.testing.expectEqual(@as(u32, 100), mock_state.last_vertex_count);
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

    var chunk = LODChunk.init(0, 0, .lod1);
    chunk.state = .renderable;

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    try meshes[1].put(key, &mesh);
    try regions[1].put(key, &chunk);

    var mock_config = LODConfig{};

    // Render through the type-erased interface
    iface.render(&meshes, &regions, mock_config.interface(), Mat4.identity, Vec3.zero, null, null, true, null);

    // Verify the real renderer's draw was invoked through the interface
    try std.testing.expectEqual(@as(u32, 1), mock_state.draw_calls);
    try std.testing.expectEqual(@as(u32, 1), mock_state.set_matrix_calls);
}
