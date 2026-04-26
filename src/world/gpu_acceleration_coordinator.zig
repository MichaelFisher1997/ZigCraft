//! GPU acceleration coordinator for chunk block uploads and GPU meshing.

const std = @import("std");
const log = @import("../engine/core/log.zig");
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const ChunkData = @import("chunk_storage.zig").ChunkData;
const GpuBlockBuffer = @import("gpu_block_buffer.zig").GpuBlockBuffer;
const GpuMesher = @import("gpu_mesher.zig").GpuMesher;

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

pub const GpuAccelerationCoordinator = struct {
    gpu_block_buffer: ?*GpuBlockBuffer,
    gpu_mesher: ?*GpuMesher,

    /// When true, forces CPU meshing even if GPU mesher is available.
    /// Set via ZIGCRAFT_FORCE_CPU_MESHING=1 env var at runtime.
    force_cpu_meshing: bool = false,

    pub fn init(gpu_block_buffer: ?*GpuBlockBuffer, gpu_mesher: ?*GpuMesher) GpuAccelerationCoordinator {
        return .{
            .gpu_block_buffer = gpu_block_buffer,
            .gpu_mesher = gpu_mesher,
        };
    }

    pub fn isGpuMeshingEnabled(self: *const GpuAccelerationCoordinator) bool {
        return self.gpu_mesher != null and self.gpu_block_buffer != null and !self.force_cpu_meshing;
    }

    pub fn refreshForceCpuMeshing(self: *GpuAccelerationCoordinator, frame_counter: u64, storage: *ChunkStorage) void {
        if (self.gpu_mesher == null or frame_counter % 30 != 0) return;

        const env_val = getenv("ZIGCRAFT_FORCE_CPU_MESHING");
        const new_force_cpu = if (env_val) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;

        if (new_force_cpu == self.force_cpu_meshing) return;

        self.force_cpu_meshing = new_force_cpu;
        if (!new_force_cpu) return;

        log.log.warn("FORCE_CPU_MESHING: GPU mesher disabled at runtime, resetting mesh-ready/uploading chunks for CPU re-mesh", .{});
        storage.chunks_mutex.lock();
        defer storage.chunks_mutex.unlock();

        var reset_iter = storage.iteratorUnsafe();
        while (reset_iter.next()) |entry| {
            const chunk = &entry.value_ptr.*.chunk;
            if (chunk.state == .mesh_ready or chunk.state == .uploading) {
                chunk.state = .generated;
            }
        }
    }

    pub fn shouldUseGpuMeshReadyPath(self: *const GpuAccelerationCoordinator) bool {
        return self.isGpuMeshingEnabled();
    }

    pub fn queueGpuMesh(self: *GpuAccelerationCoordinator, data: *ChunkData) bool {
        if (!self.isGpuMeshingEnabled()) return false;
        const buf = self.gpu_block_buffer orelse return false;
        const mesher = self.gpu_mesher.?;

        const slot = if (buf.getSlotForChunk(data.chunk.chunk_x, data.chunk.chunk_z)) |existing|
            existing
        else
            buf.allocate(data.chunk.chunk_x, data.chunk.chunk_z) catch |err| {
                log.log.err("GpuBlockBuffer allocation failed for chunk ({}, {}): {}", .{ data.chunk.chunk_x, data.chunk.chunk_z, err });
                data.chunk.state = .generated;
                return true;
            };

        const blocks_slice: []const u8 = @as([]const u8, @ptrCast(&data.chunk.blocks));
        buf.upload(slot, blocks_slice) catch |upload_err| {
            log.log.err("GpuBlockBuffer upload failed for chunk ({}, {}): {}", .{ data.chunk.chunk_x, data.chunk.chunk_z, upload_err });
            buf.free(slot);
            data.chunk.state = .generated;
            return true;
        };

        if (mesher.queueMesh(data.chunk.chunk_x, data.chunk.chunk_z, slot, data.chunk.job_token)) {
            data.chunk.state = .uploading;
        } else {
            data.chunk.state = .mesh_ready;
        }
        return true;
    }

    pub fn freeChunk(self: *GpuAccelerationCoordinator, cx: i32, cz: i32) void {
        if (self.gpu_block_buffer) |buf| {
            _ = buf.freeByChunk(cx, cz);
        }
    }
};
