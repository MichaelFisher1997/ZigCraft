const std = @import("std");
const fs = @import("fs");
const sync = @import("sync");
const lod_chunk = @import("lod_chunk.zig");
const LODLevel = lod_chunk.LODLevel;
const LODChunk = lod_chunk.LODChunk;
const LODRegionKey = lod_chunk.LODRegionKey;
const LODConfig = lod_chunk.LODConfig;
const LODState = lod_chunk.LODState;
const LODSimplifiedData = lod_chunk.LODSimplifiedData;
const world_core = @import("world-core");
const LODColumnProvenance = world_core.LODColumnProvenance;
const Vec3 = @import("engine-math").Vec3;
const Vertex = @import("engine-rhi").Vertex;
const RingBuffer = @import("engine-core").ring_buffer.RingBuffer;
const JobQueue = @import("engine-core").job_system.JobQueue;
const LODMesh = @import("lod_mesh.zig").LODMesh;
const lod_gpu = @import("lod_upload_queue.zig");
const LODGPUBridge = lod_gpu.LODGPUBridge;
const MeshMap = lod_gpu.MeshMap;
const RegionMap = lod_gpu.RegionMap;
const lod_cache = @import("lod_cache.zig");
const lod_store = @import("lod_store.zig");
const manager_mod = @import("lod_manager.zig");
const LODManager = manager_mod.LODManager;
const MAX_CACHE_LOADS_PER_UPDATE = @import("lod_manager_context.zig").MAX_CACHE_LOADS_PER_UPDATE;
const DEFAULT_LOD_UPLOAD_BUDGET_BYTES = @import("lod_manager_context.zig").DEFAULT_LOD_UPLOAD_BUDGET_BYTES;
const wouldExceedUploadBudget = @import("lod_manager_context.zig").wouldExceedUploadBudget;
const cancelWorkOutsideHorizon = @import("lod_manager_core_ops.zig").cancelWorkOutsideHorizon;
const testing = std.testing;

test "LODManager cache helpers save and reload source data" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);
    const key = LODRegionKey{ .rx = 2, .rz = -3, .lod = .lod1 };

    var data = try LODSimplifiedData.init(testing.allocator, .lod1);
    defer data.deinit();
    data.setColumn(1, 1, 72.0, .forest, .{
        .surface = .grass,
        .subsurface = .dirt,
        .foundation = .stone,
    }, 0xFF112233, .empty, .daylight, .empty);

    manager.saveCachedSourceData(key, &data);
    manager.flushCacheIO();

    const store_path = try lod_store.containerPath(testing.allocator, save_dir_path, manager.cacheKey(key));
    defer testing.allocator.free(store_path);
    fs.cwd().access(store_path, .{}) catch return error.ExpectedStoreContainer;

    var loaded = manager.loadCachedSourceData(key) orelse return error.ExpectedCacheHit;
    defer loaded.deinit();

    const idx = 1 + data.width;
    try testing.expectEqual(data.heightmap[idx], loaded.heightmap[idx]);
    try testing.expectEqual(data.biomes[idx], loaded.biomes[idx]);
    try testing.expectEqual(data.material_layers[idx].foundation, loaded.material_layers[idx].foundation);
}

test "LODManager cache helpers delete corrupt cache files" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);
    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod2 };
    const legacy_dir = try fs.path.join(testing.allocator, &.{ save_dir_path, "lod_cache" });
    defer testing.allocator.free(legacy_dir);
    try fs.cwd().makePath(legacy_dir);
    const path = try manager.legacyCacheFilePath(save_dir_path, manager.cacheKey(key));
    defer testing.allocator.free(path);

    const file = try fs.cwd().createFile(path, .{ .truncate = true });
    try file.writeAll(&.{ 0, 1, 2, 3 });
    file.close();

    try testing.expect(manager.loadCachedSourceData(key) == null);
    try testing.expectError(error.FileNotFound, fs.cwd().openFile(path, .{}));
}

