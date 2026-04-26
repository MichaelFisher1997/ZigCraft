//! World manager - handles chunk loading, unloading, and access.

const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const CHUNK_SIZE_Y = @import("chunk.zig").CHUNK_SIZE_Y;
const NeighborChunks = @import("chunk_mesh.zig").NeighborChunks;
const BlockType = @import("block.zig").BlockType;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const ChunkData = @import("chunk_storage.zig").ChunkData;
const ChunkKey = @import("chunk_storage.zig").ChunkKey;
const worldToChunk = @import("chunk.zig").worldToChunk;
const worldToLocal = @import("chunk.zig").worldToLocal;
const gen_interface = @import("worldgen/generator_interface.zig");
const Generator = gen_interface.Generator;
const registry = @import("worldgen/registry.zig");
const rhi_mod = @import("../engine/graphics/rhi.zig");
const RHI = rhi_mod.RHI;
const WorldLOD = @import("world_lod.zig").WorldLOD(RHI);

fn getenv(name: [:0]const u8) ?[]const u8 {
    return runtime_env.getenv(name);
}
const LODManager = @import("lod_manager.zig").LODManager;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const shadow_scene = @import("../engine/graphics/shadow_scene.zig");
const ShadowConfig = @import("../engine/graphics/rhi_types.zig").ShadowConfig;
const WorldStreamer = @import("world_streamer.zig").WorldStreamer;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const WorldRenderer = @import("world_renderer.zig").WorldRenderer;
const MAX_MDI_CHUNKS = @import("world_renderer.zig").MAX_MDI_CHUNKS;
const RenderStats = @import("world_renderer.zig").RenderStats;
const RenderLayer = @import("world_renderer.zig").RenderLayer;
const ShadowStats = @import("world_renderer.zig").ShadowStats;
const ChunkStateCounts = @import("../engine/ui/chunk_inspector_overlay.zig").ChunkStateCounts;

pub const DebugLightInfo = struct {
    sky: u4,
    block: u4,
    entrance_bounce: u4,
};
const WorldStateData = @import("../engine/ui/chunk_inspector_overlay.zig").WorldStateData;
const JobQueue = @import("../engine/core/job_system.zig").JobQueue;
const WorkerPool = @import("../engine/core/job_system.zig").WorkerPool;
const Job = @import("../engine/core/job_system.zig").Job;
const RingBuffer = @import("../engine/core/ring_buffer.zig").RingBuffer;
const log = @import("../engine/core/log.zig");
const runtime_env = @import("../engine/core/runtime_env.zig");

const LODConfig = @import("lod_chunk.zig").LODConfig;
const ILODConfig = @import("lod_chunk.zig").ILODConfig;
const CHUNK_UNLOAD_BUFFER = @import("chunk.zig").CHUNK_UNLOAD_BUFFER;
const SaveManager = @import("persistence/save_manager.zig").SaveManager;
const LoadResult = @import("persistence/save_manager.zig").LoadResult;
const GpuBlockBuffer = @import("gpu_block_buffer.zig").GpuBlockBuffer;
const WorldMutationCoordinator = @import("world_mutation.zig").WorldMutationCoordinator;

/// Buffer distance beyond render_distance for chunk unloading.
/// Prevents thrashing when player moves near chunk boundaries.
// const CHUNK_UNLOAD_BUFFER: i32 = 1;

/// Named statistics struct for World (extracted from anonymous return type for interface use).
pub const WorldStatsData = struct {
    chunks_loaded: usize,
    total_vertices: u64,
    gen_queue: usize,
    mesh_queue: usize,
    upload_queue: usize,
};

