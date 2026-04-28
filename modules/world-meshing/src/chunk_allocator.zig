const std = @import("std");
const sync = @import("sync");
const log = @import("engine-core").log;
const rhi_mod = @import("engine-rhi").rhi;
const ResourceManager = rhi_mod.ResourceManager;
const IDeviceQuery = rhi_mod.IDeviceQuery;
const Vertex = rhi_mod.Vertex;

pub const VertexAllocation = struct {
    offset: usize,
    count: u32,
    handle: rhi_mod.BufferHandle,
};

/// Manages a large GPU buffer ("Megabuffer") for chunk vertices.
/// Implements a free-list allocator with improved coalescing.
pub const GlobalVertexAllocator = struct {
    const FreeBlock = struct {
        offset: usize,
        size: usize,
    };

    resource_manager: ResourceManager,
    device_query: IDeviceQuery,
    buffer: rhi_mod.BufferHandle,
    capacity: usize,
    allocator: std.mem.Allocator,

    free_blocks: std.ArrayListUnmanaged(FreeBlock),
    deferred_frees: [rhi_mod.MAX_FRAMES_IN_FLIGHT]std.ArrayListUnmanaged(VertexAllocation),
    mutex: sync.Mutex,

    pub fn init(allocator: std.mem.Allocator, resources: ResourceManager, query: IDeviceQuery, capacity_mb: usize) !GlobalVertexAllocator {
        const capacity = capacity_mb * 1024 * 1024;
        const buffer = try resources.createBuffer(capacity, .vertex);

        var free_blocks = std.ArrayListUnmanaged(FreeBlock).empty;
        try free_blocks.append(allocator, .{ .offset = 0, .size = capacity });

        log.log.info("Initialized GlobalVertexAllocator with {}MB, buffer handle={}", .{ capacity_mb, buffer });

        var deferred_frees: [rhi_mod.MAX_FRAMES_IN_FLIGHT]std.ArrayListUnmanaged(VertexAllocation) = undefined;
        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            deferred_frees[i] = .empty;
        }

        return .{
            .resource_manager = resources,
            .device_query = query,
            .buffer = buffer,
            .capacity = capacity,
            .allocator = allocator,
            .free_blocks = free_blocks,
            .deferred_frees = deferred_frees,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *GlobalVertexAllocator) void {
        self.resource_manager.destroyBuffer(self.buffer);
        self.free_blocks.deinit(self.allocator);
        for (0..rhi_mod.MAX_FRAMES_IN_FLIGHT) |i| {
            self.deferred_frees[i].deinit(self.allocator);
        }
    }

    /// Processes deferred frees for the given frame slot.
    /// Should be called once per frame when the GPU is guaranteed to be done with that slot.
    pub fn tick(self: *GlobalVertexAllocator, frame_index: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const frees = &self.deferred_frees[frame_index];
        for (frees.items) |alloc| {
            self.freeImmediateUnlocked(alloc);
        }
        frees.clearRetainingCapacity();
    }

    /// Allocates space for vertices and uploads them.
    /// Returns allocation info, or error if full.
    pub fn allocate(self: *GlobalVertexAllocator, vertices: []const Vertex) !VertexAllocation {
        const size_needed = vertices.len * @sizeOf(Vertex);
        if (size_needed == 0) return error.InvalidSize;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Use Best-Fit strategy to minimize fragmentation
        var best_fit_idx: ?usize = null;
        var best_fit_size: usize = std.math.maxInt(usize);

        for (self.free_blocks.items, 0..) |block, i| {
            if (block.size >= size_needed and block.size < best_fit_size) {
                best_fit_idx = i;
                best_fit_size = block.size;
                if (block.size == size_needed) break; // Perfect fit
            }
        }

        if (best_fit_idx) |i| {
            const block = self.free_blocks.items[i];
            const allocation = VertexAllocation{
                .offset = block.offset,
                .count = @intCast(vertices.len),
                .handle = self.buffer,
            };

            // Upload at the correct offset within the megabuffer
            try self.resource_manager.updateBuffer(self.buffer, block.offset, std.mem.sliceAsBytes(vertices));

            // Update free block
            if (block.size > size_needed) {
                self.free_blocks.items[i].offset += size_needed;
                self.free_blocks.items[i].size -= size_needed;
            } else {
                _ = self.free_blocks.orderedRemove(i);
            }

            return allocation;
        }

        // Calculate actual largest block and total free for better debugging
        var largest_block: usize = 0;
        var total_free: usize = 0;
        for (self.free_blocks.items) |block| {
            if (block.size > largest_block) largest_block = block.size;
            total_free += block.size;
        }

        log.log.err("GlobalVertexAllocator OOM: needed {} ({} vertices), capacity {}GB, total free: {} KB, free blocks: {}. Largest block: {} KB", .{
            size_needed,
            vertices.len,
            self.capacity / (1024 * 1024 * 1024),
            total_free / 1024,
            self.free_blocks.items.len,
            largest_block / 1024,
        });
        return error.OutOfMemory;
    }

    /// Reserves space in the megabuffer without uploading data.
    /// The caller is responsible for filling the reserved range on the GPU.
    pub fn reserve(self: *GlobalVertexAllocator, vertex_count: u32) !VertexAllocation {
        const size_needed = @as(usize, vertex_count) * @sizeOf(Vertex);
        if (size_needed == 0) return error.InvalidSize;

        self.mutex.lock();
        defer self.mutex.unlock();

        var best_fit_idx: ?usize = null;
        var best_fit_size: usize = std.math.maxInt(usize);

        for (self.free_blocks.items, 0..) |block, i| {
            if (block.size >= size_needed and block.size < best_fit_size) {
                best_fit_idx = i;
                best_fit_size = block.size;
                if (block.size == size_needed) break;
            }
        }

        if (best_fit_idx) |i| {
            const block = self.free_blocks.items[i];
            const allocation = VertexAllocation{
                .offset = block.offset,
                .count = vertex_count,
                .handle = self.buffer,
            };

            if (block.size > size_needed) {
                self.free_blocks.items[i].offset += size_needed;
                self.free_blocks.items[i].size -= size_needed;
            } else {
                _ = self.free_blocks.orderedRemove(i);
            }

            return allocation;
        }

        // Diagnostic: report why reserve failed
        var largest_block: usize = 0;
        var total_free: usize = 0;
        for (self.free_blocks.items) |block| {
            if (block.size > largest_block) largest_block = block.size;
            total_free += block.size;
        }
        log.log.err("GlobalVertexAllocator RESERVE OOM: needed {} ({} vertices), capacity {}MB, total free: {} KB, free blocks: {}. Largest block: {} KB", .{
            size_needed,
            vertex_count,
            self.capacity / (1024 * 1024),
            total_free / 1024,
            self.free_blocks.items.len,
            largest_block / 1024,
        });
        return error.OutOfMemory;
    }

    /// Queues an allocation to be freed later.
    pub fn free(self: *GlobalVertexAllocator, allocation: VertexAllocation) void {
        if (allocation.count == 0) return;

        self.mutex.lock();
        defer self.mutex.unlock();

        // Queue for the NEXT frame slot to ensure GPU is done.
        // tick(frame_index) is called at the start of each frame, freeing the previous
        // frame's deferred allocations. By queuing to the next slot, we guarantee
        // at least 1 frame of safety margin (with MAX_FRAMES_IN_FLIGHT=2, queued in frame N
        // and freed at start of frame N+2).
        const current_frame = self.device_query.getFrameIndex();
        const frame_idx = (current_frame + 1) % rhi_mod.MAX_FRAMES_IN_FLIGHT;
        self.deferred_frees[frame_idx].append(self.allocator, allocation) catch {
            // Fallback to immediate free if queue is full (better than leak, though slightly risky)
            log.log.err("Deferred free queue full, falling back to immediate free", .{});
            self.freeImmediateUnlocked(allocation);
        };
    }

    fn freeImmediateUnlocked(self: *GlobalVertexAllocator, allocation: VertexAllocation) void {
        const size = allocation.count * @sizeOf(Vertex);

        // Safety check: ensure we're not double-freeing or freeing an overlapping region
        for (self.free_blocks.items) |block| {
            if (allocation.offset < block.offset + block.size and allocation.offset + size > block.offset) {
                log.log.err("Double-free or overlapping free detected in GlobalVertexAllocator! offset={}, size={}", .{ allocation.offset, size });
                return;
            }
        }

        // Add new free block and maintain sorted order by offset
        const new_block = FreeBlock{
            .offset = allocation.offset,
            .size = size,
        };

        var insert_idx: usize = self.free_blocks.items.len;
        for (self.free_blocks.items, 0..) |block, i| {
            if (block.offset > allocation.offset) {
                insert_idx = i;
                break;
            }
        }

        self.free_blocks.insert(self.allocator, insert_idx, new_block) catch {
            // Fallback: append to end (loses sort but prevents memory leak)
            self.free_blocks.append(self.allocator, new_block) catch {
                log.log.err("Failed to track free block in GlobalVertexAllocator (insert AND append failed), {} bytes leaked", .{size});
                return;
            };
            // No coalescing possible after unsorted append
            return;
        };

        // Coalesce blocks - check both directions iteratively
        while (true) {
            var coalesced: bool = false;

            // Check with next block(s)
            while (insert_idx + 1 < self.free_blocks.items.len) {
                const next = self.free_blocks.items[insert_idx + 1];
                if (self.free_blocks.items[insert_idx].offset + self.free_blocks.items[insert_idx].size == next.offset) {
                    self.free_blocks.items[insert_idx].size += next.size;
                    _ = self.free_blocks.orderedRemove(insert_idx + 1);
                    coalesced = true;
                } else {
                    break;
                }
            }

            // Check with previous block
            if (insert_idx > 0) {
                const prev = self.free_blocks.items[insert_idx - 1];
                if (prev.offset + prev.size == self.free_blocks.items[insert_idx].offset) {
                    self.free_blocks.items[insert_idx - 1].size += self.free_blocks.items[insert_idx].size;
                    _ = self.free_blocks.orderedRemove(insert_idx);
                    insert_idx -= 1;
                    coalesced = true;
                }
            }

            if (!coalesced) break;
        }
    }
};
