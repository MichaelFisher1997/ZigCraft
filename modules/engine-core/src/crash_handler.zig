//! Minimal local crash dump capture for CI and tester builds.
//!
//! Dumps intentionally contain process metadata only: signal/reason, pid, and a
//! timestamp. They do not include environment variables, command-line arguments,
//! memory pages, or file contents.

const std = @import("std");
const builtin = @import("builtin");

const fs = @import("fs");
const runtime_env = @import("runtime_env.zig");
const time = @import("time.zig");

pub const default_dump_dir = "zigcraft-minidumps";

var installed = false;
var signal_dump_fd: i32 = -1;

pub fn init() void {
    if (installed) return;
    installed = true;

    if (builtin.os.tag != .windows) {
        prepareSignalDumpFile();
        installPosixSignal(.ABRT);
        installPosixSignal(.TERM);
        installPosixSignal(.QUIT);
        installPosixSignal(.SEGV);
        installPosixSignal(.BUS);
        installPosixSignal(.ILL);
        installPosixSignal(.FPE);
    }
}

pub fn writePanicDump(first_trace_addr: ?usize) void {
    writeDump(.{ .kind = "panic", .signal = null, .first_trace_addr = first_trace_addr });
}

const DumpRequest = struct {
    kind: []const u8,
    signal: ?u32,
    first_trace_addr: ?usize,
};

fn dumpDir() []const u8 {
    return runtime_env.getenv("ZIGCRAFT_MINIDUMP_DIR") orelse default_dump_dir;
}

fn writeDump(request: DumpRequest) void {
    const dir_path = dumpDir();
    fs.cwd().makePath(dir_path) catch return;

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/zigcraft-{d}-{d}.dmp", .{
        dir_path,
        timestampSeconds(),
        processId(),
    }) catch return;

    const file = fs.cwd().createFile(path, .{ .exclusive = true }) catch return;
    defer file.close();

    var dump_buf: [512]u8 = undefined;
    const dump = std.fmt.bufPrint(&dump_buf,
        \\format=zigcraft-minidump-v1
        \\kind={s}
        \\pid={d}
        \\timestamp_unix={d}
        \\signal={?d}
        \\first_trace_addr={?x}
        \\pii_policy=metadata-only-no-env-no-argv-no-memory
        \\
    , .{
        request.kind,
        processId(),
        timestampSeconds(),
        request.signal,
        request.first_trace_addr,
    }) catch return;
    file.writeAll(dump) catch return;
}

fn prepareSignalDumpFile() void {
    const dir_path = dumpDir();
    fs.cwd().makePath(dir_path) catch return;

    var path_buf: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/zigcraft-signal-{d}-{d}.dmp", .{
        dir_path,
        timestampSeconds(),
        processId(),
    }) catch return;

    const file = fs.cwd().createFile(path, .{ .exclusive = true }) catch return;
    signal_dump_fd = @intCast(file.inner.handle);

    const header = std.fmt.bufPrint(&path_buf,
        \\format=zigcraft-minidump-v1
        \\kind=signal
        \\pid={d}
        \\timestamp_unix={d}
        \\pii_policy=metadata-only-no-env-no-argv-no-memory
        \\signal=
    , .{
        processId(),
        timestampSeconds(),
    }) catch return;
    file.writeAll(header) catch return;
}

fn processId() u32 {
    return switch (builtin.os.tag) {
        .windows => std.os.windows.GetCurrentProcessId(),
        .linux => @intCast(std.os.linux.getpid()),
        else => @intCast(std.c.getpid()),
    };
}

fn timestampSeconds() i64 {
    return @divFloor(time.timestampMs(), 1000);
}

fn installPosixSignal(comptime signal: std.posix.SIG) void {
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = handlePosixSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(signal, &action, null);
}

fn handlePosixSignal(signal: std.posix.SIG) callconv(.c) void {
    writeSignalDump(signal);

    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.DFL },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(signal, &default_action, null);
    std.posix.raise(signal) catch {};
}

fn writeSignalDump(signal: std.posix.SIG) void {
    const fd = signal_dump_fd;
    if (fd < 0) return;

    var buf: [64]u8 = undefined;
    var len: usize = 0;
    len = appendDecimal(&buf, len, @intFromEnum(signal));
    len = appendBytes(&buf, len, "\nfirst_trace_addr=null\n");
    signalSafeWrite(fd, buf[0..len]);
}

fn appendBytes(buf: *[64]u8, start: usize, bytes: []const u8) usize {
    var len = start;
    for (bytes) |byte| {
        if (len >= buf.len) break;
        buf[len] = byte;
        len += 1;
    }
    return len;
}

fn appendDecimal(buf: *[64]u8, start: usize, value: u32) usize {
    var digits: [10]u8 = undefined;
    var digit_count: usize = 0;
    var remaining = value;

    while (true) {
        digits[digit_count] = @intCast('0' + (remaining % 10));
        digit_count += 1;
        remaining /= 10;
        if (remaining == 0) break;
    }

    var len = start;
    while (digit_count > 0 and len < buf.len) {
        digit_count -= 1;
        buf[len] = digits[digit_count];
        len += 1;
    }
    return len;
}

fn signalSafeWrite(fd: i32, bytes: []const u8) void {
    if (bytes.len == 0) return;

    switch (builtin.os.tag) {
        .linux => _ = std.os.linux.write(fd, bytes.ptr, bytes.len),
        else => _ = std.c.write(@intCast(fd), bytes.ptr, bytes.len),
    }
}
