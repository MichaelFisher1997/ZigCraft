//! Utility helpers for Light Propagation Volumes.

const std = @import("std");
const fs = @import("fs");
const c = @import("c").c;
const log = @import("engine-core").log;
const Utils = @import("vulkan/utils.zig");

pub fn quantizeToCell(value: f32, cell_size: f32) f32 {
    return @floor(value / cell_size) * cell_size;
}

pub fn divCeil(v: u32, d: u32) u32 {
    return @divFloor(v + d - 1, d);
}

pub fn toneMap(v: f32) f32 {
    const x = @max(v, 0.0);
    return x / (1.0 + x);
}

pub fn createShaderModule(vk: c.VkDevice, path: []const u8, allocator: std.mem.Allocator) !c.VkShaderModule {
    const bytes = try fs.cwd().readFileAlloc(path, allocator, 16 * 1024 * 1024);
    defer allocator.free(bytes);
    if (bytes.len % 4 != 0) return error.InvalidState;

    var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = bytes.len;
    info.pCode = @ptrCast(@alignCast(bytes.ptr));

    var module: c.VkShaderModule = null;
    try Utils.checkVk(c.vkCreateShaderModule(vk, &info, null, &module));
    return module;
}

pub fn ensureShaderFileExists(path: []const u8) !void {
    fs.cwd().access(path, .{}) catch |err| {
        log.log.errWithTrace("LPV shader artifact missing: {s} ({})", .{ path, err });
        log.log.err("Run `nix develop --command zig build` to regenerate Vulkan SPIR-V shaders.", .{});
        return err;
    };
}
