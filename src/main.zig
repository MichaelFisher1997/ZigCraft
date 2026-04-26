const std = @import("std");
const App = @import("game/app.zig").App;
const log = @import("engine/core/log.zig");

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    log.initDefaultFile() catch |err| {
        std.debug.print("[WARN] failed to initialize file logging: {}\n", .{err});
    };
    defer log.deinit();

    const app = try App.init(allocator);
    defer app.deinit();

    try app.run();
}
