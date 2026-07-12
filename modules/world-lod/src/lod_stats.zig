//! LOD system statistics and aggregation helpers.

const std = @import("std");
const MonotonicTimer = @import("engine-core").time.MonotonicTimer;
const lod_types = @import("lod_types.zig");
const LODLevel = lod_types.LODLevel;
const LODState = lod_types.LODState;

/// Read-only, cumulative LOD profiling data. CPU durations measure only
/// instrumented CPU work; they are not GPU timings or GPU-memory accounting.
pub const LODProfilingSnapshot = struct {
    enabled: bool = false,
    update_ms: f64 = 0,
    scheduling_ms: f64 = 0,
    /// Cumulative dedicated cache-worker CPU/I/O time. This is intentionally
    /// not update-thread blocking time; frame work only queues and drains.
    cache_ms: f64 = 0,
    generation_dispatch_ms: f64 = 0,
    state_transition_ms: f64 = 0,
    upload_prep_ms: f64 = 0,
    upload_submission_ms: f64 = 0,
    visibility_ms: f64 = 0,
    coverage_ms: f64 = 0,
    eviction_ms: f64 = 0,
    worker_generation_ms: f64 = 0,
    worker_mesh_construction_ms: f64 = 0,
    upload_bytes: u64 = 0,
    pending_cpu_upload_bytes: u64 = 0,
    /// Upload-budget deferrals plus RHI upload-pressure errors.
    staging_pressure_count: u64 = 0,
    visible_count: u64 = 0,
    rejected_count: u64 = 0,
    coverage_count: u64 = 0,
    /// Per-LOD visibility projection telemetry. These counters are cumulative
    /// and count a region once, even when terrain and water are both drawn.
    visibility_levels: [LODLevel.count]LODVisibilityLevelSnapshot = [_]LODVisibilityLevelSnapshot{.{}} ** LODLevel.count,
    /// Known CPU vertex-capacity bytes retained by meshes awaiting deletion.
    /// GPU pool allocations are deliberately not reported because they are not
    /// available through the current RHI/LOD pool interface.
    deferred_deletion_bytes: u64 = 0,
    wait_idle_count: u64 = 0,
    wait_idle_ms: f64 = 0,
};

pub const LODVisibilityLevelSnapshot = struct {
    candidates: u64 = 0,
    accepted: u64 = 0,
    rejected_no_draw: u64 = 0,
    rejected_not_ready: u64 = 0,
    rejected_missing_region: u64 = 0,
    rejected_not_renderable: u64 = 0,
    rejected_finer_coverage: u64 = 0,
    rejected_range: u64 = 0,
    rejected_frustum: u64 = 0,
    rejected_chunk_coverage: u64 = 0,
    coverage_checks: u64 = 0,
};

const LODVisibilityLevelCounters = struct {
    candidates: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    accepted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_no_draw: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_not_ready: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_missing_region: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_not_renderable: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_finer_coverage: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_range: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_frustum: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rejected_chunk_coverage: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    coverage_checks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    fn add(self: *LODVisibilityLevelCounters, value: LODVisibilityLevelSnapshot) void {
        inline for (std.meta.fields(LODVisibilityLevelSnapshot)) |field| {
            const amount = @field(value, field.name);
            if (amount != 0) _ = @field(self, field.name).fetchAdd(amount, .monotonic);
        }
    }

    fn reset(self: *LODVisibilityLevelCounters) void {
        inline for (std.meta.fields(LODVisibilityLevelSnapshot)) |field| {
            @field(self, field.name).store(0, .monotonic);
        }
    }

    fn snapshot(self: *const LODVisibilityLevelCounters) LODVisibilityLevelSnapshot {
        var result = LODVisibilityLevelSnapshot{};
        inline for (std.meta.fields(LODVisibilityLevelSnapshot)) |field| {
            @field(result, field.name) = @field(self, field.name).load(.monotonic);
        }
        return result;
    }
};