test "LODManager enableCache deletes stale generator-keyed store and writes live header" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    try lod_store.writeHeader(testing.allocator, save_dir_path, .{
        .seed = 42,
        .generator_identity_hash = 1234,
        .generator_version = 1,
    });
    const stale_key = lod_cache.Key{ .seed = 42, .generator_identity_hash = 1234, .generator_version = 1, .rx = 0, .rz = 0, .lod = .lod1 };
    try lod_store.writePayload(testing.allocator, save_dir_path, stale_key, "stale", lod_store.DEFAULT_STORE_SIZE_CAP_MB);

    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    manager.cache_store.cache_dir_path = null;
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);

    try testing.expect((try lod_store.readPayload(testing.allocator, save_dir_path, stale_key)) == null);
    const header = (try lod_store.readHeader(testing.allocator, save_dir_path)).?;
    try testing.expectEqual(@as(u64, 42), header.seed);
    try testing.expectEqual(@as(u64, 99), header.generator_identity_hash);
    try testing.expectEqual(@as(u32, 7), header.generator_version);
}

test "LODManager enableCache deletes stale data-version store" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    try lod_store.writeHeader(testing.allocator, save_dir_path, .{
        .seed = 42,
        .generator_identity_hash = 99,
        .generator_version = 7,
        .lod_data_version = lod_cache.CACHE_VERSION - 1,
    });
    const stale_key = lod_cache.Key{ .seed = 42, .generator_identity_hash = 99, .generator_version = 7, .rx = 0, .rz = 0, .lod = .lod1 };
    try lod_store.writePayload(testing.allocator, save_dir_path, stale_key, "stale", lod_store.DEFAULT_STORE_SIZE_CAP_MB);

    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    manager.cache_store.cache_dir_path = null;
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);

    try testing.expect((try lod_store.readPayload(testing.allocator, save_dir_path, stale_key)) == null);
    const header = (try lod_store.readHeader(testing.allocator, save_dir_path)).?;
    try testing.expectEqual(lod_cache.CACHE_VERSION, header.lod_data_version);
}

test "LODManager queued generation applies source-store completion asynchronously" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var config = LODConfig{};
    const key = LODRegionKey{ .rx = 4, .rz = -2, .lod = .lod1 };

    var source = try LODSimplifiedData.initWithVerticalSpans(testing.allocator, .lod1);
    defer source.deinit();
    source.setColumn(2, 3, 81.0, .forest, .{
        .surface = .grass,
        .subsurface = .dirt,
        .foundation = .stone,
    }, 0xFF445566, .empty, .daylight, .empty);

    var writer = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer writer.cache_io.deinit();
    writer.config = config.interface();
    writer.cache_store.cache_dir_path = null;
    try writer.enableCache(save_dir_path);
    writer.saveCachedSourceData(key, &source);
    writer.flushCacheIO();
    if (writer.cache_store.cache_dir_path) |path| testing.allocator.free(path);
    writer.ingestion_queue.edit_dirty.deinit();

    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    manager.config = config.interface();
    manager.cache_store.cache_dir_path = null;
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);
    defer manager.ingestion_queue.edit_dirty.deinit();
    defer manager.mesh_disposal.queue.deinit(testing.allocator);

    for (0..LODLevel.count) |i| {
        manager.regions[i] = RegionMap.init(testing.allocator);
        manager.meshes[i] = MeshMap.init(testing.allocator);
        manager.upload_queues[i] = try RingBuffer(*LODChunk).init(testing.allocator, 4);
        manager.job_dispatcher.queues[i] = try testing.allocator.create(JobQueue);
        manager.job_dispatcher.queues[i].* = JobQueue.init(testing.allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            var region_iter = manager.regions[i].iterator();
            while (region_iter.next()) |entry| {
                entry.value_ptr.*.deinit(testing.allocator);
                testing.allocator.destroy(entry.value_ptr.*);
            }
            manager.regions[i].deinit();
            manager.meshes[i].deinit();
            manager.upload_queues[i].deinit();
            manager.job_dispatcher.queues[i].deinit();
            testing.allocator.destroy(manager.job_dispatcher.queues[i]);
        }
    }

    const chunk = try testing.allocator.create(LODChunk);
    chunk.* = LODChunk.init(key.rx, key.rz, key.lod);
    chunk.state = .queued_for_generation;
    chunk.job_token = 9;
    try manager.regions[@intFromEnum(key.lod)].put(key, chunk);

    try manager.processQueuedGenerations(Vec3.zero);

    // The update-side call only enqueues the read; no source data has been
    // deserialized or applied until the dedicated cache worker completes.
    try testing.expectEqual(@as(u32, 0), manager.cache_hits);
    try testing.expectEqual(LODState.queued_for_generation, chunk.state);
    manager.flushCacheIO();

    try testing.expectEqual(@as(u32, 1), manager.cache_hits);
    try testing.expectEqual(@as(usize, 0), manager.job_dispatcher.queues[LODLevel.count - 1].count());
    try testing.expectEqual(LODState.generated, chunk.state);
    switch (chunk.data) {
        .simplified => |*loaded| {
            const idx = 2 + 3 * loaded.width;
            try testing.expectEqual(source.heightmap[idx], loaded.heightmap[idx]);
            try testing.expectEqual(source.material_layers[idx].foundation, loaded.material_layers[idx].foundation);
        },
        else => return error.ExpectedSimplifiedData,
    }
}

