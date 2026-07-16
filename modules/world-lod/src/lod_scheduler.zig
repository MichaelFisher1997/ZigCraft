//! LOD region scheduling and job prioritization.

const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODConfig = lod_chunk.LODConfig;
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
const LifecycleQueue = @import("lod_manager_context.zig").LifecycleQueue;
const LifecycleToken = @import("lod_manager_context.zig").LifecycleToken;

pub const CoverageFn = *const fn (ptr: *anyopaque, bounds: LODChunk.WorldBounds, checker: ChunkChecker, ctx: *anyopaque) bool;

pub const SchedulerContext = struct {
    allocator: std.mem.Allocator,
    config: ILODConfig,
    radii: [LODLevel.count]i32,
    active_lod_count: usize,
    regions: *[LODLevel.count]RegionMap,
    gen_queues: *[LODLevel.count]*JobQueue,
    mutex: *sync.RwLock,
    player_cx: i32,
    player_cz: i32,
    next_job_token: *u32,
    cleanup_covered_regions: bool,
    coverage_ptr: *anyopaque,
    are_all_chunks_loaded: CoverageFn,
    // Dynamic per-level radius reduction (hysteresis under memory pressure).
    // Applied to all levels EXCEPT the coarsest (horizon is never shrunk).
    radius_reduction: *const [LODLevel.count]i32,
    // When true, queueLODRegions marks chunks queued_for_generation and lets
    // LODManager perform main-thread cache reads before dispatching workers.
    defer_generation_dispatch: bool = false,
    // Shared admission count for queued or in-flight regions. The manager
    // supplies this during normal updates; isolated scheduler tests may omit it.
    pending_regions: ?*usize = null,
    /// Resident-region and conservative logical-memory admission caps.
    resident_region_limit: usize = MAX_LOD_REGIONS,
    logical_memory_limit_bytes: usize = std.math.maxInt(usize),
    logical_memory_bytes: ?*usize = null,
    logical_region_reservation_bytes: usize = 0,
    use_vertical_spans: bool = false,
    /// Persistent bounded priority queue owned by the manager. `null` keeps
    /// isolated scheduler tests and legacy direct-dispatch callers working.
    generation_tokens: ?*LifecycleQueue = null,
};

const std = @import("std");

const QueueDiag = struct {
    considered: u32 = 0,
    outside_radius: u32 = 0,
    covered_chunks: u32 = 0,
    existing: u32 = 0,
    candidates: u32 = 0,
    queued: u32 = 0,
};

const LOD0_QUEUE_CANDIDATE_LIMIT: usize = 96;
const LOD1_QUEUE_CANDIDATE_LIMIT: usize = 64;
const HORIZON_QUEUE_CANDIDATE_LIMIT: usize = 64;
const REFINEMENT_QUEUE_CANDIDATE_LIMIT: usize = 48;
const MAX_PENDING_LOD_REGIONS = @import("lod_manager_context.zig").MAX_PENDING_LOD_REGIONS;
const MAX_LOD_REGIONS = @import("lod_manager_context.zig").MAX_LOD_REGIONS;

const HORIZON_SEED_DIRECTIONS = [_][2]i32{
    .{ 1024, 0 },  .{ 946, 392 },   .{ 724, 724 },   .{ 392, 946 },
    .{ 0, 1024 },  .{ -392, 946 },  .{ -724, 724 },  .{ -946, 392 },
    .{ -1024, 0 }, .{ -946, -392 }, .{ -724, -724 }, .{ -392, -946 },
    .{ 0, -1024 }, .{ 392, -946 },  .{ 724, -724 },  .{ 946, -392 },
};

fn scaledSeedOffset(component: i32, radius: i32) i32 {
    const product = component * radius;
    return @divTrunc(product + (if (product >= 0) @as(i32, 512) else -512), 1024);
}

