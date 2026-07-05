//! RHI resource adapter for LOD mesh GPU buffers.

const rhi_pkg = @import("engine-rhi").rhi;
const rhi_types = @import("engine-rhi");
const BufferHandle = rhi_types.BufferHandle;
const BufferUsage = rhi_types.BufferUsage;
const RhiError = rhi_types.RhiError;

pub const LODMeshResources = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        createBuffer: *const fn (ptr: *anyopaque, size: usize, usage: BufferUsage) RhiError!BufferHandle,
        uploadBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, data: []const u8) RhiError!void,
        updateBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void,
        destroyBuffer: *const fn (ptr: *anyopaque, handle: BufferHandle) void,
        waitIdle: *const fn (ptr: *anyopaque) void,
    };

    pub fn fromRHI(rhi: *rhi_pkg.RHI) LODMeshResources {
        return .{ .ptr = rhi, .vtable = &rhi_vtable };
    }

    pub fn fromProvider(comptime Provider: type, provider: *Provider) LODMeshResources {
        const Adapter = struct {
            fn createBuffer(ptr: *anyopaque, size: usize, usage: BufferUsage) RhiError!BufferHandle {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "resourceManager")) {
                    return typed.resourceManager().createBuffer(size, usage);
                }
                return typed.createBuffer(size, usage);
            }

            fn uploadBuffer(ptr: *anyopaque, handle: BufferHandle, data: []const u8) RhiError!void {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "resourceManager")) {
                    return typed.resourceManager().uploadBuffer(handle, data);
                }
                if (@hasDecl(Provider, "uploadBuffer")) {
                    return typed.uploadBuffer(handle, data);
                }
                if (@hasDecl(Provider, "updateBuffer")) {
                    return typed.updateBuffer(handle, 0, data);
                }
                return error.InvalidState;
            }

            fn updateBuffer(ptr: *anyopaque, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "resourceManager")) {
                    return typed.resourceManager().updateBuffer(handle, offset, data);
                }
                if (@hasDecl(Provider, "updateBuffer")) {
                    return typed.updateBuffer(handle, offset, data);
                }
                if (offset == 0 and @hasDecl(Provider, "uploadBuffer")) {
                    return typed.uploadBuffer(handle, data);
                }
                return error.InvalidState;
            }

            fn destroyBuffer(ptr: *anyopaque, handle: BufferHandle) void {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "resourceManager")) {
                    typed.resourceManager().destroyBuffer(handle);
                    return;
                }
                typed.destroyBuffer(handle);
            }

            fn waitIdle(ptr: *anyopaque) void {
                const typed: *Provider = @ptrCast(@alignCast(ptr));
                if (@hasDecl(Provider, "waitIdle")) {
                    typed.waitIdle();
                }
            }

            const vtable = VTable{
                .createBuffer = @This().createBuffer,
                .uploadBuffer = @This().uploadBuffer,
                .updateBuffer = @This().updateBuffer,
                .destroyBuffer = @This().destroyBuffer,
                .waitIdle = @This().waitIdle,
            };
        };

        return .{ .ptr = provider, .vtable = &Adapter.vtable };
    }

    pub fn createBuffer(self: LODMeshResources, size: usize, usage: BufferUsage) RhiError!BufferHandle {
        return self.vtable.createBuffer(self.ptr, size, usage);
    }

    pub fn uploadBuffer(self: LODMeshResources, handle: BufferHandle, data: []const u8) RhiError!void {
        return self.vtable.uploadBuffer(self.ptr, handle, data);
    }

    pub fn updateBuffer(self: LODMeshResources, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
        return self.vtable.updateBuffer(self.ptr, handle, offset, data);
    }

    pub fn destroyBuffer(self: LODMeshResources, handle: BufferHandle) void {
        self.vtable.destroyBuffer(self.ptr, handle);
    }

    pub fn waitIdle(self: LODMeshResources) void {
        self.vtable.waitIdle(self.ptr);
    }

    const rhi_vtable = VTable{
        .createBuffer = struct {
            fn f(ptr: *anyopaque, size: usize, usage: BufferUsage) RhiError!BufferHandle {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                return rhi.resourceManager().createBuffer(size, usage);
            }
        }.f,
        .uploadBuffer = struct {
            fn f(ptr: *anyopaque, handle: BufferHandle, data: []const u8) RhiError!void {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                return rhi.resourceManager().uploadBuffer(handle, data);
            }
        }.f,
        .updateBuffer = struct {
            fn f(ptr: *anyopaque, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                return rhi.resourceManager().updateBuffer(handle, offset, data);
            }
        }.f,
        .destroyBuffer = struct {
            fn f(ptr: *anyopaque, handle: BufferHandle) void {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                rhi.resourceManager().destroyBuffer(handle);
            }
        }.f,
        .waitIdle = struct {
            fn f(ptr: *anyopaque) void {
                const rhi: *rhi_pkg.RHI = @ptrCast(@alignCast(ptr));
                rhi.waitIdle();
            }
        }.f,
    };
};

/// Keep individual Vulkan staging-ring allocations bounded. Large LOD meshes
/// can exceed the remaining per-frame staging space even when the frame-level
/// upload budget is respected; splitting avoids one oversized allocation.
pub const MAX_STAGING_UPDATE_BYTES: usize = 8 * 1024 * 1024;

pub fn updateBufferChunked(resources: LODMeshResources, handle: BufferHandle, offset: usize, data: []const u8) RhiError!void {
    var cursor: usize = 0;
    while (cursor < data.len) {
        const chunk_len = @min(MAX_STAGING_UPDATE_BYTES, data.len - cursor);
        try resources.updateBuffer(handle, offset + cursor, data[cursor .. cursor + chunk_len]);
        cursor += chunk_len;
    }
}

pub fn uploadBufferChunked(resources: LODMeshResources, handle: BufferHandle, data: []const u8) RhiError!void {
    if (data.len <= MAX_STAGING_UPDATE_BYTES) {
        try resources.uploadBuffer(handle, data);
        return;
    }
    try updateBufferChunked(resources, handle, 0, data);
}

pub const LODMeshRenderContext = struct {
    ptr: *anyopaque,
    draw_fn: *const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: rhi_types.DrawMode) void,
    draw_offset_fn: ?*const fn (ptr: *anyopaque, handle: BufferHandle, count: u32, mode: rhi_types.DrawMode, offset: usize) void = null,

    pub fn draw(self: LODMeshRenderContext, handle: BufferHandle, count: u32, mode: rhi_types.DrawMode) void {
        self.draw_fn(self.ptr, handle, count, mode);
    }

    pub fn drawOffset(self: LODMeshRenderContext, handle: BufferHandle, count: u32, mode: rhi_types.DrawMode, offset: usize) void {
        if (self.draw_offset_fn) |draw_offset| {
            draw_offset(self.ptr, handle, count, mode, offset);
            return;
        }
        self.draw(handle, count, mode);
    }
};