/// Thread-safe backing store for an `LODProfilingSnapshot`.
///
/// Profiling is enabled once when an LOD manager is initialized. All timing
/// methods return before touching a clock when disabled, while worker updates
/// use atomics so they never race snapshot collection on the update thread.
pub const LODProfilingCollector = struct {
    const AtomicU64 = std.atomic.Value(u64);

    pub const TimerKind = enum {
        update,
        scheduling,
        cache,
        generation_dispatch,
        state_transition,
        upload_prep,
        upload_submission,
        visibility,
        coverage,
        eviction,
        worker_generation,
        worker_mesh_construction,
        wait_idle,
    };

    enabled: bool = false,
    update_ns: AtomicU64 = AtomicU64.init(0),
    scheduling_ns: AtomicU64 = AtomicU64.init(0),
    cache_ns: AtomicU64 = AtomicU64.init(0),
    generation_dispatch_ns: AtomicU64 = AtomicU64.init(0),
    state_transition_ns: AtomicU64 = AtomicU64.init(0),
    upload_prep_ns: AtomicU64 = AtomicU64.init(0),
    upload_submission_ns: AtomicU64 = AtomicU64.init(0),
    visibility_ns: AtomicU64 = AtomicU64.init(0),
    coverage_ns: AtomicU64 = AtomicU64.init(0),
    eviction_ns: AtomicU64 = AtomicU64.init(0),
    worker_generation_ns: AtomicU64 = AtomicU64.init(0),
    worker_mesh_construction_ns: AtomicU64 = AtomicU64.init(0),
    wait_idle_ns: AtomicU64 = AtomicU64.init(0),
    upload_bytes: AtomicU64 = AtomicU64.init(0),
    pending_cpu_upload_bytes: AtomicU64 = AtomicU64.init(0),
    staging_pressure_count: AtomicU64 = AtomicU64.init(0),
    visible_count: AtomicU64 = AtomicU64.init(0),
    rejected_count: AtomicU64 = AtomicU64.init(0),
    coverage_count: AtomicU64 = AtomicU64.init(0),
    visibility_levels: [LODLevel.count]LODVisibilityLevelCounters = [_]LODVisibilityLevelCounters{.{}} ** LODLevel.count,
    deferred_deletion_bytes: AtomicU64 = AtomicU64.init(0),
    wait_idle_count: AtomicU64 = AtomicU64.init(0),

    pub fn init(enabled: bool) LODProfilingCollector {
        return .{ .enabled = enabled };
    }

    pub fn begin(self: *const LODProfilingCollector) ?MonotonicTimer {
        if (!self.enabled) return null;
        return MonotonicTimer.start();
    }

    pub fn end(self: *LODProfilingCollector, kind: TimerKind, timer: ?MonotonicTimer) void {
        const elapsed = timer orelse return;
        _ = self.counterFor(kind).fetchAdd(elapsed.read(), .monotonic);
    }

    pub fn add(self: *LODProfilingCollector, counter: *AtomicU64, value: u64) void {
        if (!self.enabled or value == 0) return;
        _ = counter.fetchAdd(value, .monotonic);
    }

    pub fn addUploadBytes(self: *LODProfilingCollector, bytes: usize) void {
        self.add(&self.upload_bytes, @intCast(bytes));
    }

    pub fn setPendingCpuUploadBytes(self: *LODProfilingCollector, bytes: usize) void {
        if (!self.enabled) return;
        self.pending_cpu_upload_bytes.store(@intCast(bytes), .monotonic);
    }

    pub fn addStagingPressure(self: *LODProfilingCollector) void {
        self.add(&self.staging_pressure_count, 1);
    }

    pub fn addVisible(self: *LODProfilingCollector) void {
        self.add(&self.visible_count, 1);
    }

    pub fn addRejected(self: *LODProfilingCollector) void {
        self.add(&self.rejected_count, 1);
    }

    pub fn addCoverage(self: *LODProfilingCollector) void {
        self.add(&self.coverage_count, 1);
    }

    pub fn addVisibilityLevel(self: *LODProfilingCollector, lod: LODLevel, value: LODVisibilityLevelSnapshot) void {
        if (!self.enabled) return;
        self.visibility_levels[@intFromEnum(lod)].add(value);
    }

    pub fn addDeferredDeletionBytes(self: *LODProfilingCollector, bytes: usize) void {
        self.add(&self.deferred_deletion_bytes, @intCast(bytes));
    }

    pub fn removeDeferredDeletionBytes(self: *LODProfilingCollector, bytes: usize) void {
        if (!self.enabled or bytes == 0) return;
        _ = self.deferred_deletion_bytes.fetchSub(@intCast(bytes), .monotonic);
    }

    pub fn addWaitIdle(self: *LODProfilingCollector) void {
        self.add(&self.wait_idle_count, 1);
    }

    /// Resets cumulative profiling counters. Concurrent worker completion may
    /// land immediately before or after this reset, but snapshots are always
    /// race-free and never contain torn values.
    pub fn reset(self: *LODProfilingCollector) void {
        inline for (.{
            &self.update_ns,              &self.scheduling_ns,           &self.cache_ns,
            &self.generation_dispatch_ns, &self.state_transition_ns,     &self.upload_prep_ns,
            &self.upload_submission_ns,   &self.visibility_ns,           &self.coverage_ns,
            &self.eviction_ns,            &self.worker_generation_ns,    &self.worker_mesh_construction_ns,
            &self.wait_idle_ns,           &self.upload_bytes,            &self.pending_cpu_upload_bytes,
            &self.staging_pressure_count, &self.visible_count,           &self.rejected_count,
            &self.coverage_count,         &self.deferred_deletion_bytes, &self.wait_idle_count,
        }) |counter| counter.store(0, .monotonic);
        for (&self.visibility_levels) |*level| level.reset();
    }

    pub fn snapshot(self: *const LODProfilingCollector) LODProfilingSnapshot {
        return .{
            .enabled = self.enabled,
            .update_ms = nsToMs(self.update_ns.load(.monotonic)),
            .scheduling_ms = nsToMs(self.scheduling_ns.load(.monotonic)),
            .cache_ms = nsToMs(self.cache_ns.load(.monotonic)),
            .generation_dispatch_ms = nsToMs(self.generation_dispatch_ns.load(.monotonic)),
            .state_transition_ms = nsToMs(self.state_transition_ns.load(.monotonic)),
            .upload_prep_ms = nsToMs(self.upload_prep_ns.load(.monotonic)),
            .upload_submission_ms = nsToMs(self.upload_submission_ns.load(.monotonic)),
            .visibility_ms = nsToMs(self.visibility_ns.load(.monotonic)),
            .coverage_ms = nsToMs(self.coverage_ns.load(.monotonic)),
            .eviction_ms = nsToMs(self.eviction_ns.load(.monotonic)),
            .worker_generation_ms = nsToMs(self.worker_generation_ns.load(.monotonic)),
            .worker_mesh_construction_ms = nsToMs(self.worker_mesh_construction_ns.load(.monotonic)),
            .upload_bytes = self.upload_bytes.load(.monotonic),
            .pending_cpu_upload_bytes = self.pending_cpu_upload_bytes.load(.monotonic),
            .staging_pressure_count = self.staging_pressure_count.load(.monotonic),
            .visible_count = self.visible_count.load(.monotonic),
            .rejected_count = self.rejected_count.load(.monotonic),
            .coverage_count = self.coverage_count.load(.monotonic),
            .visibility_levels = blk: {
                var levels: [LODLevel.count]LODVisibilityLevelSnapshot = undefined;
                for (&levels, 0..) |*level, index| level.* = self.visibility_levels[index].snapshot();
                break :blk levels;
            },
            .deferred_deletion_bytes = self.deferred_deletion_bytes.load(.monotonic),
            .wait_idle_count = self.wait_idle_count.load(.monotonic),
            .wait_idle_ms = nsToMs(self.wait_idle_ns.load(.monotonic)),
        };
    }

    fn counterFor(self: *LODProfilingCollector, kind: TimerKind) *AtomicU64 {
        return switch (kind) {
            .update => &self.update_ns,
            .scheduling => &self.scheduling_ns,
            .cache => &self.cache_ns,
            .generation_dispatch => &self.generation_dispatch_ns,
            .state_transition => &self.state_transition_ns,
            .upload_prep => &self.upload_prep_ns,
            .upload_submission => &self.upload_submission_ns,
            .visibility => &self.visibility_ns,
            .coverage => &self.coverage_ns,
            .eviction => &self.eviction_ns,
            .worker_generation => &self.worker_generation_ns,
            .worker_mesh_construction => &self.worker_mesh_construction_ns,
            .wait_idle => &self.wait_idle_ns,
        };
    }
};

