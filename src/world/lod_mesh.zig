//! LOD Mesh generation for distant terrain rendering.
//!
//! LOD meshes are simplified versions of chunk meshes:
//! - LOD1: 4x4 chunks merged, 2-block resolution
//! - LOD2: 8x8 chunks merged, 4-block resolution
//! - LOD3: 16x16 chunks merged, 8-block resolution (heightmap only)
//!
//! Key simplifications:
//! - No greedy meshing (simple quads per grid cell)
//! - No lighting calculations
//! - No fluid pass (water rendered as solid)
//! - Biome colors averaged per cell

const std = @import("std");
const sync = @import("sync");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const BiomeId = @import("worldgen/biome.zig").BiomeId;
const biome_mod = @import("worldgen/biome.zig");
const BlockType = @import("block.zig").BlockType;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const rhi_types = @import("../engine/graphics/rhi_types.zig");
const Vertex = rhi_types.Vertex;
const BufferHandle = rhi_types.BufferHandle;
const RhiError = rhi_types.RhiError;
const encodeColor = rhi_types.encodeColor;
const encodeNormal = rhi_types.encodeNormal;
const encodeMeta = rhi_types.encodeMeta;
const encodeBlocklight = rhi_types.encodeBlocklight;
const QuadricSimplifier = @import("meshing/quadric_simplifier.zig").QuadricSimplifier;
const log = @import("../engine/core/log.zig");

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
    /// Buffer capacity (vertices)
    capacity: u32 = 0,
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

    pub fn deinit(self: *LODMesh, rhi: anytype) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.buffer_handle != 0) {
            rhi.destroyBuffer(self.buffer_handle);
            self.buffer_handle = 0;
        }
        if (self.pending_vertices) |p| {
            self.allocator.free(p);
            self.pending_vertices = null;
        }
        self.ready = false;
    }

    /// Build mesh from simplified LOD data (heightmap-based)
    pub fn buildFromSimplifiedData(self: *LODMesh, data: *const LODSimplifiedData, _: i32, _: i32, _: *const TextureAtlas) !void {
        const cell_size = getCellSize(self.lod_level);

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(self.allocator);

        // Generate a smooth heightmap mesh using per-vertex heights
        // Each cell is split into 2 triangles with vertices at correct heights
        var gz: u32 = 0;
        while (gz < data.width) : (gz += 1) {
            var gx: u32 = 0;
            while (gx < data.width) : (gx += 1) {
                // Get heights at all 4 corners of this cell
                const h00 = data.heightmap[gx + gz * data.width];
                const h10 = if (gx + 1 < data.width) data.heightmap[(gx + 1) + gz * data.width] else h00;
                const h01 = if (gz + 1 < data.width) data.heightmap[gx + (gz + 1) * data.width] else h00;
                const h11 = if (gx + 1 < data.width and gz + 1 < data.width) data.heightmap[(gx + 1) + (gz + 1) * data.width] else h00;

                // Use precomputed surface colors for LODs instead of biome tints.
                const c00 = data.colors[gx + gz * data.width];
                const c10 = if (gx + 1 < data.width) data.colors[(gx + 1) + gz * data.width] else c00;
                const c01 = if (gz + 1 < data.width) data.colors[gx + (gz + 1) * data.width] else c00;
                const c11 = if (gx + 1 < data.width and gz + 1 < data.width) data.colors[(gx + 1) + (gz + 1) * data.width] else c00;
                const avg_color = averageColor(c00, c10, c01, c11);
                // Local positions
                const wx: f32 = @floatFromInt(gx * cell_size);
                const wz: f32 = @floatFromInt(gz * cell_size);
                const size: f32 = @floatFromInt(cell_size);

                // Create 2 triangles with proper per-vertex heights
                try addSmoothQuad(self.allocator, &vertices, wx, wz, size, h00, h10, h01, h11, avg_color, avg_color, avg_color, avg_color, Vertex.LOD_TILE_ID);

                // Add skirts at edges
                const skirt_depth: f32 = size * 4.0;
                if (gx == 0) {
                    const avg_h = (h00 + h01) * 0.5;
                    try addSideFaceQuad(self.allocator, &vertices, wx, avg_h, wz, size, avg_h - skirt_depth, unpackR(avg_color) * 0.6, unpackG(avg_color) * 0.6, unpackB(avg_color) * 0.6, .west, Vertex.LOD_TILE_ID);
                }
                if (gx == data.width - 1) {
                    const avg_h = (h10 + h11) * 0.5;
                    try addSideFaceQuad(self.allocator, &vertices, wx, avg_h, wz, size, avg_h - skirt_depth, unpackR(avg_color) * 0.6, unpackG(avg_color) * 0.6, unpackB(avg_color) * 0.6, .east, Vertex.LOD_TILE_ID);
                }
                if (gz == 0) {
                    const avg_h = (h00 + h10) * 0.5;
                    try addSideFaceQuad(self.allocator, &vertices, wx, avg_h, wz, size, avg_h - skirt_depth, unpackR(avg_color) * 0.7, unpackG(avg_color) * 0.7, unpackB(avg_color) * 0.7, .north, Vertex.LOD_TILE_ID);
                }
                if (gz == data.width - 1) {
                    const avg_h = (h01 + h11) * 0.5;
                    try addSideFaceQuad(self.allocator, &vertices, wx, avg_h, wz, size, avg_h - skirt_depth, unpackR(avg_color) * 0.7, unpackG(avg_color) * 0.7, unpackB(avg_color) * 0.7, .south, Vertex.LOD_TILE_ID);
                }
            }
        }

        // Store pending vertices
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_vertices) |p| {
            self.allocator.free(p);
        }

        if (vertices.items.len > 0) {
            self.pending_vertices = try self.allocator.dupe(Vertex, vertices.items);
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
        const full_mesh = buildFullDetailHeightmapMesh(self.allocator, self.lod_level, data, atlas) catch |err| {
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

        if (indices.len == 0) return;

        const expanded = try self.allocator.alloc(Vertex, indices.len);
        for (expanded, 0..) |*dst, i| {
            const idx = indices[i];
            if (idx >= vertices.len) return error.InvalidIndex;
            dst.* = vertices[idx];
        }
        self.pending_vertices = expanded;
    }

    /// Build mesh from full chunk heightmap data
    pub fn buildFromHeightmap(
        self: *LODMesh,
        heightmap: []const f32,
        biomes: []const BiomeId,
        width: u32,
        _: i32,
        _: i32,
        _: *const TextureAtlas,
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
                const color = biome_mod.getBiomeColor(biome);

                const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;

                const wx: f32 = @floatFromInt(gx * cell_size);
                const wz: f32 = @floatFromInt(gz * cell_size);
                const wy: f32 = height;
                const size: f32 = @floatFromInt(cell_size);

                try addTopFaceQuad(self.allocator, &vertices, wx, wy, wz, size, r, g, b, Vertex.LOD_TILE_ID);

                // Add skirts
                const skirt_depth = size * 4.0;
                if (gx == 0) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .west, Vertex.LOD_TILE_ID);
                }
                if (gx == width - 1) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .east, Vertex.LOD_TILE_ID);
                }
                if (gz == 0) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .north, Vertex.LOD_TILE_ID);
                }
                if (gz == width - 1) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .south, Vertex.LOD_TILE_ID);
                }

                // Side faces for height differences
                if (gx > 0) {
                    const nh = heightmap[(gx - 1) + gz * width];
                    if (height > nh + 2) {
                        try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, nh, r * 0.7, g * 0.7, b * 0.7, .west, Vertex.LOD_TILE_ID);
                    }
                }
                if (gz > 0) {
                    const nh = heightmap[gx + (gz - 1) * width];
                    if (height > nh + 2) {
                        try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, nh, r * 0.8, g * 0.8, b * 0.8, .north, Vertex.LOD_TILE_ID);
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
        } else {
            self.pending_vertices = null;
        }
    }

    /// Upload pending vertices to GPU
    pub fn upload(self: *LODMesh, rhi: anytype) RhiError!void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const pending = self.pending_vertices orelse {
            self.ready = self.buffer_handle != 0;
            return;
        };

        if (pending.len == 0) {
            self.vertex_count = 0;
            self.ready = true;
            return;
        }

        const data_size = pending.len * @sizeOf(Vertex);
        const needed_capacity = @max(1024, std.math.ceilPowerOfTwo(usize, data_size) catch data_size);

        // Create or resize buffer
        if (self.buffer_handle == 0 or needed_capacity > self.capacity * @sizeOf(Vertex)) {
            if (self.buffer_handle != 0) {
                rhi.destroyBuffer(self.buffer_handle);
            }
            self.buffer_handle = try rhi.createBuffer(needed_capacity, .vertex);
            self.capacity = @intCast(needed_capacity / @sizeOf(Vertex));
        }

        // Upload data
        try rhi.uploadBuffer(self.buffer_handle, std.mem.sliceAsBytes(pending));
        self.vertex_count = @intCast(pending.len);

        self.allocator.free(pending);
        self.pending_vertices = null;
        self.ready = true;
    }

    /// Draw the LOD mesh
    pub fn draw(self: *const LODMesh, rhi: anytype) void {
        if (!self.ready or self.buffer_handle == 0 or self.vertex_count == 0) return;
        rhi.draw(self.buffer_handle, self.vertex_count, .triangles);
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

fn makeSkirtQuad(params: SkirtParams, tile_id: u16) [4]Vertex {
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
    return switch (p.dir) {
        .north => .{
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z }, col, normal, .{ 0, 0 }, tile_id),
            makeLODVertex(.{ p.x, skirt_bottom, p.z }, col, normal, .{ 1, 0 }, tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z }, col, normal, .{ 1, 1 }, tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z }, col, normal, .{ 0, 1 }, tile_id),
        },
        .south => .{
            makeLODVertex(.{ p.x, skirt_bottom, p.z + p.size }, col, normal, .{ 0, 0 }, tile_id),
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z + p.size }, col, normal, .{ 1, 0 }, tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z + p.size }, col, normal, .{ 1, 1 }, tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z + p.size }, col, normal, .{ 0, 1 }, tile_id),
        },
        .west => .{
            makeLODVertex(.{ p.x, skirt_bottom, p.z }, col, normal, .{ 0, 0 }, tile_id),
            makeLODVertex(.{ p.x, skirt_bottom, p.z + p.size }, col, normal, .{ 1, 0 }, tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z + p.size }, col, normal, .{ 1, 1 }, tile_id),
            makeLODVertex(.{ p.x, p.avg_h, p.z }, col, normal, .{ 0, 1 }, tile_id),
        },
        .east => .{
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z + p.size }, col, normal, .{ 0, 0 }, tile_id),
            makeLODVertex(.{ p.x + p.size, skirt_bottom, p.z }, col, normal, .{ 1, 0 }, tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z }, col, normal, .{ 1, 1 }, tile_id),
            makeLODVertex(.{ p.x + p.size, p.avg_h, p.z + p.size }, col, normal, .{ 0, 1 }, tile_id),
        },
    };
}

