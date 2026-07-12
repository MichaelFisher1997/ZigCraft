//! Dedicated bounded cache I/O worker for LOD source data.
//!
//! This worker is deliberately separate from generation workers. The update
//! thread only snapshots/enqueues work and applies completions; all filesystem
//! access and cache serialization/deserialization happens on this one thread.

const std = @import("std");
const fs = @import("fs");
const sync = @import("sync");
const log = @import("engine-core").log;
const LODRegionKey = @import("lod_chunk.zig").LODRegionKey;
const LODSimplifiedData = @import("lod_chunk.zig").LODSimplifiedData;
const lod_cache = @import("lod_cache.zig");
const lod_store = @import("lod_store.zig");
const LODProfilingCollector = @import("lod_stats.zig").LODProfilingCollector;

pub const MAX_PENDING_TASKS: usize = 16;
const MAX_COMPLETIONS: usize = MAX_PENDING_TASKS + 1;

pub const ReadResult = union(enum) {
    hit: LODSimplifiedData,
    miss: void,
};

pub const Completion = union(enum) {
    read: struct {
        key: LODRegionKey,
        token: u32,
        result: ReadResult,
        used_legacy: bool,
    },
    write: struct {
        key: LODRegionKey,
        revision: u32,
        success: bool,
    },
};

const Task = union(enum) {
    read: struct {
        path: []u8,
        region_key: LODRegionKey,
        cache_key: lod_cache.Key,
        token: u32,
    },
    write: struct {
        path: []u8,
        region_key: LODRegionKey,
        cache_key: lod_cache.Key,
        revision: u32,
        data: LODSimplifiedData,
        store_size_cap_mb: u32,
    },
};

/// A single worker and two bounded queues. Completion ownership transfers to
/// the update thread, which must deinit hit data after applying or rejecting it.
pub const CacheIoPipeline = struct {
    allocator: std.mem.Allocator,
    profiling: *LODProfilingCollector,
    mutex: sync.Mutex = .{},
    work_ready: sync.Condition = .{},
    idle: sync.Condition = .{},
    tasks: std.ArrayListUnmanaged(Task) = .empty,
    completions: std.ArrayListUnmanaged(Completion) = .empty,
    stopping: bool = false,
    active: bool = false,
    thread: std.Thread,

    pub fn init(allocator: std.mem.Allocator, profiling: *LODProfilingCollector) !*CacheIoPipeline {
        const result = try allocator.create(CacheIoPipeline);
        errdefer allocator.destroy(result);
        result.* = .{
            .allocator = allocator,
            .profiling = profiling,
            .thread = undefined,
        };
        try result.tasks.ensureTotalCapacity(allocator, MAX_PENDING_TASKS);
        errdefer result.tasks.deinit(allocator);
        try result.completions.ensureTotalCapacity(allocator, MAX_COMPLETIONS);
        errdefer result.completions.deinit(allocator);
        result.thread = try std.Thread.spawn(.{}, workerMain, .{result});
        return result;
    }

    pub fn enqueueRead(self: *CacheIoPipeline, path: []const u8, region_key: LODRegionKey, cache_key: lod_cache.Key, token: u32) !bool {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping or self.tasks.items.len >= MAX_PENDING_TASKS) return false;
        self.tasks.appendAssumeCapacity(.{ .read = .{ .path = path_copy, .region_key = region_key, .cache_key = cache_key, .token = token } });
        self.work_ready.signal();
        return true;
    }

    /// Transfers ownership of `data` when accepted. Rejected snapshots remain
    /// owned by the caller so it can release them or retry later.
    pub fn enqueueWrite(self: *CacheIoPipeline, path: []const u8, region_key: LODRegionKey, cache_key: lod_cache.Key, revision: u32, data: LODSimplifiedData, store_size_cap_mb: u32) !bool {
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.stopping or self.tasks.items.len >= MAX_PENDING_TASKS) return false;
        self.tasks.appendAssumeCapacity(.{ .write = .{
            .path = path_copy,
            .region_key = region_key,
            .cache_key = cache_key,
            .revision = revision,
            .data = data,
            .store_size_cap_mb = store_size_cap_mb,
        } });
        self.work_ready.signal();
        return true;
    }

    /// Moves all available completions into `out`. The caller becomes owner of
    /// every read-hit payload in the returned list.
    pub fn drainCompletions(self: *CacheIoPipeline, out: *std.ArrayListUnmanaged(Completion)) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.completions.items.len > 0) {
            const completion = self.completions.items[0];
            out.append(self.allocator, completion) catch {
                // Allocation failure cannot strand a read request. Keep the
                // completion for a later update rather than dropping it.
                return;
            };
            _ = self.completions.orderedRemove(0);
        }
    }

    /// Explicit lifecycle operation only; never call from the frame path.
    pub fn waitUntilIdle(self: *CacheIoPipeline) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.tasks.items.len != 0 or self.active) self.idle.wait(&self.mutex);
    }

    /// Stops accepting work, drains accepted tasks, joins the sole worker, and
    /// releases queued completion payloads. This may block by design.
    pub fn deinit(self: *CacheIoPipeline) void {
        self.mutex.lock();
        self.stopping = true;
        self.work_ready.broadcast();
        self.mutex.unlock();
        self.thread.join();

        for (self.tasks.items) |*task| deinitTask(self.allocator, task);
        self.tasks.deinit(self.allocator);
        for (self.completions.items) |*completion| deinitCompletion(completion);
        self.completions.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    fn workerMain(self: *CacheIoPipeline) void {
        while (true) {
            self.mutex.lock();
            while (self.tasks.items.len == 0 and !self.stopping) self.work_ready.wait(&self.mutex);
            if (self.tasks.items.len == 0 and self.stopping) {
                self.idle.broadcast();
                self.mutex.unlock();
                return;
            }
            const task = self.tasks.orderedRemove(0);
            self.active = true;
            self.mutex.unlock();

            const completion = self.runTask(task);

            self.mutex.lock();
            // Capacity is guaranteed by the bounded work queue: at most one
            // active task plus MAX_PENDING_TASKS accepted tasks can complete.
            self.completions.appendAssumeCapacity(completion);
            self.active = false;
            if (self.tasks.items.len == 0) self.idle.broadcast();
            self.mutex.unlock();
        }
    }

    fn runTask(self: *CacheIoPipeline, task: Task) Completion {
        const timer = self.profiling.begin();
        defer self.profiling.end(.cache, timer);
        return switch (task) {
            .read => |read| blk: {
                defer self.allocator.free(read.path);
                const outcome = readData(self.allocator, read.path, read.cache_key);
                break :blk .{ .read = .{
                    .key = read.region_key,
                    .token = read.token,
                    .result = outcome.result,
                    .used_legacy = outcome.used_legacy,
                } };
            },
            .write => |write| blk: {
                defer self.allocator.free(write.path);
                var data = write.data;
                defer data.deinit();
                const bytes = lod_cache.serialize(&data, write.cache_key, self.allocator) catch |err| {
                    log.log.warn("Failed to serialize LOD{} cache ({}, {}): {}", .{ @intFromEnum(write.region_key.lod), write.region_key.rx, write.region_key.rz, err });
                    break :blk .{ .write = .{ .key = write.region_key, .revision = write.revision, .success = false } };
                };
                defer self.allocator.free(bytes);
                const success = blk_success: {
                    lod_store.writePayload(self.allocator, write.path, write.cache_key, bytes, write.store_size_cap_mb) catch |err| {
                        log.log.warn("Failed to write LOD{} store ({}, {}): {}", .{ @intFromEnum(write.region_key.lod), write.region_key.rx, write.region_key.rz, err });
                        break :blk_success false;
                    };
                    break :blk_success true;
                };
                break :blk .{ .write = .{ .key = write.region_key, .revision = write.revision, .success = success } };
            },
        };
    }
};

