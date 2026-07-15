//! Persistent container store for serialized LOD source payloads.

const std = @import("std");
const fs = @import("fs");

const RegionFile = @import("world-persistence").RegionFile;
const lod_cache = @import("lod_cache.zig");

const REGION_GRID: i32 = 32;
pub const DEFAULT_STORE_SIZE_CAP_MB: u32 = 256;

pub const StoreHeader = struct {
    seed: u64,
    generator_identity_hash: u64,
    generator_version: u32,
    lod_data_version: u8 = lod_cache.CACHE_VERSION,
};

pub const StoreError = error{
    CorruptContainer,
    StoreSizeLimit,
};

pub fn headersMatch(a: StoreHeader, b: StoreHeader) bool {
    return a.seed == b.seed and
        a.generator_identity_hash == b.generator_identity_hash and
        a.generator_version == b.generator_version and
        a.lod_data_version == b.lod_data_version;
}

fn containerCoord(value: i32) i32 {
    return @divFloor(value, REGION_GRID);
}

fn localCoord(value: i32) u5 {
    return @intCast(@mod(value, REGION_GRID));
}

fn lodDirPath(allocator: std.mem.Allocator, save_dir_path: []const u8, lod: @import("lod_types.zig").LODLevel) ![]u8 {
    const lod_name = try std.fmt.allocPrint(allocator, "{}", .{@intFromEnum(lod)});
    defer allocator.free(lod_name);
    return fs.path.join(allocator, &.{ save_dir_path, "lod", lod_name });
}

pub fn containerPath(allocator: std.mem.Allocator, save_dir_path: []const u8, key: lod_cache.Key) ![]u8 {
    const dir_path = try lodDirPath(allocator, save_dir_path, key.lod);
    defer allocator.free(dir_path);
    const filename = try std.fmt.allocPrint(
        allocator,
        "r.{}.{}.zlod",
        .{ containerCoord(key.rx), containerCoord(key.rz) },
    );
    defer allocator.free(filename);
    return fs.path.join(allocator, &.{ dir_path, filename });
}

pub fn writeHeader(allocator: std.mem.Allocator, save_dir_path: []const u8, header: StoreHeader) !void {
    const lod_root = try fs.path.join(allocator, &.{ save_dir_path, "lod" });
    defer allocator.free(lod_root);
    try fs.cwd().makePath(lod_root);

    const path = try fs.path.join(allocator, &.{ lod_root, "store.json" });
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    const bytes = try std.fmt.allocPrint(
        allocator,
        "{{\n  \"seed\": {},\n  \"generator_identity_hash\": {},\n  \"generator_version\": {},\n  \"lod_data_version\": {}\n}}\n",
        .{ header.seed, header.generator_identity_hash, header.generator_version, header.lod_data_version },
    );
    defer allocator.free(bytes);

    const file = try fs.cwd().createFile(tmp_path, .{ .truncate = true });
    file.writeAll(bytes) catch |err| {
        file.close();
        fs.cwd().deleteFile(tmp_path) catch {};
        return err;
    };
    file.close();
    fs.cwd().rename(tmp_path, path) catch |err| {
        fs.cwd().deleteFile(tmp_path) catch {};
        return err;
    };
}

