//! LOD Mesh generation for distant terrain rendering.
//!
//! LOD meshes are simplified versions of chunk meshes. Region size, grid
//! detail, and span-vs-heightfield behavior are selected by runtime settings.
//!
//! Key simplifications:
//! - No greedy meshing (simple quads per grid cell)
//! - No lighting calculations
//! - Fluid vertices are split into a separate water range for WaterPass
//! - Biome colors averaged per cell

const std = @import("std");
const sync = @import("sync");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const world_core = @import("world-core");
const BiomeId = world_core.BiomeId;
const biome_mod = @import("biome_color_provider.zig");
const BlockType = world_core.BlockType;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi_pkg = @import("engine-rhi").rhi;
const rhi_types = @import("engine-rhi");
const Vertex = rhi_types.Vertex;
const BufferHandle = rhi_types.BufferHandle;
const BufferUsage = rhi_types.BufferUsage;
const RhiError = rhi_types.RhiError;
const encodeColor = rhi_types.encodeColor;
const encodeNormal = rhi_types.encodeNormal;
const encodeMeta = rhi_types.encodeMeta;
const encodeBlocklight = rhi_types.encodeBlocklight;
const QuadricSimplifier = @import("world-meshing").meshing.quadric_simplifier.QuadricSimplifier;
const engine_core = @import("engine-core");
const log = @import("engine-core").log;
const lod_seam = @import("lod_seam.zig");

pub const EdgeDir = lod_seam.EdgeDir;
pub const SeamConfig = lod_seam.SeamConfig;
pub const stitchEdge = lod_seam.stitchEdge;

pub const LODMeshResources = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createBuffer: *const fn (ptr: *anyopaque, size: usize, usage: BufferUsage) RhiError!BufferHandle,
        uploadBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, data: []const u8) RhiError!void,
        updateBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void,
        destroyBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        waitIdle: *const fn (ptr: *anyopaque) void,
    };

    pub fn fromRHI(rhi: *rhi_pkg.RHI) LODMeshResources {
        return .{ .ptr = rhi, .vtable = &rhi_vtable };
    }

    pub fn fromProvider(comptime Provider: type, provider: *Provider) LODMeshResources {
        const Adapter = struct {
            fn createBuffer(ptr: *anyopaque, size: usize, usage: BufferUsage) RhiError!BufferHandle {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "resourceManager")) {
                    return typed.resourceManager().createBuffer(size, usage);
                }
                return typed.createBuffer(size, usage);
            }

            fn uploadBuffer(ptr: *anyopaque, handle: BufferHandle, data: []const u8) RhiError!void {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "resourceManager")) {
                    return typed.resourceManager().uploadBuffer(handle, data);
                }
                if (@hasDecl(Provider, "uploadBuffer")) {
                    return typed.uploadBuffer(handle, data);
                }
                if (@hasDecl(Provider, "updateBuffer")) {
                    return typed.updateBuffer(handle, 0, data);
                }
                return error.InvalidState;
            }

            fn updateBuffer(ptr: *anyopaque, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "resourceManager")) {
                    return typed.resourceManager().updateBuffer(handle, offset, data);
                }
                if (@hasDecl(Provider, "updateBuffer")) {
                    return typed.updateBuffer(handle, offset, data);
                }
                if (offset == 0 and @hasDecl(Provider, "uploadBuffer")) {
                    return typed.uploadBuffer(handle, data);
                }
                return error.InvalidState;
            }

            fn destroyBuffer(ptr: *anyopaque, handle: BufferHandle) void {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "resourceManager")) {
                    typed.resourceManager().destroyBuffer(handle);
                    return;
                }
                typed.destroyBuffer(handle);
            }

            fn waitIdle(ptr: *anyopaque) void {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "waitIdle")) {
                    typed.waitIdle();
                }
            }

            const vtable = VTable{
                .createBuffer = @This().createBuffer,
                .uploadBuffer = @This().uploadBuffer,
                .updateBuffer = @This().updateBuffer,
                .destroyBuffer = @This().destroyBuffer,
                .waitIdle = @This().waitIdle,
            };
        };

        return .{ .ptr = provider, .vtable = &Adapter.vtable };
    }

    pub fn createBuffer(self: LODMeshResources, size: usize, usage: BufferUsage) RhiError!BufferHandle {
        return self.vtable.createBuffer(self.ptr, size, usage);
    }

    pub fn uploadBuffer(self: LODMeshResources, handle: BufferHandle, data: []const u8) RhiError!void {
        return self.vtable.uploadBuffer(self.ptr, handle, data);
    }

    pub fn updateBuffer(self: LODMeshResources, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
        return self.vtable.updateBuffer(self.ptr, handle, offset, data);
    }

    pub fn destroyBuffer(self: LODMeshResources, handle: BufferHandle) void {
        self.vtable.destroyBuffer(self.ptr, handle);
    }

    pub fn waitIdle(self: LODMeshResources) void {
        self.vtable.waitIdle(self.ptr);
    }

    const rhi_vtable = VTable{
        .createBuffer = struct {
            fn f(ptr: *anyopaque, size: usize, usage: BufferUsage) RhiError!BufferHandle {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                return rhi.resourceManager().createBuffer(size, usage);
            }
        }.f,
        .uploadBuffer = struct {
            fn f(ptr: *anyopaque, handle: BufferHandle, data: []const u8) RhiError!void {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                return rhi.resourceManager().uploadBuffer(handle, data);
            }
        }.f,
        .updateBuffer = struct {
            fn f(ptr: *anyopaque, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                return rhi.resourceManager().updateBuffer(handle, offset, data);
            }
        }.f,
        .destroyBuffer = struct {
            fn f(ptr: *anyopaque, handle: BufferHandle) void {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                rhi.resourceManager().destroyBuffer(handle);
            }
        }.f,
        .waitIdle = struct {
            fn f(ptr: *anyopaque) void {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                rhi.waitIdle();
            }
        }.f,
    };
};

/// Keep individual Vulkan staging-ring allocations bounded. Large LOD meshes
/// can exceed the remaining per-frame staging space even when the frame-level
/// upload budget is respected; splitting avoids one oversized allocation.
pub const MAX_STAGING_UPDATE_BYTES: usize = 8 * 1024 * 1024;

pub fn updateBufferChunked(resources: LODMeshResources, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
    var cursor: usize = 0;
    while (cursor < data.len) {
        const chunk_len = @min(MAX_STAGING_UPDATE_BYTES, data.len - cursor);
        try resources.updateBuffer(handle, offset + cursor, data[cursor .. cursor + chunk_len]);
        cursor += chunk_len;
    }
}

pub fn uploadBufferChunked(resources: LODMeshResources, handle: BufferHandle, data: []const u8) RhiError!void {
    if (data.len <= MAX_STAGING_UPDATE_BYTES) {
        try resources.uploadBuffer(handle, data);
        return;
    }
    try updateBufferChunked(resources, handle, 0, data);
}

pub const LODMeshRenderContext = struct {
    ptr: *anyopaque,
    draw_fn: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: rhi_types.DrawMode) void,
    draw_offset_fn: ?*const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: rhi_types.DrawMode, offset: usize) void = null,

    pub fn draw(self: LODMeshRenderContext, handle: BufferHandle, count: u32, mode: rhi_types.DrawMode) void {
        self.draw_fn(self.ptr, handle, count, mode);
    }

    pub fn drawOffset(self: LODMeshRenderContext, handle: BufferHandle, count: u32, mode: rhi_types.DrawMode, offset: usize) void {
        if (self.draw_offset_fn) |draw_offset| {
            draw_offset(self.ptr, handle, count, mode, offset);
            return;
        }
        self.draw(handle, count, mode);
    }
};

/// Size of each LOD mesh grid cell in blocks
pub fn getCellSize(lod: LODLevel) u32 {
    return LODSimplifiedData.getCellSizeBlocks(lod);
}

