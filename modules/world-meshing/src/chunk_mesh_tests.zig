const std = @import("std");
const testing = std.testing;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;
const NeighborChunks = @import("chunk_mesh.zig").NeighborChunks;
const NUM_SUBCHUNKS = @import("chunk_mesh.zig").NUM_SUBCHUNKS;
const world_core = @import("world-core");
const TextureAtlas = @import("engine-assets").TextureAtlas;
const RenderContext = @import("engine-rhi").RenderContext;

test "ChunkMesh.init creates mesh with null allocations" {
    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try testing.expectEqual(false, mesh.ready);
    try testing.expectEqual(null, mesh.solid_allocation);
    try testing.expectEqual(null, mesh.cutout_allocation);
    try testing.expectEqual(null, mesh.fluid_allocation);
    try testing.expectEqual(null, mesh.pending_solid);
    try testing.expectEqual(null, mesh.pending_cutout);
    try testing.expectEqual(null, mesh.pending_fluid);
}

test "ChunkMesh.init sets allocator" {
    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try testing.expectEqual(testing.allocator, mesh.allocator);
}

test "ChunkMesh.deinitWithoutRHI can be called on fresh mesh" {
    var mesh = ChunkMesh.init(testing.allocator);
    mesh.deinitWithoutRHI();
}

test "ChunkMesh.deinitWithoutRHI can be called twice safely" {
    var mesh = ChunkMesh.init(testing.allocator);
    mesh.deinitWithoutRHI();
    mesh.deinitWithoutRHI();
}

test "ChunkMesh.draw returns early when not ready" {
    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    const ctx: RenderContext = undefined;
    mesh.draw(ctx, .solid);

    try testing.expectEqual(false, mesh.ready);
}

test "ChunkMesh subchunk arrays are initially null" {
    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try testing.expectEqual(NUM_SUBCHUNKS, mesh.subchunk_solid.len);
    try testing.expectEqual(NUM_SUBCHUNKS, mesh.subchunk_cutout.len);
    try testing.expectEqual(NUM_SUBCHUNKS, mesh.subchunk_fluid.len);

    for (0..NUM_SUBCHUNKS) |i| {
        try testing.expectEqual(null, mesh.subchunk_solid[i]);
        try testing.expectEqual(null, mesh.subchunk_cutout[i]);
        try testing.expectEqual(null, mesh.subchunk_fluid[i]);
    }
}

test "ChunkMesh emits wall-attached fixture cutout quad" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(1, 1, 1, .vine);

    var atlas: TextureAtlas = undefined;
    atlas.tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** 256;

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try mesh.buildWithNeighbors(&chunk, NeighborChunks.empty, &atlas);

    try testing.expectEqual(@as(usize, 6), mesh.pending_cutout.?.len);
    try testing.expectEqual(null, mesh.pending_solid);
    try testing.expectEqual(null, mesh.pending_fluid);
}

test "ChunkMesh emits custom slab fixture solid mesh" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(1, 1, 1, .stone_slab);

    var atlas: TextureAtlas = undefined;
    atlas.tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** 256;

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try mesh.buildWithNeighbors(&chunk, NeighborChunks.empty, &atlas);

    try testing.expectEqual(@as(usize, 36), mesh.pending_solid.?.len);
    try testing.expectEqual(null, mesh.pending_cutout);
    try testing.expectEqual(null, mesh.pending_fluid);
}

test "ChunkMesh emits custom stair fixture solid mesh" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(1, 1, 1, .stone_stairs);

    var atlas: TextureAtlas = undefined;
    atlas.tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** 256;

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try mesh.buildWithNeighbors(&chunk, NeighborChunks.empty, &atlas);

    try testing.expectEqual(@as(usize, 72), mesh.pending_solid.?.len);
    try testing.expectEqual(null, mesh.pending_cutout);
    try testing.expectEqual(null, mesh.pending_fluid);
}