pub const IWorld = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        update: *const fn (ptr: *anyopaque, player_pos: Vec3, dt: f32) anyerror!void,
        render: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void,
        renderOpaque: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void,
        renderFluid: *const fn (ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void,
        deinit: *const fn (ptr: *anyopaque) void,
        getRenderStats: *const fn (ptr: *anyopaque) RenderStats,
        getStats: *const fn (ptr: *anyopaque) WorldStatsData,
        getLODStats: *const fn (ptr: *anyopaque) ?@import("lod_manager.zig").LODStats,
        isLODEnabled: *const fn (ptr: *anyopaque) bool,
        shadowScene: *const fn (ptr: *anyopaque) shadow_scene.IShadowScene,
    };

    pub fn update(self: IWorld, player_pos: Vec3, dt: f32) !void {
        try self.vtable.update(self.ptr, player_pos, dt);
    }

    pub fn render(self: IWorld, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.vtable.render(self.ptr, view_proj, camera_pos, render_lod);
    }

    pub fn renderOpaque(self: IWorld, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.vtable.renderOpaque(self.ptr, view_proj, camera_pos, render_lod);
    }

    pub fn renderFluid(self: IWorld, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.vtable.renderFluid(self.ptr, view_proj, camera_pos, render_lod);
    }

    pub fn deinit(self: IWorld) void {
        self.vtable.deinit(self.ptr);
    }

    pub fn getRenderStats(self: IWorld) RenderStats {
        return self.vtable.getRenderStats(self.ptr);
    }

    pub fn getStats(self: IWorld) WorldStatsData {
        return self.vtable.getStats(self.ptr);
    }

    pub fn getLODStats(self: IWorld) ?@import("lod_manager.zig").LODStats {
        return self.vtable.getLODStats(self.ptr);
    }

    pub fn isLODEnabled(self: IWorld) bool {
        return self.vtable.isLODEnabled(self.ptr);
    }

    pub fn shadowScene(self: IWorld) shadow_scene.IShadowScene {
        return self.vtable.shadowScene(self.ptr);
    }

    pub fn simulation(self: IWorld) IWorldSimulation {
        return .{ .world = self };
    }

    pub fn renderView(self: IWorld) IWorldRenderView {
        return .{ .world = self };
    }

    pub fn telemetry(self: IWorld) IWorldTelemetry {
        return .{ .world = self };
    }
};

pub const IWorldSimulation = struct {
    world: IWorld,

    pub fn update(self: IWorldSimulation, player_pos: Vec3, dt: f32) !void {
        try self.world.update(player_pos, dt);
    }

    pub fn deinit(self: IWorldSimulation) void {
        self.world.deinit();
    }
};

pub const IWorldRenderView = struct {
    world: IWorld,

    pub fn render(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.world.render(view_proj, camera_pos, render_lod);
    }

    pub fn renderOpaque(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.world.renderOpaque(view_proj, camera_pos, render_lod);
    }

    pub fn renderFluid(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.world.renderFluid(view_proj, camera_pos, render_lod);
    }

    pub fn shadowScene(self: IWorldRenderView) shadow_scene.IShadowScene {
        return self.world.shadowScene();
    }
};

pub const IWorldTelemetry = struct {
    world: IWorld,

    pub fn getRenderStats(self: IWorldTelemetry) RenderStats {
        return self.world.getRenderStats();
    }

    pub fn getStats(self: IWorldTelemetry) WorldStatsData {
        return self.world.getStats();
    }

    pub fn getLODStats(self: IWorldTelemetry) ?@import("lod_manager.zig").LODStats {
        return self.world.getLODStats();
    }

    pub fn isLODEnabled(self: IWorldTelemetry) bool {
        return self.world.isLODEnabled();
    }
};

pub const ChunkPos = struct { x: i32, z: i32 };