/// LOD Mesh for a single LOD region
pub const LODMesh = struct {
    /// GPU buffer handle
    buffer_handle: BufferHandle = 0,
    /// Number of vertices
    vertex_count: u32 = 0,
    /// Number of opaque terrain vertices at the start of the buffer.
    opaque_vertex_count: u32 = 0,
    /// Byte offset from `vertex_offset` to translucent LOD water vertices.
    water_vertex_offset: usize = 0,
    /// Number of translucent LOD water vertices.
    water_vertex_count: u32 = 0,
    /// Buffer capacity (vertices)
    capacity: u32 = 0,
    /// Byte offset inside the vertex buffer. Non-zero when backed by a shared LOD pool.
    vertex_offset: usize = 0,
    /// True when buffer_handle is owned by a shared LOD vertex pool.
    pooled: bool = false,
    /// Pending vertices to upload
    pending_vertices: ?[]Vertex = null,
    /// Allocator
    allocator: std.mem.Allocator,
    /// Mutex for thread safety
    mutex: sync.Mutex = .{},
    /// LOD level
    lod_level: LODLevel,
    /// Ready for rendering
    ready: bool = false,

    pub fn init(allocator: std.mem.Allocator, lod: LODLevel) LODMesh {
        return .{
            .allocator = allocator,
            .lod_level = lod,
        };
    }

    pub fn deinit(self: *LODMesh, resources: LODMeshResources) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pooled) {
            std.debug.assert(false);
            return;
        }

        if (self.buffer_handle != 0 and !self.pooled) {
            resources.destroyBuffer(self.buffer_handle);
        }
        self.buffer_handle = 0;
        self.vertex_offset = 0;
        self.opaque_vertex_count = 0;
        self.water_vertex_offset = 0;
        self.water_vertex_count = 0;
        self.pooled = false;
        if (self.pending_vertices) |p| {
            self.allocator.free(p);
            self.pending_vertices = null;
        }
        self.ready = false;
    }

    pub fn clearPendingVertices(self: *LODMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_vertices) |p| {
            self.allocator.free(p);
            self.pending_vertices = null;
        }
    }

    pub fn pendingUploadBytes(self: *LODMesh) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        const pending = self.pending_vertices orelse return 0;
        return std.mem.sliceAsBytes(pending).len;
    }

    /// Build mesh from simplified LOD data (heightmap-based)
    pub fn buildFromSimplifiedData(self: *LODMesh, data: *const LODSimplifiedData, world_x: i32, world_z: i32, atlas: *const TextureAtlas) !void {
        if (data.width < 2) return error.EmptyData;

        const region_size: f32 = @floatFromInt(lod_chunk.regionSizeBlocks(self.lod_level));
        const cell_size = region_size / @as(f32, @floatFromInt(data.width - 1));

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(self.allocator);
        var water_vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer water_vertices.deinit(self.allocator);
        const diag_enabled = engine_core.envFlag("ZIGCRAFT_LOD_DIAG", false);

        var gz: u32 = 0;
        while (gz + 1 < data.width) : (gz += 1) {
            var gx: u32 = 0;
            while (gx + 1 < data.width) : (gx += 1) {
                const cell_color = cell_color_for_lod(data, gx, gz, self.lod_level);
                const lit_cell_color = applyColorBrightness(cell_color, ambient_occlusion_for_lod(data, gx, gz, self.lod_level));
                const wx = @as(f32, @floatFromInt(gx)) * cell_size;
                const wz = @as(f32, @floatFromInt(gz)) * cell_size;
                const size = cell_size;

                const is_water_cell = is_lod_water_cell_for_lod(data, gx, gz, self.lod_level);
                const base_block = terrainBlockForLODQuadForLOD(data, gx, gz, is_water_cell, self.lod_level);
                const base_height = quantizedCellVisualTerrainHeightForLOD(data, gx, gz, self.lod_level, is_water_cell);
                const folded_canopy = foldedCanopyColumnForLOD(data, gx, gz, self.lod_level, base_height, base_block, is_water_cell);
                const top_block = if (folded_canopy) |folded| folded.block else base_block;
                const column_height = if (folded_canopy) |folded| folded.height else base_height;
                const top_tile = if (folded_canopy != null) Vertex.LOD_TILE_ID else getLodTopTile(top_block, atlas);
                const side_tile = if (folded_canopy != null) Vertex.LOD_TILE_ID else getLodSideTile(top_block, atlas);
                const base_top_color = if (folded_canopy) |folded|
                    applyColorBrightness(folded.color, ambient_occlusion_for_lod(data, gx, gz, self.lod_level))
                else
                    getLodTopColor(top_block, top_tile, lit_cell_color);
                const top_color = applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, top_block, .top, base_top_color), top_block, .top, atlas);
                const side_color = applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, top_block, .side, base_top_color), top_block, .side, atlas);

                try addTopFaceQuad(self.allocator, &vertices, wx, column_height, wz, size, unpackR(top_color), unpackG(top_color), unpackB(top_color), top_tile, world_x, world_z);
                try addSteppedHeightfieldSides(self.allocator, &vertices, data, gx, gz, self.lod_level, wx, wz, size, column_height, side_color, side_tile, world_x, world_z);

                if (is_water_cell) {
                    const water_height = quantizedWaterSurfaceHeightForCell(data, gx, gz, self.lod_level);
                    if (water_height > column_height + 0.01) {
                        const water_tile = getLodTopTile(.water, atlas);
                        const water_color = tintColorForLodFace(data, gx, gz, self.lod_level, .water, .top, packBlockDefaultColor(.water, 0x3366CC));
                        try addTopFaceQuad(self.allocator, &water_vertices, wx, water_height, wz, size, unpackR(water_color), unpackG(water_color), unpackB(water_color), water_tile, world_x, world_z);
                    }
                }

                if (folded_canopy == null and !is_water_cell and shouldRenderLODTree(top_block)) {
                    const vegetation = representativeVegetationForLOD(data, gx, gz, self.lod_level);
                    if (vegetation.tree_coverage >= LOD_TREE_COVERAGE_THRESHOLD) {
                        try addTreeColumn(self.allocator, &vertices, data, gx, gz, self.lod_level, wx, wz, size, column_height, vegetation, atlas, world_x, world_z);
                    }
                }
            }
        }

        if (diag_enabled) {
            const max_adjust = maxStitchedHeightAdjustment(data);
            if (max_adjust > 0.25) {
                log.log.info("LOD_SEAM_DIAG lod={} origin=({}, {}) max_edge_adjust={d:.2}", .{ @intFromEnum(self.lod_level), world_x, world_z, max_adjust });
            }
        }

        // Store pending vertices
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_vertices) |p| {
            self.allocator.free(p);
        }

        const opaque_count = vertices.items.len;
        const water_count = water_vertices.items.len;
        const total_count = opaque_count + water_count;
        self.opaque_vertex_count = @intCast(opaque_count);
        self.water_vertex_offset = opaque_count * @sizeOf(Vertex);
        self.water_vertex_count = @intCast(water_count);

        if (total_count > 0) {
            const pending = try self.allocator.alloc(Vertex, total_count);
            @memcpy(pending[0..opaque_count], vertices.items);
            @memcpy(pending[opaque_count..total_count], water_vertices.items);
            self.pending_vertices = pending;
        } else {
            self.pending_vertices = null;
        }
    }

    /// Build mesh from rich LOD column/span data, falling back to the stable heightfield path
    /// when spans are not available. This is intentionally exposed as a test/config hook.
    pub fn buildFromColumnSpans(self: *LODMesh, data: *const LODSimplifiedData, world_x: i32, world_z: i32, atlas: *const TextureAtlas) !void {
        if (data.width < 2) return error.EmptyData;
        if (!data.hasVerticalSpans()) return self.buildFromSimplifiedData(data, world_x, world_z, atlas);

        const region_size: f32 = @floatFromInt(lod_chunk.regionSizeBlocks(self.lod_level));
        const cell_size = region_size / @as(f32, @floatFromInt(data.width - 1));

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(self.allocator);
        var water_vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer water_vertices.deinit(self.allocator);

        var found_span = false;
        var gz: u32 = 0;
        while (gz + 1 < data.width) : (gz += 1) {
            var gx: u32 = 0;
            while (gx + 1 < data.width) : (gx += 1) {
                var spans_buf: [world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan = undefined;
                const span_count = collectColumnSpans(data, gx, gz, self.lod_level, &spans_buf);
                if (span_count == 0) continue;
                found_span = true;

                // Snap the surface (top) span to the stitched boundary height at
                // region/band borders so the span path matches the heightfield
                // seam behavior (issue #752 Phase 5.5).
                const on_boundary = (gx == 0) or (gz == 0) or
                    (gx + 1 >= data.width - 1) or (gz + 1 >= data.width - 1);
                if (on_boundary) {
                    if (highestSolidSpanIndex(spans_buf[0..span_count])) |solid_idx| {
                        const stitched_top = quantizedHeight(stitchedHeight(data, gx, gz));
                        spans_buf[solid_idx].max_height = if (isLeafBlock(spans_buf[solid_idx].block))
                            @max(spans_buf[solid_idx].max_height, stitched_top)
                        else
                            stitched_top;
                    }
                }

                const wx = @as(f32, @floatFromInt(gx)) * cell_size;
                const wz = @as(f32, @floatFromInt(gz)) * cell_size;

                var span_index: usize = 0;
                while (span_index < span_count) : (span_index += 1) {
                    const span = spans_buf[span_index];
                    const top_tile = getLodTopTile(span.block, atlas);
                    const side_tile = getLodSideTile(span.block, atlas);
                    const span_color = applyColorBrightness(span.color, span.ambient_occlusion);
                    const lit_color = if (span.block == .water)
                        tintColorForLodFace(data, gx, gz, self.lod_level, .water, .side, span_color)
                    else
                        applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, span.block, .side, span_color), span.block, .side, atlas);
                    const top_color = if (span.block == .water)
                        tintColorForLodFace(data, gx, gz, self.lod_level, .water, .top, packBlockDefaultColor(.water, 0x3366CC))
                    else
                        getLodTopColor(span.block, top_tile, applyTextureLuminance(tintColorForLodFace(data, gx, gz, self.lod_level, span.block, .top, span_color), span.block, .top, atlas));

                    if (span.block == .water) {
                        const water_height = quantizedWaterSurfaceHeightForSpan(data, gx, gz, self.lod_level, span.max_height);
                        try addTopFaceQuad(self.allocator, &water_vertices, wx, water_height, wz, cell_size, unpackR(top_color), unpackG(top_color), unpackB(top_color), top_tile, world_x, world_z);
                        continue;
                    }

                    if (isLeafBlock(span.block)) {
                        var vegetation = representativeVegetationForLOD(data, gx, gz, self.lod_level);
                        if (vegetation.leaves == .air) vegetation.leaves = span.block;
                        if (vegetation.tree_coverage < LOD_TREE_COVERAGE_THRESHOLD) vegetation.tree_coverage = LOD_TREE_COVERAGE_THRESHOLD;
                        if (vegetation.avg_tree_height < 2.0) vegetation.avg_tree_height = @max(2.0, span.max_height - span.min_height);
                        const tree_is_water_cell = is_lod_water_cell_for_lod(data, gx, gz, self.lod_level);
                        const tree_base_height = quantizedCellVisualTerrainHeightForLOD(data, gx, gz, self.lod_level, tree_is_water_cell);
                        try addTreeCanopyColumn(self.allocator, &vertices, data, gx, gz, self.lod_level, wx, wz, cell_size, tree_base_height, span.min_height, span.max_height, vegetation, atlas, world_x, world_z);
                        continue;
                    }

                    try addTopFaceQuad(self.allocator, &vertices, wx, span.max_height, wz, cell_size, unpackR(top_color), unpackG(top_color), unpackB(top_color), top_tile, world_x, world_z);
                    try addExposedSpanFaces(self.allocator, &vertices, data, gx, gz, self.lod_level, span, wx, wz, cell_size, lit_color, side_tile, world_x, world_z);

                    // Floating span (overhang): there is open air below this
                    // span's floor, so add a downward-facing bottom quad.
                    const supported_from_below = if (span_index == 0)
                        span.min_height <= 0.01
                    else
                        spans_buf[span_index - 1].max_height >= span.min_height - 0.01;
                    if (!supported_from_below) {
                        try addBottomFaceQuad(self.allocator, &vertices, wx, span.min_height, wz, cell_size, unpackR(lit_color) * 0.5, unpackG(lit_color) * 0.5, unpackB(lit_color) * 0.5, side_tile, world_x, world_z);
                    }
                }
            }
        }

        if (!found_span) return self.buildFromSimplifiedData(data, world_x, world_z, atlas);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_vertices) |p| {
            self.allocator.free(p);
        }

        const opaque_count = vertices.items.len;
        const water_count = water_vertices.items.len;
        const total_count = opaque_count + water_count;
        self.opaque_vertex_count = @intCast(opaque_count);
        self.water_vertex_offset = opaque_count * @sizeOf(Vertex);
        self.water_vertex_count = @intCast(water_count);

        if (total_count > 0) {
            const pending = try self.allocator.alloc(Vertex, total_count);
            @memcpy(pending[0..opaque_count], vertices.items);
            @memcpy(pending[opaque_count..total_count], water_vertices.items);
            self.pending_vertices = pending;
        } else {
            self.pending_vertices = null;
        }
    }

    /// Build mesh from simplified LOD data using QEM decimation.
    /// Generates a full-detail heightmap mesh first, then simplifies via quadric error metrics.
    /// Falls back to naive `buildFromSimplifiedData` if QEM input is too small or fails.
    pub fn buildFromSimplifiedDataWithQEM(
        self: *LODMesh,
        data: *const LODSimplifiedData,
        world_x: i32,
        world_z: i32,
        target_triangles: u32,
        min_input_triangles: u32,
        atlas: *const TextureAtlas,
    ) !void {
        const full_mesh = buildFullDetailHeightmapMesh(self.allocator, self.lod_level, data, world_x, world_z, atlas) catch |err| {
            log.log.warn("LOD{} full-detail mesh build failed, falling back: {}", .{ @intFromEnum(self.lod_level), err });
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        };
        defer {
            self.allocator.free(full_mesh.vertices);
            self.allocator.free(full_mesh.indices);
        }

        if (full_mesh.indices.len % 3 != 0) {
            log.log.warn("LOD{} mesh has invalid index count {}, falling back", .{ @intFromEnum(self.lod_level), full_mesh.indices.len });
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        }
        const input_triangles: u32 = @intCast(full_mesh.indices.len / 3);
        if (input_triangles < min_input_triangles) {
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        }

        // No simplification needed — target already meets or exceeds input
        if (target_triangles >= input_triangles) {
            try self.setPendingFromIndexed(full_mesh.vertices, full_mesh.indices);
            return;
        }
        const effective_target = target_triangles;

        const simplified = QuadricSimplifier.simplify(
            self.allocator,
            full_mesh.vertices,
            full_mesh.indices,
            effective_target,
        ) catch |err| {
            log.log.warn("LOD{} QEM simplification failed, falling back to naive: {}", .{ @intFromEnum(self.lod_level), err });
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        };
        defer {
            self.allocator.free(simplified.vertices);
            self.allocator.free(simplified.indices);
        }

        if (simplified.indices.len == 0) {
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        }

        log.log.trace("LOD{} QEM: {} -> {} triangles (error={d:.2})", .{
            @intFromEnum(self.lod_level),
            simplified.original_triangle_count,
            simplified.simplified_triangle_count,
            simplified.error_estimate,
        });

        self.setPendingFromIndexed(simplified.vertices, simplified.indices) catch |err| {
            log.log.warn("LOD{} failed to expand simplified mesh, falling back: {}", .{ @intFromEnum(self.lod_level), err });
            return self.buildFromSimplifiedData(data, world_x, world_z, atlas);
        };
    }

    /// Convert indexed triangle mesh to non-indexed vertex list and store as pending.
    fn setPendingFromIndexed(self: *LODMesh, vertices: []const Vertex, indices: []const u32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_vertices) |p| {
            self.allocator.free(p);
            self.pending_vertices = null;
        }
        self.opaque_vertex_count = 0;
        self.water_vertex_offset = 0;
        self.water_vertex_count = 0;

        if (indices.len == 0) return;

        const expanded = try self.allocator.alloc(Vertex, indices.len);
        errdefer self.allocator.free(expanded);
        for (expanded, 0..) |*dst, i| {
            const idx = indices[i];
            if (idx >= vertices.len) return error.InvalidIndex;
            dst.* = vertices[idx];
        }
        self.pending_vertices = expanded;
        self.opaque_vertex_count = @intCast(expanded.len);
        self.water_vertex_offset = expanded.len * @sizeOf(Vertex);
        self.water_vertex_count = 0;
    }

    /// Build mesh from full chunk heightmap data
    pub fn buildFromHeightmap(
        self: *LODMesh,
        heightmap: []const f32,
        biomes: []const BiomeId,
        width: u32,
        world_x: i32,
        world_z: i32,
        atlas: *const TextureAtlas,
    ) !void {
        const cell_size = getCellSize(self.lod_level);

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(self.allocator);

        var gz: u32 = 0;
        while (gz < width) : (gz += 1) {
            var gx: u32 = 0;
            while (gx < width) : (gx += 1) {
                const idx = gx + gz * width;
                const height = heightmap[idx];
                const biome = biomes[idx];
                const surface_block = biome.getSurfaceBlock();
                const color = applyTextureLuminance(biome_mod.getBiomeColor(biome), surface_block, .top, atlas);
                const side_color = applyTextureLuminance(biome_mod.getBiomeColor(biome), surface_block, .side, atlas);

                const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;
                const sr: f32 = @as(f32, @floatFromInt((side_color >> 16) & 0xFF)) / 255.0;
                const sg: f32 = @as(f32, @floatFromInt((side_color >> 8) & 0xFF)) / 255.0;
                const sb: f32 = @as(f32, @floatFromInt(side_color & 0xFF)) / 255.0;

                const wx: f32 = @floatFromInt(gx * cell_size);
                const wz: f32 = @floatFromInt(gz * cell_size);
                const wy: f32 = height;
                const size: f32 = @floatFromInt(cell_size);

                const tiles = atlas.getTilesForBlock(@intFromEnum(surface_block));

                try addTopFaceQuad(self.allocator, &vertices, wx, wy, wz, size, r, g, b, tiles.top, world_x, world_z);

                // Add skirts
                const skirt_depth = size * 4.0;
                if (gx == 0) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, sr * 0.6, sg * 0.6, sb * 0.6, .west, tiles.side, world_x, world_z);
                }
                if (gx == width - 1) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, sr * 0.6, sg * 0.6, sb * 0.6, .east, tiles.side, world_x, world_z);
                }
                if (gz == 0) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, sr * 0.7, sg * 0.7, sb * 0.7, .north, tiles.side, world_x, world_z);
                }
                if (gz == width - 1) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, sr * 0.7, sg * 0.7, sb * 0.7, .south, tiles.side, world_x, world_z);
                }

                // Side faces for height differences
                if (gx > 0) {
                    const nh = heightmap[(gx - 1) + gz * width];
                    if (height > nh + 2) {
                        try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, nh, sr * 0.7, sg * 0.7, sb * 0.7, .west, tiles.side, world_x, world_z);
                    }
                }
                if (gz > 0) {
                    const nh = heightmap[gx + (gz - 1) * width];
                    if (height > nh + 2) {
                        try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, nh, sr * 0.8, sg * 0.8, sb * 0.8, .north, tiles.side, world_x, world_z);
                    }
                }
            }
        }

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_vertices) |p| {
            self.allocator.free(p);
        }

        if (vertices.items.len > 0) {
            self.pending_vertices = try self.allocator.dupe(Vertex, vertices.items);
            self.opaque_vertex_count = @intCast(vertices.items.len);
            self.water_vertex_offset = self.opaque_vertex_count * @sizeOf(Vertex);
            self.water_vertex_count = 0;
        } else {
            self.pending_vertices = null;
            self.opaque_vertex_count = 0;
            self.water_vertex_offset = 0;
            self.water_vertex_count = 0;
        }
    }

    /// Upload pending vertices to GPU
    pub fn upload(self: *LODMesh, resources: LODMeshResources) RhiError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pooled) return error.InvalidState;

        const pending = self.pending_vertices orelse {
            self.ready = self.buffer_handle != 0;
            return;
        };

        if (pending.len == 0) {
            if (self.buffer_handle != 0 and !self.pooled) {
                resources.waitIdle();
                resources.destroyBuffer(self.buffer_handle);
            }
            self.buffer_handle = 0;
            self.vertex_count = 0;
            self.opaque_vertex_count = 0;
            self.water_vertex_offset = 0;
            self.water_vertex_count = 0;
            self.capacity = 0;
            self.vertex_offset = 0;
            self.pooled = false;
            self.allocator.free(pending);
            self.pending_vertices = null;
            self.ready = true;
            return;
        }

        const data_size = pending.len * @sizeOf(Vertex);
        const needed_capacity = @max(1024, std.math.ceilPowerOfTwo(usize, data_size) catch data_size);

        var upload_handle = self.buffer_handle;
        var new_handle: BufferHandle = 0;

        // Create or resize buffer. Keep the old buffer renderable until the
        // replacement upload succeeds, then destroy it after an idle wait.
        if (self.buffer_handle == 0 or needed_capacity > self.capacity * @sizeOf(Vertex)) {
            new_handle = try resources.createBuffer(needed_capacity, .vertex);
            upload_handle = new_handle;
        }
        errdefer if (new_handle != 0) resources.destroyBuffer(new_handle);

        // Upload data
        try uploadBufferChunked(resources, upload_handle, std.mem.sliceAsBytes(pending));
        if (new_handle != 0) {
            const old_handle = self.buffer_handle;
            self.buffer_handle = new_handle;
            self.capacity = @intCast(needed_capacity / @sizeOf(Vertex));
            self.vertex_offset = 0;
            self.pooled = false;
            if (old_handle != 0 and !self.pooled) {
                resources.waitIdle();
                resources.destroyBuffer(old_handle);
            }
        }
        self.vertex_count = @intCast(pending.len);
        if (self.opaque_vertex_count == 0 and self.water_vertex_count == 0) {
            self.opaque_vertex_count = self.vertex_count;
        }

        self.allocator.free(pending);
        self.pending_vertices = null;
        self.ready = true;
    }

    /// Draw the LOD mesh
    pub fn draw(self: *const LODMesh, render_ctx: LODMeshRenderContext) void {
        if (!self.ready or self.buffer_handle == 0 or self.vertex_count == 0) return;
        render_ctx.drawOffset(self.buffer_handle, self.vertex_count, .triangles, self.vertex_offset);
    }
};

const FullDetailMesh = struct {
    vertices: []Vertex,
    indices: []u32,
};

/// Build a full-detail indexed triangle mesh from LOD heightmap data.
/// Produces fine-grained quads with per-vertex heights suitable for QEM simplification.
/// The mesh uses 1-block resolution: each cell in the heightmap grid becomes a quad
/// subdivided into 2 triangles with separate indices for QEM edge collapse.
fn appendIndexedQuad(
    vertices: *std.ArrayListUnmanaged(Vertex),
    indices: *std.ArrayListUnmanaged(u32),
    allocator: std.mem.Allocator,
    quad: *const [4]Vertex,
) !void {
    const base: u32 = @intCast(vertices.items.len);
    try vertices.appendSlice(allocator, quad);
    try indices.appendSlice(allocator, &.{
        base, base + 1, base + 2,
        base, base + 2, base + 3,
    });
}

const SkirtParams = struct {
    x: f32,
    z: f32,
    size: f32,
    avg_h: f32,
    avg_c: u32,
    brightness: f32,
    dir: SkirtDir,
};

const SkirtDir = enum { north, south, east, west };

