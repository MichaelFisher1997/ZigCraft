//! World manager - handles chunk loading, unloading, and access.

const std = @import("std");
const Chunk = @import("chunk.zig").Chunk;
const ChunkMesh = @import("chunk_mesh.zig").ChunkMesh;
const NeighborChunks = @import("chunk_mesh.zig").NeighborChunks;
const BlockType = @import("block.zig").BlockType;
const ChunkStorage = @import("chunk_storage.zig").ChunkStorage;
const ChunkData = @import("chunk_storage.zig").ChunkData;
const worldToChunk = @import("chunk.zig").worldToChunk;
const worldToLocal = @import("chunk.zig").worldToLocal;
const CHUNK_SIZE_X = @import("chunk.zig").CHUNK_SIZE_X;
const CHUNK_SIZE_Z = @import("chunk.zig").CHUNK_SIZE_Z;
const gen_interface = @import("worldgen/generator_interface.zig");
const Generator = gen_interface.Generator;
const registry = @import("worldgen/registry.zig");
const rhi_mod = @import("../engine/graphics/rhi.zig");
const RHI = rhi_mod.RHI;
const WorldLOD = @import("world_lod.zig").WorldLOD(RHI);
const LODManager = @import("lod_manager.zig").LODManager;
const Vec3 = @import("../engine/math/vec3.zig").Vec3;
const Mat4 = @import("../engine/math/mat4.zig").Mat4;
const Frustum = @import("../engine/math/frustum.zig").Frustum;
const shadow_scene = @import("../engine/graphics/shadow_scene.zig");
const ShadowConfig = @import("../engine/graphics/rhi_types.zig").ShadowConfig;
const WorldStreamer = @import("world_streamer.zig").WorldStreamer;
const TextureAtlas = @import("../engine/graphics/texture_atlas.zig").TextureAtlas;
const WorldRenderer = @import("world_renderer.zig").WorldRenderer;
const RenderStats = @import("world_renderer.zig").RenderStats;
const JobQueue = @import("../engine/core/job_system.zig").JobQueue;
const WorkerPool = @import("../engine/core/job_system.zig").WorkerPool;
const Job = @import("../engine/core/job_system.zig").Job;
const RingBuffer = @import("../engine/core/ring_buffer.zig").RingBuffer;
const log = @import("../engine/core/log.zig");

const LODConfig = @import("lod_chunk.zig").LODConfig;
const ILODConfig = @import("lod_chunk.zig").ILODConfig;
const CHUNK_UNLOAD_BUFFER = @import("chunk.zig").CHUNK_UNLOAD_BUFFER;

/// Buffer distance beyond render_distance for chunk unloading.
/// Prevents thrashing when player moves near chunk boundaries.
// const CHUNK_UNLOAD_BUFFER: i32 = 1;

pub const ChunkPos = struct { x: i32, z: i32 };

