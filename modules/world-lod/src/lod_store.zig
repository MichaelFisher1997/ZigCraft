//! Persistent container store for serialized LOD source payloads.

const std = @import("std");
const fs = @import("fs");

const RegionFile = @import("world-persistence").RegionFile;
const lod_cache = @import("lod_cache.zig");

const REGION_GRID: i32 = 32;

pub const StoreHeader = struct {
    seed: u64,
    generator_identity_hash: u64,
    generator_version: u32,
    lod_data_version: u8 = lod_cache.CACHE_VERSION,
};

pub const StoreError = error{
    CorruptContainer,
};

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

pub fn writePayload(allocator: std.mem.Allocator, save_dir_path: []const u8, key: lod_cache.Key, bytes: []const u8) !void {
    const dir_path = try lodDirPath(allocator, save_dir_path, key.lod);
    defer allocator.free(dir_path);
    try fs.cwd().makePath(dir_path);

    const path = try containerPath(allocator, save_dir_path, key);
    defer allocator.free(path);

    var region = RegionFile.open(allocator, path) catch |err| switch (err) {
        error.FileNotFound => try RegionFile.create(allocator, path),
        else => return err,
    };
    defer region.close();

    try region.writeChunk(localCoord(key.rx), localCoord(key.rz), bytes);
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
    try writePayload(testing.allocator, save_dir, key, "payload-a");

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
    try writePayload(testing.allocator, save_dir, key, "small");
    try writePayload(testing.allocator, save_dir, key, "larger replacement payload");

    const loaded = (try readPayload(testing.allocator, save_dir, key)).?;
    defer testing.allocator.free(loaded);
    try testing.expectEqualStrings("larger replacement payload", loaded);
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
