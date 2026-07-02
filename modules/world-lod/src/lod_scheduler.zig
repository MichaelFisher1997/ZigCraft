//! LOD region scheduling and job prioritization.

const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const ILODConfig = lod_chunk.ILODConfig;
const Vec3 = @import("engine-math").Vec3;
const engine_core = @import("engine-core");
const JobQueue = engine_core.job_system.JobQueue;
const log = engine_core.log;
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

const QueueDiag = struct {
    considered: u32 = 0,
    outside_radius: u32 = 0,
    covered_chunks: u32 = 0,
    existing: u32 = 0,
    queued: u32 = 0,
};

fn lodPriorityBias(lod: LODLevel) i32 {
    const lod_idx: u3 = @intFromEnum(lod);
    return @as(i32, @intCast(LODLevel.count - 1 - lod_idx)) << 28;
}

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
    const diag_enabled = engine_core.envFlag("ZIGCRAFT_LOD_DIAG", false);
    var diag = QueueDiag{};

    // All LOD jobs go to the highest LOD queue. Encode the actual LOD in priority bits.
    const queue = ctx.gen_queues[LODLevel.count - 1];
    const lod_idx: u3 = @intFromEnum(lod);
    const lod_priority_bias = lodPriorityBias(lod);

    _ = velocity;

    // Collect candidates that need queuing, then sort nearest-first before
    // pushing. This is essential because the shared priority queue is drained
    // concurrently by worker threads: a corner-out row-major scan would push
    // far candidates (produced first) long before near candidates, so workers
    // process far terrain before near terrain is even inserted. Sorting by
    // ascending encoded priority (lower = closer, within a single LOD level the
    // bias bits are identical) ensures nearer regions enter — and thus leave —
    // the heap first.
    const Candidate = struct { chunk: *LODChunk, encoded_priority: i32 };
    var candidates = std.ArrayListUnmanaged(Candidate).empty;
    defer candidates.deinit(ctx.allocator);

    var rz = player_rz - region_radius;
    while (rz <= player_rz + region_radius) : (rz += 1) {
        var rx = player_rx - region_radius;
        while (rx <= player_rx + region_radius) : (rx += 1) {
            diag.considered += 1;
            const key = LODRegionKey{ .rx = rx, .rz = rz, .lod = lod };
            const chunk_bounds = key.chunkBounds();
            if (!chunk_bounds.intersectsRadius(ctx.player_cx, ctx.player_cz, radius)) {
                diag.outside_radius += 1;
                continue;
            }

            if (ctx.cleanup_covered_regions) {
                if (chunk_checker) |checker| {
                    const temp_chunk = LODChunk.init(rx, rz, lod);
                    if (ctx.are_all_chunks_loaded(ctx.coverage_ptr, temp_chunk.worldBounds(), checker, checker_ctx.?)) {
                        diag.covered_chunks += 1;
                        continue;
                    }
                }
            }

            const existing = storage.get(key);
            if (existing != null) diag.existing += 1;
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
                const encoded_priority = (priority & 0x0FFFFFFF) | lod_priority_bias;

                // Append before flipping state so an allocation failure leaves
                // the chunk re-queueable in .missing instead of stuck .generating.
                try candidates.append(ctx.allocator, .{ .chunk = chunk, .encoded_priority = encoded_priority });
                chunk.state = .generating;
                diag.queued += 1;
            }
        }
    }

    std.mem.sort(Candidate, candidates.items, {}, struct {
        fn lessThan(_: void, a: Candidate, b: Candidate) bool {
            return a.encoded_priority < b.encoded_priority;
        }
    }.lessThan);

    for (candidates.items) |cand| {
        try queue.push(.{
            .type = .chunk_generation,
            .dist_sq = cand.encoded_priority,
            .data = .{
                .chunk = .{
                    .x = cand.chunk.region_x,
                    .z = cand.chunk.region_z,
                    .job_token = cand.chunk.job_token,
                    .lod_level = lod_idx,
                },
            },
        });
    }

    if (diag_enabled) {
        const S = struct {
            var counter: [LODLevel.count]u64 = .{0} ** LODLevel.count;
        };
        const diag_lod_idx = @intFromEnum(lod);
        S.counter[diag_lod_idx] += 1;
        if (S.counter[diag_lod_idx] % 120 == 1) {
            log.log.info("LOD_QUEUE_DIAG lod={} radius={} scale={} considered={} outside={} covered={} existing={} queued={} player_chunk=({}, {})", .{
                diag_lod_idx,
                radius,
                scale,
                diag.considered,
                diag.outside_radius,
                diag.covered_chunks,
                diag.existing,
                diag.queued,
                ctx.player_cx,
                ctx.player_cz,
            });
        }
    }
}

test "LOD scheduling prioritizes coarse horizon before near LODs" {
    try std.testing.expect(lodPriorityBias(.lod3) < lodPriorityBias(.lod2));
    try std.testing.expect(lodPriorityBias(.lod2) < lodPriorityBias(.lod1));
}
