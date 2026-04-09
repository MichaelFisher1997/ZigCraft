//! GPU-driven greedy mesh compute shader dispatch.
//!
//! Reads chunk block data from the GpuBlockBuffer (#389) and produces vertex
//! data directly on the GPU via a compute shader. This eliminates the CPU
//! meshing bottleneck — no worker thread meshing, no vertex upload, no staging
//! buffer.
//!
//! ## Architecture
//!
//! ```
//! [GpuBlockBuffer] → [mesh.comp] → [Vertex Output Buffer] → [Draw]
//!                                       ↑
//!                [Indirect Draw Commands] ←─ [Counters]
//! ```
//!
//! ## Integration
//!
//! The `GpuMesher` is owned by `WorldRenderer` and dispatched by the
//! `MeshBuildPass` render graph pass (before `OpaquePass`). Chunks that need
//! GPU remeshing are queued each frame and dispatched in a single compute pass.
//!
//! ## CPU Fallback
//!
//! If compute capabilities are insufficient (checked at init), the mesher
//! reports `available = false` and the existing CPU meshing pipeline is used.

const std = @import("std");
const c = @import("../c.zig").c;
const log = @import("../engine/core/log.zig");
const rhi_pkg = @import("../engine/graphics/rhi.zig");
const VulkanContext = @import("../engine/graphics/vulkan/rhi_context_types.zig").VulkanContext;
const Utils = @import("../engine/graphics/vulkan/utils.zig");
const GpuBlockBuffer = @import("gpu_block_buffer.zig").GpuBlockBuffer;

pub const MESH_SHADER_PATH = "assets/shaders/vulkan/mesh.comp.spv";
pub const MAX_GPU_MESHER_CHUNKS: usize = 16384;
pub const MAX_VERTICES_PER_CHUNK: u32 = 196608;
pub const VERTEX_SIZE: u32 = 32;
pub const CHUNK_X: u32 = 16;
pub const CHUNK_Y: u32 = 256;
pub const CHUNK_Z: u32 = 16;
pub const SLOT_SIZE: u32 = CHUNK_X * CHUNK_Y * CHUNK_Z;
pub const MAX_FRAMES_IN_FLIGHT = rhi_pkg.MAX_FRAMES_IN_FLIGHT;

pub const MAX_BLOCK_TYPES = 256;

const MeshPushConstants = extern struct {
    chunk_slot: u32,
    chunk_x: u32,
    chunk_z: u32,
    output_offset: u32,
    max_output_verts: u32,
};

pub const ChunkMeshRequest = struct {
    cx: i32,
    cz: i32,
    gpu_slot: usize,
};

pub const GpuMesherStats = struct {
    chunks_dispatched: u32,
    vertices_produced: u32,
    available: bool,
};