fn buildFullDetailHeightmapMesh(
    allocator: std.mem.Allocator,
    lod_level: LODLevel,
    data: *const LODSimplifiedData,
    _: *const TextureAtlas,
) !FullDetailMesh {
    const w = data.width;
    const grid_total = w * w;
    if (grid_total == 0) return error.EmptyData;
    std.debug.assert(w <= data.heightmap.len and w <= data.biomes.len);

    const cell_size: u32 = lod_level.regionSizeBlocks() / w;
    std.debug.assert(cell_size >= 1);

    var vertices = std.ArrayListUnmanaged(Vertex).empty;
    errdefer vertices.deinit(allocator);
    var indices = std.ArrayListUnmanaged(u32).empty;
    errdefer indices.deinit(allocator);

    var gz: u32 = 0;
    while (gz < w) : (gz += 1) {
        var gx: u32 = 0;
        while (gx < w) : (gx += 1) {
            const h00 = data.heightmap[gx + gz * w];
            const h10 = if (gx + 1 < w) data.heightmap[(gx + 1) + gz * w] else h00;
            const h01 = if (gz + 1 < w) data.heightmap[gx + (gz + 1) * w] else h00;
            const h11 = if (gx + 1 < w and gz + 1 < w) data.heightmap[(gx + 1) + (gz + 1) * w] else h00;

            const c00 = data.colors[gx + gz * w];
            const c10 = if (gx + 1 < w) data.colors[(gx + 1) + gz * w] else c00;
            const c01 = if (gz + 1 < w) data.colors[gx + (gz + 1) * w] else c00;
            const c11 = if (gx + 1 < w and gz + 1 < w) data.colors[(gx + 1) + (gz + 1) * w] else c00;
            const wx: f32 = @floatFromInt(gx * cell_size);
            const wz: f32 = @floatFromInt(gz * cell_size);
            const size: f32 = @floatFromInt(cell_size);

            const top_quad = [4]Vertex{
                makeLODVertex(.{ wx, h00, wz }, .{ unpackR(c00), unpackG(c00), unpackB(c00) }, .{ 0, 1, 0 }, .{ 0, 0 }, Vertex.LOD_TILE_ID),
                makeLODVertex(.{ wx + size, h10, wz }, .{ unpackR(c10), unpackG(c10), unpackB(c10) }, .{ 0, 1, 0 }, .{ 1, 0 }, Vertex.LOD_TILE_ID),
                makeLODVertex(.{ wx + size, h11, wz + size }, .{ unpackR(c11), unpackG(c11), unpackB(c11) }, .{ 0, 1, 0 }, .{ 1, 1 }, Vertex.LOD_TILE_ID),
                makeLODVertex(.{ wx, h01, wz + size }, .{ unpackR(c01), unpackG(c01), unpackB(c01) }, .{ 0, 1, 0 }, .{ 0, 1 }, Vertex.LOD_TILE_ID),
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
            }, Vertex.LOD_TILE_ID));
            if (gz == w - 1) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h01 + h11) * 0.5,
                .avg_c = averageColor(c01, c11, c01, c11),
                .brightness = 0.7,
                .dir = .south,
            }, Vertex.LOD_TILE_ID));
            if (gx == 0) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h00 + h01) * 0.5,
                .avg_c = averageColor(c00, c01, c00, c01),
                .brightness = 0.6,
                .dir = .west,
            }, Vertex.LOD_TILE_ID));
            if (gx == w - 1) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h10 + h11) * 0.5,
                .avg_c = averageColor(c10, c11, c10, c11),
                .brightness = 0.6,
                .dir = .east,
            }, Vertex.LOD_TILE_ID));
        }
    }

    return .{
        .vertices = try vertices.toOwnedSlice(allocator),
        .indices = try indices.toOwnedSlice(allocator),
    };
}