pub fn readHeader(allocator: std.mem.Allocator, save_dir_path: []const u8) !?StoreHeader {
    const path = try fs.path.join(allocator, &.{ save_dir_path, "lod", "store.json" });
    defer allocator.free(path);

    const bytes = fs.cwd().readFileAlloc(path, allocator, 4096) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(bytes);

    const parsed = try std.json.parseFromSlice(StoreHeader, allocator, bytes, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return parsed.value;
}

pub fn deleteStore(allocator: std.mem.Allocator, save_dir_path: []const u8) !void {
    const lod_root = try fs.path.join(allocator, &.{ save_dir_path, "lod" });
    defer allocator.free(lod_root);

    fs.cwd().access(lod_root, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try fs.cwd().deleteTree(lod_root);
}

pub fn readPayload(allocator: std.mem.Allocator, save_dir_path: []const u8, key: lod_cache.Key) !?[]u8 {
    const path = try containerPath(allocator, save_dir_path, key);
    defer allocator.free(path);

    var region = RegionFile.open(allocator, path) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return StoreError.CorruptContainer,
    };
    defer region.close();

    return region.readChunk(localCoord(key.rx), localCoord(key.rz), allocator) catch |err| switch (err) {
        error.ChunkNotFound => return null,
        else => return err,
    };
}

fn storeSizeCapBytes(cap_mb: u32) usize {
    return @as(usize, @max(cap_mb, 1)) * 1024 * 1024;
}

const ContainerCandidate = struct {
    path: []u8,
    mtime_ns: i96,
};

const StoreUsage = struct {
    total_size: u64 = 0,
    oldest_candidate: ?ContainerCandidate = null,
};

fn isActiveLodDirectory(name: []const u8) bool {
    const lod_index = std.fmt.parseInt(u8, name, 10) catch return false;
    return lod_index < @import("lod_types.zig").LODLevel.count;
}

fn isOlderContainer(candidate: ContainerCandidate, path: []const u8, mtime_ns: i96) bool {
    return mtime_ns < candidate.mtime_ns or
        (mtime_ns == candidate.mtime_ns and std.mem.order(u8, path, candidate.path) == .lt);
}

/// Returns the total size of all LOD containers and the oldest removable one.
///
/// This only retains one candidate path, so eviction memory use remains bounded
/// regardless of how many containers are on disk. Files that cannot be opened
/// or statted are skipped; malformed region contents need not be parsed to
/// account for their on-disk size.
fn scanStoreUsage(allocator: std.mem.Allocator, lod_root: []const u8, protected_path: []const u8) !StoreUsage {
    var usage = StoreUsage{};
    errdefer if (usage.oldest_candidate) |candidate| allocator.free(candidate.path);

    var root_dir = fs.cwd().openDir(lod_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return usage,
        else => return err,
    };
    defer root_dir.close();

    var lod_iter = root_dir.iterate();
    while (true) {
        const maybe_lod_entry = try lod_iter.next();
        const lod_entry = maybe_lod_entry orelse break;
        if (lod_entry.kind != .directory or !isActiveLodDirectory(lod_entry.name)) continue;

        var lod_dir = root_dir.openDir(lod_entry.name, .{ .iterate = true }) catch continue;
        defer lod_dir.close();

        var container_iter = lod_dir.iterate();
        while (true) {
            const maybe_container_entry = try container_iter.next();
            const container_entry = maybe_container_entry orelse break;
            if (container_entry.kind != .file or !std.mem.endsWith(u8, container_entry.name, ".zlod")) continue;

            const file = lod_dir.openFile(container_entry.name, .{}) catch continue;
            const stat = file.stat() catch {
                file.close();
                continue;
            };
            file.close();

            usage.total_size +|= stat.size;
            const path = try fs.path.join(allocator, &.{ lod_root, lod_entry.name, container_entry.name });
            if (std.mem.eql(u8, path, protected_path)) {
                allocator.free(path);
                continue;
            }

            if (usage.oldest_candidate) |candidate| {
                if (!isOlderContainer(candidate, path, stat.mtime.nanoseconds)) {
                    allocator.free(path);
                    continue;
                }
                allocator.free(candidate.path);
            }
            usage.oldest_candidate = .{
                .path = path,
                .mtime_ns = stat.mtime.nanoseconds,
            };
        }
    }

    return usage;
}

/// Enforces the aggregate container limit after a successful atomic write.
/// The just-written container is never selected, even when it alone exceeds
/// the configured limit.
fn enforceStoreSizeCap(allocator: std.mem.Allocator, save_dir_path: []const u8, protected_path: []const u8, cap_mb: u32) !void {
    const lod_root = try fs.path.join(allocator, &.{ save_dir_path, "lod" });
    defer allocator.free(lod_root);
    const cap_bytes = storeSizeCapBytes(cap_mb);

    while (true) {
        const usage = try scanStoreUsage(allocator, lod_root, protected_path);
        defer if (usage.oldest_candidate) |candidate| allocator.free(candidate.path);
        if (usage.total_size <= cap_bytes) return;

        const candidate = usage.oldest_candidate orelse return;
        fs.cwd().deleteFile(candidate.path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
    }
}

fn writeCompactedContainer(allocator: std.mem.Allocator, path: []const u8, tmp_path: []const u8, key: lod_cache.Key, bytes: []const u8) !void {
    var region = RegionFile.create(allocator, tmp_path) catch |err| {
        fs.cwd().deleteFile(tmp_path) catch {};
        return err;
    };
    errdefer {
        region.close();
        fs.cwd().deleteFile(tmp_path) catch {};
    }

    var existing_region = try RegionFile.open(allocator, path);
    defer existing_region.close();
    const target_x = localCoord(key.rx);
    const target_z = localCoord(key.rz);
    for (0..REGION_GRID) |z| {
        for (0..REGION_GRID) |x| {
            const local_x: u5 = @intCast(x);
            const local_z: u5 = @intCast(z);
            if (local_x == target_x and local_z == target_z) continue;
            const existing = existing_region.readChunk(local_x, local_z, allocator) catch |err| switch (err) {
                error.ChunkNotFound => continue,
                else => return err,
            };
            region.writeChunk(local_x, local_z, existing) catch |err| {
                allocator.free(existing);
                return err;
            };
            allocator.free(existing);
        }
    }

    region.writeChunk(target_x, target_z, bytes) catch |err| {
        if (err == error.FileTooShort) return StoreError.StoreSizeLimit;
        return err;
    };
    region.close();
}

pub fn writePayload(allocator: std.mem.Allocator, save_dir_path: []const u8, key: lod_cache.Key, bytes: []const u8, store_size_cap_mb: u32) !void {
    const dir_path = try lodDirPath(allocator, save_dir_path, key.lod);
    defer allocator.free(dir_path);
    try fs.cwd().makePath(dir_path);

    const path = try containerPath(allocator, save_dir_path, key);
    defer allocator.free(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);
    fs.cwd().deleteFile(tmp_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };

    const use_existing = blk: {
        var existing_region = RegionFile.open(allocator, path) catch |err| switch (err) {
            error.FileNotFound => break :blk false,
            else => break :blk false,
        };
        existing_region.close();
        break :blk true;
    };

    var force_compaction = false;
    // Recover boundedly from a store created by an older implementation that
    // allowed one container to grow beyond the aggregate cap.
    if (use_existing) {
        const existing_file = try fs.cwd().openFile(path, .{});
        const existing_stat = existing_file.stat() catch |err| {
            existing_file.close();
            return err;
        };
        existing_file.close();
        if (existing_stat.size > storeSizeCapBytes(store_size_cap_mb)) {
            force_compaction = true;
        }
    }

    if (force_compaction) {
        try writeCompactedContainer(allocator, path, tmp_path, key, bytes);
    } else {
        if (use_existing) {
            const existing = try fs.cwd().readFileAlloc(path, allocator, storeSizeCapBytes(store_size_cap_mb));
            defer allocator.free(existing);
            const tmp_file = try fs.cwd().createFile(tmp_path, .{ .truncate = true });
            tmp_file.writeAll(existing) catch |err| {
                tmp_file.close();
                fs.cwd().deleteFile(tmp_path) catch {};
                return err;
            };
            tmp_file.close();
        }

        var region = (if (use_existing)
            RegionFile.open(allocator, tmp_path)
        else
            RegionFile.create(allocator, tmp_path)) catch |err| {
            fs.cwd().deleteFile(tmp_path) catch {};
            return err;
        };
        region.writeChunk(localCoord(key.rx), localCoord(key.rz), bytes) catch |err| {
            region.close();
            fs.cwd().deleteFile(tmp_path) catch {};
            if (err == error.FileTooShort) return StoreError.StoreSizeLimit;
            return err;
        };
        region.close();
    }

    var completed_tmp = try fs.cwd().openFile(tmp_path, .{});
    var completed_stat = completed_tmp.stat() catch |err| {
        completed_tmp.close();
        fs.cwd().deleteFile(tmp_path) catch {};
        return err;
    };
    completed_tmp.close();
    if (completed_stat.size > storeSizeCapBytes(store_size_cap_mb) and use_existing and !force_compaction) {
        // Sector growth crossed the cap. Rebuild only live entries on the
        // cache worker, then re-check before atomically replacing the source.
        try fs.cwd().deleteFile(tmp_path);
        try writeCompactedContainer(allocator, path, tmp_path, key, bytes);
        completed_tmp = try fs.cwd().openFile(tmp_path, .{});
        completed_stat = completed_tmp.stat() catch |err| {
            completed_tmp.close();
            fs.cwd().deleteFile(tmp_path) catch {};
            return err;
        };
        completed_tmp.close();
    }
    if (completed_stat.size > storeSizeCapBytes(store_size_cap_mb)) {
        fs.cwd().deleteFile(tmp_path) catch {};
        // Keep an in-budget previous atomic container. Legacy oversized
        // containers are discarded because they cannot satisfy the new bound.
        if (force_compaction) fs.cwd().deleteFile(path) catch {};
        try enforceStoreSizeCap(allocator, save_dir_path, path, store_size_cap_mb);
        return StoreError.StoreSizeLimit;
    }

    fs.cwd().rename(tmp_path, path) catch |err| {
        fs.cwd().deleteFile(tmp_path) catch {};
        return err;
    };

    try enforceStoreSizeCap(allocator, save_dir_path, path, store_size_cap_mb);
}

pub fn deletePayload(allocator: std.mem.Allocator, save_dir_path: []const u8, key: lod_cache.Key) void {
    const path = containerPath(allocator, save_dir_path, key) catch return;
    defer allocator.free(path);

    var region = RegionFile.open(allocator, path) catch return;
    defer region.close();
    region.deleteChunk(localCoord(key.rx), localCoord(key.rz)) catch {};
}

const testing = std.testing;

fn fillPseudoRandom(bytes: []u8, initial_state: u64) void {
    var state = initial_state;
    for (bytes) |*byte| {
        state ^= state << 13;
        state ^= state >> 7;
        state ^= state << 17;
        byte.* = @truncate(state);
    }
}

test "LOD store round-trips payloads through region containers" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);

    const key = lod_cache.Key{ .seed = 11, .generator_identity_hash = 22, .generator_version = 3, .rx = 34, .rz = -1, .lod = .lod2 };
    try writePayload(testing.allocator, save_dir, key, "payload-a", DEFAULT_STORE_SIZE_CAP_MB);

    const loaded = (try readPayload(testing.allocator, save_dir, key)).?;
    defer testing.allocator.free(loaded);
    try testing.expectEqualStrings("payload-a", loaded);
}