fn makeSkirtQuad(params: SkirtParams, tile_id: u16, world_x: i32, world_z: i32) [4]Vertex {
    const p = params;
    const cr = unpackR(p.avg_c) * p.brightness;
    const cg = unpackG(p.avg_c) * p.brightness;
    const cb = unpackB(p.avg_c) * p.brightness;
    const skirt_bottom = p.avg_h - p.size * 4.0;
    const normal: [3]f32 = switch (p.dir) {
        .north => .{ 0, 0, -1 },
        .south => .{ 0, 0, 1 },
        .west => .{ -1, 0, 0 },
        .east => .{ 1, 0, 0 },
    };
    const col = [3]f32{ cr, cg, cb };
    const face_dir = skirtDirToFaceDir(p.dir);
    return switch (p.dir) {
        .north => .{
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z }, col, normal, sideFaceUV(.{ p.x + p.size, skirt_bottom, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, skirt_bottom, p.z }, col, normal, sideFaceUV(.{ p.x, skirt_bottom, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z }, col, normal, sideFaceUV(.{ p.x, p.avg_h, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z }, col, normal, sideFaceUV(.{ p.x + p.size, p.avg_h, p.z }, face_dir, world_x, world_z), tile_id),
        },
        .south => .{
            makeLODVertex(.{ p.x, skirt_bottom, p.z + p.size }, col, normal, sideFaceUV(.{ p.x, skirt_bottom, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z + p.size }, col, normal, sideFaceUV(.{ p.x + p.size, skirt_bottom, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z + p.size }, col, normal, sideFaceUV(.{ p.x + p.size, p.avg_h, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z + p.size }, col, normal, sideFaceUV(.{ p.x, p.avg_h, p.z + p.size }, face_dir, world_x, world_z), tile_id),
        },
        .west => .{
            makeLODVertex(.{ p.x, skirt_bottom, p.z }, col, normal, sideFaceUV(.{ p.x, skirt_bottom, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, skirt_bottom, p.z + p.size }, col, normal, sideFaceUV(.{ p.x, skirt_bottom, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z + p.size }, col, normal, sideFaceUV(.{ p.x, p.avg_h, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z }, col, normal, sideFaceUV(.{ p.x, p.avg_h, p.z }, face_dir, world_x, world_z), tile_id),
        },
        .east => .{
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z + p.size }, col, normal, sideFaceUV(.{ p.x + p.size, skirt_bottom, p.z + p.size }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z }, col, normal, sideFaceUV(.{ p.x + p.size, skirt_bottom, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z }, col, normal, sideFaceUV(.{ p.x + p.size, p.avg_h, p.z }, face_dir, world_x, world_z), tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z + p.size }, col, normal, sideFaceUV(.{ p.x + p.size, p.avg_h, p.z + p.size }, face_dir, world_x, world_z), tile_id),
        },
    };
}

fn buildFullDetailHeightmapMesh(
    allocator: std.mem.Allocator,
    lod_level: LODLevel,
    data: *const LODSimplifiedData,
    world_x: i32,
    world_z: i32,
    atlas: *const TextureAtlas,
) !FullDetailMesh {
    const w = data.width;
    const grid_total = w * w;
    if (grid_total == 0) return error.EmptyData;
    const grid_count: usize = @intCast(grid_total);
    std.debug.assert(grid_count <= data.heightmap.len and
        grid_count <= data.biomes.len and
        grid_count <= data.top_blocks.len and
        grid_count <= data.colors.len and
        grid_count <= data.material_layers.len and
        grid_count <= data.water.len and
        grid_count <= data.lighting.len and
        grid_count <= data.vegetation.len);

    if (w < 2) return error.EmptyData;
    const cell_size: f32 = @as(f32, @floatFromInt(lod_chunk.regionSizeBlocks(lod_level))) / @as(f32, @floatFromInt(w - 1));

    var vertices = std.ArrayListUnmanaged(Vertex).empty;
    errdefer vertices.deinit(allocator);
    var indices = std.ArrayListUnmanaged(u32).empty;
    errdefer indices.deinit(allocator);

    var gz: u32 = 0;
    while (gz + 1 < w) : (gz += 1) {
        var gx: u32 = 0;
        while (gx + 1 < w) : (gx += 1) {
            const h00 = data.heightmap[gx + gz * w];
            const h10 = data.heightmap[(gx + 1) + gz * w];
            const h01 = data.heightmap[gx + (gz + 1) * w];
            const h11 = data.heightmap[(gx + 1) + (gz + 1) * w];

            const c00 = data.colors[gx + gz * w];
            const c10 = data.colors[(gx + 1) + gz * w];
            const c01 = data.colors[gx + (gz + 1) * w];
            const c11 = data.colors[(gx + 1) + (gz + 1) * w];
            const wx = @as(f32, @floatFromInt(gx)) * cell_size;
            const wz = @as(f32, @floatFromInt(gz)) * cell_size;
            const size = cell_size;
            const material = selectCellMaterial(data, atlas, gx, gz);

            const top_block = blockForLODQuad(data, gx, gz);
            const top_tile_id = getLodTopTile(top_block, atlas);
            const tc00 = applyTextureLuminance(getLodTopColor(top_block, top_tile_id, applyColorBrightness(c00, data.lighting[gx + gz * w].ambient_occlusion)), top_block, .top, atlas);
            const tc10 = applyTextureLuminance(getLodTopColor(top_block, top_tile_id, applyColorBrightness(c10, data.lighting[(gx + 1) + gz * w].ambient_occlusion)), top_block, .top, atlas);
            const tc01 = applyTextureLuminance(getLodTopColor(top_block, top_tile_id, applyColorBrightness(c01, data.lighting[gx + (gz + 1) * w].ambient_occlusion)), top_block, .top, atlas);
            const tc11 = applyTextureLuminance(getLodTopColor(top_block, top_tile_id, applyColorBrightness(c11, data.lighting[(gx + 1) + (gz + 1) * w].ambient_occlusion)), top_block, .top, atlas);
            const top_quad = [4]Vertex{
                makeLODVertex(.{ wx, h00, wz }, .{ unpackR(tc00), unpackG(tc00), unpackB(tc00) }, .{ 0, 1, 0 }, topFaceUV(.{ wx, h00, wz }, world_x, world_z), top_tile_id),
                makeLODVertex(.{ wx + size, h10, wz }, .{ unpackR(tc10), unpackG(tc10), unpackB(tc10) }, .{ 0, 1, 0 }, topFaceUV(.{ wx + size, h10, wz }, world_x, world_z), top_tile_id),
                makeLODVertex(.{ wx + size, h11, wz + size }, .{ unpackR(tc11), unpackG(tc11), unpackB(tc11) }, .{ 0, 1, 0 }, topFaceUV(.{ wx + size, h11, wz + size }, world_x, world_z), top_tile_id),
                makeLODVertex(.{ wx, h01, wz + size }, .{ unpackR(tc01), unpackG(tc01), unpackB(tc01) }, .{ 0, 1, 0 }, topFaceUV(.{ wx, h01, wz + size }, world_x, world_z), top_tile_id),
            };
            try appendIndexedQuad(&vertices, &indices, allocator, &top_quad);

            if (gz == 0) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h00 + h10) * 0.5,
                .avg_c = averageColor(c00, c10, c00, c10),
                .brightness = 0.7,
                .dir = .north,
            }, material.side, world_x, world_z));
            if (gz == w - 2) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h01 + h11) * 0.5,
                .avg_c = averageColor(c01, c11, c01, c11),
                .brightness = 0.7,
                .dir = .south,
            }, material.side, world_x, world_z));
            if (gx == 0) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h00 + h01) * 0.5,
                .avg_c = averageColor(c00, c01, c00, c01),
                .brightness = 0.8,
                .dir = .west,
            }, material.side, world_x, world_z));
            if (gx == w - 2) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h10 + h11) * 0.5,
                .avg_c = averageColor(c10, c11, c10, c11),
                .brightness = 0.8,
                .dir = .east,
            }, material.side, world_x, world_z));
        }
    }

    return .{
        .vertices = try vertices.toOwnedSlice(allocator),
        .indices = try indices.toOwnedSlice(allocator),
    };
}

const FaceDir = enum { north, south, east, west };
const WORLDGEN_SEA_LEVEL: f32 = 64.0;
const SEA_LEVEL_WATER_EPSILON: f32 = 2.0;
const SYNTHETIC_SEAFLOOR_SKIRT: f32 = 8.0;
const LOD_TREE_COVERAGE_THRESHOLD: f32 = 0.08;

fn is_lod_water_cell(data: *const LODSimplifiedData, gx: u32, gz: u32) bool {
    const stats = water_coverage_stats(data, gx, gz);
    const water_coverage = stats.average_coverage;
    if (water_coverage >= 0.35) return true;
    return stats.wet_samples >= 2 and water_coverage >= 0.25 and stats.representative_depth >= 1.5;
}

fn is_fine_sample_lod(lod_level: LODLevel) bool {
    return @intFromEnum(lod_level) <= @intFromEnum(LODLevel.lod1);
}

fn cell_index(data: *const LODSimplifiedData, gx: u32, gz: u32) u32 {
    return @min(gx, data.width - 1) + @min(gz, data.width - 1) * data.width;
}

fn cell_color_for_lod(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) u32 {
    if (is_fine_sample_lod(lod_level)) return data.colors[cell_index(data, gx, gz)];
    const c00 = data.colors[cell_index(data, gx, gz)];
    const c10 = data.colors[cell_index(data, gx + 1, gz)];
    const c01 = data.colors[cell_index(data, gx, gz + 1)];
    const c11 = data.colors[cell_index(data, gx + 1, gz + 1)];
    return averageColor(c00, c10, c01, c11);
}

fn ambient_occlusion_for_lod(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) f32 {
    if (is_fine_sample_lod(lod_level)) return data.lighting[cell_index(data, gx, gz)].ambient_occlusion;
    return averageAmbientOcclusion(data, gx, gz);
}

fn is_lod_water_cell_for_lod(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) bool {
    if (is_fine_sample_lod(lod_level)) {
        const water = data.water[cell_index(data, gx, gz)];
        return water.is_surface and water.coverage > 0.0 and water.depth >= 0.25;
    }
    return is_lod_water_cell(data, gx, gz);
}

fn quantizedHeight(height: f32) f32 {
    return @round(height);
}

fn terrainHeightForPoint(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const clamped_x = @min(gx, data.width - 1);
    const clamped_z = @min(gz, data.width - 1);
    const idx = clamped_x + clamped_z * data.width;
    const height = terrainSurfaceHeightForPoint(data, clamped_x, clamped_z);
    const water = data.water[idx];
    if (!water.is_surface or water.coverage <= 0.0) return height;

    const floor_height = if (water.depth > 0.0)
        @max(0.0, water.surface_height - water.depth)
    else
        water.surface_height;
    return @min(height, floor_height);
}

fn terrainSurfaceHeightForPoint(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const clamped_x = @min(gx, data.width - 1);
    const clamped_z = @min(gz, data.width - 1);
    return stitchedHeight(data, clamped_x, clamped_z);
}

fn quantizedTerrainHeightForPoint(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    return quantizedHeight(terrainHeightForPoint(data, gx, gz));
}

fn quantizedCellTerrainHeight(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    return quantizedHeight(terrainHeightForPoint(data, gx, gz));
}

fn quantizedCellSurfaceHeight(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    return quantizedHeight(terrainSurfaceHeightForPoint(data, gx, gz));
}

fn quantizedCellTerrainHeightForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) f32 {
    if (is_fine_sample_lod(lod_level)) return quantizedTerrainHeightForPoint(data, gx, gz);
    return quantizedCellTerrainHeight(data, gx, gz);
}

fn quantizedCellVisualTerrainHeightForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, is_water_cell: bool) f32 {
    if (is_water_cell) return quantizedCellTerrainHeightForLOD(data, gx, gz, lod_level);
    if (is_fine_sample_lod(lod_level)) return quantizedHeight(terrainSurfaceHeightForPoint(data, gx, gz));
    return quantizedCellSurfaceHeight(data, gx, gz);
}

fn maxWaterSurfaceHeightForCell(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) ?f32 {
    return representativeWaterSurfaceHeightForCell(data, gx, gz, lod_level);
}

fn representativeWaterSurfaceHeightForCell(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) ?f32 {
    if (is_fine_sample_lod(lod_level)) {
        const idx = cell_index(data, gx, gz);
        const water = data.water[idx];
        if (!water.is_surface or water.coverage <= 0.0) return null;
        return normalizedWaterSurfaceHeight(data, idx, water);
    }

    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    for (indices) |idx| {
        const water = data.water[idx];
        if (!water.is_surface or water.coverage <= 0.0) continue;
        return normalizedWaterSurfaceHeight(data, idx, water);
    }

    return null;
}

fn normalizedWaterSurfaceHeight(data: *const LODSimplifiedData, idx: u32, water: world_core.LODWaterState) f32 {
    if (isOceanBiome(data.biomes[idx]) and @abs(water.surface_height - WORLDGEN_SEA_LEVEL) <= SEA_LEVEL_WATER_EPSILON) {
        return WORLDGEN_SEA_LEVEL;
    }
    return water.surface_height;
}

fn isOceanBiome(biome: BiomeId) bool {
    return switch (biome) {
        .deep_ocean, .ocean, .warm_ocean, .frozen_ocean, .cold_ocean => true,
        else => false,
    };
}

fn quantizedWaterSurfaceHeightForCell(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) f32 {
    if (maxWaterSurfaceHeightForCell(data, gx, gz, lod_level)) |height| return quantizedHeight(height);
    return quantizedCellTerrainHeightForLOD(data, gx, gz, lod_level);
}

fn quantizedWaterSurfaceHeightForSpan(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, fallback_height: f32) f32 {
    if (maxWaterSurfaceHeightForCell(data, gx, gz, lod_level)) |height| return quantizedHeight(height);
    return quantizedHeight(fallback_height);
}

const FoldedCanopyColumn = struct {
    height: f32,
    block: BlockType,
    color: u32,
};

fn shouldFoldCanopyIntoTerrain(lod_level: LODLevel) bool {
    _ = lod_level;
    return false;
}

fn shouldRenderLODTreeTrunk(lod_level: LODLevel) bool {
    return @intFromEnum(lod_level) <= @intFromEnum(LODLevel.lod3);
}

fn foldedCanopyColumnForLOD(
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    base_height: f32,
    terrain_block: BlockType,
    is_water_cell: bool,
) ?FoldedCanopyColumn {
    if (!shouldFoldCanopyIntoTerrain(lod_level) or is_water_cell or !shouldRenderLODTree(terrain_block)) return null;

    const vegetation = representativeVegetationForLOD(data, gx, gz, lod_level);
    if (vegetation.tree_coverage < LOD_TREE_COVERAGE_THRESHOLD or vegetation.avg_tree_height < 2.0) return null;

    const leaves = if (vegetation.leaves == .air) BlockType.leaves else vegetation.leaves;
    const coverage = std.math.clamp(vegetation.tree_coverage, 0.0, 1.0);
    const height_boost = @max(2.0, @max(3.0, vegetation.avg_tree_height) * std.math.clamp(coverage, 0.35, 1.0));
    return .{
        .height = quantizedHeight(base_height + height_boost),
        .block = leaves,
        .color = packBlockDefaultColor(leaves, 0x2F7D2A),
    };
}

fn quantizedVisualColumnHeightForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) f32 {
    const is_water_cell = is_lod_water_cell_for_lod(data, gx, gz, lod_level);
    const terrain_block = terrainBlockForLODQuadForLOD(data, gx, gz, is_water_cell, lod_level);
    const base_height = quantizedCellVisualTerrainHeightForLOD(data, gx, gz, lod_level, is_water_cell);
    if (foldedCanopyColumnForLOD(data, gx, gz, lod_level, base_height, terrain_block, is_water_cell)) |folded| {
        return folded.height;
    }
    return base_height;
}

fn terrainBlockForLODQuad(data: *const LODSimplifiedData, gx: u32, gz: u32, is_water_cell: bool) BlockType {
    if (!is_water_cell) return blockForLODQuad(data, gx, gz);

    const side_block = sideBlockForLODQuad(data, gx, gz, .water);
    if (side_block != .air and side_block != .water) return side_block;

    const representative = representativeSurfaceBlock(data, gx, gz);
    if (representative != .air and representative != .water) return representative;

    const idx = @min(gx, data.width - 1) + @min(gz, data.width - 1) * data.width;
    return data.biomes[idx].getOceanFloorBlock(representativeWaterDepth(data, gx, gz));
}

fn terrainBlockForLODQuadForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, is_water_cell: bool, lod_level: LODLevel) BlockType {
    if (!is_fine_sample_lod(lod_level)) return terrainBlockForLODQuad(data, gx, gz, is_water_cell);
    if (!is_water_cell) return blockForLODCell(data, gx, gz);

    const idx = cell_index(data, gx, gz);
    const subsurface = data.material_layers[idx].subsurface;
    if (subsurface != .air and subsurface != .water) return subsurface;
    const surface = data.material_layers[idx].surface;
    if (surface != .air and surface != .water) return surface;
    return data.biomes[idx].getOceanFloorBlock(data.water[idx].depth);
}

fn getLodSideTile(block: BlockType, atlas: *const TextureAtlas) u16 {
    if (block == .air) return Vertex.LOD_TILE_ID;
    if (isLeafBlock(block)) return Vertex.LOD_TILE_ID;
    const tiles = atlas.getTilesForBlock(@intFromEnum(block));
    if (tiles.side == 0) return Vertex.LOD_TILE_ID;
    return tiles.side;
}

fn boundarySkirtDepth(size: f32) f32 {
    return std.math.clamp(size, 16.0, 32.0);
}

fn heightfieldSideBrightness(dir: FaceDir) f32 {
    return switch (dir) {
        .west, .east => 0.8,
        .north, .south => 0.7,
    };
}

fn addSteppedHeightfieldSides(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    wx: f32,
    wz: f32,
    size: f32,
    column_height: f32,
    color: u32,
    side_tile: u16,
    world_x: i32,
    world_z: i32,
) !void {
    try addHeightfieldSide(allocator, vertices, wx, wz, size, column_height, if (gx == 0) null else quantizedVisualColumnHeightForLOD(data, gx - 1, gz, lod_level), color, side_tile, .west, world_x, world_z);
    try addHeightfieldSide(allocator, vertices, wx, wz, size, column_height, if (gx + 1 >= data.width - 1) null else quantizedVisualColumnHeightForLOD(data, gx + 1, gz, lod_level), color, side_tile, .east, world_x, world_z);
    try addHeightfieldSide(allocator, vertices, wx, wz, size, column_height, if (gz == 0) null else quantizedVisualColumnHeightForLOD(data, gx, gz - 1, lod_level), color, side_tile, .north, world_x, world_z);
    try addHeightfieldSide(allocator, vertices, wx, wz, size, column_height, if (gz + 1 >= data.width - 1) null else quantizedVisualColumnHeightForLOD(data, gx, gz + 1, lod_level), color, side_tile, .south, world_x, world_z);
}

fn addHeightfieldSide(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    wx: f32,
    wz: f32,
    size: f32,
    column_height: f32,
    neighbor_height: ?f32,
    color: u32,
    side_tile: u16,
    dir: FaceDir,
    world_x: i32,
    world_z: i32,
) !void {
    const bottom = neighbor_height orelse (column_height - boundarySkirtDepth(size));
    if (column_height <= bottom + 0.01) return;
    const brightness = heightfieldSideBrightness(dir);
    try addSideFaceQuad(allocator, vertices, wx, column_height, wz, size, bottom, unpackR(color) * brightness, unpackG(color) * brightness, unpackB(color) * brightness, dir, side_tile, world_x, world_z);
}

const LODColumnSpan = struct {
    min_height: f32,
    max_height: f32,
    block: BlockType,
    color: u32,
    ambient_occlusion: f32,
};

const HeightInterval = struct {
    min_height: f32,
    max_height: f32,
};

