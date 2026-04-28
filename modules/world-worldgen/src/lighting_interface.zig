const std = @import("std");

const Chunk = @import("world-core").Chunk;

pub const ILightingSystem = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        computeSkylight: *const fn (ptr: *anyopaque, chunk: *Chunk, allocator: std.mem.Allocator) anyerror!void,
        computeBlockLight: *const fn (ptr: *anyopaque, chunk: *Chunk, allocator: std.mem.Allocator) anyerror!void,
    };

    pub fn computeSkylight(self: ILightingSystem, chunk: *Chunk, allocator: std.mem.Allocator) !void {
        try self.vtable.computeSkylight(self.ptr, chunk, allocator);
    }

    pub fn computeBlockLight(self: ILightingSystem, chunk: *Chunk, allocator: std.mem.Allocator) !void {
        try self.vtable.computeBlockLight(self.ptr, chunk, allocator);
    }
};