pub const World = struct {
    pub const InitOptions = struct {
        allocator: std.mem.Allocator,
        render_distance: i32,
        seed: u64,
        rhi: RHI,
        atlas: *const TextureAtlas,
        generator_index: usize = 0,
        lod_config: ?ILODConfig = null,
    };

    storage: ChunkStorage,
    streamer: *WorldStreamer,
    renderer: *WorldRenderer,
    allocator: std.mem.Allocator,
    generator: Generator,
    render_distance: i32,
    rhi: RHI,
    paused: bool = false,
    safe_mode: bool,
    safe_render_distance: i32,

    // LOD System (Issue #114, #293)
    lod: ?*WorldLOD,
    lod_enabled: bool, // Runtime toggle for LOD rendering

    // Save system (Issue #380)
    save_manager: ?*SaveManager,

    // GPU Block Buffer (Batch 5 - Issue #389)
    gpu_block_buffer: ?*GpuBlockBuffer,

    // Mutation coordinator (Issue #550)
    mutation: WorldMutationCoordinator,

    pub fn init(options: InitOptions) !*World {
        const allocator = options.allocator;
        const world = try allocator.create(World);
        errdefer allocator.destroy(world);

        const storage = ChunkStorage.init(allocator);
        const safe_mode = runtime_env.safeModeEnabled();
        const strict_safe_mode = runtime_env.strictSafeModeEnabled();
        const safe_render_distance: i32 = options.render_distance;
        const max_uploads: usize = if (strict_safe_mode)
            @as(usize, 4)
        else if (safe_mode)
            @as(usize, 8)
        else
            @as(usize, 32);
        if (safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: limiting uploads to {} per frame", .{max_uploads});
        }

        world.* = .{
            .storage = storage,
            .streamer = undefined,
            .renderer = undefined,
            .allocator = allocator,
            .render_distance = safe_render_distance,
            .generator = try registry.createGenerator(options.generator_index, options.seed, allocator),
            .rhi = options.rhi,
            .paused = false,
            .safe_mode = safe_mode,
            .safe_render_distance = safe_render_distance,
            .lod = null,
            .lod_enabled = false,
            .save_manager = null,
            .gpu_block_buffer = null,
            .mutation = undefined,
        };
        errdefer world.generator.deinit(allocator);

        log.log.info("World.init: initializing WorldRenderer", .{});
        const culling_size = options.rhi.getRenderResolution();
        var culling_system = if (!safe_mode) blk: {
            break :blk options.rhi.createCullingSystem(allocator, MAX_MDI_CHUNKS) catch |err| {
                log.log.warn("GPU culling init failed ({}), falling back to CPU culling", .{err});
                break :blk null;
            };
        } else null;
        errdefer if (culling_system) |system| system.deinit();

        world.renderer = try WorldRenderer.init(allocator, options.rhi.resourceManager(), options.rhi.renderContext(), options.rhi.query(), &world.storage, options.atlas, options.rhi, &culling_system, culling_size, safe_mode);
        errdefer world.renderer.deinit();

        world.gpu_block_buffer = world.renderer.getGpuBlockBuffer();

        world.mutation = WorldMutationCoordinator.init(
            &world.storage,
            allocator,
            world.gpu_block_buffer,
            world.renderer.getGpuMesher() != null,
        );

        log.log.info("World.init: initializing WorldStreamer (render_distance={})", .{safe_render_distance});
        world.streamer = try WorldStreamer.init(allocator, &world.storage, world.generator, options.atlas, world.render_distance, world.renderer.vertex_allocator, max_uploads, world.gpu_block_buffer, world.renderer.getGpuMesher());
        errdefer world.streamer.deinit();

        if (options.lod_config) |lod_config| {
            world.lod = try WorldLOD.init(allocator, options.rhi, lod_config, world.generator, options.atlas);
            world.lod_enabled = true;
            world.streamer.setLODManager(world.lod.?.manager);
        }
        return world;
    }

    pub fn deinit(self: *World) void {
        self.rhi.query().waitIdle();

        if (self.save_manager) |sm| {
            self.saveAllModifiedChunks();
            sm.deinit();
        }

        self.streamer.deinit();

        // Storage must be deinitialized before renderer because it uses the renderer's vertex_allocator
        // to free mesh buffers.
        // On shutdown we can skip per-chunk GPU frees since the allocator is destroyed next.
        self.storage.deinitWithoutRHI();
        self.renderer.deinit();

        if (self.lod) |lod| {
            lod.deinit();
        }

        self.generator.deinit(self.allocator);

        self.allocator.destroy(self);
    }

    pub fn pauseGeneration(self: *World) void {
        self.paused = true;
        self.streamer.setPaused(true);

        if (self.lod) |lod| {
            lod.pause();
        }
    }

    pub fn resumeGeneration(self: *World) void {
        self.paused = false;
        self.streamer.setPaused(false);

        if (self.lod) |lod| {
            lod.unpause();
        }
    }

    pub fn enableSaveManager(self: *World, save_dir_path: []const u8, world_name: []const u8) !void {
        const seed = self.generator.getSeed();
        const gen_name = self.generator.info.name;
        self.save_manager = try SaveManager.init(self.allocator, save_dir_path, world_name, seed, gen_name);
        self.streamer.setSaveManager(self.save_manager);
    }

    fn enqueueModifiedChunks(self: *World, sm: *SaveManager) std.ArrayListUnmanaged(ChunkKey) {
        var dirty_keys = std.ArrayListUnmanaged(ChunkKey).empty;

        self.storage.chunks_mutex.lock();
        var iter = self.storage.iteratorUnsafe();
        while (iter.next()) |entry| {
            const chunk = &entry.value_ptr.*.chunk;
            if (chunk.modified and chunk.generated) {
                dirty_keys.append(self.allocator, entry.key_ptr.*) catch |err| {
                    log.log.err("Failed to track dirty chunk ({}, {}) for save: {}", .{ entry.key_ptr.*.x, entry.key_ptr.*.z, err });
                    continue;
                };

                chunk.pin();
                sm.enqueueSave(chunk);
                chunk.modified = false;
                chunk.unpin();
            }
        }
        self.storage.chunks_mutex.unlock();

        return dirty_keys;
    }

    fn remarkFailedSaves(self: *World, failed: []ChunkKey) void {
        self.storage.chunks_mutex.lock();
        for (failed) |key| {
            if (self.storage.chunks.get(key)) |data| {
                data.chunk.modified = true;
            }
        }
        self.storage.chunks_mutex.unlock();
    }

    pub fn saveAllModifiedChunks(self: *World) void {
        const sm = self.save_manager orelse return;

        var dirty_keys = self.enqueueModifiedChunks(sm);
        defer dirty_keys.deinit(self.allocator);

        const failed = sm.flush();
        self.remarkFailedSaves(failed);
    }

    pub fn checkAutoSave(self: *World) void {
        const sm = self.save_manager orelse return;
        if (!sm.shouldAutoSave()) return;

        var dirty_keys = self.enqueueModifiedChunks(sm);
        defer dirty_keys.deinit(self.allocator);

        const failed = sm.flush();
        sm.markAutoSaved();
        self.remarkFailedSaves(failed);
    }

    pub fn loadChunkFromSave(self: *World, cx: i32, cz: i32, out_chunk: *Chunk) LoadResult {
        const sm = self.save_manager orelse return .not_found;
        return sm.loadChunk(cx, cz, out_chunk);
    }

    /// Set render distance and trigger chunk loading/unloading update
    pub fn setRenderDistance(self: *World, distance: i32) void {
        const target = if (self.safe_mode) @min(distance, self.safe_render_distance) else distance;

        if (self.render_distance != target) {
            if (self.safe_mode and target != distance) {
                log.log.warn("ZIGCRAFT_SAFE_MODE clamped render distance {} -> {}", .{ distance, target });
            }
            log.log.info("Render distance changed: {} -> {}", .{ self.render_distance, target });
            self.render_distance = target;
            self.streamer.setRenderDistance(target);

            if (self.lod) |lod| {
                lod.setLOD0Radius(target);
            }
        }
    }

    pub fn getOrCreateChunk(self: *World, chunk_x: i32, chunk_z: i32) !*ChunkData {
        return self.storage.getOrCreate(chunk_x, chunk_z);
    }

    pub fn getBlock(self: *World, world_x: i32, world_y: i32, world_z: i32) BlockType {
        if (world_y < 0 or world_y >= CHUNK_SIZE_Y) return .air;
        const cp = worldToChunk(world_x, world_z);
        const data = self.getChunk(cp.chunk_x, cp.chunk_z) orelse return .air;
        const local = worldToLocal(world_x, world_z);
        return data.chunk.getBlock(local.x, @intCast(world_y), local.z);
    }

    pub fn getDebugLightInfo(self: *World, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        if (world_y < 0 or world_y >= CHUNK_SIZE_Y) return null;
        const cp = worldToChunk(world_x, world_z);
        const data = self.getChunk(cp.chunk_x, cp.chunk_z) orelse return null;
        const local = worldToLocal(world_x, world_z);
        const light = data.chunk.getLight(local.x, @intCast(world_y), local.z);
        return .{
            .sky = light.getSkyLight(),
            .block = light.getBlockLight(),
            .entrance_bounce = data.chunk.getEntranceBounce(local.x, @intCast(world_y), local.z),
        };
    }

    pub fn getColumnInfo(self: *const World, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        return self.generator.getColumnInfo(@floatFromInt(world_x), @floatFromInt(world_z));
    }

    pub fn setBlock(self: *World, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        _ = try self.mutation.applyBlockMutation(world_x, world_y, world_z, block);
    }

    /// Get chunk data at chunk coordinates.
    /// WARNING: Returned pointer is only guaranteed valid if called from the main thread
    /// and used before the next call to World.update (which may unload chunks).
    /// If accessing from a background thread, the chunk must be pinned first.
    pub fn getChunk(self: *World, cx: i32, cz: i32) ?*ChunkData {
        return self.storage.get(cx, cz);
    }

    pub fn update(self: *World, player_pos: Vec3, dt: f32) !void {
        self.renderer.beginFrame();
        try self.streamer.updateFrame(player_pos, dt);
        self.checkAutoSave();
    }

    pub fn render(self: *World, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        const allow_lod = self.lod_enabled and render_lod;
        self.renderer.render(view_proj, camera_pos, self.streamer.getActiveRenderDistance(), lod_mgr, allow_lod, .all);
    }

    pub fn renderOpaque(self: *World, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        const allow_lod = self.lod_enabled and render_lod;
        self.renderer.render(view_proj, camera_pos, self.streamer.getActiveRenderDistance(), lod_mgr, allow_lod, .terrain);
    }

    pub fn renderFluid(self: *World, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        const allow_lod = self.lod_enabled and render_lod;
        self.renderer.render(view_proj, camera_pos, self.streamer.getActiveRenderDistance(), lod_mgr, allow_lod, .fluid);
    }

    pub fn renderShadowPass(self: *World, light_space_matrix: Mat4, camera_pos: Vec3, shadow_config: ShadowConfig) void {
        self.renderer.renderShadowPass(light_space_matrix, camera_pos, shadow_config.caster_distance);
    }

    pub fn shadowScene(self: *World) shadow_scene.IShadowScene {
        return .{
            .ptr = self,
            .vtable = &.{
                .renderShadowPass = renderShadowPassWrapper,
            },
        };
    }

    fn renderShadowPassWrapper(ptr: *anyopaque, light_space_matrix: Mat4, camera_pos: Vec3, shadow_config: ShadowConfig) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.renderShadowPass(light_space_matrix, camera_pos, shadow_config);
    }

    pub fn getRenderStats(self: *const World) RenderStats {
        return self.renderer.last_render_stats;
    }

    /// Shadow stats reset in `beginFrame()` and accumulate across all shadow passes until the next frame.
    /// Call `resetShadowStats()` manually if you need per-cascade stats.
    pub fn getShadowStats(self: *const World) ShadowStats {
        return self.renderer.last_shadow_stats;
    }

    pub fn resetShadowStats(self: *World) void {
        self.renderer.resetShadowStats();
    }

    /// Counts chunks by state for the debug inspector overlay.
    /// Note: Holds a shared mutex lock while iterating all chunks.
    /// May cause minor contention with world streamer threads under heavy load.
    pub fn getChunkStateCounts(self: *World) ChunkStateCounts {
        self.storage.chunks_mutex.lockShared();
        defer self.storage.chunks_mutex.unlockShared();

        var counts: ChunkStateCounts = .{};
        counts.total = @intCast(self.storage.chunks.count());

        var iter = self.storage.chunks.iterator();
        while (iter.next()) |entry| {
            const state = entry.value_ptr.*.chunk.state;
            switch (state) {
                .missing => counts.missing += 1,
                .generating => counts.generating += 1,
                .meshing => counts.meshing += 1,
                .renderable => counts.renderable += 1,
                else => counts.other_states += 1,
            }
            if (entry.value_ptr.*.chunk.dirty) counts.dirty += 1;
        }
        return counts;
    }

    pub fn getStats(self: *World) WorldStatsData {
        const streamer_stats = self.streamer.getStats();

        return .{
            .chunks_loaded = self.storage.count(),
            // Runtime callers only need queue and chunk counts here. Recomputing the
            // full loaded-vertex sum every frame walks every chunk mesh under lock and
            // can stall the main thread while the world is streaming.
            .total_vertices = self.renderer.last_render_stats.vertices_rendered,
            .gen_queue = streamer_stats.gen_queue,
            .mesh_queue = streamer_stats.mesh_queue,
            .upload_queue = streamer_stats.upload_queue,
        };
    }

    pub fn isStartupBusy(self: *World) bool {
        return self.streamer.isStartupBusy(self.render_distance);
    }

    pub fn getWorldStateData(self: *World) WorldStateData {
        const stats = self.getStats();
        return .{
            .generator_name = self.generator.info.name,
            .seed = self.generator.getSeed(),
            .gen_queue = @as(u32, @intCast(stats.gen_queue)),
            .mesh_queue = @as(u32, @intCast(stats.mesh_queue)),
            .upload_queue = @as(u32, @intCast(stats.upload_queue)),
        };
    }

    pub fn interface(self: *World) IWorld {
        return .{ .ptr = self, .vtable = &IWORLD_VTABLE };
    }

    const IWORLD_VTABLE = IWorld.VTable{
        .update = iupdate,
        .render = irender,
        .renderOpaque = irenderOpaque,
        .renderFluid = irenderFluid,
        .deinit = ideinit,
        .getRenderStats = igetRenderStats,
        .getStats = igetStats,
        .getLODStats = igetLODStats,
        .isLODEnabled = iisLODEnabled,
        .shadowScene = ishadowScene,
    };

    fn iupdate(ptr: *anyopaque, player_pos: Vec3, dt: f32) anyerror!void {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.update(player_pos, dt);
    }

    fn irender(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.render(view_proj, camera_pos, render_lod);
    }

    fn irenderOpaque(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.renderOpaque(view_proj, camera_pos, render_lod);
    }

    fn irenderFluid(ptr: *anyopaque, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.renderFluid(view_proj, camera_pos, render_lod);
    }

    fn ideinit(ptr: *anyopaque) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.deinit();
    }

    fn igetRenderStats(ptr: *anyopaque) RenderStats {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getRenderStats();
    }

    fn igetStats(ptr: *anyopaque) WorldStatsData {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getStats();
    }

    fn igetLODStats(ptr: *anyopaque) ?@import("lod_manager.zig").LODStats {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getLODStats();
    }

    fn iisLODEnabled(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.isLODEnabled();
    }

    fn ishadowScene(ptr: *anyopaque) shadow_scene.IShadowScene {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.shadowScene();
    }

    /// Get LOD system statistics (returns null if LOD not enabled)
    pub fn getLODStats(self: *World) ?@import("lod_manager.zig").LODStats {
        if (self.lod) |lod| {
            return lod.getStats();
        }
        return null;
    }

    /// Check if LOD system is enabled
    pub fn isLODEnabled(self: *const World) bool {
        return self.lod != null;
    }
};