fn collectColumnSpans(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, out: *[world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan) usize {
    var count: usize = 0;
    var has_water_span = false;
    var has_solid_span = false;
    var has_canopy_span = false;
    var i: u8 = 0;
    while (i < data.verticalSpanCount(gx, gz)) : (i += 1) {
        const raw = data.getVerticalSpan(gx, gz, i) orelse continue;
        const block = representativeSpanBlock(raw.material_layers);
        if (block == .air) continue;
        const min_height = @min(raw.min_height, raw.max_height);
        const max_height = @max(raw.min_height, raw.max_height);
        if (max_height <= min_height + 0.01) continue;
        if (block == .water) {
            if (!shouldEmitWaterSpanForLOD(data, gx, gz, lod_level, raw.water)) continue;
            has_water_span = true;
        } else {
            has_solid_span = true;
            const terrain_height = data.getHeight(gx, gz);
            if (raw.vegetation.tree_coverage > 0.0 and max_height > terrain_height + 1.0) {
                has_canopy_span = true;
            }
        }
        insertColumnSpan(out, &count, .{
            .min_height = min_height,
            .max_height = max_height,
            .block = block,
            .color = raw.color,
            .ambient_occlusion = raw.lighting.ambient_occlusion,
        });
    }

    if (gx < data.width and gz < data.width) {
        const idx = gx + gz * data.width;
        const vegetation = data.vegetation[idx];
        if (!has_canopy_span and vegetation.tree_coverage >= LOD_TREE_COVERAGE_THRESHOLD and vegetation.avg_tree_height >= 2.0 and count < out.len) {
            const leaves = if (vegetation.leaves == .air) BlockType.leaves else vegetation.leaves;
            const canopy = treeCanopyInterval(quantizedTerrainHeightForPoint(data, gx, gz), vegetation);
            insertColumnSpan(out, &count, .{
                .min_height = canopy.min_height,
                .max_height = canopy.max_height,
                .block = leaves,
                .color = packBlockDefaultColor(leaves, data.colors[idx]),
                .ambient_occlusion = data.lighting[idx].ambient_occlusion,
            });
        }

        const water = data.water[idx];
        if (!has_water_span and shouldEmitWaterSpanForLOD(data, gx, gz, lod_level, water) and count < out.len) {
            has_water_span = true;
            insertColumnSpan(out, &count, .{
                .min_height = water.surface_height - water.depth,
                .max_height = water.surface_height,
                .block = .water,
                .color = data.colors[idx],
                .ambient_occlusion = data.lighting[idx].ambient_occlusion,
            });
        }

        if (has_water_span and !has_solid_span and count < out.len) {
            const terrain_height = quantizedTerrainHeightForPoint(data, gx, gz);
            if (terrain_height > 0.01) {
                const seafloor_block = terrainBlockForLODQuad(data, gx, gz, true);
                insertColumnSpan(out, &count, .{
                    .min_height = syntheticSeafloorMinHeight(data, gx, gz),
                    .max_height = terrain_height,
                    .block = seafloor_block,
                    .color = packBlockDefaultColor(seafloor_block, data.colors[idx]),
                    .ambient_occlusion = data.lighting[idx].ambient_occlusion,
                });
            }
        }
    }
    foldCanopyIntoSpansForLOD(data, gx, gz, lod_level, out, &count);
    return count;
}

fn syntheticSeafloorMinHeight(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const x_min = if (gx == 0) gx else gx - 1;
    const z_min = if (gz == 0) gz else gz - 1;
    const x_max = @min(gx + 1, data.width - 1);
    const z_max = @min(gz + 1, data.width - 1);

    var min_height: f32 = std.math.floatMax(f32);
    var z = z_min;
    while (z <= z_max) : (z += 1) {
        var x = x_min;
        while (x <= x_max) : (x += 1) {
            min_height = @min(min_height, quantizedTerrainHeightForPoint(data, x, z));
        }
    }
    if (min_height == std.math.floatMax(f32)) return 0.0;
    return @max(0.0, min_height - SYNTHETIC_SEAFLOOR_SKIRT);
}

fn foldCanopyIntoSpansForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, spans: *[world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan, count: *usize) void {
    if (!shouldFoldCanopyIntoTerrain(lod_level) or count.* == 0) return;

    const is_water_cell = is_lod_water_cell_for_lod(data, gx, gz, lod_level);
    const terrain_block = terrainBlockForLODQuadForLOD(data, gx, gz, is_water_cell, lod_level);
    const base_height = quantizedCellVisualTerrainHeightForLOD(data, gx, gz, lod_level, is_water_cell);
    const folded = foldedCanopyColumnForLOD(data, gx, gz, lod_level, base_height, terrain_block, is_water_cell) orelse return;

    var i: usize = 0;
    while (i < count.*) {
        if (isDetachedCanopySpan(spans[i], base_height)) {
            var j = i;
            while (j + 1 < count.*) : (j += 1) spans[j] = spans[j + 1];
            count.* -= 1;
            continue;
        }
        i += 1;
    }

    var terrain_idx: ?usize = null;
    i = 0;
    while (i < count.*) : (i += 1) {
        if (spans[i].block == .water) continue;
        if (spans[i].min_height <= base_height + 0.01) terrain_idx = i;
    }

    if (terrain_idx) |idx| {
        spans[idx].max_height = @max(spans[idx].max_height, folded.height);
        spans[idx].block = folded.block;
        spans[idx].color = folded.color;
        return;
    }

    insertColumnSpan(spans, count, .{
        .min_height = 0.0,
        .max_height = folded.height,
        .block = folded.block,
        .color = folded.color,
        .ambient_occlusion = ambient_occlusion_for_lod(data, gx, gz, lod_level),
    });
}

fn isDetachedCanopySpan(span: LODColumnSpan, base_height: f32) bool {
    return isLeafBlock(span.block) and span.min_height > base_height + 0.5;
}

fn representativeSpanBlock(layers: world_core.LODMaterialLayers) BlockType {
    if (layers.surface != .air) return layers.surface;
    if (layers.subsurface != .air) return layers.subsurface;
    return layers.foundation;
}

fn insertColumnSpan(out: *[world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan, count: *usize, span: LODColumnSpan) void {
    if (count.* >= out.len) return;
    var dst = count.*;
    count.* += 1;
    while (dst > 0 and out[dst - 1].min_height > span.min_height) : (dst -= 1) {
        out[dst] = out[dst - 1];
    }
    out[dst] = span;
}

fn highestSolidSpanIndex(spans: []const LODColumnSpan) ?usize {
    var i = spans.len;
    while (i > 0) {
        i -= 1;
        if (spans[i].block != .water) return i;
    }
    return null;
}

fn addExposedSpanFaces(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    span: LODColumnSpan,
    wx: f32,
    wz: f32,
    size: f32,
    color: u32,
    tile_id: u16,
    world_x: i32,
    world_z: i32,
) !void {
    try addExposedSpanFace(allocator, vertices, data, gx, gz, if (gx == 0) null else gx - 1, gz, lod_level, span, wx, wz, size, color, tile_id, .west, world_x, world_z);
    try addExposedSpanFace(allocator, vertices, data, gx, gz, if (gx + 1 >= data.width - 1) null else gx + 1, gz, lod_level, span, wx, wz, size, color, tile_id, .east, world_x, world_z);
    try addExposedSpanFace(allocator, vertices, data, gx, gz, gx, if (gz == 0) null else gz - 1, lod_level, span, wx, wz, size, color, tile_id, .north, world_x, world_z);
    try addExposedSpanFace(allocator, vertices, data, gx, gz, gx, if (gz + 1 >= data.width - 1) null else gz + 1, lod_level, span, wx, wz, size, color, tile_id, .south, world_x, world_z);
}

fn addExposedSpanFace(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    neighbor_gx: ?u32,
    neighbor_gz: ?u32,
    lod_level: LODLevel,
    span: LODColumnSpan,
    wx: f32,
    wz: f32,
    size: f32,
    color: u32,
    tile_id: u16,
    dir: FaceDir,
    world_x: i32,
    world_z: i32,
) !void {
    _ = gx;
    _ = gz;
    var exposed: [world_core.MAX_LOD_VERTICAL_SPANS + 1]HeightInterval = undefined;
    var exposed_count: usize = 1;
    exposed[0] = .{ .min_height = span.min_height, .max_height = span.max_height };

    if (neighbor_gx == null or neighbor_gz == null) {
        // Without a border apron we do not know the adjacent region column.
        // Treat it as matching this span so region borders do not emit walls.
        subtractCoveredInterval(&exposed, &exposed_count, span.min_height, span.max_height);
    } else {
        const nx = neighbor_gx.?;
        const nz = neighbor_gz.?;
        var neighbor_spans: [world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan = undefined;
        const neighbor_count = collectColumnSpans(data, nx, nz, lod_level, &neighbor_spans);
        var ni: usize = 0;
        while (ni < neighbor_count) : (ni += 1) {
            subtractCoveredInterval(&exposed, &exposed_count, neighbor_spans[ni].min_height, neighbor_spans[ni].max_height);
        }
    }

    var i: usize = 0;
    while (i < exposed_count) : (i += 1) {
        const interval = exposed[i];
        if (interval.max_height <= interval.min_height + 0.01) continue;
        const brightness: f32 = switch (dir) {
            .west, .east => 0.8,
            .north, .south => 0.7,
        };
        try addSideFaceQuad(allocator, vertices, wx, interval.max_height, wz, size, interval.min_height, unpackR(color) * brightness, unpackG(color) * brightness, unpackB(color) * brightness, dir, tile_id, world_x, world_z);
    }
}

fn subtractCoveredInterval(intervals: *[world_core.MAX_LOD_VERTICAL_SPANS + 1]HeightInterval, count: *usize, cover_min: f32, cover_max: f32) void {
    var i: usize = 0;
    while (i < count.*) {
        const current = intervals[i];
        const overlap_min = @max(current.min_height, cover_min);
        const overlap_max = @min(current.max_height, cover_max);
        if (overlap_max <= overlap_min + 0.01) {
            i += 1;
            continue;
        }

        if (overlap_min <= current.min_height + 0.01 and overlap_max >= current.max_height - 0.01) {
            intervals[i] = intervals[count.* - 1];
            count.* -= 1;
            continue;
        }

        if (overlap_min <= current.min_height + 0.01) {
            intervals[i].min_height = overlap_max;
            i += 1;
            continue;
        }

        if (overlap_max >= current.max_height - 0.01) {
            intervals[i].max_height = overlap_min;
            i += 1;
            continue;
        }

        if (count.* < intervals.len) {
            intervals[i].max_height = overlap_min;
            intervals[count.*] = .{ .min_height = overlap_max, .max_height = current.max_height };
            count.* += 1;
        }
        i += 1;
    }
}

const LOD_UV_BLOCK_SCALE: f32 = 1.0;
const LOD_UV_WRAP_BLOCKS: i32 = 256;

fn lodUVOffset(coord: i32) f32 {
    return @floatFromInt(@mod(coord, LOD_UV_WRAP_BLOCKS));
}

fn topFaceUV(pos: [3]f32, world_x: i32, world_z: i32) [2]f32 {
    return .{
        (lodUVOffset(world_x) + pos[0]) * LOD_UV_BLOCK_SCALE,
        (lodUVOffset(world_z) + pos[2]) * LOD_UV_BLOCK_SCALE,
    };
}

fn sideFaceUV(pos: [3]f32, dir: FaceDir, world_x: i32, world_z: i32) [2]f32 {
    const horizontal = switch (dir) {
        .north, .south => lodUVOffset(world_x) + pos[0],
        .east, .west => lodUVOffset(world_z) + pos[2],
    };
    return .{ horizontal * LOD_UV_BLOCK_SCALE, pos[1] * LOD_UV_BLOCK_SCALE };
}

fn skirtDirToFaceDir(dir: SkirtDir) FaceDir {
    return switch (dir) {
        .north => .north,
        .south => .south,
        .east => .east,
        .west => .west,
    };
}

fn blockForLODCell(data: *const LODSimplifiedData, gx: u32, gz: u32) BlockType {
    const clamped_x = @min(gx, data.width - 1);
    const clamped_z = @min(gz, data.width - 1);
    const idx = clamped_x + clamped_z * data.width;
    const block = data.material_layers[idx].surface;
    if (block != .air) return block;
    if (data.top_blocks[idx] != .air) return data.top_blocks[idx];
    return data.biomes[idx].getSurfaceBlock();
}

fn blockForLODQuad(data: *const LODSimplifiedData, gx: u32, gz: u32) BlockType {
    if (is_lod_water_cell(data, gx, gz)) return .water;
    return representativeSurfaceBlock(data, gx, gz);
}

fn representativeSurfaceBlock(data: *const LODSimplifiedData, gx: u32, gz: u32) BlockType {
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    var best_block: BlockType = .air;
    var best_count: u32 = 0;
    for (indices) |idx| {
        const block = if (data.material_layers[idx].surface != .air) data.material_layers[idx].surface else if (data.top_blocks[idx] != .air) data.top_blocks[idx] else data.biomes[idx].getSurfaceBlock();
        if (block == .air or block == .water) continue;

        var count: u32 = 0;
        for (indices) |other_idx| {
            const other = if (data.material_layers[other_idx].surface != .air) data.material_layers[other_idx].surface else if (data.top_blocks[other_idx] != .air) data.top_blocks[other_idx] else data.biomes[other_idx].getSurfaceBlock();
            if (other == block) count += 1;
        }
        if (count > best_count) {
            best_block = block;
            best_count = count;
        }
    }

    if (best_block != .air) return best_block;
    return blockForLODCell(data, gx, gz);
}

fn representativeWaterDepth(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    var weighted_depth: f32 = 0.0;
    var coverage: f32 = 0.0;
    for (indices) |idx| {
        const water = data.water[idx];
        if (!water.is_surface) continue;
        weighted_depth += water.depth * water.coverage;
        coverage += water.coverage;
    }
    if (coverage <= 0.001) return 0.0;
    return weighted_depth / coverage;
}

fn selectCellMaterial(data: *const LODSimplifiedData, atlas: *const TextureAtlas, gx: u32, gz: u32) TextureAtlas.BlockTiles {
    const top_block = blockForLODQuad(data, gx, gz);
    const side_block = sideBlockForLODQuad(data, gx, gz, top_block);
    const top_tiles = atlas.getTilesForBlock(@intFromEnum(top_block));
    const side_tiles = atlas.getTilesForBlock(@intFromEnum(side_block));
    return .{
        .top = getLodTopTile(top_block, atlas),
        .bottom = if (top_tiles.bottom == 0) Vertex.LOD_TILE_ID else top_tiles.bottom,
        .side = if (side_tiles.side == 0) Vertex.LOD_TILE_ID else side_tiles.side,
    };
}

fn sideBlockForLODQuad(data: *const LODSimplifiedData, gx: u32, gz: u32, top_block: BlockType) BlockType {
    if (top_block != .water) return top_block;

    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    for (indices) |idx| {
        if (data.water[idx].is_surface and data.material_layers[idx].subsurface != .air and data.material_layers[idx].subsurface != .water) {
            return data.material_layers[idx].subsurface;
        }
    }

    return blockForLODCell(data, gx, gz);
}

fn shouldRenderLODTree(top_block: BlockType) bool {
    return top_block != .water and top_block != .air;
}

fn isLeafBlock(block: BlockType) bool {
    return switch (block) {
        .leaves,
        .mangrove_leaves,
        .jungle_leaves,
        .acacia_leaves,
        .birch_leaves,
        .spruce_leaves,
        => true,
        else => false,
    };
}

fn representativeVegetationForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel) world_core.LODVegetationHint {
    if (is_fine_sample_lod(lod_level)) return data.vegetation[cell_index(data, gx, gz)];
    return representativeVegetation(data, gx, gz);
}

fn representativeVegetation(data: *const LODSimplifiedData, gx: u32, gz: u32) world_core.LODVegetationHint {
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    var height_sum: f32 = 0.0;
    var height_count: u32 = 0;
    var best = world_core.LODVegetationHint.empty;
    for (indices) |idx| {
        const hint = data.vegetation[idx];
        if (hint.avg_tree_height > 0.0) {
            height_sum += hint.avg_tree_height;
            height_count += 1;
        }
        if (hint.tree_coverage > best.tree_coverage) best = hint;
    }

    best.avg_tree_height = if (height_count == 0) 0.0 else height_sum / @as(f32, @floatFromInt(height_count));
    return best;
}

fn averageWaterCoverage(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    return water_coverage_stats(data, gx, gz).average_coverage;
}

const WaterCoverageStats = struct {
    average_coverage: f32,
    wet_samples: u32,
    representative_depth: f32,
};

fn water_coverage_stats(data: *const LODSimplifiedData, gx: u32, gz: u32) WaterCoverageStats {
    if (data.width == 0) return .{ .average_coverage = 0.0, .wet_samples = 0, .representative_depth = 0.0 };
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const indices = [_]u32{
        x0 + z0 * data.width,
        x1 + z0 * data.width,
        x0 + z1 * data.width,
        x1 + z1 * data.width,
    };

    var coverage_sum: f32 = 0.0;
    var weighted_depth: f32 = 0.0;
    var coverage_weight: f32 = 0.0;
    var wet_samples: u32 = 0;
    for (indices) |idx| {
        const water = data.water[idx];
        if (!water.is_surface or water.coverage <= 0.0 or water.depth <= 0.01) continue;
        coverage_sum += water.coverage;
        weighted_depth += water.depth * water.coverage;
        coverage_weight += water.coverage;
        wet_samples += 1;
    }

    return .{
        .average_coverage = coverage_sum * 0.25,
        .wet_samples = wet_samples,
        .representative_depth = if (coverage_weight <= 0.001) 0.0 else weighted_depth / coverage_weight,
    };
}

fn shouldEmitWaterSpanForLOD(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, water: world_core.LODWaterState) bool {
    if (!water.is_surface or water.coverage <= 0.0 or water.depth <= 0.01) return false;
    if (is_fine_sample_lod(lod_level)) return true;
    if (water.coverage >= 0.35) return true;

    const stats = water_coverage_stats(data, gx, gz);
    return stats.wet_samples >= 2 and stats.average_coverage >= 0.25 and stats.representative_depth >= 1.5;
}

fn stitchedHeight(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const height = data.getHeight(gx, gz);
    if (data.width < 5) return height;

    const blend_cells: u32 = 2;
    const max_idx = data.width - 1;
    const edge_dist = @min(@min(gx, gz), @min(max_idx - gx, max_idx - gz));
    if (edge_dist >= blend_cells) return height;

    const coarse_x = @min(((gx + 1) / 2) * 2, max_idx);
    const coarse_z = @min(((gz + 1) / 2) * 2, max_idx);
    const coarse_height = data.getHeight(coarse_x, coarse_z);
    const edge_weight = 1.0 - (@as(f32, @floatFromInt(edge_dist)) / @as(f32, @floatFromInt(blend_cells)));
    const blend = edge_weight * 0.35;
    return height * (1.0 - blend) + coarse_height * blend;
}

fn maxStitchedHeightAdjustment(data: *const LODSimplifiedData) f32 {
    if (data.width < 5) return 0.0;

    var max_adjust: f32 = 0.0;
    var i: u32 = 0;
    while (i < data.width) : (i += 1) {
        max_adjust = @max(max_adjust, @abs(data.getHeight(i, 0) - stitchedHeight(data, i, 0)));
        max_adjust = @max(max_adjust, @abs(data.getHeight(i, data.width - 1) - stitchedHeight(data, i, data.width - 1)));
        max_adjust = @max(max_adjust, @abs(data.getHeight(0, i) - stitchedHeight(data, 0, i)));
        max_adjust = @max(max_adjust, @abs(data.getHeight(data.width - 1, i) - stitchedHeight(data, data.width - 1, i)));
    }
    return max_adjust;
}

// Helper functions for unpacking colors
fn unpackR(color: u32) f32 {
    return @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
}

fn unpackG(color: u32) f32 {
    return @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
}

fn unpackB(color: u32) f32 {
    return @as(f32, @floatFromInt(color & 0xFF)) / 255.0;
}

fn averageColor(c00: u32, c10: u32, c01: u32, c11: u32) u32 {
    const r = ((c00 >> 16) & 0xFF) + ((c10 >> 16) & 0xFF) + ((c01 >> 16) & 0xFF) + ((c11 >> 16) & 0xFF);
    const g = ((c00 >> 8) & 0xFF) + ((c10 >> 8) & 0xFF) + ((c01 >> 8) & 0xFF) + ((c11 >> 8) & 0xFF);
    const b = (c00 & 0xFF) + (c10 & 0xFF) + (c01 & 0xFF) + (c11 & 0xFF);
    const r_avg: u32 = r / 4;
    const g_avg: u32 = g / 4;
    const b_avg: u32 = b / 4;
    return (r_avg << 16) | (g_avg << 8) | b_avg;
}

fn averageAmbientOcclusion(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const a00 = data.lighting[x0 + z0 * data.width].ambient_occlusion;
    const a10 = data.lighting[x1 + z0 * data.width].ambient_occlusion;
    const a01 = data.lighting[x0 + z1 * data.width].ambient_occlusion;
    const a11 = data.lighting[x1 + z1 * data.width].ambient_occlusion;
    return (a00 + a10 + a01 + a11) * 0.25;
}

fn applyColorBrightness(color: u32, brightness: f32) u32 {
    const clamped = std.math.clamp(brightness, 0.0, 1.0);
    const r: u32 = @intFromFloat(@round(@as(f32, @floatFromInt((color >> 16) & 0xFF)) * clamped));
    const g: u32 = @intFromFloat(@round(@as(f32, @floatFromInt((color >> 8) & 0xFF)) * clamped));
    const b: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(color & 0xFF)) * clamped));
    return (r << 16) | (g << 8) | b;
}