test "LOD store overwrites existing payloads" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);

    const key = lod_cache.Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3, .rx = -32, .rz = 63, .lod = .lod1 };
    try writePayload(testing.allocator, save_dir, key, "small", DEFAULT_STORE_SIZE_CAP_MB);
    try writePayload(testing.allocator, save_dir, key, "larger replacement payload", DEFAULT_STORE_SIZE_CAP_MB);

    const loaded = (try readPayload(testing.allocator, save_dir, key)).?;
    defer testing.allocator.free(loaded);
    try testing.expectEqualStrings("larger replacement payload", loaded);
}

test "LOD store atomic overwrite preserves sibling entries" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);

    const key_a = lod_cache.Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3, .rx = 0, .rz = 0, .lod = .lod1 };
    const key_b = lod_cache.Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3, .rx = 1, .rz = 0, .lod = .lod1 };
    try writePayload(testing.allocator, save_dir, key_a, "payload-a", DEFAULT_STORE_SIZE_CAP_MB);
    try writePayload(testing.allocator, save_dir, key_b, "payload-b", DEFAULT_STORE_SIZE_CAP_MB);
    try writePayload(testing.allocator, save_dir, key_a, "payload-a-updated", DEFAULT_STORE_SIZE_CAP_MB);

    const loaded_a = (try readPayload(testing.allocator, save_dir, key_a)).?;
    defer testing.allocator.free(loaded_a);
    const loaded_b = (try readPayload(testing.allocator, save_dir, key_b)).?;
    defer testing.allocator.free(loaded_b);
    try testing.expectEqualStrings("payload-a-updated", loaded_a);
    try testing.expectEqualStrings("payload-b", loaded_b);
}

