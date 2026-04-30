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
        destroyBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
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
                return typed.uploadBuffer(handle, data);
            }

            fn destroyBuffer(ptr: *anyopaque, handle: BufferHandle) void {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "resourceManager")) {
                    typed.resourceManager().destroyBuffer(handle);
                    return;
                }
                typed.destroyBuffer(handle);
            }

            const vtable = VTable{
                .createBuffer = @This().createBuffer,
                .uploadBuffer = @This().uploadBuffer,
                .destroyBuffer = @This().destroyBuffer,
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

    pub fn destroyBuffer(self: LODMeshResources, handle: BufferHandle) void {
        self.vtable.destroyBuffer(self.ptr, handle);
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
        .destroyBuffer = struct {
            fn f(ptr: *anyopaque, handle: BufferHandle) void {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                rhi.resourceManager().destroyBuffer(handle);
            }
        }.f,
    };
};

pub const LODMeshRenderContext = struct {
    ptr: *anyopaque,
    draw_fn: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: rhi_types.DrawMode) void,

    pub fn draw(self: LODMeshRenderContext, handle: BufferHandle, count: u32, mode: rhi_types.DrawMode) void {
        self.draw_fn(self.ptr, handle, count, mode);
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

    pub fn deinit(self: *LODMesh, resources: LODMeshResources) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.buffer_handle != 0) {
            resources.destroyBuffer(self.buffer_handle);
            self.buffer_handle = 0;
        }
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
    /// Build mesh from simplified LOD data (heightmap-based)
    pub fn buildFromSimplifiedData(self: *LODMesh, data: *const LODSimplifiedData, world_x: i32, world_z: i32, atlas: *const TextureAtlas) !void {
        if (data.width < 2) return error.EmptyData;

        const region_size: f32 = @floatFromInt(lod_chunk.regionSizeBlocks(self.lod_level));
        const cell_size = region_size / @as(f32, @floatFromInt(data.width - 1));

        var vertices = std.ArrayListUnmanaged(Vertex).empty;
        defer vertices.deinit(self.allocator);

        var gz: u32 = 0;
        while (gz + 1 < data.width) : (gz += 1) {
            var gx: u32 = 0;
            while (gx + 1 < data.width) : (gx += 1) {
                const h00 = data.heightmap[gx + gz * data.width];
                const h10 = data.heightmap[(gx + 1) + gz * data.width];
                const h01 = data.heightmap[gx + (gz + 1) * data.width];
                const h11 = data.heightmap[(gx + 1) + (gz + 1) * data.width];

                const c00 = data.colors[gx + gz * data.width];
                const c10 = data.colors[(gx + 1) + gz * data.width];
                const c01 = data.colors[gx + (gz + 1) * data.width];
                const c11 = data.colors[(gx + 1) + (gz + 1) * data.width];
                const avg_color = averageColor(c00, c10, c01, c11);
                const lit_avg_color = applyColorBrightness(avg_color, averageAmbientOcclusion(data, gx, gz));
                const wx = @as(f32, @floatFromInt(gx)) * cell_size;
                const wz = @as(f32, @floatFromInt(gz)) * cell_size;
                const size = cell_size;

                const material = selectCellMaterial(data, atlas, gx, gz, self.lod_level);
                const top_tile = material.top;
                const side_tile = material.side;
                const top_block = blockForLODQuad(data, gx, gz);
                const top_color = getLodTopColor(top_block, top_tile, lit_avg_color);

                try addSmoothQuad(self.allocator, &vertices, wx, wz, size, h00, h10, h01, h11, top_color, top_color, top_color, top_color, top_tile, world_x, world_z);

                const skirt_depth: f32 = size * 4.0;
                if (gx == 0) try addSideFaceQuad(self.allocator, &vertices, wx, (h00 + h01) * 0.5, wz, size, (h00 + h01) * 0.5 - skirt_depth, unpackR(lit_avg_color) * 0.6, unpackG(lit_avg_color) * 0.6, unpackB(lit_avg_color) * 0.6, .west, side_tile, world_x, world_z);
                if (gx == data.width - 2) try addSideFaceQuad(self.allocator, &vertices, wx, (h10 + h11) * 0.5, wz, size, (h10 + h11) * 0.5 - skirt_depth, unpackR(lit_avg_color) * 0.6, unpackG(lit_avg_color) * 0.6, unpackB(lit_avg_color) * 0.6, .east, side_tile, world_x, world_z);
                if (gz == 0) try addSideFaceQuad(self.allocator, &vertices, wx, (h00 + h10) * 0.5, wz, size, (h00 + h10) * 0.5 - skirt_depth, unpackR(lit_avg_color) * 0.7, unpackG(lit_avg_color) * 0.7, unpackB(lit_avg_color) * 0.7, .north, side_tile, world_x, world_z);
                if (gz == data.width - 2) try addSideFaceQuad(self.allocator, &vertices, wx, (h01 + h11) * 0.5, wz, size, (h01 + h11) * 0.5 - skirt_depth, unpackR(lit_avg_color) * 0.7, unpackG(lit_avg_color) * 0.7, unpackB(lit_avg_color) * 0.7, .south, side_tile, world_x, world_z);

                try addHeightDeltaFaces(self.allocator, &vertices, data, gx, gz, wx, wz, size, h00, h10, h01, h11, lit_avg_color, side_tile, world_x, world_z);
                if (shouldRenderLODTree(self.lod_level, top_block)) {
                    const vegetation = representativeVegetation(data, gx, gz);
                    if (vegetation.tree_coverage >= 0.08) {
                        try addTreeImpostor(self.allocator, &vertices, wx + size * 0.5 + vegetation.offset_x, wz + size * 0.5 + vegetation.offset_z, size, (h00 + h10 + h01 + h11) * 0.25, vegetation, atlas, world_x, world_z);
                    }
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
                const color = biome_mod.getBiomeColor(biome);

                const r: f32 = @as(f32, @floatFromInt((color >> 16) & 0xFF)) / 255.0;
                const g: f32 = @as(f32, @floatFromInt((color >> 8) & 0xFF)) / 255.0;
                const b: f32 = @as(f32, @floatFromInt(color & 0xFF)) / 255.0;

                const wx: f32 = @floatFromInt(gx * cell_size);
                const wz: f32 = @floatFromInt(gz * cell_size);
                const wy: f32 = height;
                const size: f32 = @floatFromInt(cell_size);

                const tiles = atlas.getTilesForBlock(@intFromEnum(biome.getSurfaceBlock()));

                try addTopFaceQuad(self.allocator, &vertices, wx, wy, wz, size, r, g, b, tiles.top, world_x, world_z);

                // Add skirts
                const skirt_depth = size * 4.0;
                if (gx == 0) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .west, tiles.side, world_x, world_z);
                }
                if (gx == width - 1) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.6, g * 0.6, b * 0.6, .east, tiles.side, world_x, world_z);
                }
                if (gz == 0) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .north, tiles.side, world_x, world_z);
                }
                if (gz == width - 1) {
                    try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, wy - skirt_depth, r * 0.7, g * 0.7, b * 0.7, .south, tiles.side, world_x, world_z);
                }

                // Side faces for height differences
                if (gx > 0) {
                    const nh = heightmap[(gx - 1) + gz * width];
                    if (height > nh + 2) {
                        try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, nh, r * 0.7, g * 0.7, b * 0.7, .west, tiles.side, world_x, world_z);
                    }
                }
                if (gz > 0) {
                    const nh = heightmap[gx + (gz - 1) * width];
                    if (height > nh + 2) {
                        try addSideFaceQuad(self.allocator, &vertices, wx, wy, wz, size, nh, r * 0.8, g * 0.8, b * 0.8, .north, tiles.side, world_x, world_z);
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
    pub fn upload(self: *LODMesh, resources: LODMeshResources) RhiError!void {
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
                resources.destroyBuffer(self.buffer_handle);
            }
            self.buffer_handle = try resources.createBuffer(needed_capacity, .vertex);
            self.capacity = @intCast(needed_capacity / @sizeOf(Vertex));
        }

        // Upload data
        try resources.uploadBuffer(self.buffer_handle, std.mem.sliceAsBytes(pending));
        self.vertex_count = @intCast(pending.len);

        self.allocator.free(pending);
        self.pending_vertices = null;
        self.ready = true;
    }

    /// Draw the LOD mesh
    pub fn draw(self: *const LODMesh, render_ctx: LODMeshRenderContext) void {
        if (!self.ready or self.buffer_handle == 0 or self.vertex_count == 0) return;
        render_ctx.draw(self.buffer_handle, self.vertex_count, .triangles);
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
    std.debug.assert(w <= data.heightmap.len and w <= data.biomes.len);

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
            const material = selectCellMaterial(data, atlas, gx, gz, lod_level);

            const top_block = blockForLODQuad(data, gx, gz);
            const top_tile_id = getLodTopTile(top_block, atlas, lod_level);
            const tc00 = getLodTopColor(top_block, top_tile_id, applyColorBrightness(c00, data.lighting[gx + gz * w].ambient_occlusion));
            const tc10 = getLodTopColor(top_block, top_tile_id, applyColorBrightness(c10, data.lighting[(gx + 1) + gz * w].ambient_occlusion));
            const tc01 = getLodTopColor(top_block, top_tile_id, applyColorBrightness(c01, data.lighting[gx + (gz + 1) * w].ambient_occlusion));
            const tc11 = getLodTopColor(top_block, top_tile_id, applyColorBrightness(c11, data.lighting[(gx + 1) + (gz + 1) * w].ambient_occlusion));
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
                .brightness = 0.6,
                .dir = .west,
            }, material.side, world_x, world_z));
            if (gx == w - 2) try appendIndexedQuad(&vertices, &indices, allocator, &makeSkirtQuad(.{
                .x = wx,
                .z = wz,
                .size = size,
                .avg_h = (h10 + h11) * 0.5,
                .avg_c = averageColor(c10, c11, c10, c11),
                .brightness = 0.6,
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
    if (averageWaterCoverage(data, gx, gz) >= 0.25) return .water;
    return blockForLODCell(data, gx, gz);
}

fn selectCellMaterial(data: *const LODSimplifiedData, atlas: *const TextureAtlas, gx: u32, gz: u32, lod_level: LODLevel) TextureAtlas.BlockTiles {
    const top_block = blockForLODQuad(data, gx, gz);
    const side_block = sideBlockForLODQuad(data, gx, gz, top_block);
    const top_tiles = atlas.getTilesForBlock(@intFromEnum(top_block));
    const side_tiles = atlas.getTilesForBlock(@intFromEnum(side_block));
    return .{
        .top = getLodTopTile(top_block, atlas, lod_level),
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

fn shouldRenderLODTree(lod_level: LODLevel, top_block: BlockType) bool {
    if (@intFromEnum(lod_level) < @intFromEnum(LODLevel.lod2)) return false;
    return top_block != .water and top_block != .air;
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

    var coverage_sum: f32 = 0.0;
    var height_sum: f32 = 0.0;
    var height_count: u32 = 0;
    var best = world_core.LODVegetationHint.empty;
    for (indices) |idx| {
        const hint = data.vegetation[idx];
        coverage_sum += hint.tree_coverage;
        if (hint.avg_tree_height > 0.0) {
            height_sum += hint.avg_tree_height;
            height_count += 1;
        }
        if (hint.tree_coverage > best.tree_coverage) best = hint;
    }

    best.tree_coverage = coverage_sum * 0.25;
    best.avg_tree_height = if (height_count == 0) 0.0 else height_sum / @as(f32, @floatFromInt(height_count));
    return best;
}

fn averageWaterCoverage(data: *const LODSimplifiedData, gx: u32, gz: u32) f32 {
    if (data.width == 0) return 0.0;
    const x0 = @min(gx, data.width - 1);
    const z0 = @min(gz, data.width - 1);
    const x1 = @min(gx + 1, data.width - 1);
    const z1 = @min(gz + 1, data.width - 1);
    const c00 = data.water[x0 + z0 * data.width].coverage;
    const c10 = data.water[x1 + z0 * data.width].coverage;
    const c01 = data.water[x0 + z1 * data.width].coverage;
    const c11 = data.water[x1 + z1 * data.width].coverage;
    return (c00 + c10 + c01 + c11) * 0.25;
}

fn addHeightDeltaFaces(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    data: *const LODSimplifiedData,
    gx: u32,
    gz: u32,
    wx: f32,
    wz: f32,
    size: f32,
    h00: f32,
    h10: f32,
    h01: f32,
    h11: f32,
    color: u32,
    side_tile: u16,
    world_x: i32,
    world_z: i32,
) !void {
    const threshold = @max(2.0, size * 0.12);
    const west_edge = (h00 + h01) * 0.5;
    const east_edge = (h10 + h11) * 0.5;
    const north_edge = (h00 + h10) * 0.5;
    const south_edge = (h01 + h11) * 0.5;
    const r = unpackR(color);
    const g = unpackG(color);
    const b = unpackB(color);

    if (gx > 0) {
        const neighbor_edge = (data.getHeight(gx - 1, gz) + data.getHeight(gx - 1, gz + 1)) * 0.5;
        if (west_edge > neighbor_edge + threshold) {
            try addSideFaceQuad(allocator, vertices, wx, west_edge, wz, size, neighbor_edge, r * 0.6, g * 0.6, b * 0.6, .west, side_tile, world_x, world_z);
        }
    }
    if (gx + 2 < data.width) {
        const neighbor_edge = (data.getHeight(gx + 2, gz) + data.getHeight(gx + 2, gz + 1)) * 0.5;
        if (east_edge > neighbor_edge + threshold) {
            try addSideFaceQuad(allocator, vertices, wx, east_edge, wz, size, neighbor_edge, r * 0.6, g * 0.6, b * 0.6, .east, side_tile, world_x, world_z);
        }
    }
    if (gz > 0) {
        const neighbor_edge = (data.getHeight(gx, gz - 1) + data.getHeight(gx + 1, gz - 1)) * 0.5;
        if (north_edge > neighbor_edge + threshold) {
            try addSideFaceQuad(allocator, vertices, wx, north_edge, wz, size, neighbor_edge, r * 0.7, g * 0.7, b * 0.7, .north, side_tile, world_x, world_z);
        }
    }
    if (gz + 2 < data.width) {
        const neighbor_edge = (data.getHeight(gx, gz + 2) + data.getHeight(gx + 1, gz + 2)) * 0.5;
        if (south_edge > neighbor_edge + threshold) {
            try addSideFaceQuad(allocator, vertices, wx, south_edge, wz, size, neighbor_edge, r * 0.7, g * 0.7, b * 0.7, .south, side_tile, world_x, world_z);
        }
    }
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

fn packBlockDefaultColor(block: BlockType, fallback: u32) u32 {
    if (block == .air) return fallback;
    const color = world_core.block_registry.getBlockDefinition(block).default_color;
    const r: u32 = @intFromFloat(@round(std.math.clamp(color[0], 0.0, 1.0) * 255.0));
    const g: u32 = @intFromFloat(@round(std.math.clamp(color[1], 0.0, 1.0) * 255.0));
    const b: u32 = @intFromFloat(@round(std.math.clamp(color[2], 0.0, 1.0) * 255.0));
    return (r << 16) | (g << 8) | b;
}

fn getLodTopTile(block: BlockType, atlas: *const TextureAtlas, lod_level: LODLevel) u16 {
    _ = lod_level;
    if (block == .air) return Vertex.LOD_TILE_ID;

    const tiles = atlas.getTilesForBlock(@intFromEnum(block));
    if (tiles.top == 0) return Vertex.LOD_TILE_ID;
    return tiles.top;
}

fn getLodTopColor(block: BlockType, tile_id: u16, fallback_color: u32) u32 {
    if (tile_id == Vertex.LOD_TILE_ID) return fallback_color;

    return switch (block) {
        .grass,
        .water,
        .leaves,
        .mangrove_leaves,
        .jungle_leaves,
        .acacia_leaves,
        .birch_leaves,
        .spruce_leaves,
        => fallback_color,
        else => 0xFFFFFF,
    };
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
    world_x: i32,
    world_z: i32,
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
    try vertices.append(allocator, makeLODVertex(.{ x, y00, z }, .{ unpackR(c00), unpackG(c00), unpackB(c00) }, n1, topFaceUV(.{ x, y00, z }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y11, z + size }, .{ unpackR(c11), unpackG(c11), unpackB(c11) }, n1, topFaceUV(.{ x + size, y11, z + size }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y10, z }, .{ unpackR(c10), unpackG(c10), unpackB(c10) }, n1, topFaceUV(.{ x + size, y10, z }, world_x, world_z), tile_id));

    try vertices.append(allocator, makeLODVertex(.{ x, y00, z }, .{ unpackR(c00), unpackG(c00), unpackB(c00) }, n2, topFaceUV(.{ x, y00, z }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x, y01, z + size }, .{ unpackR(c01), unpackG(c01), unpackB(c01) }, n2, topFaceUV(.{ x, y01, z + size }, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(.{ x + size, y11, z + size }, .{ unpackR(c11), unpackG(c11), unpackB(c11) }, n2, topFaceUV(.{ x + size, y11, z + size }, world_x, world_z), tile_id));
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

fn addTreeImpostor(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    center_x: f32,
    center_z: f32,
    cell_size: f32,
    base_height: f32,
    vegetation: world_core.LODVegetationHint,
    atlas: *const TextureAtlas,
    world_x: i32,
    world_z: i32,
) !void {
    if (vegetation.leaves == .air) return;

    const leaf_tiles = atlas.getTilesForBlock(@intFromEnum(vegetation.leaves));
    const trunk_tiles = atlas.getTilesForBlock(@intFromEnum(vegetation.trunk));
    const leaf_tile = if (leaf_tiles.top == 0) Vertex.LOD_TILE_ID else leaf_tiles.top;
    const trunk_tile = if (trunk_tiles.side == 0) Vertex.LOD_TILE_ID else trunk_tiles.side;
    const leaf_color: u32 = packBlockDefaultColor(vegetation.leaves, 0x2F7D2A);
    const trunk_color: u32 = if (trunk_tile == Vertex.LOD_TILE_ID) packBlockDefaultColor(vegetation.trunk, 0x6B4A2B) else 0xFFFFFF;
    const canopy_height = @max(4.0, vegetation.avg_tree_height);
    const canopy_width = @max(3.0, cell_size * (0.35 + vegetation.tree_coverage * 0.3));
    const trunk_height = canopy_height * 0.55;
    const trunk_width = @max(0.75, canopy_width * 0.16);

    try addVerticalCrossQuad(allocator, vertices, center_x, center_z, trunk_width, base_height, trunk_height, trunk_color, trunk_tile, world_x, world_z);
    try addVerticalCrossQuad(allocator, vertices, center_x, center_z, canopy_width, base_height + trunk_height * 0.45, canopy_height, leaf_color, leaf_tile, world_x, world_z);
}

fn addVerticalCrossQuad(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    center_x: f32,
    center_z: f32,
    width: f32,
    y_bottom: f32,
    height: f32,
    color: u32,
    tile_id: u16,
    world_x: i32,
    world_z: i32,
) !void {
    const half = width * 0.5;
    const y_top = y_bottom + height;
    try addVerticalBillboardQuad(allocator, vertices, .{ center_x - half, y_bottom, center_z }, .{ center_x + half, y_bottom, center_z }, y_top, color, tile_id, world_x, world_z);
    try addVerticalBillboardQuad(allocator, vertices, .{ center_x, y_bottom, center_z - half }, .{ center_x, y_bottom, center_z + half }, y_top, color, tile_id, world_x, world_z);
}

fn addVerticalBillboardQuad(
    allocator: std.mem.Allocator,
    vertices: *std.ArrayListUnmanaged(Vertex),
    bottom_a: [3]f32,
    bottom_b: [3]f32,
    y_top: f32,
    color: u32,
    tile_id: u16,
    world_x: i32,
    world_z: i32,
) !void {
    const top_a = [3]f32{ bottom_a[0], y_top, bottom_a[2] };
    const top_b = [3]f32{ bottom_b[0], y_top, bottom_b[2] };
    const col = [3]f32{ unpackR(color), unpackG(color), unpackB(color) };
    const normal = [3]f32{ 0, 0, 1 };

    try vertices.append(allocator, makeLODVertex(bottom_a, col, normal, sideFaceUV(bottom_a, .north, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(bottom_b, col, normal, sideFaceUV(bottom_b, .north, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(top_b, col, normal, sideFaceUV(top_b, .north, world_x, world_z), tile_id));

    try vertices.append(allocator, makeLODVertex(bottom_a, col, normal, sideFaceUV(bottom_a, .north, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(top_b, col, normal, sideFaceUV(top_b, .north, world_x, world_z), tile_id));
    try vertices.append(allocator, makeLODVertex(top_a, col, normal, sideFaceUV(top_a, .north, world_x, world_z), tile_id));
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
        fn destroyBuffer(_: *anyopaque, _: BufferHandle) void {}

        const vtable = LODMeshResources.VTable{
            .createBuffer = createBuffer,
            .uploadBuffer = uploadBuffer,
            .destroyBuffer = destroyBuffer,
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
    try std.testing.expectEqual(@as(u32, 2), getCellSize(.lod0));
    try std.testing.expectEqual(@as(u32, 2), getCellSize(.lod1));
    try std.testing.expectEqual(@as(u32, 4), getCellSize(.lod2));
    try std.testing.expectEqual(@as(u32, 8), getCellSize(.lod3));
}

test "buildFullDetailHeightmapMesh spans full LOD region" {
    const allocator = std.testing.allocator;

    var atlas: TextureAtlas = undefined;
    @memset(std.mem.asBytes(&atlas.tile_mappings), 0);

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

fn vertexTileId(v: Vertex) u16 {
    return @intCast(v.packed_meta & 0xFFFF);
}

fn vertexRgb(v: Vertex) u32 {
    return v.color & 0x00FFFFFF;
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

test "buildFromSimplifiedData uses white tint for textured non-biome tops" {
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
            try std.testing.expectEqual(@as(u32, 0xFFFFFF), vertexRgb(v));
        }
    }
    try std.testing.expect(top_tile_count > 0);
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
    try std.testing.expectEqual(@as(u16, 41), vertexTileId(verts[0]));

    var found_floor_side = false;
    for (verts) |v| {
        if (vertexTileId(v) == 55) {
            found_floor_side = true;
            break;
        }
    }
    try std.testing.expect(found_floor_side);
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
    try std.testing.expectEqual(@as(u32, 0x3A7D42), vertexRgb(verts[0]));
}

test "buildFromSimplifiedData renders tree impostors from vegetation hints" {
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

    var data = try LODSimplifiedData.init(allocator, .lod2);
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

    var mesh = LODMesh.init(allocator, .lod2);
    defer mesh.deinit(testResources());

    try mesh.buildFromSimplifiedData(&data, 0, 0, &atlas);

    const verts = mesh.pending_vertices orelse return error.TestExpectedEqual;
    var found_leaf_impostor = false;
    for (verts) |v| {
        if (vertexTileId(v) == 70 and v.pos[1] > 64.0) {
            found_leaf_impostor = true;
            break;
        }
    }
    try std.testing.expect(found_leaf_impostor);
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
