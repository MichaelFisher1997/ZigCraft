//! LOD region scheduling and job prioritization.

const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const ILODConfig = lod_chunk.ILODConfig;
const Vec3 = @import("engine-math").Vec3;
const JobQueue = @import("engine-core").job_system.JobQueue;
const sync = @import("sync");
const lod_gpu = @import("lod_upload_queue.zig");
const ChunkChecker = lod_gpu.ChunkChecker;
const RegionMap = lod_gpu.RegionMap;

pub const CoverageFn = *const fn (ptr: *anyopaque, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool;

pub const SchedulerContext = struct {
    allocator: std.mem.Allocator,
    config: ILODConfig,
    regions: *[LODLevel.count]RegionMap,
    gen_queues: *[LODLevel.count]*JobQueue,
    mutex: *sync.RwLock,
    player_cx: i32,
    player_cz: i32,
    next_job_token: *u32,
    cleanup_covered_regions: bool,
    coverage_ptr: *anyopaque,
    are_all_chunks_loaded: CoverageFn,
};

const std = @import("std");

/// Queue LOD regions that need generation.
pub fn queueLODRegions(ctx: SchedulerContext, lod: LODLevel, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
    const radii = ctx.config.getRadii();
    const radius = radii[@intFromEnum(lod)];

    // Skip LOD0 - handled by existing World system.
    if (lod == .lod0) return;

    const scale: i32 = @intCast(lod.chunksPerSide());
    const region_radius = @divFloor(radius, scale) + 1;

    const player_rx = @divFloor(ctx.player_cx, scale);
    const player_rz = @divFloor(ctx.player_cz, scale);

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    const storage = &ctx.regions[@intFromEnum(lod)];

    // All LOD jobs go to the highest LOD queue. Encode the actual LOD in priority bits.
    const queue = ctx.gen_queues[LODLevel.count - 1];
    const lod_bits: i32 = @as(i32, @intCast(@intFromEnum(lod))) << 28;

    _ = velocity;

    var rz = player_rz - region_radius;
    while (rz <= player_rz + region_radius) : (rz += 1) {
        var rx = player_rx - region_radius;
        while (rx <= player_rx + region_radius) : (rx += 1) {
            const key = LODRegionKey{ .rx = rx, .rz = rz, .lod = lod };
            const chunk_bounds = key.chunkBounds();
            if (!chunk_bounds.intersectsRadius(ctx.player_cx, ctx.player_cz, radius)) continue;

            if (ctx.cleanup_covered_regions) {
                if (chunk_checker) |checker| {
                    const temp_chunk = LODChunk.init(rx, rz, lod);
                    if (ctx.are_all_chunks_loaded(ctx.coverage_ptr, temp_chunk.worldBounds(), checker, checker_ctx.?)) {
                        continue;
                    }
                }
            }

            const existing = storage.get(key);
            const needs_queue = if (existing) |chunk| chunk.state == .missing else true;

            if (needs_queue) {
                const chunk = if (existing) |c| c else blk: {
                    const c = try ctx.allocator.create(LODChunk);
                    c.* = LODChunk.init(rx, rz, lod);
                    try storage.put(key, c);
                    break :blk c;
                };

                chunk.job_token = ctx.next_job_token.*;
                ctx.next_job_token.* += 1;

                const dist_sq = chunk_bounds.distanceSquaredToPoint(ctx.player_cx, ctx.player_cz);
                const priority_full = dist_sq * @as(i64, scale) * @as(i64, scale);
                const priority: i32 = @as(i32, @intCast(@min(priority_full, 0x0FFFFFFF)));
                const encoded_priority = (priority & 0x0FFFFFFF) | lod_bits;

                try queue.push(.{
                    .type = .chunk_generation,
                    .dist_sq = encoded_priority,
                    .data = .{
                        .chunk = .{
                            .x = rx,
                            .z = rz,
                            .job_token = chunk.job_token,
                        },
                    },
                });
                chunk.state = .generating;
            }
        }
    }
}
