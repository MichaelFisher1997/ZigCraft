//! Chunk mesh orchestrator — coordinates meshing stages and manages GPU lifecycle.
//!
//! Vertices are built per-subchunk via the greedy mesher, then merged into
//! single solid/cutout/fluid buffers for minimal draw calls. Meshing logic is
//! delegated to modules in `meshing/`.

const std = @import("std");

const Chunk = @import("chunk.zig").Chunk;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const rhi_mod = @import("../engine/graphics/rhi.zig");
const RHI = rhi_mod.RHI;
const Vertex = rhi_mod.Vertex;
const chunk_alloc_mod = @import("chunk_allocator.zig");
const GlobalVertexAllocator = chunk_alloc_mod.GlobalVertexAllocator;
const VertexAllocation = chunk_alloc_mod.VertexAllocation;

// Meshing stage modules
const greedy_mesher = @import("meshing/greedy_mesher.zig");
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
    mutex: std.Thread.Mutex,

    // Pending merged vertex data (built on worker thread, uploaded on main thread)
    pending_solid: ?[]Vertex = null,
    pending_cutout: ?[]Vertex = null,
    pending_fluid: ?[]Vertex = null,

    // Temporary per-subchunk data during building (not stored after merge)
    subchunk_solid: [NUM_SUBCHUNKS]?[]Vertex = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,
    subchunk_cutout: [NUM_SUBCHUNKS]?[]Vertex = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,
    subchunk_fluid: [NUM_SUBCHUNKS]?[]Vertex = [_]?[]Vertex{null} ** NUM_SUBCHUNKS,

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
    }

    /// Upload pending mesh data to the GPU using GlobalVertexAllocator.
    pub fn upload(self: *ChunkMesh, allocator: *GlobalVertexAllocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Handle solid pass
        if (self.pending_solid) |v| {
            // Always free existing allocation first to reduce peak usage
            if (self.solid_allocation) |alloc| {
                allocator.free(alloc);
                self.solid_allocation = null;
            }

            if (v.len > 0) {
                self.solid_allocation = allocator.allocate(v) catch |err| {
                    std.log.err("Failed to allocate chunk mesh vertices (will retry): {}", .{err});
                    return;
                };
            }
            self.allocator.free(v);
            self.pending_solid = null;
            self.ready = true;
        } else if (self.solid_allocation != null) {
            // Chunk became empty in solid pass, free the old allocation
            allocator.free(self.solid_allocation.?);
            self.solid_allocation = null;
            self.ready = true;
        }

        // Handle cutout pass
        if (self.pending_cutout) |v| {
            if (self.cutout_allocation) |alloc| {
                allocator.free(alloc);
                self.cutout_allocation = null;
            }

            if (v.len > 0) {
                self.cutout_allocation = allocator.allocate(v) catch |err| {
                    std.log.err("Failed to allocate chunk cutout vertices (will retry): {}", .{err});
                    return;
                };
            }
            self.allocator.free(v);
            self.pending_cutout = null;
            self.ready = true;
        } else if (self.cutout_allocation != null) {
            allocator.free(self.cutout_allocation.?);
            self.cutout_allocation = null;
            self.ready = true;
        }

        // Handle fluid pass
        if (self.pending_fluid) |v| {
            if (self.fluid_allocation) |alloc| {
                allocator.free(alloc);
                self.fluid_allocation = null;
            }

            if (v.len > 0) {
                self.fluid_allocation = allocator.allocate(v) catch |err| {
                    std.log.err("Failed to allocate chunk fluid vertices (will retry): {}", .{err});
                    return;
                };
            }
            self.allocator.free(v);
            self.pending_fluid = null;
            self.ready = true;
        } else if (self.fluid_allocation != null) {
            // Chunk became empty in fluid pass, free the old allocation
            allocator.free(self.fluid_allocation.?);
            self.fluid_allocation = null;
            self.ready = true;
        }
    }

    /// Draw the chunk mesh with a single draw call per pass.
    pub fn draw(self: *const ChunkMesh, rhi: RHI, pass: Pass) void {
        if (!self.ready) return;

        switch (pass) {
            .solid => {
                if (self.solid_allocation) |alloc| {
                    rhi.drawOffset(alloc.handle, alloc.count, .triangles, alloc.offset);
                }
            },
            .cutout => {
                if (self.cutout_allocation) |alloc| {
                    rhi.drawOffset(alloc.handle, alloc.count, .triangles, alloc.offset);
                }
            },
            .fluid => {
                if (self.fluid_allocation) |alloc| {
                    rhi.drawOffset(alloc.handle, alloc.count, .triangles, alloc.offset);
                }
            },
        }
    }
};