fn initialHorizonSeedRank(rx: i32, rz: i32, player_rx: i32, player_rz: i32, region_radius: i32) ?usize {
    const outer_radius = @max(1, region_radius - 1);
    for (HORIZON_SEED_DIRECTIONS, 0..) |dir, i| {
        if (rx == player_rx + scaledSeedOffset(dir[0], outer_radius) and
            rz == player_rz + scaledSeedOffset(dir[1], outer_radius)) return i;
    }

    const middle_radius = @max(1, @divFloor(outer_radius, 2));
    for (0..8) |i| {
        const dir = HORIZON_SEED_DIRECTIONS[i * 2];
        if (rx == player_rx + scaledSeedOffset(dir[0], middle_radius) and
            rz == player_rz + scaledSeedOffset(dir[1], middle_radius)) return HORIZON_SEED_DIRECTIONS.len + i;
    }
    return null;
}

pub fn priorityRank(lod: LODLevel, active_lod_count: usize) usize {
    const lod_idx: usize = @intFromEnum(lod);
    const coarsest_idx = if (active_lod_count == 0) 0 else active_lod_count - 1;
    return if (lod_idx == coarsest_idx)
        0
    else
        lod_idx + 1;
}

pub fn priorityLevelIndex(order_idx: usize, active_lod_count: usize) usize {
    if (active_lod_count == 0) return 0;
    if (order_idx == 0) return active_lod_count - 1;
    return order_idx - 1;
}

fn lodPriorityBias(lod: LODLevel, active_lod_count: usize) i32 {
    const rank = priorityRank(lod, active_lod_count);
    return @as(i32, @intCast(rank)) << 28;
}

fn maxQueueCandidatesForLOD(lod: LODLevel, active_lod_count: usize) usize {
    const lod_idx: usize = @intFromEnum(lod);
    const coarsest_idx = if (active_lod_count == 0) 0 else active_lod_count - 1;
    if (lod_idx == 0) return LOD0_QUEUE_CANDIDATE_LIMIT;
    if (lod_idx == 1) return LOD1_QUEUE_CANDIDATE_LIMIT;
    if (lod_idx == coarsest_idx) return HORIZON_QUEUE_CANDIDATE_LIMIT;
    return REFINEMENT_QUEUE_CANDIDATE_LIMIT;
}

pub fn priorityWeightForVelocity(velocity: Vec3, chunk_dx: i32, chunk_dz: i32) f32 {
    const speed = @sqrt(velocity.x * velocity.x + velocity.z * velocity.z);
    if (speed < 2.0) return 1.0;

    const cdx: f32 = @floatFromInt(chunk_dx);
    const cdz: f32 = @floatFromInt(chunk_dz);
    const dist = @sqrt(cdx * cdx + cdz * cdz);
    if (dist < 0.001) return 0.5;

    const dir_x = velocity.x / speed;
    const dir_z = velocity.z / speed;
    const dot = (cdx * dir_x + cdz * dir_z) / dist;
    return 1.0 - dot * 0.5;
}

pub fn encodePriority(lod: LODLevel, chunk_dx: i32, chunk_dz: i32, velocity: Vec3, active_lod_count: usize) i32 {
    const dist_sq = @as(i64, chunk_dx) * @as(i64, chunk_dx) + @as(i64, chunk_dz) * @as(i64, chunk_dz);
    const weighted = @as(f64, @floatFromInt(dist_sq)) * @as(f64, priorityWeightForVelocity(velocity, chunk_dx, chunk_dz));
    const priority: i32 = @intFromFloat(@min(weighted, @as(f64, @floatFromInt(@as(i32, 0x0FFFFFFF)))));
    return (priority & 0x0FFFFFFF) | lodPriorityBias(lod, active_lod_count);
}

