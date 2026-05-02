//! Chunk mesh orchestrator — coordinates meshing stages and manages GPU lifecycle.
//!
//! Vertices are built per-subchunk via the greedy mesher, then merged into
//! single solid/cutout/fluid buffers for minimal draw calls. Meshing logic is
//! delegated to modules in `meshing/`.

const std = @import("std");
const sync = @import("sync");
const log = @import("engine-core").log;

const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const MAX_BLOCK_TYPES = world_core.MAX_BLOCK_TYPES;
const BlockType = world_core.BlockType;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const rhi_mod = @import("engine-rhi");
const RenderContext = rhi_mod.RenderContext;
const Vertex = rhi_mod.Vertex;
const chunk_alloc_mod = @import("chunk_allocator.zig");
const GlobalVertexAllocator = chunk_alloc_mod.GlobalVertexAllocator;
const VertexAllocation = chunk_alloc_mod.VertexAllocation;

// Meshing stage modules
const greedy_mesher = @import("meshing/greedy_mesher.zig");
const cross_mesher = @import("meshing/cross_mesher.zig");
const flat_quad_mesher = @import("meshing/flat_quad_mesher.zig");
const tall_cross_mesher = @import("meshing/tall_cross_mesher.zig");
const wall_attached_mesher = @import("meshing/wall_attached_mesher.zig");
const custom_mesh_mesher = @import("meshing/custom_mesh_mesher.zig");
const boundary = @import("meshing/boundary.zig");

// Re-export public types for external consumers
pub const NeighborChunks = boundary.NeighborChunks;
pub const SUBCHUNK_SIZE = boundary.SUBCHUNK_SIZE;
pub const NUM_SUBCHUNKS = boundary.NUM_SUBCHUNKS;

pub const Pass = enum {
    solid,
    cutout,
    fluid,
};

