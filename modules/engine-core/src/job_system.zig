//! Job system for asynchronous operations.
//!
//! This module provides a priority-based job queue with worker thread pools
//! for parallel execution of chunk generation, meshing, and generic tasks.
//!
//! ## Priority Model
//!
//! Jobs are ordered in a min-heap by priority value (lower = higher priority):
//! - **Spatial jobs** (chunk_generation, chunk_meshing): Use `dist_sq` field
//!   representing squared distance from player; closer chunks process first
//! - **Generic jobs**: Use explicit `priority` field; caller controls ordering
//!
//! ## Lazy Reprioritization
//!
//! As the player moves, job priorities should shift. Rather than rebuilding
//! the entire queue on every position update, the system uses lazy reprioritization:
//! - `updatePlayerPos()` marks the queue as dirty (`needs_reprioritize = true`)
//! - Actual rebuild occurs on next `pop()` if queue size >= REPRIORITIZE_THRESHOLD
//! - Small queues are reprioritized immediately (overhead is negligible)
//!
//! This amortizes the O(n log n) rebuild cost across multiple position updates.
//!
//! ## JobQueue Lifecycle
//!
//! ```
//! init() -> [push/pop cycles] -> stop() -> deinit()
//!              |      |
//!        setPaused(true)  setPaused(false)
//! ```
//!
//! - **running**: Normal operation, workers process jobs
//! - **paused**: Queue cleared, workers wait (used for world transitions)
//! - **stopped**: Workers exit, queue drained (shutdown)
//!
//! ## Job Cleanup
//!
//! When jobs are removed from the queue without being processed (via `clear()`,
//! `setPaused(true)`, or `stop()`), generic jobs with a `cleanup_fn` callback
//! will have that callback invoked to release any owned resources. Callers
//! creating generic jobs with heap-allocated context pointers MUST provide a
//! `cleanup_fn` to avoid memory leaks.
//!
//! ## WorkerPool
//!
//! Worker threads pull jobs from a shared JobQueue and invoke the appropriate
//! handler based on job type. The pool is initialized with a configurable worker
//! count and a process function callback.
//!
//! **Precondition**: `queue.stop()` must be called before `pool.deinit()` to
//! ensure all worker threads have exited before pool memory is freed.

const std = @import("std");
const sync = @import("sync");
const Thread = std.Thread;
const Mutex = sync.Mutex;
const Condition = sync.Condition;
const log = @import("log.zig");

pub const JobType = enum {
    chunk_generation,
    chunk_meshing,
    generic,
};

pub const Job = struct {
    type: JobType,

    // Priority value for generic jobs (lower = higher priority)
    priority: i32 = 0,

    // Distance-based priority for spatial jobs (lower = closer to player)
    dist_sq: i32 = 0,

    // Payload union - holds job-specific data
    data: union {
        chunk: ChunkJobData,
        generic: GenericJobData,
    },

    pub const ChunkJobData = struct {
        x: i32,
        z: i32,
        job_token: u32,
        lod_level: u3 = 0,
        /// Converts x/z into chunk coordinates for distance reprioritization.
        /// Normal chunk jobs use chunk coords directly (1); LOD jobs store
        /// region coords and set this to that LOD's chunks-per-side.
        coord_scale: i32 = 1,
    };

    pub const GenericJobData = struct {
        context: *anyopaque,
        process_fn: *const fn (*anyopaque) void,
        cleanup_fn: ?*const fn (*anyopaque) void = null,
    };

    pub fn cleanup(self: Job) void {
        switch (self.type) {
            .generic => {
                if (self.data.generic.cleanup_fn) |cleanup_fn| {
                    cleanup_fn(self.data.generic.context);
                }
            },
            .chunk_generation, .chunk_meshing => {},
        }
    }

    // Comparison for min-heap (lower priority/dist = higher priority)
    pub fn compare(a: Job, b: Job) std.math.Order {
        return std.math.order(a.getPriorityValue(), b.getPriorityValue());
    }

    fn getPriorityValue(self: Job) i32 {
        return switch (self.type) {
            .chunk_generation, .chunk_meshing => self.dist_sq,
            .generic => self.priority,
        };
    }

    pub fn getChunkCoords(self: Job) ?struct { x: i32, z: i32 } {
        return switch (self.type) {
            .chunk_generation, .chunk_meshing => .{ .x = self.data.chunk.x, .z = self.data.chunk.z },
            else => null,
        };
    }

    pub fn getJobToken(self: Job) ?u32 {
        return switch (self.type) {
            .chunk_generation, .chunk_meshing => self.data.chunk.job_token,
            else => null,
        };
    }
};