/// Queue LOD regions that need generation.
pub fn queueLODRegions(ctx: SchedulerContext, lod: LODLevel, velocity: Vec3, chunk_checker: ?ChunkChecker, checker_ctx: ?*anyopaque) !void {
    // Do not rescan thousands of horizon candidates while the bounded
    // lifecycle pipeline cannot admit another region.
    ctx.mutex.lockShared();
    if (ctx.pending_regions) |pending| {
        if (pending.* >= MAX_PENDING_LOD_REGIONS) {
            ctx.mutex.unlockShared();
            return;
        }
    }
    ctx.mutex.unlockShared();

    const radii = ctx.radii;
    const idx: u32 = @intFromEnum(lod);
    // Apply dynamic radius reduction (hysteresis) to every level except the
    // coarsest horizon band, which must keep filling regardless of pressure.
    const is_coarsest = (idx + 1 >= LODLevel.count) or (@as(usize, idx + 1) >= ctx.active_lod_count);
    const radius = if (is_coarsest) radii[idx] else @max(0, radii[idx] - ctx.radius_reduction[idx]);

    const scale: i32 = @intCast(lod.chunksPerSide());
    const region_radius = @divFloor(radius, scale) + 1;

    const player_rx = @divFloor(ctx.player_cx, scale);
    const player_rz = @divFloor(ctx.player_cz, scale);

    const diag_enabled = engine_core.envFlag("ZIGCRAFT_LOD_DIAG", false);
    var diag = QueueDiag{};
    const active_lod_count = ctx.active_lod_count;

    // All LOD jobs go to the highest LOD queue. Encode the actual LOD in priority bits.
    const queue = ctx.gen_queues[LODLevel.count - 1];
    const lod_idx: u3 = @intFromEnum(lod);

    // Keep only the bounded best candidates while walking the horizon. This
    // avoids allocating/sorting an entry for every potential region.
    const Candidate = struct { key: LODRegionKey, encoded_priority: i32, selection_priority: i64, preserve_priority: bool };
    const max_candidates = maxQueueCandidatesForLOD(lod, active_lod_count);
    var candidates = std.ArrayListUnmanaged(Candidate).empty;
    defer candidates.deinit(ctx.allocator);

    // Existing active regions must not consume the bounded candidate window.
    // Repeatedly selecting the same nearest horizon regions otherwise prevents
    // the coarsest band from progressing beyond its first batch.
    ctx.mutex.lockShared();
    const candidate_storage = &ctx.regions[@intFromEnum(lod)];
    const seed_initial_horizon = is_coarsest and candidate_storage.count() == 0;

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

            if (candidate_storage.get(key)) |chunk| {
                diag.existing += 1;
                if (chunk.getState() != .missing or chunk.isPinned()) continue;
            }

            const center_cx = key.rx * scale + @divFloor(scale, 2);
            const center_cz = key.rz * scale + @divFloor(scale, 2);
            const distance_priority = encodePriority(lod, center_cx - ctx.player_cx, center_cz - ctx.player_cz, velocity, active_lod_count);
            const seed_rank = if (seed_initial_horizon) initialHorizonSeedRank(rx, rz, player_rx, player_rz, region_radius) else null;
            // Preserve the spatial seed order in the worker queue as well as
            // candidate admission; otherwise distance reprioritization makes
            // the newly admitted outer shell wait behind nearby coarse tiles.
            const encoded_priority = if (seed_rank) |rank|
                lodPriorityBias(lod, active_lod_count) | @as(i32, @intCast(rank))
            else
                distance_priority;
            const selection_priority: i64 = if (seed_initial_horizon)
                if (seed_rank) |rank|
                    @intCast(rank)
                else
                    @as(i64, 1_000_000_000) + @as(i64, distance_priority & 0x0FFFFFFF)
            else
                distance_priority;
            const candidate = Candidate{
                .key = key,
                .encoded_priority = encoded_priority,
                .selection_priority = selection_priority,
                .preserve_priority = seed_rank != null,
            };
            var insert_at: usize = 0;
            while (insert_at < candidates.items.len and candidates.items[insert_at].selection_priority <= selection_priority) : (insert_at += 1) {}
            if (insert_at < max_candidates) {
                candidates.insert(ctx.allocator, insert_at, candidate) catch |err| {
                    ctx.mutex.unlockShared();
                    return err;
                };
                if (candidates.items.len > max_candidates) _ = candidates.pop();
            }
            diag.candidates += 1;
        }
    }
    ctx.mutex.unlockShared();

    var queued_count: usize = 0;

    ctx.mutex.lock();
    defer ctx.mutex.unlock();

    const storage = &ctx.regions[@intFromEnum(lod)];
    var resident_regions: usize = 0;
    for (ctx.regions) |region_map| resident_regions += region_map.count();
    for (candidates.items) |cand| {
        if (queued_count >= max_candidates) break;
        if (ctx.pending_regions) |pending| {
            if (pending.* >= MAX_PENDING_LOD_REGIONS) break;
        }

        const existing = storage.get(cand.key);
        if (existing == null and resident_regions >= ctx.resident_region_limit) break;
        if (existing == null) if (ctx.logical_memory_bytes) |logical| {
            const reservation = ctx.logical_region_reservation_bytes;
            if (reservation > ctx.logical_memory_limit_bytes -| logical.*) break;
        };
        // A cancelled worker keeps the region pinned until it observes its
        // cancellation signal. Do not reset that signal by dispatching a new
        // generation for the same region concurrently.
        const needs_queue = if (existing) |chunk| chunk.getState() == .missing and !chunk.isPinned() else true;
        if (!needs_queue) continue;

        const chunk = if (existing) |c| c else blk: {
            const c = try ctx.allocator.create(LODChunk);
            errdefer ctx.allocator.destroy(c);
            c.* = LODChunk.init(cand.key.rx, cand.key.rz, lod);
            try storage.put(cand.key, c);
            resident_regions += 1;
            if (ctx.logical_memory_bytes) |logical| {
                logical.* = std.math.add(usize, logical.*, ctx.logical_region_reservation_bytes) catch std.math.maxInt(usize);
            }
            break :blk c;
        };

        chunk.job_token = ctx.next_job_token.*;
        ctx.next_job_token.* += 1;
        chunk.job_priority = cand.encoded_priority;
        chunk.preserve_job_priority = cand.preserve_priority;
        if (ctx.defer_generation_dispatch) {
            chunk.setState(.queued_for_generation);
            if (ctx.generation_tokens) |tokens| {
                _ = try tokens.push(ctx.allocator, .{
                    .key = cand.key,
                    .job_token = chunk.job_token,
                    .source_revision = chunk.source_revision,
                    .priority = cand.encoded_priority,
                    .stage = .generation,
                });
            }
        } else {
            chunk.resetCancellation();
            chunk.setState(.generating);
            queue.push(.{
                .type = .chunk_generation,
                .dist_sq = cand.encoded_priority,
                .data = .{
                    .chunk = .{
                        .x = chunk.region_x,
                        .z = chunk.region_z,
                        .job_token = chunk.job_token,
                        .lod_level = lod_idx,
                        .coord_scale = scale,
                        .lod_radius = radii[idx],
                        .use_vertical_spans = ctx.use_vertical_spans,
                    },
                },
            }) catch |err| {
                chunk.setState(.missing);
                return err;
            };
        }
        diag.queued += 1;
        queued_count += 1;
        if (ctx.pending_regions) |pending| pending.* += 1;
    }

    if (diag_enabled) {
        const S = struct {
            var counter: [LODLevel.count]u64 = .{0} ** LODLevel.count;
        };
        const diag_lod_idx = @intFromEnum(lod);
        S.counter[diag_lod_idx] += 1;
        if (S.counter[diag_lod_idx] % 120 == 1) {
            log.log.info("LOD_QUEUE_DIAG lod={} radius={} scale={} considered={} outside={} covered={} existing={} candidates={} queued={} player_chunk=({}, {})", .{
                diag_lod_idx,
                radius,
                scale,
                diag.considered,
                diag.outside_radius,
                diag.covered_chunks,
                diag.existing,
                diag.candidates,
                diag.queued,
                ctx.player_cx,
                ctx.player_cz,
            });
        }
    }
}