test "LODManager queued generation dispatches beyond cache read budget" {
    var tmp_dir = testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const dir = fs.Dir{ .inner = tmp_dir.dir };
    var path_buf: [fs.max_path_bytes]u8 = undefined;
    const save_dir_path = try dir.realpath(".", &path_buf);

    var config = LODConfig{};
    var manager = try LODManager.initCacheTestManager(testing.allocator, save_dir_path);
    defer manager.cache_io.deinit();
    manager.config = config.interface();
    manager.cache_store.cache_dir_path = null;
    try manager.enableCache(save_dir_path);
    defer if (manager.cache_store.cache_dir_path) |path| testing.allocator.free(path);
    defer manager.ingestion_queue.edit_dirty.deinit();
    defer manager.mesh_disposal.queue.deinit(testing.allocator);

    for (0..LODLevel.count) |i| {
        manager.regions[i] = RegionMap.init(testing.allocator);
        manager.meshes[i] = MeshMap.init(testing.allocator);
        manager.upload_queues[i] = try RingBuffer(*LODChunk).init(testing.allocator, 4);
        manager.job_dispatcher.queues[i] = try testing.allocator.create(JobQueue);
        manager.job_dispatcher.queues[i].* = JobQueue.init(testing.allocator);
    }
    defer {
        for (0..LODLevel.count) |i| {
            var region_iter = manager.regions[i].iterator();
            while (region_iter.next()) |entry| {
                entry.value_ptr.*.deinit(testing.allocator);
                testing.allocator.destroy(entry.value_ptr.*);
            }
            manager.regions[i].deinit();
            manager.meshes[i].deinit();
            manager.upload_queues[i].deinit();
            manager.job_dispatcher.queues[i].deinit();
            testing.allocator.destroy(manager.job_dispatcher.queues[i]);
        }
    }

    const candidate_count = MAX_CACHE_LOADS_PER_UPDATE + 4;
    for (0..candidate_count) |i| {
        const key = LODRegionKey{ .rx = @intCast(i), .rz = 0, .lod = .lod1 };
        const chunk = try testing.allocator.create(LODChunk);
        chunk.* = LODChunk.init(key.rx, key.rz, key.lod);
        chunk.state = .queued_for_generation;
        chunk.job_token = @intCast(i + 1);
        try manager.regions[@intFromEnum(key.lod)].put(key, chunk);
    }

    try manager.processQueuedGenerations(Vec3.zero);

    try testing.expectEqual(@as(u32, 0), manager.cache_misses);
    try testing.expectEqual(candidate_count - MAX_CACHE_LOADS_PER_UPDATE, manager.job_dispatcher.queues[LODLevel.count - 1].count());
    manager.flushCacheIO();
    try testing.expectEqual(@as(u32, @intCast(MAX_CACHE_LOADS_PER_UPDATE)), manager.cache_misses);
    try testing.expectEqual(candidate_count, manager.job_dispatcher.queues[LODLevel.count - 1].count());
}