const FaceDir = enum { north, south, east, west };

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

fn makeLODVertex(pos: [3]f32, col: [3]f32, norm: [3]f32, uv: [2]f32, tile_id: u16) Vertex {
    return Vertex{
        .pos = pos,
        .color = encodeColor(col),
        .normal = encodeNormal(norm),
        .uv = .{ @floatCast(uv[0]), @floatCast(uv[1]) },
        .packed_meta = encodeMeta(tile_id, 1.0, 1.0),
        .blocklight = 0,
    };
}

/// Add a smooth quad with per-vertex heights and colors
fn addSmoothQuad(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    x: f32,
    z: f32,
    size: f32,
    h00: f32,
    h10: f32,
    h01: f32,
    h11: f32,
    c00: u32,
    c10: u32,
    c01: u32,
    c11: u32,
    tile_id: u16,
) !void {
    const y00 = h00;
    const y10 = h10;
    const y01 = h01;
    const y11 = h11;

    // Calculate normals for each triangle
    // Tri 1: (0,0) -> (1,1) -> (1,0)
    const v1_0 = [3]f32{ size, y11 - y00, size };
    const v1_1 = [3]f32{ size, y10 - y00, 0 };
    var n1 = [3]f32{
        v1_0[1] * v1_1[2] - v1_0[2] * v1_1[1],
        v1_0[2] * v1_1[0] - v1_0[0] * v1_1[2],
        v1_0[0] * v1_1[1] - v1_0[1] * v1_1[0],
    };
    const len1 = @sqrt(n1[0] * n1[0] + n1[1] * n1[1] + n1[2] * n1[2]);
    if (len1 > 0.0001) {
        n1[0] /= len1;
        n1[1] /= len1;
        n1[2] /= len1;
    }

    // Tri 2: (0,0) -> (0,1) -> (1,1)
    const v2_0 = [3]f32{ 0, y01 - y00, size };
    const v2_1 = [3]f32{ size, y11 - y00, size };
    var n2 = [3]f32{
        v2_0[1] * v2_1[2] - v2_0[2] * v2_1[1],
        v2_0[2] * v2_1[0] - v2_0[0] * v2_1[2],
        v2_0[0] * v2_1[1] - v2_0[1] * v2_1[0],
    };
    const len2 = @sqrt(n2[0] * n2[0] + n2[1] * n2[1] + n2[2] * n2[2]);
    if (len2 > 0.0001) {
        n2[0] /= len2;
        n2[1] /= len2;
        n2[2] /= len2;
    }

    // Triangle 1: (0,0), (1,1), (1,0)
    try vertices.append(allocator, makeLODVertex(.{ x, y00, z }, .{ unpackR(c00), unpackG(c00), unpackB(c00) }, n1, .{ 0, 0 }, tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y11, z + size }, .{ unpackR(c11), unpackG(c11), unpackB(c11) }, n1, .{ 1, 1 }, tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y10, z }, .{ unpackR(c10), unpackG(c10), unpackB(c10) }, n1, .{ 1, 0 }, tile_id));

    try vertices.append(allocator, makeLODVertex(.{ x, y00, z }, .{ unpackR(c00), unpackG(c00), unpackB(c00) }, n2, .{ 0, 0 }, tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x, y01, z + size }, .{ unpackR(c01), unpackG(c01), unpackB(c01) }, n2, .{ 0, 1 }, tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y11, z + size }, .{ unpackR(c11), unpackG(c11), unpackB(c11) }, n2, .{ 1, 1 }, tile_id));
}

