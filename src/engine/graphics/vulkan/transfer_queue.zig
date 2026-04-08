//! Dedicated Vulkan transfer queue with ring-buffered staging allocator.
//!
//! Provides async GPU uploads that can overlap with rendering when a dedicated
//! transfer queue family is available. Falls back to sharing the graphics queue
//! otherwise — the staging ring still works but without parallelism.
//!
//! ## Ring Buffer Lifecycle
//! Each frame's allocations occupy a contiguous region of the ring. When that
//! frame's fence completes, the region is reclaimed. With `MAX_FRAMES_IN_FLIGHT=2`
//! the ring needs at most 2× the per-frame upload budget.

const std = @import("std");
const c = @import("../../../c.zig").c;
const rhi = @import("../rhi.zig");
const log = @import("../../core/log.zig");
const VulkanDevice = @import("../vulkan_device.zig").VulkanDevice;
const Utils = @import("utils.zig");

pub const DEFAULT_STAGING_CAPACITY: u64 = 64 * 1024 * 1024;
const ALIGNMENT: u64 = 256;

pub const StagingRing = struct {
    buffer: c.VkBuffer = null,
    memory: c.VkDeviceMemory = null,
    mapped: [*]u8 = undefined,
    is_mapped: bool = false,
    capacity: u64 = 0,
    head: u64 = 0,
    tail: u64 = 0,
    frame_base: [rhi.MAX_FRAMES_IN_FLIGHT]u64,
    frame_used: [rhi.MAX_FRAMES_IN_FLIGHT]u64,

    pub fn init(device: *const VulkanDevice, capacity: u64) !StagingRing {
        const buf = try Utils.createVulkanBuffer(
            device,
            capacity,
            c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );
        if (buf.buffer == null or buf.mapped_ptr == null) return error.VulkanError;

        var ring = StagingRing{
            .buffer = buf.buffer,
            .memory = buf.memory,
            .mapped = @ptrCast(buf.mapped_ptr.?),
            .is_mapped = true,
            .capacity = capacity,
            .head = 0,
            .tail = 0,
            .frame_base = undefined,
            .frame_used = undefined,
        };
        @memset(&ring.frame_base, 0);
        @memset(&ring.frame_used, 0);
        return ring;
    }

    pub fn deinit(self: *StagingRing, vk_device: c.VkDevice) void {
        if (self.is_mapped and self.memory != null) {
            c.vkUnmapMemory(vk_device, self.memory);
        }
        if (self.buffer != null) c.vkDestroyBuffer(vk_device, self.buffer, null);
        if (self.memory != null) c.vkFreeMemory(vk_device, self.memory, null);
        self.buffer = null;
        self.memory = null;
        self.is_mapped = false;
        self.capacity = 0;
        self.head = 0;
        self.tail = 0;
        @memset(&self.frame_base, 0);
        @memset(&self.frame_used, 0);
    }

    pub fn beginFrame(self: *StagingRing, frame_index: usize) void {
        self.frame_base[frame_index] = self.head;
        self.frame_used[frame_index] = 0;
    }

    pub fn reclaimFrame(self: *StagingRing, frame_index: usize) void {
        self.tail = self.frame_base[frame_index] + self.frame_used[frame_index];
        if (self.tail >= self.capacity) self.tail -= self.capacity;
    }

    pub fn allocated(self: *StagingRing) u64 {
        if (self.head >= self.tail) return self.head - self.tail;
        return self.capacity - self.tail + self.head;
    }

    pub fn available(self: *StagingRing) u64 {
        return self.capacity - self.allocated();
    }

    pub fn allocate(self: *StagingRing, size: u64, frame_index: usize) ?StagingSlice {
        if (size == 0) return null;

        const aligned_head = std.mem.alignForward(u64, self.head, ALIGNMENT);
        var padded_to_end: u64 = 0;

        const try_offset = blk: {
            if (aligned_head + size <= self.capacity) {
                break :blk aligned_head;
            }
            padded_to_end = self.capacity - self.head;
            const wrap = std.mem.alignForward(u64, 0, ALIGNMENT);
            if (wrap + size > self.capacity) return null;
            const avail = self.available();
            if (size + padded_to_end > avail) return null;
            break :blk wrap;
        };

        const slice = StagingSlice{
            .ptr = self.mapped + try_offset,
            .buffer_offset = try_offset,
            .size = size,
        };

        const new_head = try_offset + size;
        self.head = if (new_head >= self.capacity) 0 else new_head;
        self.frame_used[frame_index] += size + padded_to_end;

        return slice;
    }
};

pub const StagingSlice = struct {
    ptr: [*]u8,
    buffer_offset: u64,
    size: u64,
};

