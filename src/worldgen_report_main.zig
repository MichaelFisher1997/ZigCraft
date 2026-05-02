const std = @import("std");
const terrain_report = @import("world-worldgen").terrain_report;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const allocator = init.arena.allocator();

    for (terrain_report.representative_seeds, 0..) |seed, i| {
        if (i != 0) try stdout.writeByte('\n');
        const report = try terrain_report.sampleDefaultRegion(allocator, seed);
        try terrain_report.writeReport(stdout, report);
    }
    try stdout.flush();
}