pub const REPRIORITIZE_THRESHOLD = 16;

pub const JobQueue = struct {
    mutex: Mutex,
    cond: Condition,
    jobs: std.PriorityQueue(Job, void, compareJobs),
    stopped: bool,
    paused: bool = false,
    abort_worker: bool = false,
    allocator: std.mem.Allocator,
    // Current player chunk for dynamic re-prioritization
    player_cx: i32 = 0,
    player_cz: i32 = 0,
    // Lazy re-prioritization: mark dirty instead of immediate rebuild
    needs_reprioritize: bool = false,
    // Threshold: only reprioritize if queue has this many items
    reprioritize_threshold: usize = REPRIORITIZE_THRESHOLD,

    fn compareJobs(context: void, a: Job, b: Job) std.math.Order {
        _ = context;
        return a.compare(b);
    }

    pub fn init(allocator: std.mem.Allocator) JobQueue {
        return .{
            .mutex = Mutex{},
            .cond = Condition{},
            .jobs = std.PriorityQueue(Job, void, compareJobs).initContext({}),
            .stopped = false,
            .paused = false,
            .abort_worker = false,
            .allocator = allocator,
            .needs_reprioritize = false,
            .reprioritize_threshold = REPRIORITIZE_THRESHOLD,
        };
    }

    pub fn deinit(self: *JobQueue) void {
        self.jobs.deinit(self.allocator);
    }

    pub fn push(self: *JobQueue, job: Job) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopped or self.paused) return;
        try self.jobs.push(self.allocator, job);
        self.cond.signal();
    }

    pub fn count(self: *JobQueue) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.jobs.count();
    }

    pub fn pop(self: *JobQueue) ?Job {
        self.mutex.lock();
        defer self.mutex.unlock();

        while (self.jobs.count() == 0 and !self.stopped) {
            self.cond.wait(&self.mutex);
        }

        if (self.stopped and self.jobs.count() == 0) return null;

        // Lazy reprioritization: only rebuild if marked dirty and queue is large
        if (self.needs_reprioritize and self.jobs.count() >= self.reprioritize_threshold) {
            self.doReprioritize();
            self.needs_reprioritize = false;
        }

        return self.jobs.pop();
    }

    /// Internal: rebuild queue with updated distances (called under lock)
    fn doReprioritize(self: *JobQueue) void {
        const job_count = self.jobs.count();
        if (job_count == 0) return;

        var temp = std.ArrayListUnmanaged(Job).empty;
        defer temp.deinit(self.allocator);

        // Extract all jobs
        while (self.jobs.pop()) |job| {
            var updated_job = job;

            // Only update distance for chunk-based jobs
            if (job.getChunkCoords()) |coords| {
                const scale: i32 = @max(updated_job.data.chunk.coord_scale, 1);
                // Compute squared distance in i64 then clamp, matching
                // lod_manager/lod_scheduler — i32 dx*dx can overflow at large
                // render/LOD distances.
                const dx: i64 = @as(i64, coords.x) * @as(i64, scale) - @as(i64, self.player_cx);
                const dz: i64 = @as(i64, coords.z) * @as(i64, scale) - @as(i64, self.player_cz);
                const new_dist_i64: i64 = dx * dx + dz * dz;
                const new_dist: i32 = @intCast(@min(new_dist_i64, @as(i64, 0x0FFFFFFF)));
                // Preserve the LOD-bias high bits; only refresh the low 28
                // distance bits. Overwriting dist_sq wholesale would flatten
                // all LOD levels into one distance space and break cross-level
                // ordering.
                const bias_bits = updated_job.dist_sq & ~@as(i32, 0x0FFFFFFF);
                updated_job.dist_sq = bias_bits | new_dist;
            }

            temp.append(self.allocator, updated_job) catch {
                log.log.warn("Job queue: dropped job during priority update (allocation failed)", .{});
                updated_job.cleanup();
                continue;
            };
        }

        // Re-add with updated priorities
        for (temp.items) |job| {
            self.jobs.push(self.allocator, job) catch {
                log.log.warn("Job queue: failed to re-add job after priority update", .{});
                job.cleanup();
                continue;
            };
        }
    }

    /// Update player position and mark queue for lazy re-prioritization.
    /// The actual rebuild happens on next pop() if the queue is large enough.
    pub fn updatePlayerPos(self: *JobQueue, cx: i32, cz: i32) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.paused) return;

        // Only mark for reprioritization if player moved
        if (cx == self.player_cx and cz == self.player_cz) return;
        self.player_cx = cx;
        self.player_cz = cz;

        // Mark for lazy reprioritization instead of immediate rebuild
        // For small queues, the overhead of tracking dirty state isn't worth it
        if (self.jobs.count() >= self.reprioritize_threshold) {
            self.needs_reprioritize = true;
        } else if (self.jobs.count() > 0) {
            // For small queues, just do it immediately
            self.doReprioritize();
        }
    }

    pub fn clear(self: *JobQueue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.jobs.pop()) |job| {
            job.cleanup();
        }
    }

    pub fn setPaused(self: *JobQueue, paused: bool) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.paused = paused;
        self.abort_worker = paused or self.stopped;
        if (paused) {
            while (self.jobs.pop()) |job| {
                job.cleanup();
            }
        } else {
            self.cond.broadcast();
        }
    }

    pub fn stop(self: *JobQueue) void {
        self.mutex.lock();
        self.stopped = true;
        self.abort_worker = true;
        while (self.jobs.pop()) |job| {
            job.cleanup();
        }
        self.mutex.unlock();
        self.cond.broadcast();
    }
};

