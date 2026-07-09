//! Level metadata for world saves.
//!
//! Manages the `level.dat` JSON file that stores world metadata such as
//! seed, generator type, timestamps, and spawn position.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fs = @import("fs");

fn timestampMs() i64 {
    return std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
}

pub const LevelData = struct {
    pub const CURRENT_LIGHTING_ALGORITHM_VERSION: u32 = 1;

    seed: u64,
    generator_name: []const u8,
    created_timestamp: i64,
    last_played_timestamp: i64,
    spawn_x: i32,
    spawn_z: i32,
    /// Zero is the legacy value used when an existing level.dat has no field.
    lighting_algorithm_version: u32,

    pub fn init(seed: u64, generator_name: []const u8) LevelData {
        const now = timestampMs();
        return .{
            .seed = seed,
            .generator_name = generator_name,
            .created_timestamp = now,
            .last_played_timestamp = now,
            .spawn_x = 8,
            .spawn_z = 8,
            .lighting_algorithm_version = CURRENT_LIGHTING_ALGORITHM_VERSION,
        };
    }

    pub fn deinit(self: *LevelData, allocator: Allocator) void {
        if (self.generator_name.len > 0) {
            allocator.free(self.generator_name);
        }
    }

    pub fn saveToFile(self: *const LevelData, allocator: Allocator, dir: fs.Dir) !void {
        var aw: std.Io.Writer.Allocating = try .initCapacity(allocator, 256);
        defer aw.deinit();

        const writer = &aw.writer;
        try writer.writeAll("{\n");
        try writer.print("  \"seed\": {},\n", .{self.seed});
        try writer.print("  \"generator_name\": \"{s}\",\n", .{self.generator_name});
        try writer.print("  \"created_timestamp\": {},\n", .{self.created_timestamp});
        try writer.print("  \"last_played_timestamp\": {},\n", .{self.last_played_timestamp});
        try writer.print("  \"spawn_x\": {},\n", .{self.spawn_x});
        try writer.print("  \"spawn_z\": {},\n", .{self.spawn_z});
        try writer.print("  \"lighting_algorithm_version\": {}\n", .{self.lighting_algorithm_version});
        try writer.writeAll("}");

        const file = try dir.createFile("level.dat", .{ .truncate = true });
        defer file.close();
        try file.writeAll(aw.written());
    }

    pub fn loadFromFile(allocator: Allocator, dir: fs.Dir) !LevelData {
        const file = try dir.openFile("level.dat", .{});
        defer file.close();

        const stat = try file.stat();
        if (stat.size > 4096) return error.LevelDataTooLarge;

        const contents = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(contents);
        _ = try file.preadAll(contents, 0);

        var result = LevelData{
            .seed = 0,
            .generator_name = "",
            .created_timestamp = 0,
            .last_played_timestamp = 0,
            .spawn_x = 8,
            .spawn_z = 8,
            .lighting_algorithm_version = 0,
        };

        var lines = std.mem.splitSequence(u8, contents, "\n");
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r,");
            if (trimmed.len == 0 or trimmed[0] == '{' or trimmed[0] == '}') continue;

            if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
                const key = std.mem.trim(u8, trimmed[0..colon_idx], " \"");
                const val = std.mem.trim(u8, trimmed[colon_idx + 1 ..], " \"");

                if (std.mem.eql(u8, key, "seed")) {
                    result.seed = std.fmt.parseInt(u64, val, 10) catch 0;
                } else if (std.mem.eql(u8, key, "generator_name")) {
                    result.generator_name = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "created_timestamp")) {
                    result.created_timestamp = std.fmt.parseInt(i64, val, 10) catch 0;
                } else if (std.mem.eql(u8, key, "last_played_timestamp")) {
                    result.last_played_timestamp = std.fmt.parseInt(i64, val, 10) catch 0;
                } else if (std.mem.eql(u8, key, "spawn_x")) {
                    result.spawn_x = std.fmt.parseInt(i32, val, 10) catch 8;
                } else if (std.mem.eql(u8, key, "spawn_z")) {
                    result.spawn_z = std.fmt.parseInt(i32, val, 10) catch 8;
                } else if (std.mem.eql(u8, key, "lighting_algorithm_version")) {
                    result.lighting_algorithm_version = std.fmt.parseInt(u32, val, 10) catch 0;
                }
            }
        }

        return result;
    }

    pub fn touchLastPlayed(self: *LevelData) void {
        self.last_played_timestamp = timestampMs();
    }
};

const testing = std.testing;

test "LevelData save and load round-trip" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const original = LevelData.init(12345, "overworld");
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    try original.saveToFile(testing.allocator, dir);

    var loaded = try LevelData.loadFromFile(testing.allocator, dir);
    defer loaded.deinit(testing.allocator);

    try testing.expectEqual(@as(u64, 12345), loaded.seed);
    try testing.expectEqualStrings("overworld", loaded.generator_name);
    try testing.expectEqual(@as(i32, 8), loaded.spawn_x);
    try testing.expectEqual(@as(i32, 8), loaded.spawn_z);
    try testing.expectEqual(LevelData.CURRENT_LIGHTING_ALGORITHM_VERSION, loaded.lighting_algorithm_version);
}

test "LevelData treats metadata without a lighting version as legacy" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const dir = fs.Dir{ .inner = tmp_dir.dir };
    const file = try dir.createFile("level.dat", .{ .truncate = true });
    defer file.close();
    try file.writeAll("{\n  \"seed\": 7,\n  \"generator_name\": \"flat\"\n}");

    var loaded = try LevelData.loadFromFile(testing.allocator, dir);
    defer loaded.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 0), loaded.lighting_algorithm_version);
}

test "LevelData touchLastPlayed updates timestamp" {
    var data = LevelData.init(99999, "flat");
    const old_ts = data.last_played_timestamp;
    std.Options.debug_io.sleep(.fromNanoseconds(1_000_000), .boot) catch {};
    data.touchLastPlayed();
    try testing.expect(data.last_played_timestamp >= old_ts);
}
