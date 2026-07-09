//! Save manager - background thread orchestrating chunk serialization and region file writes.
//!
//! Ties together the region file format (region_file.zig) and chunk serializer
//! (chunk_serializer.zig) into a working save/load system. Manages a background
//! save thread, dirty chunk tracking, and auto-save intervals.

const std = @import("std");
const Allocator = std.mem.Allocator;
const engine_core = @import("engine-core");
const log = engine_core.log;
const fs = @import("fs");
const sync = @import("sync");
const timestampMs = engine_core.timestampMs;
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const ChunkKey = world_core.ChunkKey;
const RegionFile = @import("region_file.zig").RegionFile;
const chunk_serializer = @import("chunk_serializer.zig");
const LevelData = @import("level_data.zig").LevelData;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;
const PackedLight = world_core.PackedLight;
const CHUNK_VOLUME = world_core.CHUNK_VOLUME;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;

const ChunkKeyContext = struct {
    pub fn hash(self: @This(), key: ChunkKey) u64 {
        _ = self;
        return key.hash();
    }

    pub fn eql(self: @This(), a: ChunkKey, b: ChunkKey) bool {
        _ = self;
        return a.eql(b);
    }
};

const QueueIndexMap = std.HashMap(ChunkKey, usize, ChunkKeyContext, std.hash_map.default_max_load_percentage);

const SAVE_THREAD_INTERVAL_NS: u64 = 25 * std.time.ns_per_ms;
const AUTO_SAVE_INTERVAL_MS: i64 = 60_000;
const MAX_OPEN_REGIONS: usize = 16;
const SAVE_FAILURE_COUNT_FILE = "save_failures.dat";

pub const LoadResult = enum {
    success,
    success_relight_required,
    not_found,
    read_error,
    corrupt_data,
};

pub const SaveQueueEntry = struct {
    chunk_x: i32,
    chunk_z: i32,
    blocks: [CHUNK_VOLUME]BlockType,
    light: [CHUNK_VOLUME]PackedLight,
    biomes: [CHUNK_SIZE_X * CHUNK_SIZE_Z]BiomeId,
    heightmap: [CHUNK_SIZE_X * CHUNK_SIZE_Z]i16,
};

const RegionCacheEntry = struct {
    region_x: i32,
    region_z: i32,
    region: RegionFile,
    last_used_ms: i64,
};