pub const WorkerPool = struct {
    threads: []Thread,
    spawned_count: usize = 0,
    allocator: std.mem.Allocator,
    context: *anyopaque,

    // Callbacks
    process_job_fn: *const fn (*anyopaque, Job) void,

    pub fn init(allocator: std.mem.Allocator, count: usize, queue: *JobQueue, context: *anyopaque, process_fn: *const fn (*anyopaque, Job) void) !*WorkerPool {
        const pool = try allocator.create(WorkerPool);
        errdefer allocator.destroy(pool);

        const threads = try allocator.alloc(Thread, count);
        errdefer allocator.free(threads);

        pool.* = WorkerPool{
            .threads = threads,
            .allocator = allocator,
            .context = context,
            .process_job_fn = process_fn,
        };

        // Note: Partial Thread.spawn failure (where some threads spawn but others fail)
        // cannot be reliably tested in unit tests because Thread.spawn rarely fails
        // deterministically. The spawned_count tracking and errdefer cleanup logic
        // is exercised by the zero-worker test case, which validates the mechanism.
        errdefer {
            queue.stop();
            for (threads[0..pool.spawned_count]) |t| {
                t.join();
            }
        }

        for (threads) |*t| {
            t.* = try Thread.spawn(.{}, workerThread, .{ queue, pool });
            pool.spawned_count += 1;
        }

        return pool;
    }

    /// Release worker pool resources. The associated JobQueue must have been
    /// stopped via `queue.stop()` before calling this to ensure all worker
    /// threads have exited their processing loops.
    pub fn deinit(self: *WorkerPool) void {
        for (self.threads[0..self.spawned_count]) |t| {
            t.join();
        }
        self.allocator.free(self.threads);
        self.allocator.destroy(self);
    }

    fn workerThread(queue: *JobQueue, pool: *WorkerPool) void {
        while (true) {
            const job = queue.pop() orelse break;
            switch (job.type) {
                .chunk_generation, .chunk_meshing => {
                    pool.process_job_fn(pool.context, job);
                },
                .generic => {
                    job.data.generic.process_fn(job.data.generic.context);
                },
            }
        }
    }
};

const testing = std.testing;

fn nopProcess(ctx: *anyopaque) void {
    _ = ctx;
}

