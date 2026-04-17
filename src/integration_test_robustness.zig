const std = @import("std");
const testing = std.testing;
const fs = @import("fs");
const c = @import("c.zig").c;

pub fn main() !void {
    std.debug.print("Running integration tests...\n", .{});

    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Find the robust-demo executable
    // Typically in zig-out/bin/robust-demo or similar
    const robust_demo_path = try findExecutable(allocator, "robust-demo");
    defer allocator.free(robust_demo_path);

    std.debug.print("Found robust-demo at: {s}\n", .{robust_demo_path});

    // Run the demo
    const run_result = try std.process.run(allocator, std.Options.debug_io, .{
        .argv = &[_][]const u8{robust_demo_path},
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
    });
    defer allocator.free(run_result.stdout);
    defer allocator.free(run_result.stderr);

    const stdout = run_result.stdout;
    const result = run_result.term;

    // Check exit code
    switch (result) {
        .Exited => |code| {
            if (code != 0) {
                std.debug.print("robust-demo failed with exit code {d}\n", .{code});
                std.debug.print("Output:\n{s}\n", .{stdout});
                return error.DemoFailed;
            }
        },
        else => {
            std.debug.print("robust-demo crashed or was signaled\n", .{});
            return error.DemoCrashed;
        },
    }

    // Verify expected output
    const expected_msg = "[SUCCESS] Command completed successfully. Robustness2 prevented device loss.";
    if (std.mem.indexOf(u8, stdout, expected_msg) == null) {
        std.debug.print("robust-demo did not output expected success message.\n", .{});
        std.debug.print("Output:\n{s}\n", .{stdout});
        return error.VerificationFailed;
    }

    std.debug.print("robust-demo exited successfully and verified robustness.\n", .{});
}

fn findExecutable(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    // Try current directory, zig-out/bin, etc.
    const paths = [_][]const u8{
        "./zig-out/bin",
        "./zig-cache/bin",
        ".",
    };

    for (paths) |path| {
        const full_path = try fs.path.join(allocator, &[_][]const u8{ path, name });
        const file = fs.cwd().openFile(full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        file.close();
        return full_path;
    }
    return error.FileNotFound;
}