fn nsToMs(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / @as(f64, std.time.ns_per_ms);
}

/// Statistics for LOD system monitoring.
pub const LODStats = struct {
    /// Cumulative opt-in CPU, upload, and pressure telemetry snapshot.
    profiling: LODProfilingSnapshot = .{},
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
    /// On-disk LOD source store counters. cache_* below are retained as
    /// compatibility aliases for existing diagnostics consumers.
    store_hits: u32 = 0,
    store_misses: u32 = 0,
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    evictions: u32 = 0,
    drawn: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    instances: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    fluid_drawn: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    fluid_instances: [LODLevel.count]u32 = [_]u32{0} ** LODLevel.count,
    ingestion_backlog: u32 = 0,
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
        self.profiling = .{};
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
        self.drawn = [_]u32{0} ** LODLevel.count;
        self.instances = [_]u32{0} ** LODLevel.count;
        self.fluid_drawn = [_]u32{0} ** LODLevel.count;
        self.fluid_instances = [_]u32{0} ** LODLevel.count;
        self.upgrades_pending = 0;
        self.downgrades_pending = 0;
        self.upload_failures = 0;
        self.ingestion_backlog = 0;
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
        const total = self.store_hits + self.store_misses;
        if (total == 0) return 0.0;
        return @as(f32, @floatFromInt(self.store_hits)) / @as(f32, @floatFromInt(total));
    }
};