const LODTextureFace = enum { top, side, bottom };

fn tintColorForLodFace(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, block: BlockType, face: LODTextureFace, fallback: u32) u32 {
    if (block == .grass and face == .top) return averageBiomeBlockTint(data, gx, gz, lod_level, block);
    if (block == .water) return averageBiomeBlockTint(data, gx, gz, lod_level, block);
    if (isLeafBlock(block)) return averageBiomeBlockTint(data, gx, gz, lod_level, block);
    return fallback;
}

fn averageBiomeBlockTint(data: *const LODSimplifiedData, gx: u32, gz: u32, lod_level: LODLevel, block: BlockType) u32 {
    if (is_fine_sample_lod(lod_level)) {
        return biome_mod.getBlockTintColor(data.biomes[cell_index(data, gx, gz)], block);
    }

    const c00 = biome_mod.getBlockTintColor(data.biomes[cell_index(data, gx, gz)], block);
    const c10 = biome_mod.getBlockTintColor(data.biomes[cell_index(data, gx + 1, gz)], block);
    const c01 = biome_mod.getBlockTintColor(data.biomes[cell_index(data, gx, gz + 1)], block);
    const c11 = biome_mod.getBlockTintColor(data.biomes[cell_index(data, gx + 1, gz + 1)], block);
    return averageColor(c00, c10, c01, c11);
}

fn applyTextureLuminance(color: u32, block: BlockType, face: LODTextureFace, atlas: *const TextureAtlas) u32 {
    if (block == .air or block == .water) return color;
    const texture_color = averageTextureColorForFace(block, face, atlas) orelse {
        const luminance = atlas.getLuminanceForBlock(@intFromEnum(block));
        const factor = switch (face) {
            .top => luminance.top,
            .side => luminance.side,
            .bottom => luminance.bottom,
        };
        return scaleColor(color, std.math.clamp(factor, 0.18, 1.0));
    };

    if (!shouldTintLodFace(block, face)) return texture_color;
    return multiplyColors(texture_color, shaderLikeTintColor(color));
}

fn averageTextureColorForFace(block: BlockType, face: LODTextureFace, atlas: *const TextureAtlas) ?u32 {
    const tiles = atlas.getTilesForBlock(@intFromEnum(block));
    const tile_id = switch (face) {
        .top => tiles.top,
        .bottom => tiles.bottom,
        .side => tiles.side,
    };
    if (tile_id == 0) return null;

    const colors = atlas.getAverageColorForBlock(@intFromEnum(block));
    return switch (face) {
        .top => colors.top,
        .bottom => colors.bottom,
        .side => colors.side,
    };
}

fn shouldTintLodFace(block: BlockType, face: LODTextureFace) bool {
    if (block == .grass) return face == .top;
    if (block == .water) return true;
    return isLeafBlock(block);
}

fn multiplyColors(base: u32, tint: u32) u32 {
    const r: u32 = @intFromFloat(@round(unpackR(base) * unpackR(tint) * 255.0));
    const g: u32 = @intFromFloat(@round(unpackG(base) * unpackG(tint) * 255.0));
    const b: u32 = @intFromFloat(@round(unpackB(base) * unpackB(tint) * 255.0));
    const rr: u32 = @min(r, 255);
    const gg: u32 = @min(g, 255);
    const bb: u32 = @min(b, 255);
    return (rr << 16) | (gg << 8) | bb;
}

fn shaderLikeTintColor(color: u32) u32 {
    const r: u32 = (color >> 16) & 0xFF;
    const g: u32 = (color >> 8) & 0xFF;
    const b: u32 = color & 0xFF;
    const max_channel = @max(r, @max(g, b));
    if (max_channel == 0) return 0xFFFFFF;

    const min_channel = @min(r, @min(g, b));
    const chroma = @as(f32, @floatFromInt(max_channel - min_channel)) / @as(f32, @floatFromInt(max_channel));
    const tint_strength = smoothstep(0.05, 0.2, chroma);

    const max_f = @as(f32, @floatFromInt(max_channel));
    const nr = @as(f32, @floatFromInt(r)) / max_f;
    const ng = @as(f32, @floatFromInt(g)) / max_f;
    const nb = @as(f32, @floatFromInt(b)) / max_f;
    const out_r: u32 = @intFromFloat(@round((1.0 + (nr - 1.0) * tint_strength) * 255.0));
    const out_g: u32 = @intFromFloat(@round((1.0 + (ng - 1.0) * tint_strength) * 255.0));
    const out_b: u32 = @intFromFloat(@round((1.0 + (nb - 1.0) * tint_strength) * 255.0));
    const rr: u32 = @min(out_r, 255);
    const gg: u32 = @min(out_g, 255);
    const bb: u32 = @min(out_b, 255);
    return (rr << 16) | (gg << 8) | bb;
}

fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = std.math.clamp((x - edge0) / (edge1 - edge0), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

fn scaleColor(color: u32, factor: f32) u32 {
    const clamped = std.math.clamp(factor, 0.0, 2.0);
    const r: u32 = @intFromFloat(@round(std.math.clamp(@as(f32, @floatFromInt((color >> 16) & 0xFF)) * clamped, 0.0, 255.0)));
    const g: u32 = @intFromFloat(@round(std.math.clamp(@as(f32, @floatFromInt((color >> 8) & 0xFF)) * clamped, 0.0, 255.0)));
    const b: u32 = @intFromFloat(@round(std.math.clamp(@as(f32, @floatFromInt(color & 0xFF)) * clamped, 0.0, 255.0)));
    return (r << 16) | (g << 8) | b;
}

fn packBlockDefaultColor(block: BlockType, fallback: u32) u32 {
    if (block == .air) return fallback;
    const color = world_core.block_registry.getBlockDefinition(block).default_color;
    const r: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0));
    return (r << 16) | (g << 8) | b;
}

fn getLodTopTile(block: BlockType, atlas: *const TextureAtlas) u16 {
    if (block == .air) return Vertex.LOD_TILE_ID;
    if (isLeafBlock(block)) return Vertex.LOD_TILE_ID;

    const tiles = atlas.getTilesForBlock(@intFromEnum(block));
    if (tiles.top == 0) return Vertex.LOD_TILE_ID;
    return tiles.top;
}

fn getLodTopColor(block: BlockType, tile_id: u16, fallback_color: u32) u32 {
    _ = block;
    if (tile_id == Vertex.LOD_TILE_ID) return fallback_color;
    return fallback_color;
}

fn makeLODVertex(pos: [3]f32, col: [3]f32, norm: [3]f32, uv: [2]f32, tile_id: u16) Vertex {
    return Vertex{
        .pos = pos,
        .color = encodeColor(col),
        .normal = encodeNormal(norm),
        .uv = .{ @floatCast(uv[0]), @floatCast(uv[1]) },
        .packed_meta = encodeMeta(tile_id, 1.0, 1.0),
        .blocklight = 0,
        .entrance_dir = 0,
    };
}

/// Add a top-facing quad (two triangles)
fn addTopFaceQuad(allocator: std.mem.Allocator, vertices: *std.ArrayListUnmanaged(Vertex), x: f32, y: f32, z: f32, size: f32, r: f32, g: f32, b: f32, tile_id: u16, world_x: i32, world_z: i32) !void {
    const normal = [3]f32{ 0, 1, 0 };
    const color = [3]f32{ r, g, b };

    try vertices.append(allocator, makeLODVertex(.{ x, y, z }, color, normal, topFaceUV(.{ x, y, z }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z + size }, color, normal, topFaceUV(.{ x + size, y, z + size }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x, y, z + size }, color, normal, topFaceUV(.{ x, y, z + size }, world_x, world_z), tile_id));

    try vertices.append(allocator, makeLODVertex(.{ x, y, z }, color, normal, topFaceUV(.{ x, y, z }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z + size }, color, normal, topFaceUV(.{ x + size, y, z + size }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z }, color, normal, topFaceUV(.{ x + size, y, z }, world_x, world_z), tile_id));
}

/// Add a downward-facing bottom quad for floating spans (overhangs) so
/// caves/arches read correctly from below (issue #752 Phase 3.3).
fn addBottomFaceQuad(allocator: std.mem.Allocator, vertices: *std.ArrayListUnmanaged(Vertex), x: f32, y: f32, z: f32, size: f32, r: f32, g: f32, b: f32, tile_id: u16, world_x: i32, world_z: i32) !void {
    const normal = [3]f32{ 0, -1, 0 };
    const color = [3]f32{ r, g, b };

    try vertices.append(allocator, makeLODVertex(.{ x, y, z }, color, normal, topFaceUV(.{ x, y, z }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x, y, z + size }, color, normal, topFaceUV(.{ x, y, z + size }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z + size }, color, normal, topFaceUV(.{ x + size, y, z + size }, world_x, world_z), tile_id));

    try vertices.append(allocator, makeLODVertex(.{ x, y, z }, color, normal, topFaceUV(.{ x, y, z }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z + size }, color, normal, topFaceUV(.{ x + size, y, z + size }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z }, color, normal, topFaceUV(.{ x + size, y, z }, world_x, world_z), tile_id));
}

