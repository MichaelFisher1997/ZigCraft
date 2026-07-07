const std = @import("std");
const testing = std.testing;

const world_list = @import("world_list.zig");

fn freeWorldEntries(allocator: std.mem.Allocator, entries: []world_list.WorldEntry) void {
    for (entries) |entry| {
        allocator.free(entry.name);
        allocator.free(entry.dir_path);
    }
    allocator.free(entries);
}

test "writeLevelDat and readLevelDat round-trip metadata" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try world_list.writeLevelDat(testing.allocator, tmp.dir, "Alpha", 12345, 0, 99);
    const level = world_list.readLevelDat(testing.allocator, tmp.dir) orelse return error.MissingLevelDat;
    defer testing.allocator.free(level.name);

    try testing.expectEqualStrings("Alpha", level.name);
    try testing.expectEqual(@as(u64, 12345), level.seed);
    try testing.expectEqual(@as(usize, 0), level.generator_index);
    try testing.expectEqual(@as(i64, 99), level.last_played);
}

test "readLevelDat returns null when file is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try testing.expectEqual(@as(?world_list.LevelDat, null), world_list.readLevelDat(testing.allocator, tmp.dir));
}

test "readLevelDat returns null for invalid JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "level.dat", .data = "not json" });

    try testing.expectEqual(@as(?world_list.LevelDat, null), world_list.readLevelDat(testing.allocator, tmp.dir));
}

test "readLevelDat returns null for non-object JSON" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "level.dat", .data = "[]" });

    try testing.expectEqual(@as(?world_list.LevelDat, null), world_list.readLevelDat(testing.allocator, tmp.dir));
}

test "readLevelDat returns null when required name is missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "level.dat", .data = "{\"seed\":1,\"generator_index\":0}" });

    try testing.expectEqual(@as(?world_list.LevelDat, null), world_list.readLevelDat(testing.allocator, tmp.dir));
}

test "readLevelDat defaults missing last_played to zero" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{ .sub_path = "level.dat", .data = "{\"name\":\"Beta\",\"seed\":7,\"generator_index\":0}" });
    const level = world_list.readLevelDat(testing.allocator, tmp.dir) orelse return error.MissingLevelDat;
    defer testing.allocator.free(level.name);

    try testing.expectEqualStrings("Beta", level.name);
    try testing.expectEqual(@as(i64, 0), level.last_played);
}

test "scanWorldsInHome returns empty for absent home" {
    const entries = try world_list.scanWorldsInHome(testing.allocator, "/definitely/not/a/zigcraft/home");
    defer freeWorldEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "scanWorldsInHome creates missing save directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(home);

    const entries = try world_list.scanWorldsInHome(testing.allocator, home);
    defer freeWorldEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 0), entries.len);
    var saves = try tmp.dir.openDir(world_list.SAVE_DIR, .{});
    saves.close();
}

test "scanWorldsInHome loads worlds sorted by last_played descending" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(home);

    try tmp.dir.makePath(world_list.SAVE_DIR ++ "/Older");
    try tmp.dir.makePath(world_list.SAVE_DIR ++ "/Newer");
    var older = try tmp.dir.openDir(world_list.SAVE_DIR ++ "/Older", .{});
    defer older.close();
    var newer = try tmp.dir.openDir(world_list.SAVE_DIR ++ "/Newer", .{});
    defer newer.close();
    try world_list.writeLevelDat(testing.allocator, older, "Older", 1, 0, 10);
    try world_list.writeLevelDat(testing.allocator, newer, "Newer", 2, 0, 20);

    const entries = try world_list.scanWorldsInHome(testing.allocator, home);
    defer freeWorldEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqualStrings("Newer", entries[0].name);
    try testing.expectEqualStrings("Older", entries[1].name);
}

test "scanWorldsInHome falls back to directory name without level.dat" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(home);

    try tmp.dir.makePath(world_list.SAVE_DIR ++ "/BareWorld");

    const entries = try world_list.scanWorldsInHome(testing.allocator, home);
    defer freeWorldEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 1), entries.len);
    try testing.expectEqualStrings("BareWorld", entries[0].name);
    try testing.expectEqual(@as(u64, 0), entries[0].seed);
    try testing.expectEqual(@as(i64, 0), entries[0].last_played);
}

test "scanWorldsInHome ignores non-directory save entries" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(home);

    try tmp.dir.makePath(world_list.SAVE_DIR);
    try tmp.dir.writeFile(.{ .sub_path = world_list.SAVE_DIR ++ "/README.txt", .data = "not a world" });

    const entries = try world_list.scanWorldsInHome(testing.allocator, home);
    defer freeWorldEntries(testing.allocator, entries);

    try testing.expectEqual(@as(usize, 0), entries.len);
}

test "deleteWorld removes only the requested directory" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const home = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(home);

    try tmp.dir.makePath(world_list.SAVE_DIR ++ "/DeleteMe/nested");
    try tmp.dir.makePath(world_list.SAVE_DIR ++ "/KeepMe");
    const target = try std.fmt.allocPrint(testing.allocator, "{s}/{s}/DeleteMe", .{ home, world_list.SAVE_DIR });
    defer testing.allocator.free(target);

    try world_list.deleteWorld(target);

    try testing.expectError(error.FileNotFound, tmp.dir.openDir(world_list.SAVE_DIR ++ "/DeleteMe", .{}));
    var kept = try tmp.dir.openDir(world_list.SAVE_DIR ++ "/KeepMe", .{});
    kept.close();
}

test "deleteWorld rejects rootless path" {
    try testing.expectError(error.InvalidSavePath, world_list.deleteWorld("lonely"));
}
