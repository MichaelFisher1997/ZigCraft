//! LOD system statistics and aggregation helpers.

const lod_types = @import("lod_types.zig");
const LODLevel = lod_types.LODLevel;
const LODState = lod_types.LODState;

/// Statistics for LOD system monitoring.
pub const LODStats = struct {
    loaded: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    generating: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    generated: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    meshing: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    mesh_ready: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    uploading: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,

    memory_used_mb: u32 = 0,
    mesh_count: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    mesh_vertices: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    gen_queue_depth: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    upload_queue_depth: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    upgrades_pending: u32 = 0,
    downgrades_pending: u32 = 0,
    upload_failures: u32 = 0,

    pub fn totalLoaded(self: *const LODStats) u32 {
        var total: u32 = 0;
        for (self.loaded) |count| total += count;
        return total;
    }

    pub fn totalGenerating(self: *const LODStats) u32 {
        var total: u32 = 0;
        for (self.generating) |count| total += count;
        return total;
    }

    pub fn reset(self: *LODStats) void {
        self.loaded = [_]u32{0} ** LODLevel.count;
        self.generating = [_]u32{0} ** LODLevel.count;
        self.generated = [_]u32{0} ** LODLevel.count;
        self.meshing = [_]u32{0} ** LODLevel.count;
        self.mesh_ready = [_]u32{0} ** LODLevel.count;
        self.uploading = [_]u32{0} ** LODLevel.count;
        self.memory_used_mb = 0;
        self.mesh_count = [_]u32{0} ** LODLevel.count;
        self.mesh_vertices = [_]u32{0} ** LODLevel.count;
        self.gen_queue_depth = [_]u32{0} ** LODLevel.count;
        self.upload_queue_depth = [_]u32{0} ** LODLevel.count;
        self.cache_hits = 0;
        self.cache_misses = 0;
        self.upgrades_pending = 0;
        self.downgrades_pending = 0;
        self.upload_failures = 0;
    }

    pub fn recordState(self: *LODStats, lod_idx: usize, state: LODState) void {
        switch (state) {
            .renderable => self.loaded[lod_idx] += 1,
            .generating => self.generating[lod_idx] += 1,
            .generated => self.generated[lod_idx] += 1,
            .meshing => self.meshing[lod_idx] += 1,
            .mesh_ready => self.mesh_ready[lod_idx] += 1,
            .uploading => self.uploading[lod_idx] += 1,
            else => {},
        }
    }

    pub fn addMemory(self: *LODStats, bytes: usize) void {
        const mb = bytes / (1024 * 1024);
        self.memory_used_mb += @intCast(mb);
    }

    pub fn cacheHitRate(self: *const LODStats) f32 {
        const total = self.cache_hits + self.cache_misses;
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.cache_hits)) / @as(f32, @floatFromInt(total));
    }
};

const std = @import("std");

test "LODStats reports cache hit rate" {
    var stats = LODStats{};
    try std.testing.expectEqual(@as(f32, 0.0), stats.cacheHitRate());

    stats.cache_hits = 3;
    stats.cache_misses = 1;
    try std.testing.expectEqual(@as(f32, 0.75), stats.cacheHitRate());
}