pub const GpuMesher = struct {
    allocator: std.mem.Allocator,
    rhi: rhi_pkg.RHI,
    vk_ctx: *VulkanContext,
    available: bool,

    descriptor_pool: c.VkDescriptorPool = null,
    descriptor_set_layout: c.VkDescriptorSetLayout = null,
    descriptor_sets: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet,
    pipeline_layout: c.VkPipelineLayout = null,
    pipeline: c.VkPipeline = null,

    vertex_output_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    counter_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,
    block_props_buffer: Utils.VulkanBuffer,
    neighbor_buffers: [MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer,

    mesh_queue: std.ArrayListUnmanaged(ChunkMeshRequest),
    max_chunks: usize,
    max_total_vertices: u32,

    stats: GpuMesherStats,

    pub fn init(
        allocator: std.mem.Allocator,
        rhi: rhi_pkg.RHI,
        max_chunks: usize,
        gpu_block_buffer: *GpuBlockBuffer,
    ) !*GpuMesher {
        const self = try allocator.create(GpuMesher);
        errdefer allocator.destroy(self);

        const vk_ctx: *VulkanContext = @ptrCast(@alignCast(rhi.ptr));
        const clamped_max = std.math.clamp(max_chunks, 1, MAX_GPU_MESHER_CHUNKS);
        const max_total_verts = clamped_max * MAX_VERTICES_PER_CHUNK;

        self.* = .{
            .allocator = allocator,
            .rhi = rhi,
            .vk_ctx = vk_ctx,
            .available = false,
            .descriptor_sets = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet),
            .vertex_output_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .counter_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .block_props_buffer = .{},
            .neighbor_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer),
            .mesh_queue = .empty,
            .max_chunks = clamped_max,
            .max_total_vertices = @intCast(max_total_verts),
            .stats = .{ .chunks_dispatched = 0, .vertices_produced = 0, .available = false },
        };

        errdefer self.destroyAllBuffers();
        errdefer self.deinitComputeResources();

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            const vert_buf_size: usize = max_total_verts * VERTEX_SIZE;
            self.vertex_output_buffers[i] = Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                vert_buf_size,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                c.VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT,
            ) catch |err| {
                log.log.warn("GpuMesher: vertex output buffer creation failed: {}", .{err});
                return err;
            };

            self.counter_buffers[i] = Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                16,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT | c.VK_BUFFER_USAGE_TRANSFER_DST_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ) catch |err| {
                log.log.warn("GpuMesher: counter buffer creation failed: {}", .{err});
                return err;
            };

            self.neighbor_buffers[i] = Utils.createVulkanBuffer(
                &vk_ctx.vulkan_device,
                16,
                c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
                c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
            ) catch |err| {
                log.log.warn("GpuMesher: neighbor buffer creation failed: {}", .{err});
                return err;
            };
        }

        try self.createBlockPropsBuffer();

        ensureShaderFileExists(MESH_SHADER_PATH) catch |err| {
            log.log.warn("GpuMesher: shader not found: {} — GPU meshing disabled", .{err});
            return self;
        };

        self.initComputeResources(gpu_block_buffer) catch |err| {
            log.log.warn("GpuMesher: compute init failed: {} — GPU meshing disabled", .{err});
            return self;
        };

        self.available = true;
        self.stats.available = true;
        log.log.info("GpuMesher initialized (max_chunks={}, max_vertices={})", .{ clamped_max, max_total_verts });

        return self;
    }

    pub fn deinit(self: *GpuMesher) void {
        self.deinitComputeResources();
        self.destroyAllBuffers();
        self.mesh_queue.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn queueMesh(self: *GpuMesher, cx: i32, cz: i32, gpu_slot: usize) void {
        if (!self.available) return;
        if (self.mesh_queue.items.len >= self.max_chunks) return;
        self.mesh_queue.append(self.allocator, .{
            .cx = cx,
            .cz = cz,
            .gpu_slot = gpu_slot,
        }) catch |err| {
            log.log.debug("GpuMesher: queue failed: {}", .{err});
        };
    }

    pub fn dispatch(self: *GpuMesher, _: *GpuBlockBuffer) void {
        if (!self.available or self.mesh_queue.items.len == 0) return;

        const fi = self.vk_ctx.frames.current_frame;
        const cmd = self.vk_ctx.frames.command_buffers[fi];
        if (cmd == null) return;

        self.resetCounters(cmd, fi);

        var host_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        host_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        host_barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT;
        host_barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_HOST_BIT,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1,
            &host_barrier,
            0,
            null,
            0,
            null,
        );

        c.vkCmdBindPipeline(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline);
        c.vkCmdBindDescriptorSets(cmd, c.VK_PIPELINE_BIND_POINT_COMPUTE, self.pipeline_layout, 0, 1, &self.descriptor_sets[fi], 0, null);

        var chunks_dispatched: u32 = 0;

        for (self.mesh_queue.items) |req| {
            const push = MeshPushConstants{
                .chunk_slot = @intCast(req.gpu_slot),
                .chunk_x = @intCast(req.cx),
                .chunk_z = @intCast(req.cz),
                .output_offset = 0,
                .max_output_verts = self.max_total_vertices,
            };

            c.vkCmdPushConstants(cmd, self.pipeline_layout, c.VK_SHADER_STAGE_COMPUTE_BIT, 0, @sizeOf(MeshPushConstants), &push);
            c.vkCmdDispatch(cmd, CHUNK_Y, 1, 1);
            chunks_dispatched += 1;
        }

        var compute_barrier = std.mem.zeroes(c.VkMemoryBarrier);
        compute_barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        compute_barrier.srcAccessMask = c.VK_ACCESS_SHADER_WRITE_BIT;
        compute_barrier.dstAccessMask = c.VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            c.VK_PIPELINE_STAGE_VERTEX_SHADER_BIT,
            0,
            1,
            &compute_barrier,
            0,
            null,
            0,
            null,
        );

        self.stats.chunks_dispatched = chunks_dispatched;
        self.mesh_queue.clearRetainingCapacity();
    }

    pub fn getVertexOutputBuffer(self: *GpuMesher) ?c.VkBuffer {
        if (!self.available) return null;
        const fi = self.vk_ctx.frames.current_frame;
        return self.vertex_output_buffers[fi].buffer;
    }

    pub fn getStats(self: *const GpuMesher) GpuMesherStats {
        return self.stats;
    }

    pub fn resetFrame(self: *GpuMesher) void {
        self.mesh_queue.clearRetainingCapacity();
        self.stats.chunks_dispatched = 0;
        self.stats.vertices_produced = 0;
    }

    fn resetCounters(self: *GpuMesher, cmd: c.VkCommandBuffer, frame_index: usize) void {
        const buf = &self.counter_buffers[frame_index];
        if (buf.mapped_ptr) |ptr| {
            const zeros: [4]u32 = .{ 0, 0, 0, 0 };
            @memcpy(@as([*]u8, @ptrCast(ptr))[0..16], @as([*]const u8, @ptrCast(&zeros))[0..16]);
        }

        var barrier = std.mem.zeroes(c.VkMemoryBarrier);
        barrier.sType = c.VK_STRUCTURE_TYPE_MEMORY_BARRIER;
        barrier.srcAccessMask = c.VK_ACCESS_HOST_WRITE_BIT;
        barrier.dstAccessMask = c.VK_ACCESS_SHADER_READ_BIT | c.VK_ACCESS_SHADER_WRITE_BIT;
        c.vkCmdPipelineBarrier(
            cmd,
            c.VK_PIPELINE_STAGE_HOST_BIT,
            c.VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT,
            0,
            1,
            &barrier,
            0,
            null,
            0,
            null,
        );
    }

    fn createBlockPropsBuffer(self: *GpuMesher) !void {
        const packed_size = MAX_BLOCK_TYPES * @sizeOf(u32);
        const r_size = MAX_BLOCK_TYPES * @sizeOf(f32);
        const g_size = MAX_BLOCK_TYPES * @sizeOf(f32);
        const b_size = MAX_BLOCK_TYPES * @sizeOf(f32);
        const total_size = packed_size + r_size + g_size + b_size;

        self.block_props_buffer = try Utils.createVulkanBuffer(
            &self.vk_ctx.vulkan_device,
            total_size,
            c.VK_BUFFER_USAGE_STORAGE_BUFFER_BIT,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        if (self.block_props_buffer.mapped_ptr) |ptr| {
            const base: [*]u8 = @ptrCast(ptr);

            var packed_props: [MAX_BLOCK_TYPES]u32 = std.mem.zeroes([MAX_BLOCK_TYPES]u32);
            var colors_r: [MAX_BLOCK_TYPES]f32 = std.mem.zeroes([MAX_BLOCK_TYPES]f32);
            var colors_g: [MAX_BLOCK_TYPES]f32 = std.mem.zeroes([MAX_BLOCK_TYPES]f32);
            var colors_b: [MAX_BLOCK_TYPES]f32 = std.mem.zeroes([MAX_BLOCK_TYPES]f32);

            const block_registry = @import("block_registry.zig").BLOCK_REGISTRY;
            for (0..MAX_BLOCK_TYPES) |i| {
                const def = block_registry[i];
                var p: u32 = 0;
                if (def.is_solid) p |= 0x1;
                if (def.is_transparent) p |= 0x2;
                if (def.is_fluid) p |= 0x4;
                if (def.is_tintable) p |= 0x8;
                const rp: u32 = switch (def.render_pass) {
                    .solid => 0,
                    .cutout => 1,
                    .fluid => 2,
                    .translucent => 1,
                };
                p |= rp << 4;
                const rs: u32 = switch (def.render_shape) {
                    .cube => 0,
                    .cross => 1,
                };
                p |= rs << 6;

                packed_props[i] = p;
                colors_r[i] = def.default_color[0];
                colors_g[i] = def.default_color[1];
                colors_b[i] = def.default_color[2];
            }

            @memcpy(base[0..packed_size], std.mem.sliceAsBytes(&packed_props));
            @memcpy(base[packed_size .. packed_size + r_size], std.mem.sliceAsBytes(&colors_r));
            @memcpy(base[packed_size + r_size .. packed_size + r_size + g_size], std.mem.sliceAsBytes(&colors_g));
            @memcpy(base[packed_size + r_size + g_size .. total_size], std.mem.sliceAsBytes(&colors_b));
        }
    }

    fn initComputeResources(self: *GpuMesher, gpu_block_buffer: *GpuBlockBuffer) !void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        var pool_sizes = [_]c.VkDescriptorPoolSize{
            .{ .type = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 6 * MAX_FRAMES_IN_FLIGHT },
        };

        var pool_info = std.mem.zeroes(c.VkDescriptorPoolCreateInfo);
        pool_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
        pool_info.maxSets = MAX_FRAMES_IN_FLIGHT;
        pool_info.poolSizeCount = pool_sizes.len;
        pool_info.pPoolSizes = &pool_sizes;
        try Utils.checkVk(c.vkCreateDescriptorPool(vk, &pool_info, null, &self.descriptor_pool));

        const bindings = [_]c.VkDescriptorSetLayoutBinding{
            .{ .binding = 0, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 1, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 2, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 3, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 4, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
            .{ .binding = 5, .descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, .descriptorCount = 1, .stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT, .pImmutableSamplers = null },
        };

        var layout_info = std.mem.zeroes(c.VkDescriptorSetLayoutCreateInfo);
        layout_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
        layout_info.bindingCount = bindings.len;
        layout_info.pBindings = &bindings;
        try Utils.checkVk(c.vkCreateDescriptorSetLayout(vk, &layout_info, null, &self.descriptor_set_layout));

        var layouts = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSetLayout);
        for (&layouts) |*l| l.* = self.descriptor_set_layout;

        var alloc_info = std.mem.zeroes(c.VkDescriptorSetAllocateInfo);
        alloc_info.sType = c.VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
        alloc_info.descriptorPool = self.descriptor_pool;
        alloc_info.descriptorSetCount = MAX_FRAMES_IN_FLIGHT;
        alloc_info.pSetLayouts = &layouts;
        try Utils.checkVk(c.vkAllocateDescriptorSets(vk, &alloc_info, &self.descriptor_sets));

        self.updateDescriptorSets(gpu_block_buffer);

        var pc_range = std.mem.zeroes(c.VkPushConstantRange);
        pc_range.stageFlags = c.VK_SHADER_STAGE_COMPUTE_BIT;
        pc_range.offset = 0;
        pc_range.size = @sizeOf(MeshPushConstants);

        var pipeline_layout_info = std.mem.zeroes(c.VkPipelineLayoutCreateInfo);
        pipeline_layout_info.sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
        pipeline_layout_info.setLayoutCount = 1;
        pipeline_layout_info.pSetLayouts = &self.descriptor_set_layout;
        pipeline_layout_info.pushConstantRangeCount = 1;
        pipeline_layout_info.pPushConstantRanges = &pc_range;
        try Utils.checkVk(c.vkCreatePipelineLayout(vk, &pipeline_layout_info, null, &self.pipeline_layout));

        const shader_module = try loadShaderModule(vk, MESH_SHADER_PATH, self.allocator);
        defer c.vkDestroyShaderModule(vk, shader_module, null);

        var stage = std.mem.zeroes(c.VkPipelineShaderStageCreateInfo);
        stage.sType = c.VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
        stage.stage = c.VK_SHADER_STAGE_COMPUTE_BIT;
        stage.module = shader_module;
        stage.pName = "main";

        var pipeline_info = std.mem.zeroes(c.VkComputePipelineCreateInfo);
        pipeline_info.sType = c.VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO;
        pipeline_info.stage = stage;
        pipeline_info.layout = self.pipeline_layout;
        try Utils.checkVk(c.vkCreateComputePipelines(vk, null, 1, &pipeline_info, null, &self.pipeline));
    }

    fn updateDescriptorSets(self: *GpuMesher, gpu_block_buffer: *GpuBlockBuffer) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;
        const block_buf_handle = gpu_block_buffer.getBufferHandle();

        const native_block_buf: c.VkBuffer = if (self.vk_ctx.resources.buffers.get(block_buf_handle)) |vb| vb.buffer else null;

        var writes: [6 * MAX_FRAMES_IN_FLIGHT]c.VkWriteDescriptorSet = undefined;
        var block_buf_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var props_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var vert_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var cmd_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var counter_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var neighbor_infos: [MAX_FRAMES_IN_FLIGHT]c.VkDescriptorBufferInfo = undefined;
        var n: usize = 0;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            block_buf_infos[i] = .{
                .buffer = native_block_buf,
                .offset = 0,
                .range = c.VK_WHOLE_SIZE,
            };

            props_infos[i] = .{
                .buffer = self.block_props_buffer.buffer,
                .offset = 0,
                .range = c.VK_WHOLE_SIZE,
            };

            vert_infos[i] = .{
                .buffer = self.vertex_output_buffers[i].buffer,
                .offset = 0,
                .range = c.VK_WHOLE_SIZE,
            };

            cmd_infos[i] = .{
                .buffer = self.vertex_output_buffers[i].buffer,
                .offset = 0,
                .range = c.VK_WHOLE_SIZE,
            };

            counter_infos[i] = .{
                .buffer = self.counter_buffers[i].buffer,
                .offset = 0,
                .range = 16,
            };

            neighbor_infos[i] = .{
                .buffer = self.neighbor_buffers[i].buffer,
                .offset = 0,
                .range = 16,
            };

            const set = self.descriptor_sets[i];

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = set;
            writes[n].dstBinding = 0;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &block_buf_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = set;
            writes[n].dstBinding = 1;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &props_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = set;
            writes[n].dstBinding = 2;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &vert_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = set;
            writes[n].dstBinding = 3;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &cmd_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = set;
            writes[n].dstBinding = 4;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &counter_infos[i];
            n += 1;

            writes[n] = std.mem.zeroes(c.VkWriteDescriptorSet);
            writes[n].sType = c.VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
            writes[n].dstSet = set;
            writes[n].dstBinding = 5;
            writes[n].descriptorType = c.VK_DESCRIPTOR_TYPE_STORAGE_BUFFER;
            writes[n].descriptorCount = 1;
            writes[n].pBufferInfo = &neighbor_infos[i];
            n += 1;
        }

        c.vkUpdateDescriptorSets(vk, @intCast(n), &writes[0], 0, null);
    }

    fn deinitComputeResources(self: *GpuMesher) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;
        if (self.pipeline != null) c.vkDestroyPipeline(vk, self.pipeline, null);
        if (self.pipeline_layout != null) c.vkDestroyPipelineLayout(vk, self.pipeline_layout, null);
        if (self.descriptor_set_layout != null) c.vkDestroyDescriptorSetLayout(vk, self.descriptor_set_layout, null);
        if (self.descriptor_pool != null) c.vkDestroyDescriptorPool(vk, self.descriptor_pool, null);

        self.pipeline = null;
        self.pipeline_layout = null;
        self.descriptor_set_layout = null;
        self.descriptor_pool = null;
        self.descriptor_sets = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]c.VkDescriptorSet);
    }

    fn destroyAllBuffers(self: *GpuMesher) void {
        const vk = self.vk_ctx.vulkan_device.vk_device;

        for (0..MAX_FRAMES_IN_FLIGHT) |i| {
            destroyVulkanBuffer(vk, &self.vertex_output_buffers[i]);
            destroyVulkanBuffer(vk, &self.counter_buffers[i]);
            destroyVulkanBuffer(vk, &self.neighbor_buffers[i]);
        }
        destroyVulkanBuffer(vk, &self.block_props_buffer);

        self.vertex_output_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
        self.counter_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
        self.neighbor_buffers = std.mem.zeroes([MAX_FRAMES_IN_FLIGHT]Utils.VulkanBuffer);
        self.block_props_buffer = .{};
    }
};