/// Add a top-facing quad (two triangles)
fn addTopFaceQuad(allocator: std.mem.Allocator, vertices: *std.ArrayListUnmanaged(Vertex), x: f32, y: f32, z: f32, size: f32, r: f32, g: f32, b: f32, tile_id: u16) !void {
    const normal = [3]f32{ 0, 1, 0 };
    const color = [3]f32{ r, g, b };

    try vertices.append(allocator, makeLODVertex(.{ x, y, z }, color, normal, .{ 0, 0 }, tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z + size }, color, normal, .{ 1, 1 }, tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x, y, z + size }, color, normal, .{ 0, 1 }, tile_id));

    try vertices.append(allocator, makeLODVertex(.{ x, y, z }, color, normal, .{ 0, 0 }, tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z + size }, color, normal, .{ 1, 1 }, tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y, z }, color, normal, .{ 1, 0 }, tile_id));
}

/// Add a side-facing quad for cliff faces
fn addSideFaceQuad(allocator: std.mem.Allocator, vertices: *std.ArrayListUnmanaged(Vertex), x: f32, y_top: f32, z: f32, size: f32, y_bottom: f32, r: f32, g: f32, b: f32, dir: FaceDir, tile_id: u16) !void {
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

    try vertices.append(allocator, makeLODVertex(corners[0], color, normal, .{ 0, 0 }, tile_id));
    try vertices.append(allocator, makeLODVertex(corners[1], color, normal, .{ 1, 0 }, tile_id));
    try vertices.append(allocator, makeLODVertex(corners[2], color, normal, .{ 1, 1 }, tile_id));

    try vertices.append(allocator, makeLODVertex(corners[0], color, normal, .{ 0, 0 }, tile_id));
    try vertices.append(allocator, makeLODVertex(corners[2], color, normal, .{ 1, 1 }, tile_id));
    try vertices.append(allocator, makeLODVertex(corners[3], color, normal, .{ 0, 1 }, tile_id));
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
        _: i32,
        _: i32,
        _: *const TextureAtlas,
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

                    const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                    const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                    const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;

                    const wx: f32 = @floatFromInt(offset[0] + @as(i32, @intCast(gx * cell_size)));
                    const wz: f32 = @floatFromInt(offset[1] + @as(i32, @intCast(gz * cell_size)));
                    const wy: f32 = @floatFromInt(height);
                    const size: f32 = @floatFromInt(cell_size);

                    try addTopFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, r, g, b, Vertex.LOD_TILE_ID);

                    // Skirts
                    const skirt_depth = size * 4.0;
                    if (gx == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .west, Vertex.LOD_TILE_ID);
                    if (gx == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .east, Vertex.LOD_TILE_ID);
                    if (gz == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .north, Vertex.LOD_TILE_ID);
                    if (gz == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .south, Vertex.LOD_TILE_ID);
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
        _: i32,
        _: i32,
        _: *const TextureAtlas,
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

                    const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                    const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                    const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;

                    const wx: f32 = @floatFromInt(offset_x + @as(i32, @intCast(gx * cell_size)));
                    const wz: f32 = @floatFromInt(offset_z + @as(i32, @intCast(gz * cell_size)));
                    const wy: f32 = @floatFromInt(height);
                    const size: f32 = @floatFromInt(cell_size);

                    try addTopFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, r, g, b, Vertex.LOD_TILE_ID);

                    // Skirts
                    const skirt_depth = size * 4.0;
                    if (gx == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .west, Vertex.LOD_TILE_ID);
                    if (gx == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .east, Vertex.LOD_TILE_ID);
                    if (gz == 0) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .north, Vertex.LOD_TILE_ID);
                    if (gz == grid_per_chunk - 1) try addSideFaceQuad(mesh.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .south, Vertex.LOD_TILE_ID);
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
test "LODMesh initialization" {
    const allocator = std.testing.allocator;
    var mesh = LODMesh.init(allocator, .lod1);
    const MockRHI = struct {
        pub fn destroyBuffer(_: @This(), _: BufferHandle) void {}
    };
    defer mesh.deinit(MockRHI{});

    try std.testing.expectEqual(LODLevel.lod1, mesh.lod_level);
    try std.testing.expectEqual(@as(u32, 0), mesh.vertex_count);
    try std.testing.expect(!mesh.ready);
}