/// Add a side-facing quad for cliff faces
fn addSideFaceQuad(allocator: std.mem.Allocator, vertices: *std.ArrayListUnmanaged(Vertex), x: f32, y_top: f32, z: f32, size: f32, y_bottom: f32, r: f32, g: f32, b: f32, dir: FaceDir, tile_id: u16, world_x: i32, world_z: i32) !void {
    const color = [3]f32{ r, g, b };

    const normal: [3]f32 = switch (dir) {
        .north => .{ 0, 0, -1 },
        .south => .{ 0, 0, 1 },
        .east => .{ 1, 0, 0 },
        .west => .{ -1, 0, 0 },
    };

    // Calculate quad corners based on direction
    const corners: [4][3]f32 = switch (dir) {
        .west => .{
            .{ x, y_bottom, z },
            .{ x, y_bottom, z + size },
            .{ x, y_top, z + size },
            .{ x, y_top, z },
        },
        .east => .{
            .{ x + size, y_bottom, z + size },
            .{ x + size, y_bottom, z },
            .{ x + size, y_top, z },
            .{ x + size, y_top, z + size },
        },
        .north => .{
            .{ x + size, y_bottom, z },
            .{ x, y_bottom, z },
            .{ x, y_top, z },
            .{ x + size, y_top, z },
        },
        .south => .{
            .{ x, y_bottom, z + size },
            .{ x + size, y_bottom, z + size },
            .{ x + size, y_top, z + size },
            .{ x, y_top, z + size },
        },
    };

    try vertices.append(allocator, makeLODVertex(corners[0], color, normal, sideFaceUV(corners[0], dir, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(corners[1], color, normal, sideFaceUV(corners[1], dir, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(corners[2], color, normal, sideFaceUV(corners[2], dir, world_x, world_z), tile_id));

    try vertices.append(allocator, makeLODVertex(corners[0], color, normal, sideFaceUV(corners[0], dir, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(corners[2], color, normal, sideFaceUV(corners[2], dir, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(corners[3], color, normal, sideFaceUV(corners[3], dir, world_x, world_z), tile_id));
}

fn addTreeColumn(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    wx: f32,
    wz: f32,
    cell_size: f32,
    base_height: f32,
    vegetation: world_core.LODVegetationHint,
    atlas: *const TextureAtlas,
    world_x: i32,
    world_z: i32,
) !void {
    if (vegetation.leaves == .air) return;

    const canopy = treeCanopyInterval(base_height, vegetation);
    try addTreeCanopyColumn(allocator, vertices, data, gx, gz, lod_level, wx, wz, cell_size, base_height, canopy.min_height, canopy.max_height, vegetation, atlas, world_x, world_z);
}

fn addTreeCanopyColumn(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    wx: f32,
    wz: f32,
    cell_size: f32,
    base_height: f32,
    canopy_min_height: f32,
    canopy_max_height: f32,
    vegetation: world_core.LODVegetationHint,
    atlas: *const TextureAtlas,
    world_x: i32,
    world_z: i32,
) !void {
    if (vegetation.leaves == .air) return;
    if (canopy_max_height <= canopy_min_height + 0.01) return;

    const leaf_tile = Vertex.LOD_TILE_ID;
    const leaf_base_color = tintColorForLodFace(data, gx, gz, lod_level, vegetation.leaves, .top, packBlockDefaultColor(vegetation.leaves, 0x2F7D2A));
    const leaf_top_color = applyTextureLuminance(leaf_base_color, vegetation.leaves, .top, atlas);
    const footprint = treeCanopyFootprint(cell_size, vegetation);
    const origin = treeFootprintOrigin(wx, wz, cell_size, footprint, vegetation);
    try addBoxColumn(allocator, vertices, origin.x, origin.z, footprint, canopy_min_height, canopy_max_height, leaf_top_color, leaf_tile, world_x, world_z);

    if (shouldRenderLODTreeTrunk(lod_level) and vegetation.trunk != .air and canopy_min_height > base_height + 1.0) {
        const trunk_tiles = atlas.getTilesForBlock(@intFromEnum(vegetation.trunk));
        const trunk_tile = if (trunk_tiles.side == 0) Vertex.LOD_TILE_ID else trunk_tiles.side;
        const trunk_color = applyTextureLuminance(0xFFFFFF, vegetation.trunk, .side, atlas);
        const trunk_size = @min(footprint * 0.35, @max(0.65, cell_size * 0.18));
        const trunk_inset = (footprint - trunk_size) * 0.5;
        try addBoxColumn(allocator, vertices, origin.x + trunk_inset, origin.z + trunk_inset, trunk_size, base_height, canopy_min_height, trunk_color, trunk_tile, world_x, world_z);
    }
}

fn treeCanopyFootprint(cell_size: f32, vegetation: world_core.LODVegetationHint) f32 {
    const coverage = std.math.clamp(vegetation.tree_coverage, LOD_TREE_COVERAGE_THRESHOLD, 1.0);
    const desired = @max(1.0, vegetation.avg_tree_height * (0.30 + coverage * 0.18));
    const min_size = @min(cell_size, 1.35);
    const max_size = @max(min_size, cell_size * 0.72);
    return std.math.clamp(desired, min_size, max_size);
}

const TreeFootprintOrigin = struct { x: f32, z: f32 };

fn treeFootprintOrigin(wx: f32, wz: f32, cell_size: f32, footprint: f32, vegetation: world_core.LODVegetationHint) TreeFootprintOrigin {
    const max_offset = @max(0.0, (cell_size - footprint) * 0.5 - 0.01);
    const offset_x = std.math.clamp(vegetation.offset_x, -max_offset, max_offset);
    const offset_z = std.math.clamp(vegetation.offset_z, -max_offset, max_offset);
    return .{
        .x = wx + (cell_size - footprint) * 0.5 + offset_x,
        .z = wz + (cell_size - footprint) * 0.5 + offset_z,
    };
}

fn treeCanopyInterval(base_height: f32, vegetation: world_core.LODVegetationHint) HeightInterval {
    const canopy_height = @max(3.0, vegetation.avg_tree_height);
    const top = base_height + canopy_height;
    const depth = @max(2.0, canopy_height * 0.45);
    return .{
        .min_height = @max(base_height + 1.0, top - depth),
        .max_height = top,
    };
}

fn addTreeColumnSides(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    lod_level: LODLevel,
    wx: f32,
    wz: f32,
    size: f32,
    canopy: HeightInterval,
    color: u32,
    tile_id: u16,
    world_x: i32,
    world_z: i32,
) !void {
    try addTreeColumnSide(allocator, vertices, data, if (gx == 0) null else gx - 1, gz, lod_level, wx, wz, size, canopy, color, tile_id, .west, world_x, world_z);
    try addTreeColumnSide(allocator, vertices, data, if (gx + 1 >= data.width - 1) null else gx + 1, gz, lod_level, wx, wz, size, canopy, color, tile_id, .east, world_x, world_z);
    try addTreeColumnSide(allocator, vertices, data, gx, if (gz == 0) null else gz - 1, lod_level, wx, wz, size, canopy, color, tile_id, .north, world_x, world_z);
    try addTreeColumnSide(allocator, vertices, data, gx, if (gz + 1 >= data.width - 1) null else gz + 1, lod_level, wx, wz, size, canopy, color, tile_id, .south, world_x, world_z);
}

fn addTreeColumnSide(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    neighbor_gx: ?u32,
    neighbor_gz: ?u32,
    lod_level: LODLevel,
    wx: f32,
    wz: f32,
    size: f32,
    canopy: HeightInterval,
    color: u32,
    tile_id: u16,
    dir: FaceDir,
    world_x: i32,
    world_z: i32,
) !void {
    var exposed: [world_core.MAX_LOD_VERTICAL_SPANS + 1]HeightInterval = undefined;
    var exposed_count: usize = 1;
    exposed[0] = canopy;

    if (neighbor_gx) |nx| {
        if (neighbor_gz) |nz| {
            const neighbor_veg = representativeVegetationForLOD(data, nx, nz, lod_level);
            if (neighbor_veg.tree_coverage >= LOD_TREE_COVERAGE_THRESHOLD) {
                const neighbor_is_water_cell = is_lod_water_cell_for_lod(data, nx, nz, lod_level);
                const neighbor_base = quantizedCellVisualTerrainHeightForLOD(data, nx, nz, lod_level, neighbor_is_water_cell);
                const neighbor_canopy = treeCanopyInterval(neighbor_base, neighbor_veg);
                subtractCoveredInterval(&exposed, &exposed_count, neighbor_canopy.min_height, neighbor_canopy.max_height);
            }
        }
    }

    var i: usize = 0;
    while (i < exposed_count) : (i += 1) {
        const interval = exposed[i];
        if (interval.max_height <= interval.min_height + 0.01) continue;
        const brightness = heightfieldSideBrightness(dir);
        try addSideFaceQuad(allocator, vertices, wx, interval.max_height, wz, size, interval.min_height, unpackR(color) * brightness, unpackG(color) * brightness, unpackB(color) * brightness, dir, tile_id, world_x, world_z);
    }
}

fn addBoxColumn(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    x: f32,
    z: f32,
    size: f32,
    min_height: f32,
    max_height: f32,
    color: u32,
    tile_id: u16,
    world_x: i32,
    world_z: i32,
) !void {
    if (max_height <= min_height + 0.01) return;
    try addTopFaceQuad(allocator, vertices, x, max_height, z, size, unpackR(color), unpackG(color), unpackB(color), tile_id, world_x, world_z);
    try addSideFaceQuad(allocator, vertices, x, max_height, z, size, min_height, unpackR(color) * 0.8, unpackG(color) * 0.8, unpackB(color) * 0.8, .west, tile_id, world_x, world_z);
    try addSideFaceQuad(allocator, vertices, x, max_height, z, size, min_height, unpackR(color) * 0.8, unpackG(color) * 0.8, unpackB(color) * 0.8, .east, tile_id, world_x, world_z);
    try addSideFaceQuad(allocator, vertices, x, max_height, z, size, min_height, unpackR(color) * 0.7, unpackG(color) * 0.7, unpackB(color) * 0.7, .north, tile_id, world_x, world_z);
    try addSideFaceQuad(allocator, vertices, x, max_height, z, size, min_height, unpackR(color) * 0.7, unpackG(color) * 0.7, unpackB(color) * 0.7, .south, tile_id, world_x, world_z);
}

/// LOD Mesh Builder - builds meshes for LOD regions
pub const LODMeshBuilder = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) LODMeshBuilder {
        return .{ .allocator = allocator };
    }

    /// Build LOD1 mesh from 2x2 chunk heightmaps
    pub fn buildLOD1(
        self: *LODMeshBuilder,
        mesh: *LODMesh,
        heightmaps: [4][]const f32, // NW, NE, SW, SE chunks
        biomes: [4][]const BiomeId,
        world_x: i32,
        world_z: i32,
        atlas: *const TextureAtlas,
    ) !void {
        _ = self;
        const chunk_size: u32 = 16;
        const cell_size: u32 = 2; // LOD1 = 2x scale
        const grid_per_chunk = chunk_size / cell_size; // 8 cells per chunk

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(mesh.allocator);

        // Process each of the 4 chunks
        const chunk_offsets = [4][2]i32{
            .{ 0, 0 }, // NW
            .{ 16, 0 }, // NE
            .{ 0, 16 }, // SW
            .{ 16, 16 }, // SE
        };

        for (chunk_offsets, 0..) |offset, chunk_idx| {
            const heightmap = heightmaps[chunk_idx];
            const biome_data = biomes[chunk_idx];

            var gz: u32 = 0;
            while (gz < grid_per_chunk) : (gz += 1) {
                var gx: u32 = 0;
                while (gx < grid_per_chunk) : (gx += 1) {
                    // Sample center of each cell
                    const sample_x = gx * cell_size + cell_size / 2;
                    const sample_z = gz * cell_size + cell_size / 2;
                    const idx = sample_x + sample_z * chunk_size;

                    if (idx >= heightmap.len) continue;

                    const height = heightmap[idx];
                    const biome = biome_data[idx];
                    const color = biome_mod.getBiomeColor(biome);
                    const tiles = atlas.getTilesForBlock(@intFromEnum(biome.getSurfaceBlock()));

                    const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                    const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                    const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;

                    const wx: f32 = @floatFromInt(offset[0] + @as(i32, @intCast(gx * cell_size)));
                    const wz: f32 = @floatFromInt(offset[1] + @as(i32, @intCast(gz * cell_size)));
                    const wy: f32 = @floatFromInt(height);
                    const size: f32 = @floatFromInt(cell_size);

                    try addTopFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, r, g, b, tiles.top, world_x, world_z);

                    // Skirts
                    const skirt_depth = size * 4.0;
                    if (gx == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .west, tiles.side, world_x, world_z);
                    if (gx == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .east, tiles.side, world_x, world_z);
                    if (gz == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .north, tiles.side, world_x, world_z);
                    if (gz == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .south, tiles.side, world_x, world_z);
                }
            }
        }

        mesh.mutex.lock();
        defer mesh.mutex.unlock();

        if (mesh.pending_vertices) |p| {
            mesh.allocator.free(p);
        }

        if (vertices.items.len > 0) {
            mesh.pending_vertices = try mesh.allocator.dupe(Vertex, vertices.items);
        } else {
            mesh.pending_vertices = null;
        }
    }

    /// Build LOD2 mesh from 4x4 chunk heightmaps
    pub fn buildLOD2(
        self: *LODMeshBuilder,
        mesh: *LODMesh,
        heightmaps: [16][]const f32,
        biomes_data: [16][]const BiomeId,
        world_x: i32,
        world_z: i32,
        atlas: *const TextureAtlas,
    ) !void {
        _ = self;
        const chunk_size: u32 = 16;
        const cell_size: u32 = 4; // LOD2 = 4x scale
        const grid_per_chunk = chunk_size / cell_size; // 4 cells per chunk

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(mesh.allocator);

        // 4x4 grid of chunks
        for (0..16) |chunk_idx| {
            const cx: i32 = @intCast(chunk_idx % 4);
            const cz: i32 = @intCast(chunk_idx / 4);
            const offset_x = cx * @as(i32, chunk_size);
            const offset_z = cz * @as(i32, chunk_size);

            const heightmap = heightmaps[chunk_idx];
            const biome_data = biomes_data[chunk_idx];

            var gz: u32 = 0;
            while (gz < grid_per_chunk) : (gz += 1) {
                var gx: u32 = 0;
                while (gx < grid_per_chunk) : (gx += 1) {
                    const sample_x = gx * cell_size + cell_size / 2;
                    const sample_z = gz * cell_size + cell_size / 2;
                    const idx = sample_x + sample_z * chunk_size;

                    if (idx >= heightmap.len) continue;

                    const height = heightmap[idx];
                    const biome = biome_data[idx];
                    const color = biome_mod.getBiomeColor(biome);
                    const tiles = atlas.getTilesForBlock(@intFromEnum(biome.getSurfaceBlock()));

                    const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                    const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                    const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;

                    const wx: f32 = @floatFromInt(offset_x + @as(i32, @intCast(gx * cell_size)));
                    const wz: f32 = @floatFromInt(offset_z + @as(i32, @intCast(gz * cell_size)));
                    const wy: f32 = @floatFromInt(height);
                    const size: f32 = @floatFromInt(cell_size);

                    try addTopFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, r, g, b, tiles.top, world_x, world_z);

                    // Skirts
                    const skirt_depth = size * 4.0;
                    if (gx == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .west, tiles.side, world_x, world_z);
                    if (gx == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .east, tiles.side, world_x, world_z);
                    if (gz == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .north, tiles.side, world_x, world_z);
                    if (gz == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .south, tiles.side, world_x, world_z);
                }
            }
        }

        mesh.mutex.lock();
        defer mesh.mutex.unlock();

        if (mesh.pending_vertices) |p| {
            mesh.allocator.free(p);
        }

        if (vertices.items.len > 0) {
            mesh.pending_vertices = try mesh.allocator.dupe(Vertex, vertices.items);
        } else {
            mesh.pending_vertices = null;
        }
    }

    /// Build LOD3 mesh from simplified heightmap data
    pub fn buildLOD3(
        self: *LODMeshBuilder,
        mesh: *LODMesh,
        data: *const LODSimplifiedData,
        region_world_x: i32,
        region_world_z: i32,
        atlas: *const TextureAtlas,
    ) !void {
        _ = self;
        try mesh.buildFromSimplifiedData(data, region_world_x, region_world_z, atlas);
    }
};

// Tests
fn testResources() LODMeshResources {
    const Mock = struct {
        fn createBuffer(_: *anyopaque, _: usize, _: BufferUsage) RhiError!BufferHandle {
            return 1;
        }
        fn uploadBuffer(_: *anyopaque, _: BufferHandle, _: []const u8) RhiError!void {}
        fn updateBuffer(_: *anyopaque, _: BufferHandle, _: usize, _: []const u8) RhiError!void {}
        fn destroyBuffer(_: *anyopaque, _: BufferHandle) void {}
        fn waitIdle(_: *anyopaque) void {}

        const vtable = LODMeshResources.VTable{
            .createBuffer = createBuffer,
            .uploadBuffer = uploadBuffer,
            .updateBuffer = updateBuffer,
            .destroyBuffer = destroyBuffer,
            .waitIdle = waitIdle,
        };
    };
    return .{ .ptr = undefined, .vtable = &Mock.vtable };
}

test "LODMesh initialization" {
    const allocator = std.testing.allocator;
    var mesh = LODMesh.init(allocator, .lod1);
    defer mesh.deinit(testResources());

    try std.testing.expectEqual(LODLevel.lod1, mesh.lod_level);
    try std.testing.expectEqual(@as(u32, 0), mesh.vertex_count);
    try std.testing.expect(!mesh.ready);
}

test "getCellSize" {
    try std.testing.expectEqual(@as(u32, 1), getCellSize(.lod0));
    try std.testing.expectEqual(@as(u32, 1), getCellSize(.lod1));
    try std.testing.expectEqual(@as(u32, 2), getCellSize(.lod2));
    try std.testing.expectEqual(@as(u32, 2), getCellSize(.lod3));
    try std.testing.expectEqual(@as(u32, 4), getCellSize(.lod4));
}

test "buildFromSimplifiedData keeps distant heightfields voxel stepped" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();
    fillColumnSpanData(&data, .grass, 64.0, 0x3A7D42);
    data.setHeight(0, 0, 64.0);
    data.setHeight(1, 0, 70.0);
    data.setHeight(0, 1, 66.0);
    data.setHeight(1, 1, 72.0);

    var mesh = LODMesh.init(allocator, .lod3);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len >= 6);

    var top_vertices_at_base_height: usize = 0;
    for (verts[0..6]) |v| {
        if (v.pos[1] == 64.0) top_vertices_at_base_height += 1;
    }

    try std.testing.expectEqual(@as(usize, 6), top_vertices_at_base_height);
}

test "buildFullDetailHeightmapMesh spans full LOD region" {
    const allocator = std.testing.allocator;

    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);
    atlas.tile_luminance = [_]TextureAtlas.BlockTileLuminance{TextureAtlas.BlockTileLuminance.uniform(1.0)} ** world_core.MAX_BLOCK_TYPES;
    atlas.tile_colors = [_]TextureAtlas.BlockTileColor{TextureAtlas.BlockTileColor.uniform(0xFFFFFF)} ** world_core.MAX_BLOCK_TYPES;

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    const cell_count: usize = @intCast(data.width * data.width);
    var i: usize = 0;
    while (i < cell_count) : (i += 1) {
        data.heightmap[i] = 0.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .air;
        data.colors[i] = 0;
    }

    const mesh = try buildFullDetailHeightmapMesh(allocator, .lod3, &data, 32, 64, &atlas);
    defer {
        allocator.free(mesh.vertices);
        allocator.free(mesh.indices);
    }

    var max_x: f32 = 0.0;
    var max_z: f32 = 0.0;
    for (mesh.vertices) |v| {
        max_x = @max(max_x, v.pos[0]);
        max_z = @max(max_z, v.pos[2]);
    }

    try std.testing.expectEqual(@as(f32, 256.0), max_x);
    try std.testing.expectEqual(@as(f32, 256.0), max_z);
    try std.testing.expectEqual(@as(f32, 32.0), @as(f32, mesh.vertices[0].uv[0]));
    try std.testing.expectEqual(@as(f32, 64.0), @as(f32, mesh.vertices[0].uv[1]));
}

test "setPendingFromIndexed resets stale LOD draw ranges" {
    const allocator = std.testing.allocator;
    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    mesh.opaque_vertex_count = 24;
    mesh.water_vertex_offset = 24 * @sizeOf(Vertex);
    mesh.water_vertex_count = 6;

    const source = [_]Vertex{
        makeLODVertex(.{ 0.0, 1.0, 0.0 }, .{ 1.0, 1.0, 1.0 }, .{ 0.0, 1.0, 0.0 }, .{ 0.0, 0.0 }, Vertex.LOD_TILE_ID),
        makeLODVertex(.{ 1.0, 1.0, 0.0 }, .{ 1.0, 1.0, 1.0 }, .{ 0.0, 1.0, 0.0 }, .{ 1.0, 0.0 }, Vertex.LOD_TILE_ID),
        makeLODVertex(.{ 0.0, 1.0, 1.0 }, .{ 1.0, 1.0, 1.0 }, .{ 0.0, 1.0, 0.0 }, .{ 0.0, 1.0 }, Vertex.LOD_TILE_ID),
    };
    const indices = [_]u32{ 0, 1, 2 };

    try mesh.setPendingFromIndexed(&source, &indices);

    const pending = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 3), pending.len);
    try std.testing.expectEqual(@as(u32, 3), mesh.opaque_vertex_count);
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(Vertex)), mesh.water_vertex_offset);
    try std.testing.expectEqual(@as(u32, 0), mesh.water_vertex_count);
}