fn initEvictionTestManager(allocator: std.mem.Allocator, config: *LODConfig) !LODManager {
    var manager = try LODManager.initCacheTestManager(allocator, "");
    manager.config = config.interface();
    for (0..LODLevel.count) |i| {
        manager.regions[i] = RegionMap.init(allocator);
        manager.meshes[i] = MeshMap.init(allocator);
        manager.upload_queues[i] = try RingBuffer(*LODChunk).init(allocator, 4);
        manager.job_dispatcher.queues[i] = try allocator.create(JobQueue);
        manager.job_dispatcher.queues[i].* = JobQueue.init(allocator);
    }
    var bridge_ctx: u8 = 0;
    manager.gpu_bridge = .{
        .on_upload = struct {
            fn f(_: *LODMesh, _: *anyopaque) @import("engine-rhi").RhiError!void {}
        }.f,
        .on_destroy = struct {
            fn f(_: *LODMesh, _: *anyopaque) void {}
        }.f,
        .on_wait_idle = struct {
            fn f(_: *anyopaque) void {}
        }.f,
        .ctx = @ptrCast(&bridge_ctx),
    };
    return manager;
}

fn deinitEvictionTestManager(manager: *LODManager) void {
    manager.cache_io.deinit();
    for (0..LODLevel.count) |i| {
        var region_iter = manager.regions[i].iterator();
        while (region_iter.next()) |entry| {
            entry.value_ptr.*.deinit(manager.allocator);
            manager.allocator.destroy(entry.value_ptr.*);
        }
        manager.regions[i].deinit();

        var mesh_iter = manager.meshes[i].iterator();
        while (mesh_iter.next()) |entry| {
            if (entry.value_ptr.*.pending_vertices) |pending| {
                manager.allocator.free(pending);
            }
            manager.allocator.destroy(entry.value_ptr.*);
        }
        manager.meshes[i].deinit();
        manager.upload_queues[i].deinit();
        manager.job_dispatcher.queues[i].deinit();
        manager.allocator.destroy(manager.job_dispatcher.queues[i]);
    }
    for (manager.mesh_disposal.queue.items) |mesh| {
        manager.allocator.destroy(mesh);
    }
    manager.mesh_disposal.queue.deinit(manager.allocator);
    manager.ingestion_queue.edit_dirty.deinit();
}

fn putTestRegion(manager: *LODManager, key: LODRegionKey, state: LODState) !*LODChunk {
    const chunk = try manager.allocator.create(LODChunk);
    chunk.* = LODChunk.init(key.rx, key.rz, key.lod);
    chunk.state = state;
    try manager.regions[@intFromEnum(key.lod)].put(key, chunk);
    return chunk;
}

fn putTestMesh(manager: *LODManager, key: LODRegionKey, capacity: u32) !*LODMesh {
    const mesh = try manager.allocator.create(LODMesh);
    mesh.* = LODMesh.init(manager.allocator, key.lod);
    mesh.ready = true;
    mesh.vertex_count = capacity;
    mesh.capacity = capacity;
    try manager.meshes[@intFromEnum(key.lod)].put(key, mesh);
    return mesh;
}

fn putTestPendingMesh(manager: *LODManager, key: LODRegionKey, vertex_count: usize) !*LODMesh {
    const mesh = try manager.allocator.create(LODMesh);
    mesh.* = LODMesh.init(manager.allocator, key.lod);
    mesh.pending_vertices = try manager.allocator.alloc(Vertex, vertex_count);
    try manager.meshes[@intFromEnum(key.lod)].put(key, mesh);
    return mesh;
}