test "getCellSize" {
    try std.testing.expectEqual(@as(u32, 2), getCellSize(.lod0));
    try std.testing.expectEqual(@as(u32, 2), getCellSize(.lod1));
    try std.testing.expectEqual(@as(u32, 4), getCellSize(.lod2));
    try std.testing.expectEqual(@as(u32, 8), getCellSize(.lod3));
}

test "buildFullDetailHeightmapMesh spans full LOD region" {
    const allocator = std.testing.allocator;

    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);

    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();

    const cell_count: usize = @intCast(data.width * data.width);
    var i: usize = 0;
    while (i < cell_count) : (i += 1) {
        data.heightmap[i] = 0.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .air;
        data.colors[i] = 0;
    }

    const mesh = try buildFullDetailHeightmapMesh(allocator, .lod3, &data, &atlas);
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
}

test "buildFromSimplifiedData marks vertices as LOD" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = @import("chunk.zig").MAX_BLOCK_TYPES;

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
    atlas.tile_mappings[@intFromEnum(BlockType.grass)] = TextureAtlas.BlockTiles.uniform(23);

    var data = try LODSimplifiedData.init(allocator, .lod3);
    defer data.deinit();

    for (0..data.width * data.width) |i| {
        data.heightmap[i] = 64.0;
        data.biomes[i] = .plains;
        data.top_blocks[i] = .grass;
        data.colors[i] = biome_mod.getBiomeColor(.plains);
    }

    var mesh = LODMesh.init(allocator, .lod3);
    const MockRHI = struct {
        pub fn destroyBuffer(_: @This(), _: BufferHandle) void {}
    };
    defer mesh.deinit(MockRHI{});

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);

    for (verts) |v| try std.testing.expectEqual(Vertex.LOD_TILE_ID, @as(u16, @intCast(v.packed_meta & 0xFFFF)));
}