pub const SaveManager = struct {
    allocator: Allocator,
    save_dir: fs.Dir,
    save_dir_path: []const u8,
    world_name: []const u8,

    queue_mutex: sync.Mutex,
    queue: std.ArrayListUnmanaged(SaveQueueEntry),
    queue_index: QueueIndexMap,
    running: std.atomic.Value(bool),
    pending_saves: std.atomic.Value(usize),

    failed_mutex: sync.Mutex,
    failed_chunks: std.ArrayListUnmanaged(ChunkKey),
    failed_save_count: std.atomic.Value(usize),
    persisted_failed_save_count: std.atomic.Value(usize),
    persisted_failed_save_mutex: sync.Mutex,

    thread: std.Thread,

    region_cache_mutex: sync.Mutex,
    region_cache: std.ArrayListUnmanaged(RegionCacheEntry),

    level_data: LevelData,
    last_auto_save_ms: i64,

    pub fn init(allocator: Allocator, save_dir_path: []const u8, world_name: []const u8, seed: u64, generator_name: []const u8) !*SaveManager {
        var dir = try fs.cwd().makeOpenPath(save_dir_path, .{});
        errdefer dir.close();

        const sm = try allocator.create(SaveManager);
        errdefer allocator.destroy(sm);

        const name_copy = try allocator.dupe(u8, world_name);
        errdefer allocator.free(name_copy);

        const path_copy = try allocator.dupe(u8, save_dir_path);
        errdefer allocator.free(path_copy);

        const persisted_failures = loadPersistedSaveFailureCount(allocator, dir);

        sm.* = .{
            .allocator = allocator,
            .save_dir = dir,
            .save_dir_path = path_copy,
            .world_name = name_copy,
            .queue_mutex = .{},
            .queue = .empty,
            .queue_index = QueueIndexMap.init(allocator),
            .running = std.atomic.Value(bool).init(true),
            .pending_saves = std.atomic.Value(usize).init(0),
            .thread = undefined,
            .region_cache_mutex = .{},
            .region_cache = .empty,
            .failed_mutex = .{},
            .failed_chunks = .empty,
            .failed_save_count = std.atomic.Value(usize).init(0),
            .persisted_failed_save_count = std.atomic.Value(usize).init(persisted_failures),
            .persisted_failed_save_mutex = .{},
            .level_data = LevelData.loadFromFile(allocator, dir) catch |err| switch (err) {
                error.FileNotFound => blk: {
                    const generator_copy = try allocator.dupe(u8, generator_name);
                    errdefer allocator.free(generator_copy);
                    break :blk LevelData.init(seed, generator_copy);
                },
                else => return err,
            },
            .last_auto_save_ms = timestampMs(),
        };

        try sm.level_data.saveToFile(allocator, sm.save_dir);

        try dir.makePath("regions");

        sm.thread = try std.Thread.spawn(.{}, saveThreadFn, .{sm});

        log.log.info("SaveManager initialized for world '{s}' at '{s}'", .{ world_name, save_dir_path });
        return sm;
    }

    pub fn deinit(self: *SaveManager) void {
        _ = self.flush();

        self.running.store(false, .release);
        self.thread.join();

        self.flushRegionCache();

        self.level_data.touchLastPlayed();
        self.level_data.saveToFile(self.allocator, self.save_dir) catch |err| {
            log.log.err("Failed to save level.dat: {}", .{err});
            self.recordSaveFailure();
        };

        self.queue.deinit(self.allocator);
        self.queue_index.deinit();
        self.failed_chunks.deinit(self.allocator);

        self.save_dir.close();

        self.level_data.deinit(self.allocator);
        self.allocator.free(self.world_name);
        self.allocator.free(self.save_dir_path);
        self.allocator.destroy(self);
    }

    pub fn enqueueSave(self: *SaveManager, chunk: *const Chunk) void {
        std.debug.assert(chunk.pin_count.load(.acquire) > 0);

        const snapshot = SaveQueueEntry{
            .chunk_x = chunk.chunk_x,
            .chunk_z = chunk.chunk_z,
            .blocks = chunk.blocks,
            .light = chunk.light,
            .biomes = chunk.biomes,
            .heightmap = chunk.heightmap,
        };

        self.queue_mutex.lock();
        defer self.queue_mutex.unlock();

        const key = ChunkKey{ .x = snapshot.chunk_x, .z = snapshot.chunk_z };
        if (self.queue_index.get(key)) |idx| {
            if (idx < self.queue.items.len) {
                self.queue.items[idx] = snapshot;
                return;
            }
            _ = self.queue_index.remove(key);
        }

        self.queue.append(self.allocator, snapshot) catch |err| {
            log.log.err("Failed to enqueue chunk ({}, {}) for save: {}", .{ snapshot.chunk_x, snapshot.chunk_z, err });
            self.recordSaveFailure();
            return;
        };
        self.queue_index.put(key, self.queue.items.len - 1) catch |err| {
            log.log.err("Failed to index queued chunk ({}, {}) for save: {}", .{ snapshot.chunk_x, snapshot.chunk_z, err });
            _ = self.queue.pop();
            self.recordSaveFailure();
        };
    }

    pub fn loadChunk(self: *SaveManager, cx: i32, cz: i32, out_chunk: *Chunk) LoadResult {
        const rx: i32 = @divFloor(cx, 32);
        const rz: i32 = @divFloor(cz, 32);

        self.region_cache_mutex.lock();
        var region = self.getOrOpenRegion(rx, rz) catch |err| {
            self.region_cache_mutex.unlock();
            log.log.debug("No saved chunk at ({}, {}): region error: {}", .{ cx, cz, err });
            return .not_found;
        };

        const local_x: u5 = @intCast(@mod(cx, 32));
        const local_z: u5 = @intCast(@mod(cz, 32));

        if (!region.hasChunk(local_x, local_z)) {
            self.region_cache_mutex.unlock();
            return .not_found;
        }

        const data = region.readChunk(local_x, local_z, self.allocator) catch |err| {
            self.region_cache_mutex.unlock();
            log.log.err("Failed to read chunk ({}, {}) from region: {}", .{ cx, cz, err });
            return .read_error;
        };
        self.region_cache_mutex.unlock();
        defer self.allocator.free(data);

        chunk_serializer.deserializeChunk(data, out_chunk) catch |err| {
            log.log.err("Failed to deserialize chunk ({}, {}): {}", .{ cx, cz, err });
            return .corrupt_data;
        };

        out_chunk.chunk_x = cx;
        out_chunk.chunk_z = cz;
        out_chunk.generated = true;

        if (self.level_data.lighting_algorithm_version != LevelData.CURRENT_LIGHTING_ALGORITHM_VERSION) {
            for (&out_chunk.light) |*light| light.* = PackedLight.init(0, 0);
            out_chunk.markLightChanged();
            self.level_data.lighting_algorithm_version = LevelData.CURRENT_LIGHTING_ALGORITHM_VERSION;
            log.log.info("Discarded stale derived lighting while loading chunk ({}, {})", .{ cx, cz });
            return .success_relight_required;
        }

        log.log.debug("Loaded chunk ({}, {}) from save", .{ cx, cz });
        return .success;
    }

    pub fn shouldAutoSave(self: *const SaveManager) bool {
        const now = timestampMs();
        return (now - self.last_auto_save_ms) >= AUTO_SAVE_INTERVAL_MS;
    }

    pub fn markAutoSaved(self: *SaveManager) void {
        self.last_auto_save_ms = timestampMs();
    }

    pub fn flush(self: *SaveManager) []ChunkKey {
        var spins: u32 = 0;
        while (spins < 12000) : (spins += 1) {
            self.queue_mutex.lock();
            const count = self.queue.items.len;
            self.queue_mutex.unlock();
            const saving = self.pending_saves.load(.acquire);
            if (count == 0 and saving == 0) break;
            std.Options.debug_io.sleep(.fromNanoseconds(2 * std.time.ns_per_ms), .boot) catch {};
        }

        self.failed_mutex.lock();
        const failed = self.failed_chunks.items;
        self.failed_chunks = .empty;
        self.failed_mutex.unlock();
        return failed;
    }

    pub fn takeFailedSaveCount(self: *SaveManager) usize {
        return self.failed_save_count.swap(0, .acq_rel);
    }

    pub fn takePersistedFailedSaveCount(self: *SaveManager) usize {
        self.persisted_failed_save_mutex.lock();
        defer self.persisted_failed_save_mutex.unlock();

        const count = self.persisted_failed_save_count.swap(0, .acq_rel);
        if (count > 0) {
            self.save_dir.deleteFile(SAVE_FAILURE_COUNT_FILE) catch |err| {
                log.log.warn("Failed to clear persisted save failure count: {}", .{err});
            };
        }
        return count;
    }

    fn recordSaveFailure(self: *SaveManager) void {
        _ = self.failed_save_count.fetchAdd(1, .monotonic);
        self.persisted_failed_save_mutex.lock();
        defer self.persisted_failed_save_mutex.unlock();

        const persisted_count = self.persisted_failed_save_count.load(.acquire) + 1;
        self.persisted_failed_save_count.store(persisted_count, .release);
        persistSaveFailureCount(self.save_dir, persisted_count) catch |err| {
            log.log.err("Failed to persist save failure count: {}", .{err});
        };
    }

    fn saveThreadFn(self: *SaveManager) void {
        log.log.debug("Save thread started", .{});

        while (self.running.load(.acquire)) {
            // On error, treat as "no work done" so the loop sleeps before
            // retrying — otherwise a persistent fault (e.g. disk full) would
            // busy-loop at 100% CPU and spam the log.
            const did_work = self.processSaveQueue() catch |err| blk: {
                log.log.err("Save thread error: {}", .{err});
                break :blk false;
            };
            // Only idle-sleep when there is nothing to do. Previously the thread
            // slept a full interval between every batch, so flushing N dirty
            // chunks on exit took ceil(N/64)*interval. Draining back-to-back
            // collapses that to the actual IO/compression cost.
            if (!did_work) {
                std.Options.debug_io.sleep(.fromNanoseconds(SAVE_THREAD_INTERVAL_NS), .boot) catch {};
            }
        }

        _ = self.processSaveQueue() catch |err| blk: {
            log.log.err("Save thread final flush error: {}", .{err});
            break :blk false;
        };

        log.log.debug("Save thread exiting", .{});
    }

    fn processSaveQueue(self: *SaveManager) !bool {
        var batch: [64]SaveQueueEntry = undefined;

        self.queue_mutex.lock();
        const count = @min(self.queue.items.len, batch.len);
        if (count == 0) {
            self.queue_mutex.unlock();
            return false;
        }
        log.log.debug("Save thread processing {} chunks", .{count});
        @memcpy(batch[0..count], self.queue.items[0..count]);

        const remaining_count = self.queue.items.len - count;
        try self.queue_index.ensureTotalCapacity(@intCast(remaining_count));

        var remaining = std.ArrayListUnmanaged(SaveQueueEntry).empty;
        errdefer remaining.deinit(self.allocator);
        if (remaining_count > 0) {
            try remaining.appendSlice(self.allocator, self.queue.items[count..]);
        }
        self.queue.deinit(self.allocator);
        self.queue = remaining;
        remaining = .empty;
        self.rebuildQueueIndexLocked();
        self.pending_saves.store(count, .release);
        self.queue_mutex.unlock();

        for (batch[0..count]) |entry| {
            self.saveOneChunk(&entry) catch |err| {
                log.log.err("Failed to save chunk ({}, {}): {}", .{ entry.chunk_x, entry.chunk_z, err });
                self.recordSaveFailure();
                self.failed_mutex.lock();
                self.failed_chunks.append(self.allocator, .{ .x = entry.chunk_x, .z = entry.chunk_z }) catch |append_err| {
                    log.log.err("Failed to track failed chunk save ({}, {}): {}", .{ entry.chunk_x, entry.chunk_z, append_err });
                    self.recordSaveFailure();
                };
                self.failed_mutex.unlock();
            };
        }
        self.pending_saves.store(0, .release);
        return true;
    }

    fn rebuildQueueIndexLocked(self: *SaveManager) void {
        self.queue_index.clearRetainingCapacity();
        for (self.queue.items, 0..) |entry, idx| {
            self.queue_index.putAssumeCapacity(.{ .x = entry.chunk_x, .z = entry.chunk_z }, idx);
        }
    }

    fn saveOneChunk(self: *SaveManager, entry: *const SaveQueueEntry) !void {
        var chunk = Chunk.init(entry.chunk_x, entry.chunk_z);
        chunk.blocks = entry.blocks;
        chunk.light = entry.light;
        chunk.biomes = entry.biomes;
        chunk.heightmap = entry.heightmap;
        chunk.generated = true;

        const serialized = chunk_serializer.serializeChunk(&chunk, self.allocator) catch |err| {
            log.log.err("Failed to serialize chunk ({}, {}): {}", .{ entry.chunk_x, entry.chunk_z, err });
            return err;
        };
        defer self.allocator.free(serialized);

        const rx: i32 = @divFloor(entry.chunk_x, 32);
        const rz: i32 = @divFloor(entry.chunk_z, 32);

        self.region_cache_mutex.lock();
        defer self.region_cache_mutex.unlock();

        var region = try self.getOrOpenRegion(rx, rz);

        const local_x: u5 = @intCast(@mod(entry.chunk_x, 32));
        const local_z: u5 = @intCast(@mod(entry.chunk_z, 32));

        region.writeChunk(local_x, local_z, serialized) catch |err| {
            log.log.err("Failed to write chunk ({}, {}) to region ({}, {}): {}", .{ entry.chunk_x, entry.chunk_z, rx, rz, err });
            return err;
        };

        log.log.debug("Saved chunk ({}, {}) to region ({}, {})", .{ entry.chunk_x, entry.chunk_z, rx, rz });
    }

    fn getOrOpenRegion(self: *SaveManager, rx: i32, rz: i32) !*RegionFile {
        const now_ms = timestampMs();

        for (self.region_cache.items) |*entry| {
            if (entry.region_x == rx and entry.region_z == rz) {
                entry.last_used_ms = now_ms;
                return &entry.region;
            }
        }

        if (self.region_cache.items.len >= MAX_OPEN_REGIONS) {
            self.evictOldestRegion();
        }

        var rel_buf: [fs.max_path_bytes]u8 = undefined;
        const region_filename = std.fmt.bufPrint(&rel_buf, "regions/r.{}.{}.mca", .{ rx, rz }) catch unreachable;

        const region = blk: {
            var abs_buf: [fs.max_path_bytes]u8 = undefined;
            if (self.save_dir.realpath(region_filename, &abs_buf)) |abs_path| {
                break :blk try RegionFile.open(self.allocator, abs_path);
            } else |_| {
                const file = self.save_dir.createFile(region_filename, .{ .read = true, .exclusive = true }) catch |err| {
                    if (err == error.PathAlreadyExists) {
                        const abs_path = try self.save_dir.realpath(region_filename, &abs_buf);
                        break :blk try RegionFile.open(self.allocator, abs_path);
                    }
                    return err;
                };
                file.close();
                break :blk try RegionFile.create(self.allocator, try self.save_dir.realpath(region_filename, &abs_buf));
            }
        };

        try self.region_cache.append(self.allocator, .{
            .region_x = rx,
            .region_z = rz,
            .region = region,
            .last_used_ms = now_ms,
        });

        return &self.region_cache.items[self.region_cache.items.len - 1].region;
    }

    fn evictOldestRegion(self: *SaveManager) void {
        if (self.region_cache.items.len == 0) return;

        var oldest_idx: usize = 0;
        var oldest_ts: i64 = self.region_cache.items[0].last_used_ms;
        for (self.region_cache.items[1..], 1..) |entry, i| {
            if (entry.last_used_ms < oldest_ts) {
                oldest_ts = entry.last_used_ms;
                oldest_idx = i;
            }
        }

        self.region_cache.items[oldest_idx].region.close();
        _ = self.region_cache.orderedRemove(oldest_idx);
    }

    fn flushRegionCache(self: *SaveManager) void {
        for (self.region_cache.items) |*entry| {
            entry.region.close();
        }
        self.region_cache.deinit(self.allocator);
    }
};