fn vertexTileId(v: Vertex) u16 {
    return @intCast(v.packed_meta & 0xFFFF);
}

fn vertexRgb(v: Vertex) u32 {
    const r = v.color & 0xFF;
    const g = (v.color >> 8) & 0xFF;
    const b = (v.color >> 16) & 0xFF;
    return (r << 16) | (g << 8) | b;
}

fn linearizeTestRgb(color: u32) u32 {
    const r = linearizeTestChannel(@intCast((color >> 16) & 0xFF));
    const g = linearizeTestChannel(@intCast((color >> 8) & 0xFF));
    const b = linearizeTestChannel(@intCast(color & 0xFF));
    return (r << 16) | (g << 8) | b;
}

fn linearizeTestChannel(value: u8) u32 {
    const c = @as(f32, @floatFromInt(value)) / 255.0;
    const linear = if (c <= 0.04045) c / 12.92 else std.math.pow(f32, (c + 0.055) / 1.055, 2.4);
    return @intFromFloat(@round(std.math.clamp(linear * 255.0, 0.0, 255.0)));
}

test "updateBufferChunked bounds individual staging updates" {
    const Mock = struct {
        calls: u32 = 0,
        max_len: usize = 0,
        total_len: usize = 0,

        fn createBuffer(_: *anyopaque, _: usize, _: BufferUsage) RhiError!BufferHandle {
            return 1;
        }

        fn uploadBuffer(_: *anyopaque, _: BufferHandle, _: []const u8) RhiError!void {}

        fn updateBuffer(ptr: *anyopaque, _: BufferHandle, _: usize, data: []const u8) RhiError!void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.calls += 1;
            self.max_len = @max(self.max_len, data.len);
            self.total_len += data.len;
        }

        fn destroyBuffer(_: *anyopaque, _: BufferHandle) void {}
        fn waitIdle(_: *anyopaque) void {}

        const vtable = LODMeshResources.VTable{
            .createBuffer = createBuffer,
            .uploadBuffer = uploadBuffer,
            .updateBuffer = updateBuffer,
            .destroyBuffer = destroyBuffer,
            .waitIdle = waitIdle,
        };
    };

    const allocator = std.testing.allocator;
    const len = MAX_STAGING_UPDATE_BYTES + 17;
    const data = try allocator.alloc(u8, len);
    defer allocator.free(data);
    @memset(data, 0xAB);

    var mock = Mock{};
    try updateBufferChunked(.{ .ptr = &mock, .vtable = &Mock.vtable }, 1, 128, data);

    try std.testing.expectEqual(@as(u32, 2), mock.calls);
    try std.testing.expect(mock.max_len <= MAX_STAGING_UPDATE_BYTES);
    try std.testing.expectEqual(len, mock.total_len);
}

fn testAtlas(allocator: std.mem.Allocator) TextureAtlas {
    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** world_core.MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };
    atlas.tile_mappings[@intFromEnum(BlockType.dirt)] = .{ .top = 25, .bottom = 25, .side = 26 };
    atlas.tile_mappings[@intFromEnum(BlockType.stone)] = .{ .top = 31, .bottom = 31, .side = 32 };
    atlas.tile_mappings[@intFromEnum(BlockType.sand)] = .{ .top = 51, .bottom = 52, .side = 55 };
    atlas.tile_mappings[@intFromEnum(BlockType.water)] = .{ .top = 41, .bottom = 41, .side = 42 };
    atlas.tile_mappings[@intFromEnum(BlockType.wood)] = .{ .top = 62, .bottom = 62, .side = 63 };
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };
    atlas.tile_colors[@intFromEnum(BlockType.grass)] = .{ .top = linearizeTestRgb(0x7FBF5A), .bottom = linearizeTestRgb(0x8A5A35), .side = linearizeTestRgb(0x6A8F42) };
    atlas.tile_colors[@intFromEnum(BlockType.dirt)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0x8A5A35));
    atlas.tile_colors[@intFromEnum(BlockType.stone)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0x777777));
    atlas.tile_colors[@intFromEnum(BlockType.sand)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0xD8C76D));
    atlas.tile_colors[@intFromEnum(BlockType.water)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0x3366CC));
    atlas.tile_colors[@intFromEnum(BlockType.wood)] = .{ .top = linearizeTestRgb(0x7B5A32), .bottom = linearizeTestRgb(0x7B5A32), .side = linearizeTestRgb(0x6B4428) };
    atlas.tile_colors[@intFromEnum(BlockType.leaves)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0x4C8F38));
    return atlas;
}

fn fillColumnSpanData(data: *LODSimplifiedData, block: BlockType, height: f32, color: u32) void {
    for (0..data.width * data.width) |i| {
        data.heightmap[i] = height;
        data.biomes[i] = .plains;
        data.top_blocks[i] = block;
        data.colors[i] = color;
        data.material_layers[i] = .{ .surface = block, .subsurface = block, .foundation = block };
        data.lighting[i] = world_core.LODLightingHint.daylight;
    }
}

fn testSpan(min_height: f32, max_height: f32, block: BlockType, color: u32) world_core.LODVerticalSpan {
    return .{
        .min_height = min_height,
        .max_height = max_height,
        .biome = .plains,
        .material_layers = .{ .surface = block, .subsurface = block, .foundation = block },
        .color = color,
        .water = world_core.LODWaterState.empty,
        .lighting = world_core.LODLightingHint.daylight,
        .vegetation = world_core.LODVegetationHint.empty,
    };
}

test "buildFromColumnSpans falls back to heightfield without span data" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .grass, 64.0, 0x3A7D42);

    var heightfield_mesh = LODMesh.init(allocator, .lod2);
    defer heightfield_mesh.deinit(testResources());
    try heightfield_mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    var span_mesh = LODMesh.init(allocator, .lod2);
    defer span_mesh.deinit(testResources());
    try span_mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const heightfield_verts = heightfield_mesh.pending_vertices orelse return error.TestExpectedEqual;
    const span_verts = span_mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(heightfield_verts.len, span_verts.len);
}

test "buildFromColumnSpans emits side faces for steep span terrain" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .stone, 64.0, 0x808080);
    data.clearVerticalSpans(0, 0);
    data.clearVerticalSpans(1, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(50.0, 96.0, .stone, 0x808080)));
    try std.testing.expect(data.setVerticalSpan(1, 0, 0, testSpan(50.0, 64.0, .stone, 0x808080)));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_cliff_side = false;
    for (verts) |v| {
        if (vertexTileId(v) == 32 and v.pos[1] >= 95.0) {
            found_cliff_side = true;
            break;
        }
    }
    try std.testing.expect(found_cliff_side);
}

test "addExposedSpanFace suppresses unknown region border walls" {
    const allocator = std.testing.allocator;

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();

    var vertices = std.ArrayListUnmanaged(Vertex).empty;
    defer vertices.deinit(allocator);

    try addExposedSpanFace(
        allocator,
        &vertices,
        &data,
        0,
        0,
        null,
        0,
        .lod2,
        .{ .min_height = 0.0, .max_height = 64.0, .block = .stone, .color = 0x808080, .ambient_occlusion = 1.0 },
        0.0,
        0.0,
        8.0,
        0x808080,
        32,
        .west,
        0,
        0,
    );

    try std.testing.expectEqual(@as(usize, 0), vertices.items.len);
}

test "buildFromColumnSpans adds water as a separate span" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 60.0, 0xD8C76D);
    data.clearVerticalSpans(0, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(45.0, 60.0, .sand, 0xD8C76D)));
    data.water[0] = .{ .is_surface = true, .surface_height = 63.0, .depth = 3.0, .coverage = 1.0 };

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(mesh.opaque_vertex_count > 0);
    try std.testing.expect(mesh.water_vertex_count > 0);
    try std.testing.expectEqual(@as(u32, 6), mesh.water_vertex_count);
    try std.testing.expectEqual(mesh.opaque_vertex_count * @sizeOf(Vertex), mesh.water_vertex_offset);

    for (verts[0..mesh.opaque_vertex_count]) |v| {
        try std.testing.expect(vertexTileId(v) != 41);
    }

    var found_water = false;
    const water_start: usize = @intCast(mesh.opaque_vertex_count);
    for (verts[water_start..]) |v| {
        if (vertexTileId(v) == 41 and v.pos[1] == 63.0) {
            found_water = true;
            break;
        }
    }
    try std.testing.expect(found_water);
}

test "collectColumnSpans synthesizes local material seafloor under ocean water" {
    const allocator = std.testing.allocator;

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 58.0;
        data.biomes[i] = .ocean;
        data.top_blocks[i] = .water;
        data.colors[i] = 0x3355AA;
        data.material_layers[i] = .{ .surface = .water, .subsurface = .sand, .foundation = .stone };
        data.water[i] = .{ .is_surface = true, .surface_height = 64.0, .depth = 6.0, .coverage = 1.0 };
        data.lighting[i] = world_core.LODLightingHint.daylight;
    }

    var spans: [world_core.MAX_LOD_VERTICAL_SPANS + 1]LODColumnSpan = undefined;
    const count = collectColumnSpans(&data, 0, 0, .lod2, &spans);

    var found_seafloor = false;
    var found_water = false;
    var i: usize = 0;
    while (i < count) : (i += 1) {
        if (spans[i].block == .sand) {
            found_seafloor = true;
            try std.testing.expectEqual(@as(f32, 50.0), spans[i].min_height);
            try std.testing.expectEqual(@as(f32, 58.0), spans[i].max_height);
            try std.testing.expect(spans[i].color != 0x3355AA);
        }
        if (spans[i].block == .water) found_water = true;
    }

    try std.testing.expect(found_seafloor);
    try std.testing.expect(found_water);
}

test "buildFromSimplifiedData separates heightfield water from opaque terrain" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 60.0, 0xD8C76D);

    const water_points = [_]u32{ 0, 1, data.width, data.width + 1 };
    for (water_points) |idx| {
        data.water[idx] = .{ .is_surface = true, .surface_height = 63.0, .depth = 3.0, .coverage = 1.0 };
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(mesh.opaque_vertex_count > 0);
    try std.testing.expect(mesh.water_vertex_count > 0);
    try std.testing.expectEqual(mesh.opaque_vertex_count * @sizeOf(Vertex), mesh.water_vertex_offset);

    var found_seafloor = false;
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        try std.testing.expect(vertexTileId(v) != 41);
        if (vertexTileId(v) == 51 and v.pos[1] == 60.0) found_seafloor = true;
    }
    try std.testing.expect(found_seafloor);

    var found_water = false;
    const water_start: usize = @intCast(mesh.opaque_vertex_count);
    for (verts[water_start..]) |v| {
        if (vertexTileId(v) == 41 and v.pos[1] == 63.0) {
            found_water = true;
            break;
        }
    }
    try std.testing.expect(found_water);
}

test "coarse heightfield water ignores isolated deep wet corner" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 60.0, 0xD8C76D);
    data.water[0] = .{ .is_surface = true, .surface_height = 63.0, .depth = 8.0, .coverage = 1.0 };

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(u32, 0), mesh.water_vertex_count);

    var found_surface_sand = false;
    var found_depressed_sand = false;
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        try std.testing.expect(vertexTileId(v) != 41);
        if (vertexTileId(v) == 51 and v.pos[1] == 60.0) found_surface_sand = true;
        if (vertexTileId(v) == 51 and v.pos[1] < 60.0) found_depressed_sand = true;
    }

    try std.testing.expect(found_surface_sand);
    try std.testing.expect(!found_depressed_sand);
}

test "coarse span water ignores isolated low-coverage water span" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 60.0, 0xD8C76D);
    data.clearVerticalSpans(0, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(45.0, 60.0, .sand, 0xD8C76D)));

    const water_state = world_core.LODWaterState{ .is_surface = true, .surface_height = 63.0, .depth = 3.0, .coverage = 0.2 };
    data.water[0] = water_state;
    try std.testing.expect(data.setVerticalSpan(0, 0, 1, .{
        .min_height = 60.0,
        .max_height = 63.0,
        .biome = .plains,
        .material_layers = .{ .surface = .water, .subsurface = .water, .foundation = .sand },
        .color = 0x3366CC,
        .water = water_state,
        .lighting = world_core.LODLightingHint.daylight,
        .vegetation = world_core.LODVegetationHint.empty,
    }));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(mesh.opaque_vertex_count > 0);
    try std.testing.expectEqual(@as(u32, 0), mesh.water_vertex_count);
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        try std.testing.expect(vertexTileId(v) != 41);
    }
}

test "buildFromColumnSpans skips empty columns while exposing neighbors" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .grass, 64.0, 0x3A7D42);
    data.clearVerticalSpans(0, 0);
    data.clearVerticalSpans(1, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(50.0, 64.0, .grass, 0x3A7D42)));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var side_count: usize = 0;
    for (verts) |v| {
        if (vertexTileId(v) == 24) side_count += 1;
    }
    try std.testing.expect(side_count >= 6);
}

test "buildFromColumnSpans sorts representative spans by height" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .stone, 64.0, 0x808080);
    data.clearVerticalSpans(0, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(80.0, 90.0, .stone, 0x808080)));
    try std.testing.expect(data.setVerticalSpan(0, 0, 1, testSpan(40.0, 55.0, .dirt, 0x6B4A2B)));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_lower_top = false;
    var found_upper_top = false;
    for (verts) |v| {
        if (vertexTileId(v) == 25 and v.pos[1] == 55.0) found_lower_top = true;
        if (vertexTileId(v) == 31 and v.pos[1] == 90.0) found_upper_top = true;
    }
    try std.testing.expect(found_lower_top);
    try std.testing.expect(found_upper_top);
}

test "buildFromColumnSpans snaps boundary span tops to stitched height" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    data.setHeight(0, 1, 100.0);
    data.setHeight(0, 2, 10.0);
    try std.testing.expect(data.setVerticalSpan(0, 1, 0, testSpan(0.0, 100.0, .grass, 0x3A7D42)));

    const expected_height = quantizedHeight(stitchedHeight(&data, 0, 1));
    try std.testing.expect(expected_height < 100.0);

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_stitched_top = false;
    for (verts) |v| {
        if (vertexTileId(v) == 23 and @abs(v.pos[1] - expected_height) <= 0.001) {
            found_stitched_top = true;
            break;
        }
    }
    try std.testing.expect(found_stitched_top);
}

test "buildFromColumnSpans keeps LOD2 canopy spans detached" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };

    var data = try LODSimplifiedData.initWithVerticalSpans(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .grass, 64.0, 0x2D591A);

    for (0..data.width * data.width) |i| {
        data.vegetation[i] = .{
            .tree_coverage = 0.6,
            .avg_tree_height = 7.0,
            .offset_x = 0.0,
            .offset_z = 0.0,
            .trunk = .wood,
            .leaves = .leaves,
        };
    }
    data.clearVerticalSpans(0, 0);
    try std.testing.expect(data.setVerticalSpan(0, 0, 0, testSpan(0.0, 64.0, .grass, 0x2D591A)));
    try std.testing.expect(data.setVerticalSpan(0, 0, 1, testSpan(66.0, 71.0, .leaves, 0x24941F)));

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromColumnSpans(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_folded = false;
    var found_detached = false;
    var found_compact_canopy = false;
    for (verts) |v| {
        if (v.pos[1] == 68.0 and vertexTileId(v) == Vertex.LOD_TILE_ID) found_folded = true;
        if (v.pos[1] == 71.0) found_detached = true;
        if (v.pos[1] == 71.0 and vertexTileId(v) == Vertex.LOD_TILE_ID and v.pos[0] > 0.0 and v.pos[0] < 4.0) found_compact_canopy = true;
    }
    try std.testing.expect(!found_folded);
    try std.testing.expect(found_detached);
    try std.testing.expect(found_compact_canopy);
}

test "buildFromSimplifiedData renders LOD3 tree columns" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_mappings[@intFromEnum(BlockType.wood)] = .{ .top = 62, .bottom = 62, .side = 63 };
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };

    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();
    fillColumnSpanData(&data, .grass, 64.0, 0x2D591A);
    data.vegetation[0] = .{
        .tree_coverage = 1.0,
        .avg_tree_height = 8.0,
        .offset_x = 0.0,
        .offset_z = 0.0,
        .trunk = .wood,
        .leaves = .leaves,
    };

    var mesh = LODMesh.init(allocator, .lod3);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_trunk_side = false;
    var found_canopy = false;
    var found_compact_canopy = false;
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        if (vertexTileId(v) == 63 and v.pos[1] > 64.0) found_trunk_side = true;
        if (vertexTileId(v) == Vertex.LOD_TILE_ID and v.pos[1] >= 72.0) found_canopy = true;
        if (vertexTileId(v) == Vertex.LOD_TILE_ID and v.pos[1] >= 72.0 and v.pos[0] > 0.0 and v.pos[0] < 8.0) found_compact_canopy = true;
    }

    try std.testing.expect(found_trunk_side);
    try std.testing.expect(found_canopy);
    try std.testing.expect(found_compact_canopy);
}