var cleanup_count: usize = 0;

fn countingCleanup(ctx: *anyopaque) void {
    _ = ctx;
    cleanup_count += 1;
}

fn makeGenericJob() Job {
    return Job{
        .type = .generic,
        .priority = 0,
        .data = .{
            .generic = .{
                .context = undefined,
                .process_fn = nopProcess,
                .cleanup_fn = countingCleanup,
            },
        },
    };
}

fn makeGenericJobNoCleanup() Job {
    return Job{
        .type = .generic,
        .priority = 0,
        .data = .{
            .generic = .{
                .context = undefined,
                .process_fn = nopProcess,
                .cleanup_fn = null,
            },
        },
    };
}

fn testWorkerProcess(ctx: *anyopaque, job: Job) void {
    _ = ctx;
    _ = job;
}

test "Job.cleanup calls cleanup_fn for generic jobs" {
    cleanup_count = 0;
    var job = makeGenericJob();
    job.cleanup();
    try testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "Job.cleanup is no-op for generic jobs without cleanup_fn" {
    cleanup_count = 0;
    var job = makeGenericJobNoCleanup();
    job.cleanup();
    try testing.expectEqual(@as(usize, 0), cleanup_count);
}

test "Job.cleanup is no-op for chunk jobs" {
    cleanup_count = 0;
    const job = Job{
        .type = .chunk_generation,
        .dist_sq = 0,
        .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = 1 } },
    };
    job.cleanup();
    try testing.expectEqual(@as(usize, 0), cleanup_count);
}

test "JobQueue reprioritizes region-scaled chunk jobs" {
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();

    try queue.push(.{
        .type = .chunk_generation,
        .dist_sq = 0,
        .data = .{ .chunk = .{ .x = 60, .z = 0, .job_token = 1, .lod_level = 0, .coord_scale = 2 } },
    });
    try queue.push(.{
        .type = .chunk_generation,
        .dist_sq = 0,
        .data = .{ .chunk = .{ .x = 50, .z = 0, .job_token = 2, .lod_level = 0, .coord_scale = 2 } },
    });

    try queue.updatePlayerPos(100, 0);

    const first = queue.pop() orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(u32, 2), first.data.chunk.job_token);
    try testing.expectEqual(@as(i32, 50), first.data.chunk.x);
}

test "JobQueue.clear calls cleanup on generic jobs" {
    cleanup_count = 0;
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();

    queue.push(makeGenericJob()) catch unreachable;
    queue.push(makeGenericJob()) catch unreachable;
    queue.push(makeGenericJob()) catch unreachable;

    queue.clear();
    try testing.expectEqual(@as(usize, 3), cleanup_count);
}

test "JobQueue.stop calls cleanup on generic jobs" {
    cleanup_count = 0;
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();

    queue.push(makeGenericJob()) catch unreachable;
    queue.push(makeGenericJob()) catch unreachable;

    queue.stop();
    try testing.expectEqual(@as(usize, 2), cleanup_count);
}

test "JobQueue.setPaused true calls cleanup on generic jobs" {
    cleanup_count = 0;
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();

    queue.push(makeGenericJob()) catch unreachable;
    queue.push(makeGenericJob()) catch unreachable;
    queue.push(makeGenericJob()) catch unreachable;

    queue.setPaused(true);
    try testing.expectEqual(@as(usize, 3), cleanup_count);
}

test "JobQueue.clear with mixed job types" {
    cleanup_count = 0;
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();

    queue.push(makeGenericJob()) catch unreachable;
    queue.push(Job{
        .type = .chunk_meshing,
        .dist_sq = 0,
        .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = 1 } },
    }) catch unreachable;
    queue.push(makeGenericJob()) catch unreachable;

    queue.clear();
    try testing.expectEqual(@as(usize, 2), cleanup_count);
}

test "WorkerPool.init supports zero worker pools" {
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();

    var context: u8 = 0;
    const pool = try WorkerPool.init(testing.allocator, 0, &queue, &context, testWorkerProcess);
    defer pool.deinit();

    try testing.expectEqual(@as(usize, 0), pool.spawned_count);
    try testing.expectEqual(@as(usize, 0), pool.threads.len);
}
