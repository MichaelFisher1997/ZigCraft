//! Compatibility wrappers for 0.16 filesystem APIs.

const std = @import("std");
const Allocator = std.mem.Allocator;

const io = std.Options.debug_io;

pub const path = std.fs.path;
pub const max_path_bytes = std.Io.Dir.max_path_bytes;
pub const max_name_bytes = std.Io.Dir.max_name_bytes;

pub const AccessOptions = std.Io.Dir.AccessOptions;
pub const OpenOptions = std.Io.Dir.OpenOptions;
pub const OpenFileOptions = std.Io.Dir.OpenFileOptions;
pub const CreateFileOptions = std.Io.Dir.CreateFileOptions;
pub const CreateDirPathOpenOptions = std.Io.Dir.CreateDirPathOpenOptions;
pub const Permissions = std.Io.Dir.Permissions;
pub const Stat = std.Io.File.Stat;

pub const File = struct {
    inner: std.Io.File,

    pub fn close(self: File) void {
        self.inner.close(io);
    }

    pub fn stat(self: File) !Stat {
        return self.inner.stat(io);
    }

    pub fn writeAll(self: File, bytes: []const u8) !void {
        try self.inner.writeStreamingAll(io, bytes);
    }

    pub fn preadAll(self: File, buffer: []u8, offset: u64) !usize {
        return self.inner.readPositionalAll(io, buffer, offset);
    }

    pub fn writePositionalAll(self: File, bytes: []const u8, offset: u64) !void {
        try self.inner.writePositionalAll(io, bytes, offset);
    }

    pub fn setLength(self: File, new_length: u64) !void {
        try self.inner.setLength(io, new_length);
    }

    pub fn sync(self: File) !void {
        try self.inner.sync(io);
    }
};

pub const Dir = struct {
    inner: std.Io.Dir,

    pub const Entry = std.Io.Dir.Entry;

    pub const Iterator = struct {
        inner: std.Io.Dir.Iterator,

        pub fn next(self: *Iterator) !?Entry {
            return self.inner.next(io);
        }
    };

    pub fn cwd() Dir {
        return .{ .inner = std.Io.Dir.cwd() };
    }

    pub fn close(self: Dir) void {
        self.inner.close(io);
    }

    pub fn iterate(self: Dir) Iterator {
        return .{ .inner = self.inner.iterate() };
    }

    pub fn openDir(self: Dir, sub_path: []const u8, options: OpenOptions) !Dir {
        return .{ .inner = try self.inner.openDir(io, sub_path, options) };
    }

    pub fn openFile(self: Dir, sub_path: []const u8, options: OpenFileOptions) !File {
        return .{ .inner = try self.inner.openFile(io, sub_path, options) };
    }

    pub fn createFile(self: Dir, sub_path: []const u8, flags: CreateFileOptions) !File {
        return .{ .inner = try self.inner.createFile(io, sub_path, flags) };
    }

    pub fn access(self: Dir, sub_path: []const u8, options: AccessOptions) !void {
        try self.inner.access(io, sub_path, options);
    }

    pub fn createDir(self: Dir, sub_path: []const u8, permissions: Permissions) !void {
        try self.inner.createDir(io, sub_path, permissions);
    }

    pub fn createDirPath(self: Dir, sub_path: []const u8) !void {
        try self.inner.createDirPath(io, sub_path);
    }

    pub fn createDirPathOpen(self: Dir, sub_path: []const u8, options: CreateDirPathOpenOptions) !Dir {
        return .{ .inner = try self.inner.createDirPathOpen(io, sub_path, options) };
    }

    pub fn deleteDir(self: Dir, sub_path: []const u8) !void {
        try self.inner.deleteDir(io, sub_path);
    }

    pub fn deleteTree(self: Dir, sub_path: []const u8) !void {
        try self.inner.deleteTree(io, sub_path);
    }

    pub fn deleteFile(self: Dir, sub_path: []const u8) !void {
        try self.inner.deleteFile(io, sub_path);
    }

    pub fn readFileAlloc(self: Dir, sub_path: []const u8, allocator: Allocator, limit: usize) ![]u8 {
        return self.inner.readFileAlloc(io, sub_path, allocator, .limited(limit));
    }

    pub fn realpath(self: Dir, sub_path: []const u8, out_buffer: []u8) ![]u8 {
        const len = try self.inner.realPathFile(io, sub_path, out_buffer);
        return out_buffer[0..len];
    }

    pub fn makePath(self: Dir, sub_path: []const u8) !void {
        try self.inner.createDirPath(io, sub_path);
    }

    pub fn makeOpenPath(self: Dir, sub_path: []const u8, options: CreateDirPathOpenOptions) !Dir {
        return .{ .inner = try self.inner.createDirPathOpen(io, sub_path, options) };
    }
};

pub fn cwd() Dir {
    return Dir.cwd();
}

pub fn openDirAbsolute(absolute_path: []const u8, options: OpenOptions) !Dir {
    return .{ .inner = try std.Io.Dir.openDirAbsolute(io, absolute_path, options) };
}

pub fn openFileAbsolute(absolute_path: []const u8, options: OpenFileOptions) !File {
    return .{ .inner = try std.Io.Dir.openFileAbsolute(io, absolute_path, options) };
}

pub fn createFileAbsolute(absolute_path: []const u8, flags: CreateFileOptions) !File {
    return .{ .inner = try std.Io.Dir.createFileAbsolute(io, absolute_path, flags) };
}

pub fn accessAbsolute(absolute_path: []const u8, options: AccessOptions) !void {
    try std.Io.Dir.accessAbsolute(io, absolute_path, options);
}

pub fn createDirAbsolute(absolute_path: []const u8, permissions: Permissions) !void {
    try std.Io.Dir.createDirAbsolute(io, absolute_path, permissions);
}

pub fn deleteFileAbsolute(absolute_path: []const u8) !void {
    try std.Io.Dir.deleteFileAbsolute(io, absolute_path);
}
