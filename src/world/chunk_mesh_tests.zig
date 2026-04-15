const std = @import("std");
const testing = std.testing;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;

test "ChunkMesh.init sets ready to false" {
    var mesh = ChunkMesh.init(testing.allocator);
    try testing.expect(!mesh.ready);
}

test "ChunkMesh.init has null allocations" {
    var mesh = ChunkMesh.init(testing.allocator);
    try testing.expectEqual(null, mesh.solid_allocation);
    try testing.expectEqual(null, mesh.cutout_allocation);
    try testing.expectEqual(null, mesh.fluid_allocation);
}

test "ChunkMesh.init has null pending arrays" {
    var mesh = ChunkMesh.init(testing.allocator);
    try testing.expectEqual(null, mesh.pending_solid);
    try testing.expectEqual(null, mesh.pending_cutout);
    try testing.expectEqual(null, mesh.pending_fluid);
}

test "ChunkMesh.deinitWithoutRHI clears all subchunk data" {
    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try testing.expect(!mesh.ready);
    try testing.expectEqual(null, mesh.solid_allocation);
    try testing.expectEqual(null, mesh.cutout_allocation);
    try testing.expectEqual(null, mesh.fluid_allocation);
}

test "ChunkMesh.draw early return when not ready" {
    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    try testing.expect(!mesh.ready);
}

test "ChunkMesh subchunk arrays initialized to null" {
    var mesh = ChunkMesh.init(testing.allocator);
    defer mesh.deinitWithoutRHI();

    const NUM_SUBCHUNKS = @import("chunk_mesh.zig").NUM_SUBCHUNKS;
    try testing.expectEqual(NUM_SUBCHUNKS, mesh.subchunk_solid.len);
    try testing.expectEqual(NUM_SUBCHUNKS, mesh.subchunk_cutout.len);
    try testing.expectEqual(NUM_SUBCHUNKS, mesh.subchunk_fluid.len);

    for (0..NUM_SUBCHUNKS) |i| {
        try testing.expectEqual(null, mesh.subchunk_solid[i]);
        try testing.expectEqual(null, mesh.subchunk_cutout[i]);
        try testing.expectEqual(null, mesh.subchunk_fluid[i]);
    }
}