test "LOD scheduling seeds horizon before detailed refinements" {
    try std.testing.expect(lodPriorityBias(.lod4, LODLevel.count) < lodPriorityBias(.lod0, LODLevel.count));
    try std.testing.expect(lodPriorityBias(.lod0, LODLevel.count) < lodPriorityBias(.lod1, LODLevel.count));
    try std.testing.expect(lodPriorityBias(.lod1, LODLevel.count) < lodPriorityBias(.lod2, LODLevel.count));
    try std.testing.expect(lodPriorityBias(.lod2, LODLevel.count) < lodPriorityBias(.lod3, LODLevel.count));

    try std.testing.expect(lodPriorityBias(.lod3, 4) < lodPriorityBias(.lod0, 4));
    try std.testing.expect(lodPriorityBias(.lod0, 4) < lodPriorityBias(.lod1, 4));

    try std.testing.expectEqual(@as(usize, 4), priorityLevelIndex(0, LODLevel.count));
    try std.testing.expectEqual(@as(usize, 0), priorityLevelIndex(1, LODLevel.count));
    try std.testing.expectEqual(@as(usize, 1), priorityLevelIndex(2, LODLevel.count));
    try std.testing.expectEqual(@as(usize, 2), priorityLevelIndex(3, LODLevel.count));
    try std.testing.expectEqual(@as(usize, 3), priorityLevelIndex(4, LODLevel.count));
}

