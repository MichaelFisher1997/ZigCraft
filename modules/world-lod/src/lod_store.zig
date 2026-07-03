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
        return err;
    };
    region.close();

    fs.cwd().rename(tmp_path, path) catch |err| {
        fs.cwd().deleteFile(tmp_path) catch {};
        return err;
    };
}

pub fn deletePayload(allocator: std.mem.Allocator, save_dir_path: []const u8, key: lod_cache.Key) void {
    const path = containerPath(allocator, save_dir_path, key) catch return;
    defer allocator.free(path);

    var region = RegionFile.open(allocator, path) catch return;
    defer region.close();
    region.deleteChunk(localCoord(key.rx), localCoord(key.rz)) catch {};
}

const testing = std.testing;

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
    try testing.expect(std.mem.indexOf(u8, bytes, "\"lod_data_version\": 2") != null);
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