const UploadMock = struct {
    allocator: std.mem.Allocator,
    calls: u32 = 0,
    fail_with_pressure: bool = false,

    fn bridge(self: *UploadMock) LODGPUBridge {
        return .{
            .on_upload = upload,
            .on_destroy = destroy,
            .on_wait_idle = waitIdle,
            .ctx = @ptrCast(self),
        };
    }

    fn upload(mesh: *LODMesh, ctx: *anyopaque) @import("engine-rhi").RhiError!void {
        const self: *UploadMock = @ptrCast(@alignCast(ctx));
        self.calls += 1;
        if (self.fail_with_pressure) return error.OutOfMemory;
        if (mesh.pending_vertices) |pending| {
            mesh.vertex_count = @intCast(pending.len);
            mesh.opaque_vertex_count = @intCast(pending.len);
            mesh.ready = true;
            self.allocator.free(pending);
            mesh.pending_vertices = null;
        }
    }

    fn destroy(_: *LODMesh, _: *anyopaque) void {}
    fn waitIdle(_: *anyopaque) void {}
};

test "LODManager upload budget defers remaining queued meshes" {
    var config = LODConfig{ .max_uploads_per_frame = 8 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var mock = UploadMock{ .allocator = testing.allocator };
    manager.gpu_bridge = mock.bridge();

    const first_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const second_key = LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod1 };
    const first = try putTestRegion(&manager, first_key, .uploading);
    const second = try putTestRegion(&manager, second_key, .uploading);
    _ = try putTestPendingMesh(&manager, first_key, 1);
    _ = try putTestPendingMesh(&manager, second_key, 1);
    try manager.upload_queues[1].push(first);
    try manager.upload_queues[1].push(second);

    manager.processUploadsWithBudget(@sizeOf(Vertex));

    try testing.expectEqual(@as(u32, 1), mock.calls);
    try testing.expectEqual(LODState.renderable, first.state);
    try testing.expectEqual(LODState.uploading, second.state);
    try testing.expectEqual(@as(usize, 1), manager.upload_queues[1].count());
}