test "LOD scheduling caps resident regions and logical admission memory" {
    const allocator = std.testing.allocator;

    var regions: [LODLevel.count]RegionMap = undefined;
    for (&regions) |*region_map| region_map.* = RegionMap.init(allocator);
    defer {
        for (&regions) |*region_map| {
            var it = region_map.iterator();
            while (it.next()) |entry| {
                const chunk = entry.value_ptr.*;
                chunk.deinit(allocator);
                allocator.destroy(chunk);
            }
            region_map.deinit();
        }
    }

    var queues: [LODLevel.count]JobQueue = undefined;
    var queue_ptrs: [LODLevel.count]*JobQueue = undefined;
    for (&queues, 0..) |*queue, i| {
        queue.* = JobQueue.init(allocator);
        queue_ptrs[i] = queue;
    }
    defer for (&queues) |*queue| queue.deinit();

    var config = LODConfig{
        .chunk_render_radius = 2,
        .radii = .{ 5, 12, 24, 48, 96 },
    };
    const config_iface = config.interface();
    var mutex: sync.RwLock = .{};
    var next_job_token: u32 = 1;
    var radius_reduction = [_]i32{0} ** LODLevel.count;
    var pending_regions: usize = 0;
    var logical_memory_bytes: usize = 0;
    const reservation_bytes: usize = 1024;
    var coverage_ctx: u8 = 0;
    const Coverage = struct {
        fn neverCovered(_: *anyopaque, _: LODChunk.WorldBounds, _: ChunkChecker, _: *anyopaque) bool {
            return false;
        }
    };

    try queueLODRegions(.{
        .allocator = allocator,
        .config = config_iface,
        .radii = config_iface.getRadii(),
        .active_lod_count = lod_chunk.activeLODCount(config_iface),
        .regions = &regions,
        .gen_queues = &queue_ptrs,
        .mutex = &mutex,
        .player_cx = 0,
        .player_cz = 0,
        .next_job_token = &next_job_token,
        .cleanup_covered_regions = false,
        .coverage_ptr = &coverage_ctx,
        .are_all_chunks_loaded = Coverage.neverCovered,
        .radius_reduction = &radius_reduction,
        .pending_regions = &pending_regions,
        .resident_region_limit = 1,
        .logical_memory_limit_bytes = reservation_bytes,
        .logical_memory_bytes = &logical_memory_bytes,
        .logical_region_reservation_bytes = reservation_bytes,
    }, .lod0, Vec3.zero, null, null);

    const queue = queue_ptrs[LODLevel.count - 1];
    try std.testing.expectEqual(@as(usize, 1), queue.count());
    try std.testing.expectEqual(queue.count(), pending_regions);
    try std.testing.expectEqual(reservation_bytes, logical_memory_bytes);
    const job = queue.pop().?;
    try std.testing.expectEqual(engine_core.job_system.JobType.chunk_generation, job.type);
    try std.testing.expectEqual(@as(u3, 0), job.data.chunk.lod_level);

    const key = LODRegionKey{ .rx = job.data.chunk.x, .rz = job.data.chunk.z, .lod = .lod0 };
    const chunk = regions[0].get(key).?;
    try std.testing.expectEqual(lod_chunk.LODState.generating, chunk.state);
}

