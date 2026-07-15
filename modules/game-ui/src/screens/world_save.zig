const std = @import("std");
const fs = @import("fs");
const registry = @import("world-worldgen").registry;
const log = @import("engine-core").log;

pub const SAVE_DIR = ".local/share/zigcraft/saves";

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

pub fn writeLevelDat(allocator: std.mem.Allocator, save_dir: fs.Dir, name: []const u8, seed: u64, generator_index: usize, last_played: i64) !void {
    const generator_id = if (generator_index < registry.getGeneratorCount()) registry.getGeneratorId(generator_index) else registry.getGeneratorId(0);
    const payload = .{
        .name = name,
        .seed = seed,
        .last_played = last_played,
        .generator_index = generator_index,
        .generator_id = generator_id,
    };
    const json_str = try std.json.Stringify.valueAlloc(allocator, payload, .{ .whitespace = .indent_2 });
    defer allocator.free(json_str);
    const file = try save_dir.createFile("level.dat", .{});
    defer file.close();
    try file.writeAll(json_str);
}

pub fn saveNewWorld(allocator: std.mem.Allocator, seed: u64, generator_index: usize, world_name: []const u8) !void {
    const home = getenv("HOME") orelse {
        log.log.warn("Cannot save world: HOME not set", .{});
        return error.NoHome;
    };
    var home_dir = fs.openDirAbsolute(home, .{}) catch |err| {
        log.log.warn("Cannot save world: failed to open home dir: {}", .{err});
        return err;
    };
    defer home_dir.close();
    home_dir.makePath(SAVE_DIR) catch |err| {
        log.log.warn("Cannot save world: failed to create saves dir: {}", .{err});
        return err;
    };
    var dir_name_buf: [128]u8 = undefined;
    const timestamp = std.Io.Clock.real.now(std.Options.debug_io).toMilliseconds();
    const dir_name = std.fmt.bufPrint(&dir_name_buf, "world_{}", .{timestamp}) catch "world_new";
    const world_dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ SAVE_DIR, dir_name });
    defer allocator.free(world_dir_path);
    home_dir.makePath(world_dir_path) catch |err| {
        log.log.warn("Cannot save world: failed to create world dir: {}", .{err});
        return err;
    };
    var save_dir = home_dir.openDir(world_dir_path, .{}) catch |err| {
        log.log.warn("Cannot save world: failed to open world dir: {}", .{err});
        return err;
    };
    defer save_dir.close();
    writeLevelDat(allocator, save_dir, world_name, seed, generator_index, timestamp) catch |err| {
        log.log.warn("Cannot save world: failed to write level.dat: {}", .{err});
        return err;
    };
}