pub const TransferQueue = struct {
    queue: c.VkQueue = null,
    family_index: u32 = 0,
    is_dedicated: bool = false,
    command_pool: c.VkCommandPool = null,
    command_buffers: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkCommandBuffer = undefined,
    fence: c.VkFence = null,
    frame_fences: [rhi.MAX_FRAMES_IN_FLIGHT]c.VkFence = .{null} ** rhi.MAX_FRAMES_IN_FLIGHT,
    transfer_semaphore: c.VkSemaphore = null,
    transfer_ready: [rhi.MAX_FRAMES_IN_FLIGHT]bool = undefined,
    current_frame: usize = 0,

    pub fn init(device: *const VulkanDevice, transfer_family: u32, is_dedicated: bool) !TransferQueue {
        var self = TransferQueue{
            .family_index = transfer_family,
            .is_dedicated = is_dedicated,
        };
        @memset(&self.transfer_ready, false);

        c.vkGetDeviceQueue(device.vk_device, transfer_family, 0, &self.queue);

        var pool_info = std.mem.zeroes(c.VkCommandPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
        pool_info.queueFamilyIndex = transfer_family;
        pool_info.flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT | c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
        try Utils.checkVk(c.vkCreateCommandPool(device.vk_device, &pool_info, null, &self.command_pool));

        var alloc_info = std.mem.zeroes(c.VkCommandBufferAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
        alloc_info.commandPool = self.command_pool;
        alloc_info.level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY;
        alloc_info.commandBufferCount = rhi.MAX_FRAMES_IN_FLIGHT;
        try Utils.checkVk(c.vkAllocateCommandBuffers(device.vk_device, &alloc_info, &self.command_buffers));

        var fence_info = std.mem.zeroes(c.VkFenceCreateInfo);
        fence_info.sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
        try Utils.checkVk(c.vkCreateFence(device.vk_device, &fence_info, null, &self.fence));

        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            try Utils.checkVk(c.vkCreateFence(device.vk_device, &fence_info, null, &self.frame_fences[i]));
        }

        var sem_info = std.mem.zeroes(c.VkSemaphoreCreateInfo);
        sem_info.sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
        try Utils.checkVk(c.vkCreateSemaphore(device.vk_device, &sem_info, null, &self.transfer_semaphore));

        return self;
    }

    pub fn deinit(self: *TransferQueue, vk_device: c.VkDevice) void {
        if (vk_device == null) return;
        _ = c.vkDeviceWaitIdle(vk_device);

        if (self.command_pool != null) {
            c.vkDestroyCommandPool(vk_device, self.command_pool, null);
            self.command_pool = null;
        }
        if (self.fence != null) {
            c.vkDestroyFence(vk_device, self.fence, null);
            self.fence = null;
        }
        for (0..rhi.MAX_FRAMES_IN_FLIGHT) |i| {
            if (self.frame_fences[i] != null) {
                c.vkDestroyFence(vk_device, self.frame_fences[i], null);
                self.frame_fences[i] = null;
            }
        }
        if (self.transfer_semaphore != null) {
            c.vkDestroySemaphore(vk_device, self.transfer_semaphore, null);
            self.transfer_semaphore = null;
        }
    }

    pub fn setCurrentFrame(self: *TransferQueue, frame_index: usize) void {
        self.current_frame = frame_index;
    }

    pub fn prepareTransfer(self: *TransferQueue) !c.VkCommandBuffer {
        if (self.transfer_ready[self.current_frame]) return self.command_buffers[self.current_frame];

        const cb = self.command_buffers[self.current_frame];
        try Utils.checkVk(c.vkResetCommandBuffer(cb, 0));

        var begin_info = std.mem.zeroes(c.VkCommandBufferBeginInfo);
        begin_info.sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
        begin_info.flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
        try Utils.checkVk(c.vkBeginCommandBuffer(cb, &begin_info));

        self.transfer_ready[self.current_frame] = true;
        return cb;
    }

    pub fn getTransferCommandBuffer(self: *TransferQueue) ?c.VkCommandBuffer {
        if (!self.transfer_ready[self.current_frame]) return null;
        return self.command_buffers[self.current_frame];
    }

    pub fn resetTransferState(self: *TransferQueue) void {
        self.transfer_ready[self.current_frame] = false;
    }

    pub fn endTransferCommandBuffer(self: *TransferQueue) !void {
        if (!self.transfer_ready[self.current_frame]) return;
        const cb = self.command_buffers[self.current_frame];
        try Utils.checkVk(c.vkEndCommandBuffer(cb));
    }

    pub fn waitForFrameFence(self: *TransferQueue, vk_device: c.VkDevice, frame_index: usize) void {
        if (self.frame_fences[frame_index] == null) return;
        _ = c.vkWaitForFences(vk_device, 1, &self.frame_fences[frame_index], c.VK_TRUE, std.math.maxInt(u64));
        _ = c.vkResetFences(vk_device, 1, &self.frame_fences[frame_index]);
    }

    pub fn submitAndWait(self: *TransferQueue, vk_device: c.VkDevice, queue_mutex: *std.Thread.Mutex) !void {
        if (!self.transfer_ready[self.current_frame]) return;

        const cb = self.command_buffers[self.current_frame];
        try Utils.checkVk(c.vkEndCommandBuffer(cb));

        var submit_info = std.mem.zeroes(c.VkSubmitInfo);
        submit_info.sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO;
        submit_info.commandBufferCount = 1;
        submit_info.pCommandBuffers = &cb;

        try Utils.checkVk(c.vkResetFences(vk_device, 1, &self.fence));

        queue_mutex.lock();
        const result = c.vkQueueSubmit(self.queue, 1, &submit_info, self.fence);
        queue_mutex.unlock();

        if (result != c.VK_SUCCESS) return error.VulkanError;

        try Utils.checkVk(c.vkWaitForFences(vk_device, 1, &self.fence, c.VK_TRUE, std.math.maxInt(u64)));

        self.transfer_ready[self.current_frame] = false;
    }

    pub fn flushSync(self: *TransferQueue, vk_device: c.VkDevice, queue_mutex: *std.Thread.Mutex) !void {
        if (!self.transfer_ready[self.current_frame]) return;
        try self.submitAndWait(vk_device, queue_mutex);
    }
};