test "LOD scheduling caps LOD0 flood while still queuing horizon jobs" {
    const allocator = std.testing.allocator;

    var regions: [LODLevel.count]RegionMap = undefined;
    for (&regions) |*region_map| region_map.* = RegionMap.init(allocator);
    defer {
        for (&regions) |*region_map| {
            var it = region_map.iterator();
            while (it.next()) |entry| {
                const chunk = entry.value_ptr.*;
                chunk.deinit(allocator);
                allocator.destroy(chunk);
            }
            region_map.deinit();
        }
    }

    var queues: [LODLevel.count]JobQueue = undefined;
    var queue_ptrs: [LODLevel.count]*JobQueue = undefined;
    for (&queues, 0..) |*queue, i| {
        queue.* = JobQueue.init(allocator);
        queue_ptrs[i] = queue;
    }
    defer for (&queues) |*queue| queue.deinit();

    var config = LODConfig{
        .chunk_render_radius = 16,
        .radii = .{ 64, 128, 256, 384, 512 },
    };
    const config_iface = config.interface();
    var mutex: sync.RwLock = .{};
    var next_job_token: u32 = 1;
    var radius_reduction = [_]i32{0} ** LODLevel.count;
    var coverage_ctx: u8 = 0;
    const Coverage = struct {
        fn neverCovered(_: *anyopaque, _: LODChunk.WorldBounds, _: ChunkChecker, _: *anyopaque) bool {
            return false;
        }
    };
    const ctx = SchedulerContext{
        .allocator = allocator,
        .config = config_iface,
        .radii = config_iface.getRadii(),
        .active_lod_count = lod_chunk.activeLODCount(config_iface),
        .regions = &regions,
        .gen_queues = &queue_ptrs,
        .mutex = &mutex,
        .player_cx = 0,
        .player_cz = 0,
        .next_job_token = &next_job_token,
        .cleanup_covered_regions = false,
        .coverage_ptr = &coverage_ctx,
        .are_all_chunks_loaded = Coverage.neverCovered,
        .radius_reduction = &radius_reduction,
    };

    try queueLODRegions(ctx, .lod0, Vec3.zero, null, null);
    try queueLODRegions(ctx, .lod4, Vec3.zero, null, null);

    const queue = queue_ptrs[LODLevel.count - 1];
    const total = queue.count();
    try std.testing.expectEqual(LOD0_QUEUE_CANDIDATE_LIMIT + HORIZON_QUEUE_CANDIDATE_LIMIT, total);

    // A cold cache must not keep admitting work once the global pipeline is
    // full; completed regions free capacity on subsequent manager updates.
    var pending_regions = MAX_PENDING_LOD_REGIONS;
    var capped_ctx = ctx;
    capped_ctx.pending_regions = &pending_regions;
    try queueLODRegions(capped_ctx, .lod1, Vec3.zero, null, null);
    try std.testing.expectEqual(total, queue.count());

    const first_job = queue.pop().?;
    try std.testing.expectEqual(@intFromEnum(LODLevel.lod4), first_job.data.chunk.lod_level);

    var lod0_count: usize = 0;
    var horizon_count: usize = 1;
    var max_horizon_dist_sq: i64 = 0;
    const recordHorizonDistance = struct {
        fn record(max_dist_sq: *i64, job: engine_core.job_system.Job) void {
            const scale: i32 = @intCast(LODLevel.lod4.chunksPerSide());
            const center_x: i64 = job.data.chunk.x * scale + @divFloor(scale, 2);
            const center_z: i64 = job.data.chunk.z * scale + @divFloor(scale, 2);
            max_dist_sq.* = @max(max_dist_sq.*, center_x * center_x + center_z * center_z);
        }
    }.record;
    recordHorizonDistance(&max_horizon_dist_sq, first_job);
    var i: usize = 1;
    while (i < total) : (i += 1) {
        const job = queue.pop().?;
        if (job.data.chunk.lod_level == @intFromEnum(LODLevel.lod0)) lod0_count += 1;
        if (job.data.chunk.lod_level == @intFromEnum(LODLevel.lod4)) {
            horizon_count += 1;
            recordHorizonDistance(&max_horizon_dist_sq, job);
        }
    }

    try std.testing.expectEqual(LOD0_QUEUE_CANDIDATE_LIMIT, lod0_count);
    try std.testing.expectEqual(HORIZON_QUEUE_CANDIDATE_LIMIT, horizon_count);
    // The bootstrap batch includes azimuthally distributed outer-horizon
    // seeds instead of spending every admission near the player.
    try std.testing.expect(max_horizon_dist_sq >= 400 * 400);
}