test "buildFromHeightmap marks vertices as LOD" {
    const allocator = std.testing.allocator;
    const MAX_BLOCK_TYPES = @import("chunk.zig").MAX_BLOCK_TYPES;

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

    const width: u32 = 4;
    const count = width * width;
    const heightmap = [_]f32{64.0} ** count;
    const biomes = [_]BiomeId{.plains} ** count;

    var mesh = LODMesh.init(allocator, .lod1);
    const MockRHI = struct {
        pub fn destroyBuffer(_: @This(), _: BufferHandle) void {}
    };
    defer mesh.deinit(MockRHI{});

    try mesh.buildFromHeightmap(&heightmap, &biomes, width, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    try std.testing.expect(verts.len > 0);
    for (verts) |v| try std.testing.expectEqual(@as(u16, Vertex.LOD_TILE_ID), @as(u16, @intCast(v.packed_meta & 0xFFFF)));
}

// ============================================================================
// LOD Transition Seam Handling (Issue #114)
// ============================================================================

/// Edge direction for seam stitching
pub const EdgeDir = enum {
    north, // -Z
    south, // +Z
    east, // +X
    west, // -X
};

/// Seam stitching configuration
pub const SeamConfig = struct {
    /// Enable seam stitching
    enabled: bool = true,
    /// Number of blend cells at the edge
    blend_cells: u32 = 2,
    /// Height interpolation factor (0 = this LOD, 1 = neighbor LOD)
    blend_factor: f32 = 0.5,
};

/// Stitch LOD mesh edge to match neighbor LOD level.
/// This adjusts edge vertices to blend between LOD levels and prevent gaps.
pub fn stitchEdge(
    mesh_heightmap: []f32,
    mesh_width: u32,
    neighbor_heightmap: []const f32,
    neighbor_width: u32,
    edge: EdgeDir,
    this_lod: LODLevel,
    neighbor_lod: LODLevel,
    config: SeamConfig,
) void {
    if (!config.enabled) return;

    const this_scale = this_lod.scale();
    const neighbor_scale = neighbor_lod.scale();

    // Only stitch if neighbor is coarser (higher LOD number)
    if (neighbor_scale <= this_scale) return;

    const scale_ratio = neighbor_scale / this_scale;
    const blend_cells = @min(config.blend_cells, mesh_width / 4);

    switch (edge) {
        .north => {
            // Blend along Z=0 edge
            var x: u32 = 0;
            while (x < mesh_width) : (x += 1) {
                var z: u32 = 0;
                while (z < blend_cells) : (z += 1) {
                    const idx = x + z * mesh_width;
                    if (idx >= mesh_heightmap.len) continue;

                    // Sample neighbor height (lower resolution)
                    const nx = x / scale_ratio;
                    const nz: u32 = 0; // Edge of neighbor
                    const nidx = @min(nx + nz * neighbor_width, neighbor_width * neighbor_width - 1);
                    if (nidx >= neighbor_heightmap.len) continue;

                    const this_h = mesh_heightmap[idx];
                    const neighbor_h = neighbor_heightmap[nidx];

                    // Interpolate based on distance from edge
                    const t = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(blend_cells));
                    const blend = 1.0 - t; // 1.0 at edge, 0.0 at blend distance
                    mesh_heightmap[idx] = this_h * (1.0 - blend * config.blend_factor) +
                        neighbor_h * blend * config.blend_factor;
                }
            }
        },
        .south => {
            var x: u32 = 0;
            while (x < mesh_width) : (x += 1) {
                var z: u32 = 0;
                while (z < blend_cells) : (z += 1) {
                    const actual_z = mesh_width - 1 - z;
                    const idx = x + actual_z * mesh_width;
                    if (idx >= mesh_heightmap.len) continue;

                    const nx = x / scale_ratio;
                    const nz = neighbor_width - 1;
                    const nidx = @min(nx + nz * neighbor_width, neighbor_width * neighbor_width - 1);
                    if (nidx >= neighbor_heightmap.len) continue;

                    const this_h = mesh_heightmap[idx];
                    const neighbor_h = neighbor_heightmap[nidx];

                    const t = @as(f32, @floatFromInt(z)) / @as(f32, @floatFromInt(blend_cells));
                    const blend = 1.0 - t;
                    mesh_heightmap[idx] = this_h * (1.0 - blend * config.blend_factor) +
                        neighbor_h * blend * config.blend_factor;
                }
            }
        },
        .west => {
            var z: u32 = 0;
            while (z < mesh_width) : (z += 1) {
                var x: u32 = 0;
                while (x < blend_cells) : (x += 1) {
                    const idx = x + z * mesh_width;
                    if (idx >= mesh_heightmap.len) continue;

                    const nx: u32 = 0;
                    const nz = z / scale_ratio;
                    const nidx = @min(nx + nz * neighbor_width, neighbor_width * neighbor_width - 1);
                    if (nidx >= neighbor_heightmap.len) continue;

                    const this_h = mesh_heightmap[idx];
                    const neighbor_h = neighbor_heightmap[nidx];

                    const t = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(blend_cells));
                    const blend = 1.0 - t;
                    mesh_heightmap[idx] = this_h * (1.0 - blend * config.blend_factor) +
                        neighbor_h * blend * config.blend_factor;
                }
            }
        },
        .east => {
            var z: u32 = 0;
            while (z < mesh_width) : (z += 1) {
                var x: u32 = 0;
                while (x < blend_cells) : (x += 1) {
                    const actual_x = mesh_width - 1 - x;
                    const idx = actual_x + z * mesh_width;
                    if (idx >= mesh_heightmap.len) continue;

                    const nx = neighbor_width - 1;
                    const nz = z / scale_ratio;
                    const nidx = @min(nx + nz * neighbor_width, neighbor_width * neighbor_width - 1);
                    if (nidx >= neighbor_heightmap.len) continue;

                    const this_h = mesh_heightmap[idx];
                    const neighbor_h = neighbor_heightmap[nidx];

                    const t = @as(f32, @floatFromInt(x)) / @as(f32, @floatFromInt(blend_cells));
                    const blend = 1.0 - t;
                    mesh_heightmap[idx] = this_h * (1.0 - blend * config.blend_factor) +
                        neighbor_h * blend * config.blend_factor;
                }
            }
        },
    }
}

test "stitchEdge basic" {
    var mesh_hm = [_]f32{ 100, 100, 100, 100, 90, 90, 90, 90, 80, 80, 80, 80, 70, 70, 70, 70 };
    const neighbor_hm = [_]f32{ 50, 50, 50, 50 };

    stitchEdge(
        &mesh_hm,
        4,
        &neighbor_hm,
        2,
        .north,
        .lod1,
        .lod2,
        .{ .blend_cells = 2 },
    );

    // First row should be blended toward 50
    try std.testing.expect(mesh_hm[0] < 100);
    // Last row should be unchanged
    try std.testing.expectEqual(@as(f32, 70), mesh_hm[12]);
}