test "LODManager upload budget defers an oversized first mesh" {
    var config = LODConfig{ .max_uploads_per_frame = 8 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var mock = UploadMock{ .allocator = testing.allocator };
    manager.gpu_bridge = mock.bridge();

    const key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const chunk = try putTestRegion(&manager, key, .uploading);
    _ = try putTestPendingMesh(&manager, key, 1);
    try manager.upload_queues[1].push(chunk);

    manager.processUploadsWithBudget(@sizeOf(Vertex) - 1);

    try testing.expectEqual(@as(u32, 0), mock.calls);
    try testing.expectEqual(LODState.uploading, chunk.state);
    try testing.expectEqual(@as(usize, 1), manager.upload_queues[1].count());
}

test "LOD upload budget permits zero-pending and unlimited uploads" {
    const pending_bytes = @sizeOf(Vertex);

    try testing.expect(!wouldExceedUploadBudget(0, 0, 1));
    try testing.expect(!wouldExceedUploadBudget(0, pending_bytes, 0));
    try testing.expect(!wouldExceedUploadBudget(0, pending_bytes, std.math.maxInt(usize)));
}

test "LODManager staging pressure failure stops upload sweep" {
    var config = LODConfig{ .max_uploads_per_frame = 8 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    var mock = UploadMock{ .allocator = testing.allocator, .fail_with_pressure = true };
    manager.gpu_bridge = mock.bridge();

    const first_key = LODRegionKey{ .rx = 0, .rz = 0, .lod = .lod1 };
    const second_key = LODRegionKey{ .rx = 1, .rz = 0, .lod = .lod1 };
    const first = try putTestRegion(&manager, first_key, .uploading);
    const second = try putTestRegion(&manager, second_key, .uploading);
    _ = try putTestPendingMesh(&manager, first_key, 1);
    _ = try putTestPendingMesh(&manager, second_key, 1);
    try manager.upload_queues[1].push(first);
    try manager.upload_queues[1].push(second);

    manager.processUploadsWithBudget(DEFAULT_LOD_UPLOAD_BUDGET_BYTES);

    try testing.expectEqual(@as(u32, 1), mock.calls);
    try testing.expectEqual(LODState.uploading, first.state);
    try testing.expectEqual(LODState.uploading, second.state);
    try testing.expectEqual(@as(usize, 2), manager.upload_queues[1].count());
    try testing.expectEqual(@as(u32, 1), manager.stats.upload_failures);
}

test "LODManager pause cancels queued and pinned stale work" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const queued_generation = try putTestRegion(&manager, .{ .rx = 0, .rz = 0, .lod = .lod1 }, .generating);
    queued_generation.job_token = 11;
    const queued_mesh = try putTestRegion(&manager, .{ .rx = 1, .rz = 0, .lod = .lod1 }, .meshing);
    queued_mesh.job_token = 12;
    const running_generation = try putTestRegion(&manager, .{ .rx = 2, .rz = 0, .lod = .lod1 }, .generating);
    running_generation.job_token = 13;
    running_generation.pin();
    defer running_generation.unpin();
    const running_mesh = try putTestRegion(&manager, .{ .rx = 3, .rz = 0, .lod = .lod1 }, .meshing);
    running_mesh.job_token = 14;
    running_mesh.pin();
    defer running_mesh.unpin();
    manager.pending_region_count = 4;

    const queue = manager.job_dispatcher.queues[LODLevel.count - 1];
    try queue.push(.{ .type = .chunk_generation, .data = .{ .chunk = .{ .x = 0, .z = 0, .job_token = 11, .lod_level = 1 } } });
    try queue.push(.{ .type = .chunk_meshing, .data = .{ .chunk = .{ .x = 1, .z = 0, .job_token = 12, .lod_level = 1 } } });

    manager.pause();

    try testing.expectEqual(@as(usize, 0), queue.count());
    try testing.expectEqual(LODState.missing, queued_generation.state);
    try testing.expectEqual(@as(u32, 12), queued_generation.job_token);
    try testing.expectEqual(LODState.generated, queued_mesh.state);
    try testing.expectEqual(@as(u32, 13), queued_mesh.job_token);
    try testing.expectEqual(LODState.missing, running_generation.state);
    try testing.expectEqual(@as(u32, 14), running_generation.job_token);
    try testing.expect(running_generation.cancellationRequested());
    try testing.expectEqual(LODState.generated, running_mesh.state);
    try testing.expectEqual(@as(u32, 15), running_mesh.job_token);
    try testing.expect(running_mesh.cancellationRequested());
    try testing.expectEqual(@as(usize, 2), manager.pending_region_count);
    try testing.expectEqual(@as(u32, 4), manager.cancelled_jobs);
}

test "LODManager traversal cancels work outside its level horizon" {
    var config = LODConfig{ .radii = .{ 8, 16, 32, 64, 128 } };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const near = try putTestRegion(&manager, .{ .rx = 0, .rz = 0, .lod = .lod1 }, .generating);
    near.job_token = 7;
    const stale = try putTestRegion(&manager, .{ .rx = 100, .rz = 100, .lod = .lod1 }, .generating);
    stale.job_token = 9;
    stale.cache_read_queued = true;
    manager.pending_region_count = 2;

    cancelWorkOutsideHorizon(&manager, 0, 0);

    try testing.expectEqual(LODState.generating, near.state);
    try testing.expectEqual(@as(u32, 7), near.job_token);
    try testing.expect(!near.cancellationRequested());
    try testing.expectEqual(LODState.missing, stale.state);
    try testing.expectEqual(@as(u32, 10), stale.job_token);
    try testing.expect(stale.cancellationRequested());
    try testing.expect(!stale.cache_read_queued);
    try testing.expectEqual(@as(usize, 1), manager.pending_region_count);
    try testing.expectEqual(@as(u32, 1), manager.cancelled_jobs);
}

test "LODManager ready child counters update on renderable transitions and removal" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const child_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const child = try putTestRegion(&manager, child_key, .mesh_ready);
    _ = try putTestMesh(&manager, child_key, 1);
    manager.markRegionRenderable(child_key, child);

    const parent_key = child_key.parentKey().?;
    const parent = try putTestRegion(&manager, parent_key, .mesh_ready);
    manager.markRegionRenderable(parent_key, parent);
    try testing.expectEqual(@as(u8, 1), parent.ready_children);

    manager.noteRegionRemoved(child_key, child);
    try testing.expectEqual(@as(u8, 0), parent.ready_children);
}

