const std = @import("std");
const testing = std.testing;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;
const NUM_SUBCHUNKS = @import("chunk_mesh.zig").NUM_SUBCHUNKS;
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