pub const World = struct {
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

    pub fn init(allocator: std.mem.Allocator, render_distance: i32, seed: u64, rhi: RHI, atlas: *const TextureAtlas) !*World {
        return initGen(0, allocator, render_distance, seed, rhi, atlas);
    }

    pub fn initGen(generator_index: usize, allocator: std.mem.Allocator, render_distance: i32, seed: u64, rhi: RHI, atlas: *const TextureAtlas) !*World {
        const world = try allocator.create(World);

        const storage = ChunkStorage.init(allocator);
        const safe_mode_env = std.posix.getenv("ZIGCRAFT_SAFE_MODE");
        const safe_mode = if (safe_mode_env) |val|
            !(std.mem.eql(u8, val, "0") or std.mem.eql(u8, val, "false"))
        else
            false;
        const safe_render_distance: i32 = if (safe_mode) @min(render_distance, 8) else render_distance;
        const max_uploads: usize = if (safe_mode) @as(usize, 4) else @as(usize, 32);
        if (safe_mode) {
            std.log.warn("ZIGCRAFT_SAFE_MODE enabled: limiting uploads to {} per frame", .{max_uploads});
            if (safe_render_distance != render_distance) {
                std.log.warn("ZIGCRAFT_SAFE_MODE clamped render distance to {}", .{safe_render_distance});
            }
        }

        world.* = .{
            .storage = storage,
            .streamer = undefined,
            .renderer = undefined,
            .allocator = allocator,
            .render_distance = safe_render_distance,
            .generator = try registry.createGenerator(generator_index, seed, allocator),
            .rhi = rhi,
            .paused = false,
            .safe_mode = safe_mode,
            .safe_render_distance = safe_render_distance,
            .lod = null,
            .lod_enabled = false,
        };

        world.renderer = try WorldRenderer.init(allocator, rhi.resourceManager(), rhi.renderContext(), rhi.query(), &world.storage);
        world.streamer = try WorldStreamer.init(allocator, &world.storage, world.generator, atlas, render_distance, world.renderer.vertex_allocator, max_uploads);

        return world;
    }

    /// Initialize with LOD system enabled for extended render distances
    pub fn initWithLOD(allocator: std.mem.Allocator, render_distance: i32, seed: u64, rhi: RHI, lod_config: ILODConfig, atlas: *const TextureAtlas) !*World {
        return initGenWithLOD(0, allocator, render_distance, seed, rhi, lod_config, atlas);
    }

    pub fn initGenWithLOD(generator_index: usize, allocator: std.mem.Allocator, render_distance: i32, seed: u64, rhi: RHI, lod_config: ILODConfig, atlas: *const TextureAtlas) !*World {
        const world = try initGen(generator_index, allocator, render_distance, seed, rhi, atlas);
        errdefer world.deinit();

        world.lod = try WorldLOD.init(allocator, rhi, lod_config, world.generator);
        world.lod_enabled = true;
        world.streamer.setLODManager(world.lod.?.manager);
        return world;
    }

    pub fn deinit(self: *World) void {
        self.rhi.waitIdle();
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

    /// Set render distance and trigger chunk loading/unloading update
    pub fn setRenderDistance(self: *World, distance: i32) void {
        const target = if (self.safe_mode) @min(distance, self.safe_render_distance) else distance;

        if (self.render_distance != target) {
            if (self.safe_mode and target != distance) {
                std.log.warn("ZIGCRAFT_SAFE_MODE clamped render distance {} -> {}", .{ distance, target });
            }
            std.log.info("Render distance changed: {} -> {}", .{ self.render_distance, target });
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
        if (world_y < 0 or world_y >= 256) return .air;
        const cp = worldToChunk(world_x, world_z);
        const data = self.getChunk(cp.chunk_x, cp.chunk_z) orelse return .air;
        const local = worldToLocal(world_x, world_z);
        return data.chunk.getBlock(local.x, @intCast(world_y), local.z);
    }

    pub fn setBlock(self: *World, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        if (world_y < 0 or world_y >= 256) return;
        const cp = worldToChunk(world_x, world_z);
        const data = try self.getOrCreateChunk(cp.chunk_x, cp.chunk_z);
        const local = worldToLocal(world_x, world_z);
        data.chunk.setBlock(local.x, @intCast(world_y), local.z, block);

        // Update skylight for this column
        data.chunk.updateSkylightColumn(local.x, local.z);

        // Mark neighbor chunks dirty if block is on chunk boundary
        // This ensures their meshes update to show/hide faces correctly
        if (local.x == 0) {
            if (self.getChunk(cp.chunk_x - 1, cp.chunk_z)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
        if (local.x == CHUNK_SIZE_X - 1) {
            if (self.getChunk(cp.chunk_x + 1, cp.chunk_z)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
        if (local.z == 0) {
            if (self.getChunk(cp.chunk_x, cp.chunk_z - 1)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
        if (local.z == CHUNK_SIZE_Z - 1) {
            if (self.getChunk(cp.chunk_x, cp.chunk_z + 1)) |neighbor| {
                neighbor.chunk.dirty = true;
            }
        }
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
    }

    pub fn render(self: *World, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        self.renderer.render(view_proj, camera_pos, self.render_distance, lod_mgr, self.lod_enabled and render_lod);
    }

    pub fn renderShadowPass(self: *World, light_space_matrix: Mat4, camera_pos: Vec3, shadow_config: ShadowConfig) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        self.renderer.renderShadowPass(light_space_matrix, camera_pos, shadow_config.caster_distance, lod_mgr);
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

    pub fn getStats(self: *World) struct { chunks_loaded: usize, total_vertices: u64, gen_queue: usize, mesh_queue: usize, upload_queue: usize } {
        const total_verts = self.storage.totalVertexCount();
        const streamer_stats = self.streamer.getStats();

        return .{
            .chunks_loaded = self.storage.count(),
            .total_vertices = total_verts,
            .gen_queue = streamer_stats.gen_queue,
            .mesh_queue = streamer_stats.mesh_queue,
            .upload_queue = streamer_stats.upload_queue,
        };
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