test "buildFromSimplifiedData uses atlas tiles and world-scaled UVs" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = biome_mod.getBiomeColor(.plains);
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 32, 64, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    try std.testing.expectEqual(@as(u16, 23), vertexTileId(verts[0]));
    try std.testing.expectEqual(@as(f32, 32.0), @as(f32, verts[0].uv[0]));
    try std.testing.expectEqual(@as(f32, 64.0), @as(f32, verts[0].uv[1]));

    var found_top_tile = false;
    var found_side_tile = false;
    for (verts) |v| {
        const tile_id = vertexTileId(v);
        try std.testing.expect(tile_id == 23 or tile_id == 24);
        if (tile_id == 23) found_top_tile = true;
        if (tile_id == 24) found_side_tile = true;
    }
    try std.testing.expect(found_top_tile);
    try std.testing.expect(found_side_tile);
}

test "buildFromSimplifiedData uses texture average for non-tint LOD tops" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.sand)] = .{ .top = 31, .bottom = 0, .side = 0 };
    atlas.tile_colors[@intFromEnum(BlockType.sand)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0xC2A85E));

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .beach;
        data.top_blocks[i] = .sand;
        data.colors[i] = 0xD8C76D;
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    var top_tile_count: usize = 0;
    for (verts) |v| {
        const tile_id = vertexTileId(v);
        try std.testing.expect(tile_id == 31 or tile_id == Vertex.LOD_TILE_ID);
        if (tile_id == 31) {
            top_tile_count += 1;
            try std.testing.expectEqual(linearizeTestRgb(0xC2A85E), vertexRgb(v));
        }
    }
    try std.testing.expect(top_tile_count > 0);
}

test "buildFromSimplifiedData keeps texture averages stable across world origins" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();
    fillColumnSpanData(&data, .sand, 64.0, 0xD8C76D);

    const expected = linearizeTestRgb(0xD8C76D);
    const origins = [_][2]i32{
        .{ 0, 0 },
        .{ 37, -91 },
        .{ -256, 513 },
        .{ 1024, 33 },
    };

    for (origins) |origin| {
        var mesh = LODMesh.init(allocator, .lod2);
        defer mesh.deinit(testResources());

        try mesh.buildFromSimplifiedData(&data, origin[0], origin[1], &atlas);

        const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
        var checked_top = false;
        for (verts) |v| {
            if (vertexTileId(v) == 51) {
                checked_top = true;
                try std.testing.expectEqual(expected, vertexRgb(v));
            }
        }
        try std.testing.expect(checked_top);
    }
}

test "buildFromSimplifiedData falls back to LOD tile for unmapped top blocks" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = biome_mod.getBiomeColor(.plains);
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    for (verts) |v| try std.testing.expectEqual(@as(u16, Vertex.LOD_TILE_ID), vertexTileId(v));
}

test "buildFromSimplifiedData promotes mixed water cells to water material" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };
    atlas.tile_mappings[@intFromEnum(BlockType.water)] = .{ .top = 41, .bottom = 41, .side = 42 };
    atlas.tile_mappings[@intFromEnum(BlockType.sand)] = .{ .top = 51, .bottom = 52, .side = 55 };

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 63.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = biome_mod.getBiomeColor(.plains);
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }
    data.water[0] = .{
        .is_surface = true,
        .surface_height = 63.0,
        .depth = 8.0,
        .coverage = 1.0,
    };
    data.material_layers[0] = .{
        .surface = .water,
        .subsurface = .sand,
        .foundation = .stone,
    };

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    var found_seafloor_top = false;
    const water_start: usize = @intCast(mesh.opaque_vertex_count);
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        if (vertexTileId(v) == 51) found_seafloor_top = true;
        try std.testing.expect(vertexTileId(v) != 41);
    }
    try std.testing.expect(found_seafloor_top);

    var found_water_top = false;
    for (verts[water_start..]) |v| {
        if (vertexTileId(v) == 41 and v.pos[1] == 63.0) found_water_top = true;
    }
    try std.testing.expect(found_water_top);

    var found_floor_side = false;
    for (verts[0..mesh.opaque_vertex_count]) |v| {
        if (vertexTileId(v) == 55) {
            found_floor_side = true;
            break;
        }
    }
    try std.testing.expect(found_floor_side);
}

test "blockForLODQuad uses representative non-water surface" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod1);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }

    data.material_layers[1].surface = .stone;
    data.material_layers[data.width].surface = .stone;
    data.material_layers[data.width + 1].surface = .stone;

    try std.testing.expectEqual(BlockType.stone, blockForLODQuad(&data, 0, 0));
}

test "stitchedHeight blends boundary points toward coarse grid" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod1);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 10.0;
    }
    data.setHeight(0, 1, 100.0);

    try std.testing.expect(stitchedHeight(&data, 0, 1) < 100.0);
    try std.testing.expectEqual(@as(f32, 10.0), stitchedHeight(&data, 4, 4));
}

test "coarse cell terrain height uses source sample instead of corner mean" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 96.0;
    }
    data.setHeight(0, 0, 64.0);

    try std.testing.expectEqual(@as(f32, 64.0), quantizedCellTerrainHeight(&data, 0, 0));
    try std.testing.expectEqual(@as(f32, 64.0), quantizedCellSurfaceHeight(&data, 0, 0));
}

test "representativeVegetationForLOD preserves sparse coarse coverage" {
    const allocator = std.testing.allocator;
    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    data.vegetation[0] = .{
        .tree_coverage = 0.1,
        .avg_tree_height = 7.0,
        .offset_x = 0.0,
        .offset_z = 0.0,
        .trunk = .wood,
        .leaves = .leaves,
    };

    const vegetation = representativeVegetationForLOD(&data, 0, 0, .lod2);
    try std.testing.expect(vegetation.tree_coverage >= 0.1);
    try std.testing.expect(vegetation.avg_tree_height >= 7.0);
}

test "buildFromSimplifiedData uses averaged color tile for far LOD tops" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };
    atlas.tile_colors[@intFromEnum(BlockType.grass)] = .{ .top = linearizeTestRgb(0x80C060), .bottom = linearizeTestRgb(0x805030), .side = linearizeTestRgb(0x607040) };

    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0x3A7D42;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }

    var mesh = LODMesh.init(allocator, .lod3);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);
    try std.testing.expectEqual(@as(u16, Vertex.LOD_TILE_ID), vertexTileId(verts[0]));
    try std.testing.expect(vertexRgb(verts[0]) != 0x3A7D42);
}

test "buildFromSimplifiedData tints atlas average for grass tops" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_colors[@intFromEnum(BlockType.grass)] = .{ .top = linearizeTestRgb(0x80C060), .bottom = linearizeTestRgb(0x805030), .side = linearizeTestRgb(0x607040) };

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0x3A7D42;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    const rgb = vertexRgb(verts[0]);
    try std.testing.expect(rgb != 0x3A7D42);
    try std.testing.expect(((rgb >> 8) & 0xFF) > ((rgb >> 16) & 0xFF));
}

test "buildFromSimplifiedData uses chunk grass tint for grass tops" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_colors[@intFromEnum(BlockType.grass)] = .{ .top = linearizeTestRgb(0x80C060), .bottom = linearizeTestRgb(0x805030), .side = linearizeTestRgb(0x607040) };

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0xFFFFFF;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());
    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    const expected = applyTextureLuminance(biome_mod.getGrassTintColor(.plains), .grass, .top, &atlas);
    try std.testing.expectEqual(expected, vertexRgb(verts[0]));
}

test "addTreeCanopyColumn uses chunk foliage tint" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_colors[@intFromEnum(BlockType.leaves)] = TextureAtlas.BlockTileColor.uniform(linearizeTestRgb(0x4C8F38));

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();
    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .forest;
    }

    var vertices = std.ArrayListUnmanaged(Vertex).empty;
    defer vertices.deinit(allocator);
    const vegetation: world_core.LODVegetationHint = .{
        .tree_coverage = 0.35,
        .avg_tree_height = 8.0,
        .offset_x = 0.0,
        .offset_z = 0.0,
        .trunk = .wood,
        .leaves = .leaves,
    };

    try addTreeCanopyColumn(allocator, &vertices, &data, 0, 0, .lod2, 0.0, 0.0, 8.0, 64.0, 67.0, 72.0, vegetation, &atlas, 0, 0);

    try std.testing.expect(vertices.items.len >= 6);
    const expected = applyTextureLuminance(biome_mod.getFoliageTintColor(.forest), .leaves, .top, &atlas);
    for (vertices.items[0..6]) |v| {
        try std.testing.expectEqual(expected, vertexRgb(v));
    }
}

test "buildFromSimplifiedData uses single source sample for fine LOD tops" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };

    var data = try LODSimplifiedData.init(allocator, .lod1);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 96.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0xFFFFFF;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
    }
    data.heightmap[0] = 64.0;
    data.colors[0] = 0x123456;

    var mesh = LODMesh.init(allocator, .lod1);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);
    try std.testing.expectEqual(@as(f32, 64.0), verts[0].pos[1]);
    const expected = applyTextureLuminance(biome_mod.getGrassTintColor(.plains), .grass, .top, &atlas);
    try std.testing.expectEqual(expected, vertexRgb(verts[0]));
}

test "buildFromSimplifiedData keeps mixed water cells on one flat surface" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);

    var data = try LODSimplifiedData.init(allocator, .lod2);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 58.0;
        data.biomes[i] = .ocean;
        data.top_blocks[i] = .sand;
        data.colors[i] = 0x3355AA;
        data.material_layers[i] = .{ .surface = .sand, .subsurface = .sand, .foundation = .stone };
        data.water[i] = .{ .is_surface = true, .surface_height = 63.0, .depth = 5.0, .coverage = 1.0 };
    }
    data.water[0].surface_height = 62.0;
    data.water[1].surface_height = 64.0;
    data.water[data.width].surface_height = 63.0;
    data.water[data.width + 1].surface_height = 63.0;

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    const water_start: usize = @intCast(mesh.opaque_vertex_count);
    try std.testing.expect(water_start < verts.len);
    for (verts[water_start .. water_start + 6]) |v| {
        try std.testing.expectEqual(@as(f32, 64.0), v.pos[1]);
    }
}

test "adjacent ocean regions normalize water tops to shared sea level" {
    const allocator = std.testing.allocator;

    var left = try LODSimplifiedData.init(allocator, .lod2);
    defer left.deinit();
    var right = try LODSimplifiedData.init(allocator, .lod2);
    defer right.deinit();

    for (0..left.width * left.width) |i| {
        left.heightmap[i] = 58.0;
        left.biomes[i] = .ocean;
        left.top_blocks[i] = .water;
        left.material_layers[i] = .{ .surface = .water, .subsurface = .sand, .foundation = .stone };
        left.water[i] = .{ .is_surface = true, .surface_height = 62.0, .depth = 4.0, .coverage = 1.0 };

        right.heightmap[i] = 58.0;
        right.biomes[i] = .ocean;
        right.top_blocks[i] = .water;
        right.material_layers[i] = .{ .surface = .water, .subsurface = .sand, .foundation = .stone };
        right.water[i] = .{ .is_surface = true, .surface_height = 63.0, .depth = 5.0, .coverage = 1.0 };
    }

    try std.testing.expectEqual(@as(f32, 64.0), quantizedWaterSurfaceHeightForCell(&left, left.width - 2, 0, .lod2));
    try std.testing.expectEqual(@as(f32, 64.0), quantizedWaterSurfaceHeightForCell(&right, 0, 0, .lod2));
}

test "buildFromSimplifiedData renders voxel tree columns for fine vegetation hints" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };
    atlas.tile_mappings[@intFromEnum(BlockType.wood)] = .{ .top = 71, .bottom = 71, .side = 72 };

    var data = try LODSimplifiedData.init(allocator, .lod1);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .forest;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0x2D591A;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
        data.vegetation[i] = .{
            .tree_coverage = 0.6,
            .avg_tree_height = 7.0,
            .offset_x = 0.0,
            .offset_z = 0.0,
            .trunk = .wood,
            .leaves = .leaves,
        };
    }

    var mesh = LODMesh.init(allocator, .lod1);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_leaf_column_top = false;
    for (verts) |v| {
        if (vertexTileId(v) == Vertex.LOD_TILE_ID and v.pos[1] == 71.0 and vertexRgb(v) != 0xFFFFFF) {
            found_leaf_column_top = true;
            break;
        }
    }
    try std.testing.expect(found_leaf_column_top);
}

test "buildFromSimplifiedData renders far vegetation as separate tree silhouettes" {
    const allocator = std.testing.allocator;
    var atlas = testAtlas(allocator);
    atlas.tile_mappings[@intFromEnum(BlockType.leaves)] = .{ .top = 70, .bottom = 70, .side = 70 };

    var data = try LODSimplifiedData.init(allocator, .lod4);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .forest;
        data.top_blocks[i] = .grass;
        data.colors[i] = 0x2D591A;
        data.material_layers[i] = .{
            .surface = .grass,
            .subsurface = .dirt,
            .foundation = .stone,
        };
        data.vegetation[i] = .{
            .tree_coverage = 0.6,
            .avg_tree_height = 7.0,
            .offset_x = 0.0,
            .offset_z = 0.0,
            .trunk = .wood,
            .leaves = .leaves,
        };
    }

    var mesh = LODMesh.init(allocator, .lod4);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_ground_top = false;
    var found_canopy_top = false;
    var found_compact_canopy = false;
    for (verts) |v| {
        if (v.pos[1] == 64.0 and vertexRgb(v) == 0x2D591A) found_ground_top = true;
        if (v.pos[1] == 71.0 and vertexTileId(v) == Vertex.LOD_TILE_ID and vertexRgb(v) != 0x2D591A) found_canopy_top = true;
        if (v.pos[1] == 71.0 and vertexTileId(v) == Vertex.LOD_TILE_ID and v.pos[0] > 0.0 and v.pos[0] < 8.0) found_compact_canopy = true;
    }
    try std.testing.expect(found_ground_top);
    try std.testing.expect(found_canopy_top);
    try std.testing.expect(found_compact_canopy);
}

test "buildFromSimplifiedData adds internal faces for steep LOD height deltas" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(0)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.stone)] = .{ .top = 11, .bottom = 12, .side = 13 };

    var flat_data = try LODSimplifiedData.init(allocator, .lod3);
    defer flat_data.deinit();
    var cliff_data = try LODSimplifiedData.init(allocator, .lod3);
    defer cliff_data.deinit();

    for (0..flat_data.width * flat_data.width) |i| {
        flat_data.heightmap[i] = 64.0;
        flat_data.biomes[i] = .mountains;
        flat_data.top_blocks[i] = .stone;
        flat_data.colors[i] = 0x808080;
        flat_data.material_layers[i] = .{
            .surface = .stone,
            .subsurface = .stone,
            .foundation = .stone,
        };
        cliff_data.heightmap[i] = flat_data.heightmap[i];
        cliff_data.biomes[i] = flat_data.biomes[i];
        cliff_data.top_blocks[i] = flat_data.top_blocks[i];
        cliff_data.colors[i] = flat_data.colors[i];
        cliff_data.material_layers[i] = flat_data.material_layers[i];
    }

    cliff_data.setHeight(15, 15, 96.0);
    cliff_data.setHeight(16, 15, 96.0);
    cliff_data.setHeight(15, 16, 96.0);
    cliff_data.setHeight(16, 16, 96.0);

    var flat_mesh = LODMesh.init(allocator, .lod3);
    defer flat_mesh.deinit(testResources());
    try flat_mesh.buildFromSimplifiedData(&flat_data, 0, 0, &atlas);
    const flat_verts = flat_mesh.pending_vertices orelse return error.TestExpectedEqual;

    var cliff_mesh = LODMesh.init(allocator, .lod3);
    defer cliff_mesh.deinit(testResources());
    try cliff_mesh.buildFromSimplifiedData(&cliff_data, 0, 0, &atlas);
    const cliff_verts = cliff_mesh.pending_vertices orelse return error.TestExpectedEqual;

    try std.testing.expect(cliff_verts.len > flat_verts.len);
}

test "buildFromHeightmap uses biome atlas tiles" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;

    var atlas = TextureAtlas{
        .texture = undefined,
        .normal_texture = null,
        .roughness_texture = null,
        .displacement_texture = null,
        .allocator = allocator,
        .pack_manager = null,
        .tile_size = 16,
        .atlas_size = 256,
        .has_pbr = false,
        .tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** MAX_BLOCK_TYPES,
    };
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = .{ .top = 23, .bottom = 2, .side = 24 };

    const width: u32 = 4;
    const count = width * width;
    const heightmap = [_]f32{64.0} ** count;
    const biomes = [_]BiomeId{.plains} ** count;

    var mesh = LODMesh.init(allocator, .lod1);
    defer mesh.deinit(testResources());

    try mesh.buildFromHeightmap(&heightmap, &biomes, width, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    var found_top_tile = false;
    for (verts) |v| {
        if (vertexTileId(v) == 23) {
            found_top_tile = true;
            break;
        }
    }
    try std.testing.expect(found_top_tile);
}