test "LOD store write replaces corrupt containers" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);
    const key = lod_cache.Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3, .rx = 0, .rz = 0, .lod = .lod1 };

    const path = try containerPath(testing.allocator, save_dir, key);
    defer testing.allocator.free(path);
    const parent = fs.path.dirname(path).?;
    try fs.cwd().makePath(parent);
    const file = try fs.cwd().createFile(path, .{ .truncate = true });
    try file.writeAll("bad");
    file.close();

    try writePayload(testing.allocator, save_dir, key, "replacement", DEFAULT_STORE_SIZE_CAP_MB);
    const loaded = (try readPayload(testing.allocator, save_dir, key)).?;
    defer testing.allocator.free(loaded);
    try testing.expectEqualStrings("replacement", loaded);
}

test "LOD store evicts old containers to enforce the total size cap" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);
    const header = StoreHeader{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3 };
    try writeHeader(testing.allocator, save_dir, header);

    const payload_size = 700 * 1024;
    const old_payload = try testing.allocator.alloc(u8, payload_size);
    defer testing.allocator.free(old_payload);
    const new_payload = try testing.allocator.alloc(u8, payload_size);
    defer testing.allocator.free(new_payload);
    fillPseudoRandom(old_payload, 0x123456789abcdef0);
    fillPseudoRandom(new_payload, 0xfedcba9876543210);

    const old_key = lod_cache.Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3, .rx = 0, .rz = 0, .lod = .lod1 };
    const new_key = lod_cache.Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3, .rx = 32, .rz = 0, .lod = .lod1 };
    try writePayload(testing.allocator, save_dir, old_key, old_payload, 1);
    try writePayload(testing.allocator, save_dir, new_key, new_payload, 1);

    try testing.expect((try readPayload(testing.allocator, save_dir, old_key)) == null);
    const retained = (try readPayload(testing.allocator, save_dir, new_key)).?;
    defer testing.allocator.free(retained);
    try testing.expectEqualSlices(u8, new_payload, retained);
    try testing.expect(headersMatch(header, (try readHeader(testing.allocator, save_dir)).?));
}

