const std = @import("std");
const testing = std.testing;

const diagnostics_mod = @import("world_diagnostics.zig");
const world_core = @import("world-core");
const world_meshing = @import("world-meshing");

fn makeChunkData(allocator: std.mem.Allocator, cx: i32, cz: i32) world_meshing.ChunkData {
    return .{
        .chunk = world_core.Chunk.init(cx, cz),
        .render = .{ .mesh = world_meshing.ChunkMesh.init(allocator) },
    };
}

test "CpuCullDiagnostics starts with zero counters" {
    const diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    try testing.expectEqual(@as(u32, 0), diagnostics.not_renderable);
    try testing.expectEqual(@as(u32, 0), diagnostics.not_in_storage);
    try testing.expectEqual(@as(u32, 0), diagnostics.missing_in_circle);
    try testing.expectEqual(@as(u32, 0), diagnostics.frustum_culled);
    try testing.expectEqual(@as(u32, 0), diagnostics.visible_no_mesh);
    try testing.expectEqual(@as(u32, 0), diagnostics.visible_zero_verts);
}

test "recordFrustumCulled increments frustum counter" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.recordFrustumCulled();
    diagnostics.recordFrustumCulled();

    try testing.expectEqual(@as(u32, 2), diagnostics.frustum_culled);
}

test "recordNotRenderable tracks missing chunks inside render circle" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.recordNotRenderable(3, 4, 25, 5);

    try testing.expectEqual(@as(u32, 1), diagnostics.not_renderable);
    try testing.expectEqual(@as(u32, 1), diagnostics.missing_in_circle);
    try testing.expectEqual(@as(i32, 3), diagnostics.missing_cx);
    try testing.expectEqual(@as(i32, 4), diagnostics.missing_cz);
}

test "recordNotRenderable ignores missing chunks outside render circle" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.recordNotRenderable(6, 0, 36, 5);

    try testing.expectEqual(@as(u32, 1), diagnostics.not_renderable);
    try testing.expectEqual(@as(u32, 0), diagnostics.missing_in_circle);
}

test "recordNotInStorage tracks storage misses independently" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};

    diagnostics.recordNotInStorage(-2, 1, 5, 3);

    try testing.expectEqual(@as(u32, 1), diagnostics.not_in_storage);
    try testing.expectEqual(@as(u32, 1), diagnostics.missing_in_circle);
    try testing.expectEqual(@as(i32, -2), diagnostics.missing_cx);
    try testing.expectEqual(@as(i32, 1), diagnostics.missing_cz);
}

test "recordVisible records first visible chunk without mesh" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};
    var data = makeChunkData(testing.allocator, 7, -3);

    diagnostics.recordVisible(7, -3, &data);
    diagnostics.recordVisible(8, -4, &data);

    try testing.expectEqual(@as(u32, 2), diagnostics.visible_no_mesh);
    try testing.expectEqual(@as(i32, 7), diagnostics.first_no_mesh_cx);
    try testing.expectEqual(@as(i32, -3), diagnostics.first_no_mesh_cz);
}

test "recordVisible records first allocated mesh with zero vertices" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};
    var data = makeChunkData(testing.allocator, 0, 0);
    data.render.mesh.solid_allocation = .{ .offset = 0, .count = 0 };

    diagnostics.recordVisible(11, 12, &data);

    try testing.expectEqual(@as(u32, 0), diagnostics.visible_no_mesh);
    try testing.expectEqual(@as(u32, 1), diagnostics.visible_zero_verts);
    try testing.expectEqual(@as(i32, 11), diagnostics.first_zero_verts_cx);
    try testing.expectEqual(@as(i32, 12), diagnostics.first_zero_verts_cz);
}

test "recordVisible does not flag chunks with vertices" {
    var diagnostics = diagnostics_mod.CpuCullDiagnostics{};
    var data = makeChunkData(testing.allocator, 0, 0);
    data.render.mesh.solid_allocation = .{ .offset = 0, .count = 12 };

    diagnostics.recordVisible(1, 2, &data);

    try testing.expectEqual(@as(u32, 0), diagnostics.visible_no_mesh);
    try testing.expectEqual(@as(u32, 0), diagnostics.visible_zero_verts);
}
