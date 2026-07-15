//! Bounded, renderer-backed LOD fixture used only by the GPU-culling benchmark.
//!
//! This deliberately installs normal manager-owned regions and compact meshes;
//! it never writes renderer telemetry or culling counters.  Keeping it here
//! makes the production ownership path (maps -> bridge -> compact pool ->
//! renderer) the only route to a ready fixture region.
const std = @import("std");
const Self = @import("lod_manager.zig").LODManager;
const lod_chunk = @import("lod_chunk.zig");
const LODChunk = lod_chunk.LODChunk;
const LODLevel = lod_chunk.LODLevel;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const LODMesh = @import("lod_mesh.zig").LODMesh;

pub const NAME = "gpu-culling-scale";
pub const REGION_COUNT: usize = 1024;
pub const GRID_SIDE: i32 = 32;
pub const REGION_STRIDE: i32 = 1;
pub const FIXTURE_LOD: LODLevel = .lod4;
pub const SOURCE_DENSITY: f32 = 0.25;
pub const MIN_HORIZON_CHUNKS: i32 = 4096;

comptime {
    std.debug.assert(REGION_COUNT == @as(usize, @intCast(GRID_SIDE * GRID_SIDE)));
}

/// Returns one deterministic, contiguous same-level region in a 32x32 lattice.
/// The negative half is intentional: it verifies floor-based region ownership
/// and keeps the fixed source set centered around the benchmark camera path.
pub fn regionKey(index: usize) LODRegionKey {
    std.debug.assert(index < REGION_COUNT);
    const x: i32 = @intCast(index % @as(usize, @intCast(GRID_SIDE)));
    const z: i32 = @intCast(index / @as(usize, @intCast(GRID_SIDE)));
    return .{
        .rx = (x - GRID_SIDE / 2) * REGION_STRIDE,
        .rz = (z - GRID_SIDE / 2) * REGION_STRIDE,
        .lod = FIXTURE_LOD,
    };
}

/// Installs exactly `REGION_COUNT` non-overlapping LOD4 regions through the
/// production compact upload bridge. There are intentionally no finer regions
/// or parents: LOD4 has no parent fallback and same-level contiguous regions retain
/// CPU hierarchy/coverage authority without a synthetic visibility shortcut.
pub fn install(self: *Self) !void {
    if (self.benchmark_fixture_active) return error.BenchmarkFixtureAlreadyInstalled;
    if (self.config.getRadii()[@intFromEnum(FIXTURE_LOD)] < MIN_HORIZON_CHUNKS) return error.BenchmarkFixtureHorizonTooSmall;

    for (0..REGION_COUNT) |index| {
        const key = regionKey(index);
        var source = try LODSimplifiedData.initWithSampleDensity(self.allocator, FIXTURE_LOD, SOURCE_DENSITY);
        var source_transferred = false;
        errdefer if (!source_transferred) source.deinit();
        fillRenderableTerrain(&source, key);

        const chunk = try self.allocator.create(LODChunk);
        errdefer self.allocator.destroy(chunk);
        chunk.* = LODChunk.init(key.rx, key.rz, FIXTURE_LOD);
        chunk.data = .{ .simplified = source };
        source_transferred = true;
        errdefer chunk.deinit(self.allocator);

        const mesh = try self.allocator.create(LODMesh);
        errdefer self.allocator.destroy(mesh);
        mesh.* = LODMesh.init(self.allocator, FIXTURE_LOD);
        errdefer mesh.releasePendingCompactTile();
        try mesh.buildCompactTile(simplifiedData(chunk));
        try self.gpu_bridge.upload(mesh);
        errdefer self.gpu_bridge.destroy(mesh);

        self.mutex.lock();
        const regions = &self.regions[@intFromEnum(FIXTURE_LOD)];
        const meshes = &self.meshes[@intFromEnum(FIXTURE_LOD)];
        if (regions.contains(key) or meshes.contains(key)) {
            self.mutex.unlock();
            return error.BenchmarkFixtureKeyCollision;
        }
        regions.put(key, chunk) catch |err| {
            self.mutex.unlock();
            return err;
        };
        meshes.put(key, mesh) catch |err| {
            _ = regions.remove(key);
            self.mutex.unlock();
            return err;
        };
        // The bridge succeeded, so this is the normal published renderable
        // state. LOD4 has no parent to update and no fabricated child count.
        chunk.markRenderable(0);
        self.mutex.unlock();
    }
    self.benchmark_fixture_active = true;
    self.updateStats();
}

fn simplifiedData(chunk: *LODChunk) *const LODSimplifiedData {
    return switch (chunk.data) {
        .simplified => |*data| data,
        else => unreachable,
    };
}

/// Populate valid, supported source columns. A gentle deterministic slope
/// makes each tile renderable without invoking world generation or injecting a
/// draw/candidate counter.
fn fillRenderableTerrain(data: *LODSimplifiedData, key: LODRegionKey) void {
    var z: u32 = 0;
    while (z < data.width) : (z += 1) {
        var x: u32 = 0;
        while (x < data.width) : (x += 1) {
            const wave: i32 = @mod(key.rx * 3 + key.rz * 5 + @as(i32, @intCast(x)) + @as(i32, @intCast(z)), 7);
            data.setColumn(x, z, @as(f32, @floatFromInt(72 + wave)), .plains, .{ .surface = .grass, .subsurface = .dirt, .foundation = .stone }, 0x0068_a84f, .empty, .daylight, .empty);
        }
    }
}

test "gpu culling scale fixture has exactly spaced negative and positive LOD4 keys" {
    try std.testing.expectEqual(REGION_COUNT, @as(usize, @intCast(GRID_SIDE * GRID_SIDE)));
    const first = regionKey(0);
    const next = regionKey(1);
    const next_row = regionKey(@as(usize, @intCast(GRID_SIDE)));
    const last = regionKey(REGION_COUNT - 1);
    try std.testing.expectEqual(FIXTURE_LOD, first.lod);
    try std.testing.expectEqual(-16, first.rx);
    try std.testing.expectEqual(-16, first.rz);
    try std.testing.expectEqual(REGION_STRIDE, next.rx - first.rx);
    try std.testing.expectEqual(REGION_STRIDE, next_row.rz - first.rz);
    try std.testing.expectEqual(15, last.rx);
    try std.testing.expectEqual(15, last.rz);
}