test "LOD scheduling advances horizon beyond existing nearest batch" {
    const allocator = std.testing.allocator;

    var regions: [LODLevel.count]RegionMap = undefined;
    for (&regions) |*region_map| region_map.* = RegionMap.init(allocator);
    defer {
        for (&regions) |*region_map| {
            var it = region_map.iterator();
            while (it.next()) |entry| {
                const chunk = entry.value_ptr.*;
                chunk.deinit(allocator);
                allocator.destroy(chunk);
            }
            region_map.deinit();
        }
    }

    var queues: [LODLevel.count]JobQueue = undefined;
    var queue_ptrs: [LODLevel.count]*JobQueue = undefined;
    for (&queues, 0..) |*queue, i| {
        queue.* = JobQueue.init(allocator);
        queue_ptrs[i] = queue;
    }
    defer for (&queues) |*queue| queue.deinit();

    var config = LODConfig{
        .chunk_render_radius = 16,
        .radii = .{ 64, 128, 256, 384, 512 },
    };
    const config_iface = config.interface();
    var mutex: sync.RwLock = .{};
    var next_job_token: u32 = 1;
    var radius_reduction = [_]i32{0} ** LODLevel.count;
    var coverage_ctx: u8 = 0;
    const Coverage = struct {
        fn neverCovered(_: *anyopaque, _: LODChunk.WorldBounds, _: ChunkChecker, _: *anyopaque) bool {
            return false;
        }
    };
    const ctx = SchedulerContext{
        .allocator = allocator,
        .config = config_iface,
        .radii = config_iface.getRadii(),
        .active_lod_count = lod_chunk.activeLODCount(config_iface),
        .regions = &regions,
        .gen_queues = &queue_ptrs,
        .mutex = &mutex,
        .player_cx = 0,
        .player_cz = 0,
        .next_job_token = &next_job_token,
        .cleanup_covered_regions = false,
        .coverage_ptr = &coverage_ctx,
        .are_all_chunks_loaded = Coverage.neverCovered,
        .radius_reduction = &radius_reduction,
    };

    try queueLODRegions(ctx, .lod4, Vec3.zero, null, null);
    try std.testing.expectEqual(HORIZON_QUEUE_CANDIDATE_LIMIT, queue_ptrs[LODLevel.count - 1].count());

    try queueLODRegions(ctx, .lod4, Vec3.zero, null, null);
    try std.testing.expectEqual(HORIZON_QUEUE_CANDIDATE_LIMIT * 2, queue_ptrs[LODLevel.count - 1].count());
}

test "LOD scheduling biases priorities toward movement direction" {
    const velocity = Vec3.init(10, 0, 0);
    const ahead = encodePriority(.lod2, 10, 0, velocity, LODLevel.count) & 0x0FFFFFFF;
    const behind = encodePriority(.lod2, -10, 0, velocity, LODLevel.count) & 0x0FFFFFFF;
    const stationary_ahead = encodePriority(.lod2, 10, 0, Vec3.zero, LODLevel.count) & 0x0FFFFFFF;
    const stationary_behind = encodePriority(.lod2, -10, 0, Vec3.zero, LODLevel.count) & 0x0FFFFFFF;

    try std.testing.expect(ahead < behind);
    try std.testing.expectEqual(stationary_ahead, stationary_behind);
}