test "LODStats reports cache hit rate" {
    var stats = LODStats{};
    try std.testing.expectEqual(@as(f32, 0.0), stats.cacheHitRate());

    stats.store_hits = 3;
    stats.store_misses = 1;
    try std.testing.expectEqual(@as(f32, 0.75), stats.cacheHitRate());
}

test "LOD profiling collector snapshots and resets cumulative counters" {
    var collector = LODProfilingCollector.init(true);
    collector.addUploadBytes(128);
    collector.setPendingCpuUploadBytes(64);
    collector.addVisible();
    collector.addRejected();
    collector.addCoverage();
    collector.addVisibilityLevel(.lod1, .{ .candidates = 3, .accepted = 1, .rejected_frustum = 1, .coverage_checks = 1 });
    collector.addDeferredDeletionBytes(32);
    collector.addWaitIdle();

    const snapshot = collector.snapshot();
    try std.testing.expect(snapshot.enabled);
    try std.testing.expectEqual(@as(u64, 128), snapshot.upload_bytes);
    try std.testing.expectEqual(@as(u64, 64), snapshot.pending_cpu_upload_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.visible_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.rejected_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.coverage_count);
    try std.testing.expectEqual(@as(u64, 3), snapshot.visibility_levels[1].candidates);
    try std.testing.expectEqual(@as(u64, 1), snapshot.visibility_levels[1].rejected_frustum);
    try std.testing.expectEqual(@as(u64, 32), snapshot.deferred_deletion_bytes);
    try std.testing.expectEqual(@as(u64, 1), snapshot.wait_idle_count);

    collector.reset();
    const reset_snapshot = collector.snapshot();
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.upload_bytes);
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.visible_count);
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.deferred_deletion_bytes);
    try std.testing.expectEqual(@as(u64, 0), reset_snapshot.visibility_levels[1].candidates);
}

test "disabled LOD profiling collector does not accumulate samples" {
    var collector = LODProfilingCollector.init(false);
    const timer = collector.begin();
    collector.end(.update, timer);
    collector.addUploadBytes(256);
    collector.addVisible();

    const snapshot = collector.snapshot();
    try std.testing.expect(!snapshot.enabled);
    try std.testing.expectEqual(@as(f64, 0), snapshot.update_ms);
    try std.testing.expectEqual(@as(u64, 0), snapshot.upload_bytes);
    try std.testing.expectEqual(@as(u64, 0), snapshot.visible_count);
}