fn destroyVulkanBuffer(vk: c.VkDevice, buf: *Utils.VulkanBuffer) void {
    if (buf.mapped_ptr != null) {
        c.vkUnmapMemory(vk, buf.memory);
        buf.mapped_ptr = null;
    }
    if (buf.buffer != null) c.vkDestroyBuffer(vk, buf.buffer, null);
    if (buf.memory != null) c.vkFreeMemory(vk, buf.memory, null);
    buf.* = .{};
}

fn loadShaderModule(vk: c.VkDevice, path: []const u8, allocator: std.mem.Allocator) !c.VkShaderModule {
    const bytes = try std.fs.cwd().readFileAlloc(path, allocator, @enumFromInt(16 * 1024 * 1024));
    defer allocator.free(bytes);
    if (bytes.len % 4 != 0) return error.InvalidShader;

    var info = std.mem.zeroes(c.VkShaderModuleCreateInfo);
    info.sType = c.VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    info.codeSize = bytes.len;
    info.pCode = @ptrCast(@alignCast(bytes.ptr));

    var module: c.VkShaderModule = null;
    try Utils.checkVk(c.vkCreateShaderModule(vk, &info, null, &module));
    return module;
}

fn ensureShaderFileExists(path: []const u8) !void {
    std.fs.cwd().access(path, .{}) catch |err| {
        log.log.errWithTrace("Mesh shader artifact missing: {s} ({})", .{ path, err });
        log.log.err("Run `nix develop --command zig build` to regenerate Vulkan SPIR-V shaders.", .{});
        return err;
    };
}
