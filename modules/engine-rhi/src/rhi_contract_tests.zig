const std = @import("std");
const rhi = @import("rhi.zig");
const types = @import("rhi_types.zig");
const Vec3 = @import("engine-math").Vec3;

const Mock = struct {
    created_size: usize = 0,
    uploaded_handle: types.BufferHandle = 0,
    destroyed_handle: types.BufferHandle = 0,
    begin_count: u32 = 0,
    clear_color: Vec3 = Vec3.zero,
    command_buffer: u64 = 0x1234,

    fn createBuffer(ptr: *anyopaque, size: usize, usage: types.BufferUsage) types.RhiError!types.BufferHandle {
        _ = usage;
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.created_size = size;
        return 7;
    }
    fn uploadBuffer(ptr: *anyopaque, handle: types.BufferHandle, data: []const u8) types.RhiError!void {
        _ = data;
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.uploaded_handle = handle;
    }
    fn updateBuffer(_: *anyopaque, _: types.BufferHandle, _: usize, _: []const u8) types.RhiError!void {}
    fn destroyBuffer(ptr: *anyopaque, handle: types.BufferHandle) void {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.destroyed_handle = handle;
    }
    fn createTexture(_: *anyopaque, _: types.TextureConfig) types.RhiError!types.TextureHandle {
        return 11;
    }
    fn createTexture3D(_: *anyopaque, _: u32, _: u32, _: u32, _: types.TextureFormat, _: []const u8) types.RhiError!types.TextureHandle {
        return 12;
    }
    fn destroyTexture(_: *anyopaque, _: types.TextureHandle) void {}
    fn updateTexture(_: *anyopaque, _: types.TextureHandle, _: []const u8) types.RhiError!void {}
    fn createShader(_: *anyopaque, _: []const u8) types.RhiError!types.ShaderHandle {
        return 13;
    }
    fn destroyShader(_: *anyopaque, _: types.ShaderHandle) void {}
    fn mapBuffer(_: *anyopaque, _: types.BufferHandle) types.RhiError!?*anyopaque {
        return null;
    }
    fn unmapBuffer(_: *anyopaque, _: types.BufferHandle) void {}

    fn beginFrame(ptr: *anyopaque) void {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.begin_count += 1;
    }
    fn endFrame(_: *anyopaque) void {}
    fn abortFrame(_: *anyopaque) void {}
    fn requestSwapchainRecreate(_: *anyopaque) void {}
    fn getEncoder(_: *anyopaque) rhi.IGraphicsCommandEncoder {
        return undefined;
    }
    fn getStateContext(_: *anyopaque) rhi.IRenderStateContext {
        return undefined;
    }
    fn setClearColor(ptr: *anyopaque, color: Vec3) void {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        self.clear_color = color;
    }

    fn getCommandBuffer(ptr: *anyopaque) u64 {
        const self: *Mock = @ptrCast(@alignCast(ptr));
        return self.command_buffer;
    }
    fn getSwapchainExtent(_: *anyopaque) [2]u32 {
        return .{ 1920, 1080 };
    }
    fn getDevice(_: *anyopaque) u64 {
        return 1;
    }
    fn getInstance(_: *anyopaque) u64 {
        return 2;
    }
    fn getPhysicalDevice(_: *anyopaque) u64 {
        return 3;
    }
    fn getQueue(_: *anyopaque) u64 {
        return 4;
    }
    fn getQueueFamily(_: *anyopaque) u32 {
        return 5;
    }
    fn getDescriptorPool(_: *anyopaque) u64 {
        return 6;
    }
    fn getUiRenderPass(_: *anyopaque) u64 {
        return 8;
    }
    fn getSwapchainImageCount(_: *anyopaque) u32 {
        return 3;
    }
};

const resource_vtable = rhi.IResourceFactory.VTable{
    .createBuffer = Mock.createBuffer,
    .uploadBuffer = Mock.uploadBuffer,
    .updateBuffer = Mock.updateBuffer,
    .destroyBuffer = Mock.destroyBuffer,
    .createTexture = Mock.createTexture,
    .createTexture3D = Mock.createTexture3D,
    .destroyTexture = Mock.destroyTexture,
    .updateTexture = Mock.updateTexture,
    .createShader = Mock.createShader,
    .destroyShader = Mock.destroyShader,
    .mapBuffer = Mock.mapBuffer,
    .unmapBuffer = Mock.unmapBuffer,
};

const render_vtable = rhi.IRenderContext.VTable{
    .beginFrame = Mock.beginFrame,
    .endFrame = Mock.endFrame,
    .abortFrame = Mock.abortFrame,
    .requestSwapchainRecreate = Mock.requestSwapchainRecreate,
    .getEncoder = Mock.getEncoder,
    .getStateContext = Mock.getStateContext,
    .setClearColor = Mock.setClearColor,
};

const native_vtable = rhi.INativeHandlesContext.VTable{
    .getCommandBuffer = Mock.getCommandBuffer,
    .getSwapchainExtent = Mock.getSwapchainExtent,
    .getDevice = Mock.getDevice,
    .getInstance = Mock.getInstance,
    .getPhysicalDevice = Mock.getPhysicalDevice,
    .getQueue = Mock.getQueue,
    .getQueueFamily = Mock.getQueueFamily,
    .getDescriptorPool = Mock.getDescriptorPool,
    .getUiRenderPass = Mock.getUiRenderPass,
    .getSwapchainImageCount = Mock.getSwapchainImageCount,
};

test "ResourceManager forwards resource factory calls" {
    var mock = Mock{};
    const manager = rhi.ResourceManager{ .factory = .{ .ptr = &mock, .vtable = &resource_vtable } };

    const handle = try manager.createBuffer(256, .vertex);
    try std.testing.expectEqual(@as(types.BufferHandle, 7), handle);
    try std.testing.expectEqual(@as(usize, 256), mock.created_size);

    try manager.uploadBuffer(handle, &.{ 1, 2, 3 });
    try std.testing.expectEqual(handle, mock.uploaded_handle);

    manager.destroyBuffer(handle);
    try std.testing.expectEqual(handle, mock.destroyed_handle);
}

test "IRenderContext forwards lifecycle and state calls" {
    var mock = Mock{};
    const ctx = rhi.IRenderContext{ .ptr = &mock, .vtable = &render_vtable };

    ctx.beginFrame();
    ctx.setClearColor(.{ .x = 0.25, .y = 0.5, .z = 0.75 });

    try std.testing.expectEqual(@as(u32, 1), mock.begin_count);
    try std.testing.expectEqual(@as(f32, 0.25), mock.clear_color.x);
}

test "native handles expose explicit handles only" {
    var mock = Mock{};
    const native = rhi.INativeHandlesContext{ .ptr = &mock, .vtable = &native_vtable };

    try std.testing.expectEqual(@as(u64, 0x1234), native.getCommandBuffer());
    try std.testing.expectEqual([2]u32{ 1920, 1080 }, native.getSwapchainExtent());
    try std.testing.expect(!@hasDecl(rhi.INativeHandlesContext, "getBackendContext"));
}
