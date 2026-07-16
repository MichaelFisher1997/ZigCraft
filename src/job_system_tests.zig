//! Regression tests for engine-core job_system.
//!
//! These live under src/ (rather than alongside modules/engine-core/src/
//! job_system.zig) because Zig 0.16 lazy compilation does not collect test
//! blocks from module sub-files reached only through namespace references
//! like `_ = @import("engine-core").job_system;`. Importing the public API
//! types into a local src/ test file forces analysis and ensures these
//! regressions actually execute under `zig build test`.

const std = @import("std");
const testing = std.testing;
const engine_core = @import("engine-core");
const Job = engine_core.Job;
const JobQueue = engine_core.JobQueue;
const JobType = engine_core.JobType;

// --- Test helpers -----------------------------------------------------------

var test_cleanup_count: usize = 0;

fn testNopProcess(ctx: *anyopaque) void {
    _ = ctx;
}

fn testCountingCleanup(ctx: *anyopaque) void {
    _ = ctx;
    test_cleanup_count += 1;
}

fn makeCountingCleanupJob() Job {
    return Job{
        .type = .generic,
        .priority = 0,
        .data = .{
            .generic = .{
                .context = undefined,
                .process_fn = testNopProcess,
                .cleanup_fn = testCountingCleanup,
            },
        },
    };
}

// --- Regression tests for the doReprioritize double-cleanup fix ------------

test "Job.cleanup nullifies cleanup_fn to prevent double-cleanup" {
    // Regression for the doReprioritize OOM double-cleanup issue: after
    // cleanup() runs, cleanup_fn must be cleared so any subsequent call
    // (e.g. if the same Job value is later re-added and the queue is
    // drained) is a no-op rather than a double-free.
    test_cleanup_count = 0;
    var job = makeCountingCleanupJob();
    job.cleanup();
    try testing.expectEqual(@as(usize, 1), test_cleanup_count);
    try testing.expect(job.data.generic.cleanup_fn == null);
    // Subsequent cleanup must not re-invoke the cleanup function.
    job.cleanup();
    try testing.expectEqual(@as(usize, 1), test_cleanup_count);
}

test "Job.cleanup idempotency survives queue drain after OOM-style drop" {
    // Simulates the doReprioritize OOM pattern at the Job level: a job is
    // dropped via the OOM catch arm (cleanup invoked), then the same Job
    // value is later re-added to a queue that is drained via stop(). With
    // the fix, cleanup_fn is null after the first cleanup, so the queue
    // drain must not trigger a second invocation.
    test_cleanup_count = 0;
    var job = makeCountingCleanupJob();

    // Emulate the doReprioritize OOM drop: cleanup is invoked on the job
    // that failed to be re-added.
    job.cleanup();
    try testing.expectEqual(@as(usize, 1), test_cleanup_count);

    // The caller still holds the (now-cleaned) Job value and re-adds it.
    // Without the fix, cleanup_fn would still be set here.
    try testing.expect(job.data.generic.cleanup_fn == null);

    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();
    queue.push(job) catch unreachable;

    // Draining the queue must not double-invoke cleanup.
    queue.stop();
    try testing.expectEqual(@as(usize, 1), test_cleanup_count);
}

test "JobQueue.stop calls cleanup exactly once per generic job" {
    test_cleanup_count = 0;
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();

    queue.push(makeCountingCleanupJob()) catch unreachable;
    queue.push(makeCountingCleanupJob()) catch unreachable;

    queue.stop();
    try testing.expectEqual(@as(usize, 2), test_cleanup_count);
}

test "Job.cleanup is no-op for chunk jobs (signature change)" {
    // Sanity check that the *Job signature change for cleanup() compiles
    // and works for chunk-type jobs (which have no cleanup_fn).
    test_cleanup_count = 0;
    var job = Job{
        .type = .chunk_generation,
        .dist_sq = 0,
        .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = 1 } },
    };
    job.cleanup();
    try testing.expectEqual(@as(usize, 0), test_cleanup_count);
}

test "JobQueue retains explicit bootstrap priorities" {
    var queue = JobQueue.init(testing.allocator);
    defer queue.deinit();

    try queue.push(.{
        .type = .chunk_generation,
        .dist_sq = 7,
        .data = .{ .chunk = .{ .x = 100, .z = 0, .job_token = 1, .preserve_priority = true } },
    });
    try queue.updatePlayerPos(100, 0);

    const job = queue.pop() orelse return error.TestExpectedEqual;
    try testing.expectEqual(@as(i32, 7), job.dist_sq);
}
