const std = @import("std");

pub fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

pub fn envFlag(name: [:0]const u8, default: bool) bool {
    const value = getenv(name) orelse return default;
    return !(std.mem.eql(u8, value, "0") or std.mem.eql(u8, value, "false"));
}

/// Reads a non-negative integer from an environment variable, returning
/// `default` when unset or unparseable. Used to override worker pool sizes and
/// other tunable counts without code changes.
pub fn envInt(name: [:0]const u8, default: usize) usize {
    const value = getenv(name) orelse return default;
    return std.fmt.parseInt(usize, value, 10) catch default;
}

pub fn isWaylandSession() bool {
    if (getenv("WAYLAND_DISPLAY") != null) return true;
    if (getenv("XDG_SESSION_TYPE")) |value| {
        return std.ascii.eqlIgnoreCase(value, "wayland");
    }
    return false;
}

pub fn safeModeEnabled() bool {
    return envFlag("ZIGCRAFT_SAFE_MODE", false);
}

pub fn safeModeExplicitlyEnabled() bool {
    return envFlag("ZIGCRAFT_SAFE_MODE", false);
}

pub fn safeModeAutoEnabled() bool {
    return false;
}

pub fn strictSafeModeAutoEnabled() bool {
    return false;
}

pub fn strictSafeModeEnabled() bool {
    return safeModeExplicitlyEnabled() or strictSafeModeAutoEnabled();
}