test "LOD store compacts live entries when sector growth reaches the cap" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);
    const old_payload = try testing.allocator.alloc(u8, 200 * 1024);
    defer testing.allocator.free(old_payload);
    const sibling_payload = try testing.allocator.alloc(u8, 200 * 1024);
    defer testing.allocator.free(sibling_payload);
    const replacement = try testing.allocator.alloc(u8, 600 * 1024);
    defer testing.allocator.free(replacement);
    fillPseudoRandom(old_payload, 0x1111111111111111);
    fillPseudoRandom(sibling_payload, 0x2222222222222222);
    fillPseudoRandom(replacement, 0x3333333333333333);

    const target_key = lod_cache.Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3, .rx = 0, .rz = 0, .lod = .lod1 };
    const sibling_key = lod_cache.Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3, .rx = 1, .rz = 0, .lod = .lod1 };
    try writePayload(testing.allocator, save_dir, target_key, old_payload, 1);
    try writePayload(testing.allocator, save_dir, sibling_key, sibling_payload, 1);
    try writePayload(testing.allocator, save_dir, target_key, replacement, 1);

    const loaded_target = (try readPayload(testing.allocator, save_dir, target_key)).?;
    defer testing.allocator.free(loaded_target);
    try testing.expectEqualSlices(u8, replacement, loaded_target);
    const loaded_sibling = (try readPayload(testing.allocator, save_dir, sibling_key)).?;
    defer testing.allocator.free(loaded_sibling);
    try testing.expectEqualSlices(u8, sibling_payload, loaded_sibling);
}

test "LOD store rejects a container larger than the aggregate cap" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);
    const payload = try testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer testing.allocator.free(payload);
    fillPseudoRandom(payload, 0x9e3779b97f4a7c15);

    const key = lod_cache.Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3, .rx = 0, .rz = 0, .lod = .lod1 };
    try testing.expectError(StoreError.StoreSizeLimit, writePayload(testing.allocator, save_dir, key, payload, 1));
    try testing.expect((try readPayload(testing.allocator, save_dir, key)) == null);
}

test "LOD store missing and corrupt containers are advisory misses" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);
    const key = lod_cache.Key{ .seed = 1, .generator_identity_hash = 2, .generator_version = 3, .rx = 0, .rz = 0, .lod = .lod1 };

    try testing.expect((try readPayload(testing.allocator, save_dir, key)) == null);

    const path = try containerPath(testing.allocator, save_dir, key);
    defer testing.allocator.free(path);
    const parent = fs.path.dirname(path).?;
    try fs.cwd().makePath(parent);
    const file = try fs.cwd().createFile(path, .{ .truncate = true });
    try file.writeAll("bad");
    file.close();

    try testing.expectError(StoreError.CorruptContainer, readPayload(testing.allocator, save_dir, key));
}

test "LOD store writes metadata header atomically" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);

    try writeHeader(testing.allocator, save_dir, .{ .seed = 123, .generator_identity_hash = 456, .generator_version = 7 });
    const header_path = try fs.path.join(testing.allocator, &.{ save_dir, "lod", "store.json" });
    defer testing.allocator.free(header_path);
    const bytes = try fs.cwd().readFileAlloc(header_path, testing.allocator, 4096);
    defer testing.allocator.free(bytes);

    try testing.expect(std.mem.indexOf(u8, bytes, "\"seed\": 123") != null);
    try testing.expect(std.mem.indexOf(u8, bytes, "\"lod_data_version\": 11") != null);
}

test "LOD store reads and deletes metadata store" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir = try dir.realpath(".", &path_buf);
    const header = StoreHeader{ .seed = 123, .generator_identity_hash = 456, .generator_version = 7 };

    try writeHeader(testing.allocator, save_dir, header);
    const loaded = (try readHeader(testing.allocator, save_dir)).?;
    try testing.expect(headersMatch(header, loaded));

    try deleteStore(testing.allocator, save_dir);
    try testing.expect((try readHeader(testing.allocator, save_dir)) == null);
}