test "ChunkMesh tall_cross emits 2-block billboard from single block" {
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(1, 5, 1, .tall_grass);

    var atlas: TextureAtlas = undefined;
    atlas.tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** 256;

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try mesh.buildWithNeighbors(&chunk, NeighborChunks.empty, &atlas);

    // tall_cross emits 2 diagonal quads × 6 verts = 12 cutout vertices
    try testing.expectEqual(@as(usize, 12), mesh.pending_cutout.?.len);
    // The quad should span 2 blocks vertically (y=5 to y=7)
    const verts = mesh.pending_cutout.?;
    var found_y5 = false;
    var found_y7 = false;
    for (verts) |v| {
        if (v.pos[1] == 5.0) found_y5 = true;
        if (v.pos[1] == 7.0) found_y7 = true;
    }
    try testing.expect(found_y5);
    try testing.expect(found_y7);
}

test "ChunkMesh tall_cross renders full height at subchunk top boundary" {
    // Place tall_grass at the LAST y of subchunk 0 (y=15). The 2-block-tall
    // billboard extends into subchunk 1's range but should still be fully meshed.
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(1, 15, 1, .tall_grass);

    var atlas: TextureAtlas = undefined;
    atlas.tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** 256;

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try mesh.buildWithNeighbors(&chunk, NeighborChunks.empty, &atlas);

    try testing.expectEqual(@as(usize, 12), mesh.pending_cutout.?.len);
    const verts = mesh.pending_cutout.?;
    var found_y15 = false;
    var found_y17 = false;
    for (verts) |v| {
        if (v.pos[1] == 15.0) found_y15 = true;
        if (v.pos[1] == 17.0) found_y17 = true;
    }
    try testing.expect(found_y15);
    try testing.expect(found_y17);
}

test "ChunkMesh emits top face for cube at subchunk boundary (regression for #705)" {
    // Place a stone cube at y=15 — the LAST layer of subchunk 0. Its top face
    // lives at the sy=16 boundary (between subchunk 0 and subchunk 1).
    //
    // The horizontal slice loop MUST iterate `sy <= y1` so subchunk 0 can emit
    // this top face: greedy_mesher.meshSlice uses isEmittingSubchunk(.top, s - 1, ...)
    // to assign the face to the subchunk that OWNS the solid block (y=15 → subchunk 0).
    // Switching to `sy < y1` dropped the sy=16 iteration, so the top face was never
    // emitted — and this happened at EVERY subchunk boundary (y=15, 31, ..., 255),
    // not just the world ceiling.
    //
    // A standalone cube surrounded by air emits all 6 faces (6 verts each = 36).
    // With the `sy < y1` regression only 5 faces (30 verts) were emitted.
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(1, 15, 1, .stone);

    var atlas: TextureAtlas = undefined;
    atlas.tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** 256;

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try mesh.buildWithNeighbors(&chunk, NeighborChunks.empty, &atlas);

    try testing.expect(mesh.pending_solid != null);
    try testing.expectEqual(@as(usize, 36), mesh.pending_solid.?.len);
}

test "ChunkMesh emits top face for cube at world ceiling (regression for #705)" {
    // Same regression at the world ceiling: a cube at y=CHUNK_SIZE_Y-1 needs its
    // top face meshed at the sy=CHUNK_SIZE_Y boundary. This is the exact case
    // the PR review flagged (mountain peaks at y=255 would show a hole).
    const top_y = world_core.CHUNK_SIZE_Y - 1;
    var chunk = world_core.Chunk.init(0, 0);
    chunk.setBlock(1, top_y, 1, .stone);

    var atlas: TextureAtlas = undefined;
    atlas.tile_mappings = [_]TextureAtlas.BlockTiles{TextureAtlas.BlockTiles.uniform(7)} ** 256;

    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try mesh.buildWithNeighbors(&chunk, NeighborChunks.empty, &atlas);

    try testing.expect(mesh.pending_solid != null);
    try testing.expectEqual(@as(usize, 36), mesh.pending_solid.?.len);
}
