const std = @import("std");
const testing = std.testing;
const world_list = @import("screens/world_list.zig");

test "writeLevelDat creates valid JSON" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try world_list.writeLevelDat(allocator, tmp_dir.dir, "TestWorld", 12345, 0, 100000);
    const content = try tmp_dir.dir.readFileAlloc("level.dat", allocator, @enumFromInt(4096));
    defer allocator.free(content);
    try testing.expect(content.len > 0);
    try testing.expect(std.mem.indexOf(u8, content, "TestWorld") != null);
    try testing.expect(std.mem.indexOf(u8, content, "12345") != null);
}

test "readLevelDat returns correct values" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try world_list.writeLevelDat(allocator, tmp_dir.dir, "MyWorld", 99887766, 1, 200000);
    const result = world_list.readLevelDat(allocator, tmp_dir.dir);
    try testing.expect(result != null);
    defer allocator.free(result.?.name);
    try testing.expectEqualStrings("MyWorld", result.?.name);
    try testing.expectEqual(@as(u64, 99887766), result.?.seed);
    try testing.expectEqual(@as(usize, 1), result.?.generator_index);
    try testing.expect(result.?.last_played > 0);
}

test "readLevelDat returns null for missing file" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const result = world_list.readLevelDat(allocator, tmp_dir.dir);
    try testing.expect(result == null);
}

test "readLevelDat returns null for invalid JSON" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const file = try tmp_dir.dir.createFile("level.dat", .{});
    defer file.close();
    try file.writeAll("not valid json!!!");
    const result = world_list.readLevelDat(allocator, tmp_dir.dir);
    try testing.expect(result == null);
}

test "writeLevelDat overwrites existing" {
    const allocator = testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    try world_list.writeLevelDat(allocator, tmp_dir.dir, "First", 100, 0, 100000);
    try world_list.writeLevelDat(allocator, tmp_dir.dir, "Second", 200, 1, 200000);
    const result = world_list.readLevelDat(allocator, tmp_dir.dir);
    try testing.expect(result != null);
    defer allocator.free(result.?.name);
    try testing.expectEqualStrings("Second", result.?.name);
    try testing.expectEqual(@as(u64, 200), result.?.seed);
    try testing.expectEqual(@as(usize, 1), result.?.generator_index);
}