fn loadPersistedSaveFailureCount(allocator: Allocator, save_dir: fs.Dir) usize {
    const content = save_dir.readFileAlloc(SAVE_FAILURE_COUNT_FILE, allocator, 128) catch return 0;
    defer allocator.free(content);
    return std.fmt.parseInt(usize, std.mem.trim(u8, content, " \t\r\n"), 10) catch 0;
}

fn persistSaveFailureCount(save_dir: fs.Dir, count: usize) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{}\n", .{count});
    const file = try save_dir.createFile(SAVE_FAILURE_COUNT_FILE, .{});
    defer file.close();
    try file.writeAll(text);
}

const testing = std.testing;

test "SaveManager init creates save directory and level.dat" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var save_path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/test_world", .{base_path});

    var sm = try SaveManager.init(testing.allocator, save_path, "test_world", 42, "overworld");
    defer sm.deinit();

    const file = dir.openFile("test_world/level.dat", .{}) catch {
        try testing.expect(false);
        return;
    };
    file.close();
}

test "SaveManager enqueue and flush processes chunks" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var save_path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/test_flush", .{base_path});

    var sm = try SaveManager.init(testing.allocator, save_path, "test_flush", 99, "flat");
    defer sm.deinit();

    var chunk = Chunk.init(5, -3);
    chunk.setBlock(8, 64, 8, .stone);
    chunk.setBiome(0, 0, .forest);
    chunk.generated = true;
    chunk.pin();

    sm.enqueueSave(&chunk);
    chunk.unpin();
    _ = sm.flush();

    var loaded = Chunk.init(5, -3);
    try testing.expect(sm.loadChunk(5, -3, &loaded) == .success);
    try testing.expectEqual(BlockType.stone, loaded.getBlock(8, 64, 8));
    try testing.expectEqual(BiomeId.forest, loaded.getBiome(0, 0));
}

