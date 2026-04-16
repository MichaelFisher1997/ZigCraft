const std = @import("std");
const testing = std.testing;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;

test "ChunkMesh.init creates mesh with null allocations" {
    var mesh = ChunkMesh.init(testing.allocator);
    try testing.expectEqual(false, mesh.ready);
    try testing.expectEqual(null, mesh.solid_allocation);
    try testing.expectEqual(null, mesh.cutout_allocation);
    try testing.expectEqual(null, mesh.fluid_allocation);
    try testing.expectEqual(null, mesh.pending_solid);
    try testing.expectEqual(null, mesh.pending_cutout);
    try testing.expectEqual(null, mesh.pending_fluid);
    mesh.deinitWithoutRHI();
}

test "ChunkMesh.init sets allocator" {
    var mesh = ChunkMesh.init(testing.allocator);
    try testing.expectEqual(testing.allocator, mesh.allocator);
    mesh.deinitWithoutRHI();
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

test "ChunkMesh.subchunk arrays are initially null" {
    const NUM_SUBCHUNKS = @import("chunk_mesh.zig").NUM_SUBCHUNKS;
    var mesh = ChunkMesh.init(testing.allocator);
    for (0..NUM_SUBCHUNKS) |i| {
        try testing.expectEqual(null, mesh.subchunk_solid[i]);
        try testing.expectEqual(null, mesh.subchunk_cutout[i]);
        try testing.expectEqual(null, mesh.subchunk_fluid[i]);
    }
    mesh.deinitWithoutRHI();
}
