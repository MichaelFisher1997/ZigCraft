//! Engine-wide logging system with severity levels and error return trace
//! support. All logging should go through this module rather than std.log
//! directly to ensure consistent formatting.
//!
//! Usage:
//!   const log = @import("../engine/core/log.zig");
//!   log.log.info("initialized subsystem", .{});
//!   log.log.err("failed: {}", .{err});
//!   log.log.errWithTrace("init failed: {}", .{err}); // includes stack trace

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const runtime_env = @import("runtime_env.zig");

pub const LogLevel = enum {
    trace,
    debug,
    info,
    warn,
    err,
    fatal,
};

pub const Logger = struct {
    min_level: LogLevel = .info,

    pub fn init(min_level: LogLevel) Logger {
        return .{ .min_level = min_level };
    }

    pub fn trace(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.trace, fmt, args);
    }

    pub fn debug(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.debug, fmt, args);
    }

    pub fn info(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.info, fmt, args);
    }

    pub fn warn(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.warn, fmt, args);
    }

    pub fn err(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
    }

    pub fn fatal(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.fatal, fmt, args);
    }

    pub fn errWithTrace(self: *const Logger, comptime fmt: []const u8, args: anytype) void {
        self.log(.err, fmt, args);
        if (@errorReturnTrace()) |ret_trace| {
            std.debug.dumpErrorReturnTrace(ret_trace);
        }
    }

    fn log(self: *const Logger, level: LogLevel, comptime fmt: []const u8, args: anytype) void {
        const min_level = resolveRuntimeLogLevel(self.min_level);
        if (@intFromEnum(level) < @intFromEnum(min_level)) return;

        const level_str = switch (level) {
            .trace => "[TRACE]",
            .debug => "[DEBUG]",
            .info => "[INFO] ",
            .warn => "[WARN] ",
            .err => "[ERROR]",
            .fatal => "[FATAL]",
        };

        std.debug.print("{s} " ++ fmt ++ "\n", .{level_str} ++ args);
    }
};

fn parseLogLevel(value: []const u8) ?LogLevel {
    if (std.ascii.eqlIgnoreCase(value, "trace")) return .trace;
    if (std.ascii.eqlIgnoreCase(value, "debug")) return .debug;
    if (std.ascii.eqlIgnoreCase(value, "info")) return .info;
    if (std.ascii.eqlIgnoreCase(value, "warn")) return .warn;
    if (std.ascii.eqlIgnoreCase(value, "error") or std.ascii.eqlIgnoreCase(value, "err")) return .err;
    if (std.ascii.eqlIgnoreCase(value, "fatal")) return .fatal;
    return null;
}

fn resolveStaticDefaultLogLevel() LogLevel {
    if (builtin.is_test) return .err;
    if (build_options.startup_diagnostic_seconds > 0) return .info;
    return .warn;
}

fn resolveRuntimeLogLevel(default_level: LogLevel) LogLevel {
    if (runtime_env.getenv("ZIGCRAFT_LOG_LEVEL")) |value| {
        return parseLogLevel(value) orelse default_level;
    }
    return default_level;
}

pub var log = Logger.init(resolveStaticDefaultLogLevel());