const ReadDataOutcome = struct {
    result: ReadResult,
    used_legacy: bool = false,
};

fn readData(allocator: std.mem.Allocator, path: []const u8, key: lod_cache.Key) ReadDataOutcome {
    const payload = lod_store.readPayload(allocator, path, key) catch |err| switch (err) {
        lod_store.StoreError.CorruptContainer => {
            const container_path = lod_store.containerPath(allocator, path, key) catch return .{ .result = .miss };
            defer allocator.free(container_path);
            log.log.warn("Discarding corrupt LOD store container '{s}'", .{container_path});
            fs.cwd().deleteFile(container_path) catch |delete_err| {
                if (delete_err != error.FileNotFound) log.log.warn("Failed to delete corrupt LOD store container '{s}': {}", .{ container_path, delete_err });
            };
            return .{ .result = .miss };
        },
        else => {
            log.log.warn("Failed to read LOD store for LOD{} ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
            return .{ .result = .miss };
        },
    };
    if (payload) |bytes| {
        defer allocator.free(bytes);
        const data = lod_cache.deserialize(bytes, key, allocator) catch |err| {
            log.log.warn("Discarding corrupt LOD store payload LOD{} ({}, {}): {}", .{ @intFromEnum(key.lod), key.rx, key.rz, err });
            lod_store.deletePayload(allocator, path, key);
            return .{ .result = .miss };
        };
        return .{ .result = .{ .hit = data } };
    }

    const legacy_path = std.fmt.allocPrint(allocator, "{s}/lod_cache/lod_{}_{}_{}_{}_{}_{}.dat", .{ path, key.seed, key.generator_identity_hash, key.generator_version, key.rx, key.rz, @intFromEnum(key.lod) }) catch return .{ .result = .miss };
    defer allocator.free(legacy_path);
    const bytes = fs.cwd().readFileAlloc(legacy_path, allocator, 16 * 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{ .result = .miss },
        else => {
            log.log.warn("Failed to read legacy LOD cache '{s}': {}", .{ legacy_path, err });
            return .{ .result = .miss };
        },
    };
    defer allocator.free(bytes);
    const data = lod_cache.deserialize(bytes, key, allocator) catch |err| {
        log.log.warn("Discarding corrupt legacy LOD cache '{s}': {}", .{ legacy_path, err });
        fs.cwd().deleteFile(legacy_path) catch |delete_err| {
            if (delete_err != error.FileNotFound) log.log.warn("Failed to delete corrupt legacy LOD cache '{s}': {}", .{ legacy_path, delete_err });
        };
        return .{ .result = .miss, .used_legacy = true };
    };
    return .{ .result = .{ .hit = data }, .used_legacy = true };
}

fn deinitTask(allocator: std.mem.Allocator, task: *Task) void {
    switch (task.*) {
        .read => |read| allocator.free(read.path),
        .write => |*write| {
            allocator.free(write.path);
            write.data.deinit();
        },
    }
}

fn deinitCompletion(completion: *Completion) void {
    switch (completion.*) {
        .read => |*read| switch (read.result) {
            .hit => |*data| data.deinit(),
            .miss => {},
        },
        .write => {},
    }
}