/// Merged chunk mesh with single solid/cutout/fluid buffers for minimal draw calls.
/// Subchunk data is only used during mesh building, then merged.
pub const ChunkMesh = struct {
    // Merged GPU allocations from GlobalVertexAllocator
    solid_allocation: ?VertexAllocation = null,
    cutout_allocation: ?VertexAllocation = null,
    fluid_allocation: ?VertexAllocation = null,

    ready: bool = false,

    allocator: std.mem.Allocator,
    mutex: sync.Mutex,

    // Pending merged vertex data (built on worker thread, uploaded on main thread)
    pending_solid: ?[]Vertex = null,
    pending_cutout: ?[]Vertex = null,
    pending_fluid: ?[]Vertex = null,

    // Temporary per-subchunk data during building (not stored after merge)
    subchunk_solid: [NUM_SUBCHUNKS]?[]Vertex = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,
    subchunk_cutout: [NUM_SUBCHUNKS]?[]Vertex = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,
    subchunk_fluid: [NUM_SUBCHUNKS]?[]Vertex = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,

    // Diagnostic: count of vertices with tile_id == 0 (white)
    diag_tile0_count: u32 = 0,
    diag_total_verts: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) ChunkMesh {
        return .{
            .allocator = allocator,
            .mutex = .{},
        };
    }

    // Must be called on main thread
    pub fn deinit(self: *ChunkMesh, allocator: *GlobalVertexAllocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.solid_allocation) |alloc| allocator.free(alloc);
        if (self.cutout_allocation) |alloc| allocator.free(alloc);
        if (self.fluid_allocation) |alloc| allocator.free(alloc);
        self.solid_allocation = null;
        self.cutout_allocation = null;
        self.fluid_allocation = null;

        if (self.pending_solid) |p| self.allocator.free(p);
        if (self.pending_cutout) |p| self.allocator.free(p);
        if (self.pending_fluid) |p| self.allocator.free(p);

        for (0..NUM_SUBCHUNKS) |i| {
            if (self.subchunk_solid[i]) |p| self.allocator.free(p);
            if (self.subchunk_cutout[i]) |p| self.allocator.free(p);
            if (self.subchunk_fluid[i]) |p| self.allocator.free(p);
        }
    }

    pub fn deinitWithoutRHI(self: *ChunkMesh) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.pending_solid) |p| self.allocator.free(p);
        if (self.pending_cutout) |p| self.allocator.free(p);
        if (self.pending_fluid) |p| self.allocator.free(p);

        for (0..NUM_SUBCHUNKS) |i| {
            if (self.subchunk_solid[i]) |p| self.allocator.free(p);
            if (self.subchunk_cutout[i]) |p| self.allocator.free(p);
            if (self.subchunk_fluid[i]) |p| self.allocator.free(p);
        }
    }

    /// Build the full chunk mesh from chunk data and neighbors.
    /// Delegates greedy meshing to the meshing stage modules.
    pub fn buildWithNeighbors(self: *ChunkMesh, chunk: *const Chunk, neighbors: NeighborChunks, atlas: *const TextureAtlas) !void {
        // Build each subchunk separately (greedy meshing works per Y slice)
        for (0..NUM_SUBCHUNKS) |i| {
            try self.buildSubchunk(chunk, neighbors, @intCast(i), atlas);
        }

        // Merge all subchunk vertices into single buffers
        try self.mergeSubchunks();
    }

    fn buildSubchunk(self: *ChunkMesh, chunk: *const Chunk, neighbors: NeighborChunks, si: u32, atlas: *const TextureAtlas) !void {
        var solid_verts = std.ArrayListUnmanaged(Vertex).empty;
        defer solid_verts.deinit(self.allocator);
        var cutout_verts = std.ArrayListUnmanaged(Vertex).empty;
        defer cutout_verts.deinit(self.allocator);
        var fluid_verts = std.ArrayListUnmanaged(Vertex).empty;
        defer fluid_verts.deinit(self.allocator);

        const y0: i32 = @intCast(si * SUBCHUNK_SIZE);
        const y1: i32 = y0 + SUBCHUNK_SIZE;

        // Mesh horizontal slices (top/bottom faces)
        var sy: i32 = y0;
        while (sy <= y1) : (sy += 1) {
            try greedy_mesher.meshSlice(self.allocator, chunk, neighbors, .top, sy, si, &solid_verts, &cutout_verts, &fluid_verts, atlas);
        }
        // Mesh east/west face slices
        var sx: i32 = 0;
        while (sx <= CHUNK_SIZE_X) : (sx += 1) {
            try greedy_mesher.meshSlice(self.allocator, chunk, neighbors, .east, sx, si, &solid_verts, &cutout_verts, &fluid_verts, atlas);
        }
        // Mesh south/north face slices
        var sz: i32 = 0;
        while (sz <= CHUNK_SIZE_Z) : (sz += 1) {
            try greedy_mesher.meshSlice(self.allocator, chunk, neighbors, .south, sz, si, &solid_verts, &cutout_verts, &fluid_verts, atlas);
        }

        // Mesh non-cube shapes (plants, attached quads, and custom solid geometry)
        try cross_mesher.meshCrossBlocks(self.allocator, chunk, neighbors, si, &cutout_verts, atlas);
        try flat_quad_mesher.meshFlatQuadBlocks(self.allocator, chunk, neighbors, si, &cutout_verts, atlas);
        try tall_cross_mesher.meshTallCrossBlocks(self.allocator, chunk, neighbors, si, &cutout_verts, atlas);
        try wall_attached_mesher.meshWallAttachedBlocks(self.allocator, chunk, neighbors, si, &cutout_verts, atlas);
        try custom_mesh_mesher.meshCustomMeshBlocks(self.allocator, chunk, neighbors, si, &solid_verts, atlas);

        // Store subchunk data temporarily (will be merged later)
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.subchunk_solid[si]) |p| self.allocator.free(p);
        if (self.subchunk_cutout[si]) |p| self.allocator.free(p);
        if (self.subchunk_fluid[si]) |p| self.allocator.free(p);

        self.subchunk_solid[si] = if (solid_verts.items.len > 0)
            try self.allocator.dupe(Vertex, solid_verts.items)
        else
            null;
        self.subchunk_cutout[si] = if (cutout_verts.items.len > 0)
            try self.allocator.dupe(Vertex, cutout_verts.items)
        else
            null;
        self.subchunk_fluid[si] = if (fluid_verts.items.len > 0)
            try self.allocator.dupe(Vertex, fluid_verts.items)
        else
            null;
    }

    /// Merge all subchunk vertices into single solid/fluid arrays.
    /// Called after all subchunks are built.
    fn mergeSubchunks(self: *ChunkMesh) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Count total vertices
        var total_solid: usize = 0;
        var total_cutout: usize = 0;
        var total_fluid: usize = 0;
        for (0..NUM_SUBCHUNKS) |i| {
            if (self.subchunk_solid[i]) |v| total_solid += v.len;
            if (self.subchunk_cutout[i]) |v| total_cutout += v.len;
            if (self.subchunk_fluid[i]) |v| total_fluid += v.len;
        }

        // Free old pending data
        if (self.pending_solid) |p| self.allocator.free(p);
        if (self.pending_cutout) |p| self.allocator.free(p);
        if (self.pending_fluid) |p| self.allocator.free(p);

        // Merge solid vertices
        if (total_solid > 0) {
            var merged = try self.allocator.alloc(Vertex, total_solid);
            var offset: usize = 0;
            for (0..NUM_SUBCHUNKS) |i| {
                if (self.subchunk_solid[i]) |v_slice| {
                    @memcpy(merged[offset..][0..v_slice.len], v_slice);
                    offset += v_slice.len;
                    self.allocator.free(v_slice);
                    self.subchunk_solid[i] = null;
                }
            }
            self.pending_solid = merged;
        } else {
            self.pending_solid = null;
        }

        // Merge cutout vertices
        if (total_cutout > 0) {
            var merged = try self.allocator.alloc(Vertex, total_cutout);
            var offset: usize = 0;
            for (0..NUM_SUBCHUNKS) |i| {
                if (self.subchunk_cutout[i]) |v_slice| {
                    @memcpy(merged[offset..][0..v_slice.len], v_slice);
                    offset += v_slice.len;
                    self.allocator.free(v_slice);
                    self.subchunk_cutout[i] = null;
                }
            }
            self.pending_cutout = merged;
        } else {
            self.pending_cutout = null;
        }

        // Merge fluid vertices
        if (total_fluid > 0) {
            var merged = try self.allocator.alloc(Vertex, total_fluid);
            var offset: usize = 0;
            for (0..NUM_SUBCHUNKS) |i| {
                if (self.subchunk_fluid[i]) |v_slice| {
                    @memcpy(merged[offset..][0..v_slice.len], v_slice);
                    offset += v_slice.len;
                    self.allocator.free(v_slice);
                    self.subchunk_fluid[i] = null;
                }
            }
            self.pending_fluid = merged;
        } else {
            self.pending_fluid = null;
        }

        var tile0: u32 = 0;
        var total: u32 = 0;
        for ([_]?[]Vertex{ self.pending_solid, self.pending_cutout, self.pending_fluid }) |opt| {
            if (opt) |verts| {
                total += @intCast(verts.len);
                for (verts) |v| {
                    const tid: u16 = @intCast(v.packed_meta & 0xFFFF);
                    if (tid == 0 and tid != Vertex.LOD_TILE_ID) tile0 += 1;
                }
            }
        }
        self.diag_tile0_count = tile0;
        self.diag_total_verts = total;
    }

    pub fn upload(self: *ChunkMesh, allocator: *GlobalVertexAllocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old_solid = self.solid_allocation;
        const old_cutout = self.cutout_allocation;
        const old_fluid = self.fluid_allocation;
        const had_old_allocations = old_solid != null or old_cutout != null or old_fluid != null;

        var new_solid: ?VertexAllocation = null;
        var new_cutout: ?VertexAllocation = null;
        var new_fluid: ?VertexAllocation = null;
        var alloc_ok = true;

        if (self.pending_solid) |v| {
            if (v.len > 0) blk: {
                new_solid = allocator.allocate(v) catch {
                    alloc_ok = false;
                    break :blk;
                };
            }
        }

        if (alloc_ok) {
            if (self.pending_cutout) |v| {
                if (v.len > 0) blk: {
                    new_cutout = allocator.allocate(v) catch {
                        alloc_ok = false;
                        break :blk;
                    };
                }
            }
        }

        if (alloc_ok) {
            if (self.pending_fluid) |v| {
                if (v.len > 0) blk: {
                    new_fluid = allocator.allocate(v) catch {
                        alloc_ok = false;
                        break :blk;
                    };
                }
            }
        }

        if (alloc_ok) {
            if (self.pending_solid) |v| self.allocator.free(v);
            if (self.pending_cutout) |v| self.allocator.free(v);
            if (self.pending_fluid) |v| self.allocator.free(v);
            self.pending_solid = null;
            self.pending_cutout = null;
            self.pending_fluid = null;

            if (old_solid) |a| allocator.free(a);
            if (old_cutout) |a| allocator.free(a);
            if (old_fluid) |a| allocator.free(a);
            self.solid_allocation = new_solid;
            self.cutout_allocation = new_cutout;
            self.fluid_allocation = new_fluid;
            self.ready = true;
        } else {
            if (new_solid) |a| allocator.free(a);
            if (new_cutout) |a| allocator.free(a);
            if (new_fluid) |a| allocator.free(a);
            self.solid_allocation = old_solid;
            self.cutout_allocation = old_cutout;
            self.fluid_allocation = old_fluid;
            self.ready = had_old_allocations;
        }
    }

    /// Replaces all GPU allocations with externally produced vertex ranges.
    /// Used by the GPU mesher after copying compute output into the megabuffer.
    pub fn replaceAllocations(
        self: *ChunkMesh,
        allocator: *GlobalVertexAllocator,
        solid: ?VertexAllocation,
        cutout: ?VertexAllocation,
        fluid: ?VertexAllocation,
    ) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const old_solid = self.solid_allocation;
        const old_cutout = self.cutout_allocation;
        const old_fluid = self.fluid_allocation;

        const freeing_allocs = old_solid != null or old_cutout != null or old_fluid != null;
        const setting_allocs = solid != null or cutout != null or fluid != null;
        if (freeing_allocs and !setting_allocs) {
            log.log.warn("REPLACE_FREE: freeing allocations without replacement (underground/empty re-mesh)", .{});
        }

        self.solid_allocation = solid;
        self.cutout_allocation = cutout;
        self.fluid_allocation = fluid;
        self.ready = true;

        if (old_solid) |a| allocator.free(a);
        if (old_cutout) |a| allocator.free(a);
        if (old_fluid) |a| allocator.free(a);
    }

    /// Draw the chunk mesh with a single draw call per pass.
    pub fn draw(self: *const ChunkMesh, ctx: RenderContext, pass: Pass) void {
        if (!self.ready) return;

        switch (pass) {
            .solid => {
                if (self.solid_allocation) |alloc| {
                    ctx.drawOffset(alloc.handle, alloc.count, .triangles, alloc.offset);
                }
            },
            .cutout => {
                if (self.cutout_allocation) |alloc| {
                    ctx.drawOffset(alloc.handle, alloc.count, .triangles, alloc.offset);
                }
            },
            .fluid => {
                if (self.fluid_allocation) |alloc| {
                    ctx.drawOffset(alloc.handle, alloc.count, .triangles, alloc.offset);
                }
            },
        }
    }
};