test "LODManager demoting renderable child clears parent coverage" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const child_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const child = try putTestRegion(&manager, child_key, .mesh_ready);
    _ = try putTestMesh(&manager, child_key, 1);
    manager.markRegionRenderable(child_key, child);

    const parent_key = child_key.parentKey().?;
    const parent = try putTestRegion(&manager, parent_key, .mesh_ready);
    manager.markRegionRenderable(parent_key, parent);
    try testing.expectEqual(@as(u8, 1), parent.ready_children);

    manager.demoteRegionForRemesh(child_key, child);

    try testing.expectEqual(LODState.generated, child.state);
    try testing.expectEqual(@as(u8, 0), parent.ready_children);
}

test "LODManager ready child counters ignore renderable children without geometry" {
    var config = LODConfig{};
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const child_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const child = try putTestRegion(&manager, child_key, .mesh_ready);
    _ = try putTestMesh(&manager, child_key, 0);
    manager.markRegionRenderable(child_key, child);

    const parent_key = child_key.parentKey().?;
    const parent = try putTestRegion(&manager, parent_key, .mesh_ready);
    manager.markRegionRenderable(parent_key, parent);

    try testing.expectEqual(@as(u8, 0), parent.ready_children);
}

test "LODManager memory budget eviction skips unsafe regions and evicts farthest first" {
    var config = LODConfig{ .memory_budget_mb = 1 };
    var manager = try initEvictionTestManager(testing.allocator, &config);
    defer deinitEvictionTestManager(&manager);

    const budget_bytes = @as(usize, config.memory_budget_mb) * 1024 * 1024;
    const eviction_bytes = 600 * 1024;
    const mesh_capacity: u32 = @intCast(@max(eviction_bytes / @sizeOf(Vertex), 1));
    const mesh_bytes = @as(usize, mesh_capacity) * @sizeOf(Vertex);

    const near_key = LODRegionKey{ .rx = 2, .rz = 0, .lod = .lod1 };
    const far_key = LODRegionKey{ .rx = 20, .rz = 0, .lod = .lod1 };
    const pinned_key = LODRegionKey{ .rx = 40, .rz = 0, .lod = .lod1 };
    const no_parent_key = LODRegionKey{ .rx = 60, .rz = 0, .lod = .lod1 };
    const in_flight_key = LODRegionKey{ .rx = 80, .rz = 0, .lod = .lod1 };

    _ = try putTestRegion(&manager, near_key.parentKey().?, .renderable);
    _ = try putTestRegion(&manager, far_key.parentKey().?, .renderable);
    _ = try putTestRegion(&manager, pinned_key.parentKey().?, .renderable);
    _ = try putTestRegion(&manager, in_flight_key.parentKey().?, .renderable);

    _ = try putTestRegion(&manager, near_key, .renderable);
    _ = try putTestRegion(&manager, far_key, .renderable);
    const pinned_chunk = try putTestRegion(&manager, pinned_key, .renderable);
    pinned_chunk.pin();
    _ = try putTestRegion(&manager, no_parent_key, .renderable);
    _ = try putTestRegion(&manager, in_flight_key, .generating);

    _ = try putTestMesh(&manager, near_key, mesh_capacity);
    _ = try putTestMesh(&manager, far_key, mesh_capacity);
    _ = try putTestMesh(&manager, pinned_key, mesh_capacity);
    _ = try putTestMesh(&manager, no_parent_key, mesh_capacity);
    _ = try putTestMesh(&manager, in_flight_key, mesh_capacity);

    manager.memory_governor.used_bytes = budget_bytes + mesh_bytes;
    try manager.enforceMemoryBudget();

    try testing.expect(!manager.regions[1].contains(far_key));
    try testing.expect(!manager.meshes[1].contains(far_key));
    try testing.expect(manager.regions[1].contains(near_key));
    try testing.expect(manager.regions[1].contains(pinned_key));
    try testing.expect(manager.regions[1].contains(no_parent_key));
    try testing.expect(manager.regions[1].contains(in_flight_key));
    try testing.expect(manager.memory_governor.used_bytes <= budget_bytes);
    try testing.expectEqual(@as(u32, 1), manager.stats.evictions);
    try testing.expectEqual(@as(u32, 1), manager.mesh_disposal.queue.items.len);
}