test "SaveManager loadChunk returns false for non-existent chunk" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var save_path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/test_load_miss", .{base_path});

    var sm = try SaveManager.init(testing.allocator, save_path, "test_load_miss", 0, "overworld");
    defer sm.deinit();

    var chunk = Chunk.init(100, 200);
    try testing.expect(sm.loadChunk(100, 200, &chunk) == .not_found);
}

test "SaveManager duplicate enqueue overwrites previous" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var save_path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/test_dup", .{base_path});

    var sm = try SaveManager.init(testing.allocator, save_path, "test_dup", 0, "flat");
    defer sm.deinit();

    var chunk1 = Chunk.init(0, 0);
    chunk1.setBlock(5, 5, 5, .dirt);
    chunk1.pin();

    var chunk2 = Chunk.init(0, 0);
    chunk2.setBlock(5, 5, 5, .gold_ore);
    chunk2.pin();

    sm.enqueueSave(&chunk1);
    chunk1.unpin();
    sm.enqueueSave(&chunk2);
    chunk2.unpin();
    _ = sm.flush();

    var loaded = Chunk.init(0, 0);
    try testing.expect(sm.loadChunk(0, 0, &loaded) == .success);
    try testing.expectEqual(BlockType.gold_ore, loaded.getBlock(5, 5, 5));
}

test "SaveManager persists and consumes save failure count" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };

    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const base_path = try dir.realpath(".", &path_buf);

    var save_path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_path = try std.fmt.bufPrint(&save_path_buf, "{s}/test_failures", .{base_path});

    {
        var sm = try SaveManager.init(testing.allocator, save_path, "test_failures", 0, "flat");
        sm.recordSaveFailure();
        try testing.expectEqual(@as(usize, 1), sm.takeFailedSaveCount());
        sm.deinit();
    }

    var sm = try SaveManager.init(testing.allocator, save_path, "test_failures", 0, "flat");
    defer sm.deinit();

    try testing.expectEqual(@as(usize, 1), sm.takePersistedFailedSaveCount());
    try testing.expectEqual(@as(usize, 0), sm.takePersistedFailedSaveCount());
}
