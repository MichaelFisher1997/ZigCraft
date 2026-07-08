//! World manager - handles chunk loading, unloading, and access.

const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const CHUNK_SIZE_X = world_core.CHUNK_SIZE_X;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = world_core.CHUNK_SIZE_Z;
const BlockType = world_core.BlockType;
const ChunkKey = world_core.ChunkKey;
const worldToChunk = world_core.worldToChunk;
const worldToLocal = world_core.worldToLocal;
const world_meshing = @import("world-meshing");
const NeighborChunks = world_meshing.NeighborChunks;
const ChunkStorage = world_meshing.ChunkStorage;
const ChunkData = world_meshing.ChunkData;
const gen_interface = @import("world-worldgen");
const Generator = gen_interface.Generator;
const registry = @import("world-worldgen").registry;
const rhi_mod = @import("engine-rhi").rhi;
const RHI = rhi_mod.RHI;
const WorldLOD = @import("world-lod").WorldLOD(RHI);
const LODGenerator = @import("world-lod").LODGenerator;

fn getenv(name: [:0]const u8) ?[]const u8 {
    return runtime_env.getenv(name);
}
const LODManager = @import("world-lod").LODManager;
const math = @import("engine-math");
const Vec3 = math.Vec3;
const Mat4 = math.Mat4;
const Frustum = math.Frustum;
const IShadowScene = @import("engine-rhi").IShadowScene;
const ShadowConfig = @import("engine-rhi").ShadowConfig;
const WorldStreamer = @import("world_streamer.zig").WorldStreamer;
const TextureAtlas = @import("engine-assets").TextureAtlas;
const WorldRenderer = @import("world_renderer.zig").WorldRenderer;
const MAX_MDI_CHUNKS = @import("world_renderer.zig").MAX_MDI_CHUNKS;
const RenderStats = @import("world_renderer.zig").RenderStats;
const RenderLayer = @import("world_renderer.zig").RenderLayer;
const ShadowStats = @import("world_renderer.zig").ShadowStats;
const ChunkStateCounts = world_core.ChunkStateCounts;
const VoxelCollisionWorld = @import("engine-physics").VoxelCollisionWorld;
const GraphicsWorldRenderView = @import("engine-rhi").IWorldRenderView;
const ILPVWorld = @import("engine-rhi").ILPVWorld;
const block_registry = @import("world-core").block_registry;
const LpvGridBuilder = @import("lpv_grid_builder.zig").LpvGridBuilder;

pub const DebugLightInfo = struct {
    sky: u4,
    block: u4,
    entrance_bounce: u4,
};
const WorldStateData = world_core.WorldStateData;
pub const GpuMeshDispatch = struct {
    dispatch_fn: ?*const fn (ctx: *anyopaque) void,
    dispatch_ctx: ?*anyopaque,
};

pub const WorldOrchestration = struct {
    /// World facade operation `update` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn update(renderer: anytype, streamer: anytype, world: anytype, player_pos: Vec3, dt: f32) !void {
        renderer.beginFrame();
        try streamer.updateFrame(player_pos, dt);
        world.checkAutoSave();
    }

    /// World facade operation `render` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn render(renderer: anytype, streamer: anytype, lod_manager: anytype, lod_enabled: bool, view_proj: Mat4, camera_pos: Vec3, render_lod: bool, layer: anytype) void {
        const allow_lod = lod_enabled and render_lod;
        renderer.render(view_proj, camera_pos, streamer.getActiveRenderDistance(), lod_manager, allow_lod, layer);
    }
};
const engine_core = @import("engine-core");
const JobQueue = engine_core.JobQueue;
const WorkerPool = engine_core.WorkerPool;
const Job = engine_core.Job;
const RingBuffer = engine_core.ring_buffer.RingBuffer;
const log = engine_core.log;
const runtime_env = engine_core.runtime_env;

const LODConfig = @import("world-lod").lod_chunk.LODConfig;
const ILODConfig = @import("world-lod").lod_chunk.ILODConfig;
const LODLevel = @import("world-lod").LODLevel;
const CHUNK_UNLOAD_BUFFER = world_core.CHUNK_UNLOAD_BUFFER;
const SaveManager = @import("world-persistence").SaveManager;
const LoadResult = @import("world-persistence").LoadResult;
const GpuBlockBuffer = world_meshing.GpuBlockBuffer;
const WorldMutationCoordinator = @import("world_mutation.zig").WorldMutationCoordinator;

fn lodGeneratorFromGenerator(generator: Generator) LODGenerator {
    return .{
        .ptr = generator.ptr,
        .generate_heightmap_only = generator.vtable.generateHeightmapOnly,
        .maybe_recenter_cache = generator.vtable.maybeRecenterCache,
        .seed = generator.getSeed(),
        .identity_hash = std.hash.Wyhash.hash(0, generator.info.name),
        .version = generator.info.version,
    };
}

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
        getLODStats: *const fn (ptr: *anyopaque) ?@import("world-lod").LODStats,
        isLODEnabled: *const fn (ptr: *anyopaque) bool,
        shadowScene: *const fn (ptr: *anyopaque) IShadowScene,
        enableSaveManager: *const fn (ptr: *anyopaque, save_dir_path: []const u8, world_name: []const u8) anyerror!void,
        takeSaveFailureWarningCount: *const fn (ptr: *anyopaque) usize,
        pauseGeneration: *const fn (ptr: *anyopaque) void,
        isPaused: *const fn (ptr: *anyopaque) bool,
        collisionWorld: *const fn (ptr: *anyopaque) VoxelCollisionWorld,
        getBlock: *const fn (ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) BlockType,
        setBlock: *const fn (ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32, block: BlockType) anyerror!void,
        getColumnInfo: *const fn (ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.ColumnInfo,
        getDebugLightInfo: *const fn (ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo,
        getRegionInfo: *const fn (ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.RegionInfo,
        getGenerator: *const fn (ptr: *anyopaque) Generator,
        getGeneratorName: *const fn (ptr: *anyopaque) []const u8,
        getRenderDistance: *const fn (ptr: *anyopaque) i32,
        setRenderDistance: *const fn (ptr: *anyopaque, distance: i32) void,
        getHorizonDistance: *const fn (ptr: *anyopaque) i32,
        setHorizonDistance: *const fn (ptr: *anyopaque, distance: i32) void,
        isLODRenderingEnabled: *const fn (ptr: *anyopaque) bool,
        toggleLODRendering: *const fn (ptr: *anyopaque) bool,
        getChunkStateCounts: *const fn (ptr: *anyopaque) ChunkStateCounts,
        isStartupBusy: *const fn (ptr: *anyopaque) bool,
        getWorldStateData: *const fn (ptr: *anyopaque) WorldStateData,
        lpvWorld: *const fn (ptr: *anyopaque) ILPVWorld,
        graphicsRenderView: *const fn (ptr: *anyopaque) GraphicsWorldRenderView,
        getGpuMeshDispatch: *const fn (ptr: *anyopaque) GpuMeshDispatch,
    };

    /// World facade operation `update` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn update(self: IWorld, player_pos: Vec3, dt: f32) !void {
        try self.vtable.update(self.ptr, player_pos, dt);
    }

    /// World facade operation `render` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn render(self: IWorld, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.vtable.render(self.ptr, view_proj, camera_pos, render_lod);
    }

    /// World facade operation `renderOpaque` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn renderOpaque(self: IWorld, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.vtable.renderOpaque(self.ptr, view_proj, camera_pos, render_lod);
    }

    /// World facade operation `renderFluid` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn renderFluid(self: IWorld, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.vtable.renderFluid(self.ptr, view_proj, camera_pos, render_lod);
    }

    /// World facade operation `deinit` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn deinit(self: IWorld) void {
        self.vtable.deinit(self.ptr);
    }

    /// World facade operation `getRenderStats` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getRenderStats(self: IWorld) RenderStats {
        return self.vtable.getRenderStats(self.ptr);
    }

    /// World facade operation `getStats` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getStats(self: IWorld) WorldStatsData {
        return self.vtable.getStats(self.ptr);
    }

    /// World facade operation `getLODStats` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getLODStats(self: IWorld) ?@import("world-lod").LODStats {
        return self.vtable.getLODStats(self.ptr);
    }

    /// World facade operation `isLODEnabled` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn isLODEnabled(self: IWorld) bool {
        return self.vtable.isLODEnabled(self.ptr);
    }

    /// World facade operation `shadowScene` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn shadowScene(self: IWorld) IShadowScene {
        return self.vtable.shadowScene(self.ptr);
    }

    /// World facade operation `enableSaveManager` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn enableSaveManager(self: IWorld, save_dir_path: []const u8, world_name: []const u8) !void {
        try self.vtable.enableSaveManager(self.ptr, save_dir_path, world_name);
    }

    /// World facade operation `takeSaveFailureWarningCount` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn takeSaveFailureWarningCount(self: IWorld) usize {
        return self.vtable.takeSaveFailureWarningCount(self.ptr);
    }

    /// World facade operation `pauseGeneration` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn pauseGeneration(self: IWorld) void {
        self.vtable.pauseGeneration(self.ptr);
    }

    /// World facade operation `isPaused` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn isPaused(self: IWorld) bool {
        return self.vtable.isPaused(self.ptr);
    }

    /// World facade operation `collisionWorld` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn collisionWorld(self: IWorld) VoxelCollisionWorld {
        return self.vtable.collisionWorld(self.ptr);
    }

    /// World facade operation `getBlock` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getBlock(self: IWorld, world_x: i32, world_y: i32, world_z: i32) BlockType {
        return self.vtable.getBlock(self.ptr, world_x, world_y, world_z);
    }

    /// World facade operation `setBlock` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn setBlock(self: IWorld, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        try self.vtable.setBlock(self.ptr, world_x, world_y, world_z, block);
    }

    /// World facade operation `getColumnInfo` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getColumnInfo(self: IWorld, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        return self.vtable.getColumnInfo(self.ptr, world_x, world_z);
    }

    /// World facade operation `getDebugLightInfo` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getDebugLightInfo(self: IWorld, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        return self.vtable.getDebugLightInfo(self.ptr, world_x, world_y, world_z);
    }

    /// World facade operation `getRegionInfo` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getRegionInfo(self: IWorld, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        return self.vtable.getRegionInfo(self.ptr, world_x, world_z);
    }

    /// World facade operation `getGenerator` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getGenerator(self: IWorld) Generator {
        return self.vtable.getGenerator(self.ptr);
    }

    /// World facade operation `getGeneratorName` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getGeneratorName(self: IWorld) []const u8 {
        return self.vtable.getGeneratorName(self.ptr);
    }

    /// World facade operation `getRenderDistance` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getRenderDistance(self: IWorld) i32 {
        return self.vtable.getRenderDistance(self.ptr);
    }

    /// World facade operation `setRenderDistance` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn setRenderDistance(self: IWorld, distance: i32) void {
        self.vtable.setRenderDistance(self.ptr, distance);
    }

    /// World facade operation `getHorizonDistance` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getHorizonDistance(self: IWorld) i32 {
        return self.vtable.getHorizonDistance(self.ptr);
    }

    /// World facade operation `setHorizonDistance` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn setHorizonDistance(self: IWorld, distance: i32) void {
        self.vtable.setHorizonDistance(self.ptr, distance);
    }

    /// World facade operation `isLODRenderingEnabled` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn isLODRenderingEnabled(self: IWorld) bool {
        return self.vtable.isLODRenderingEnabled(self.ptr);
    }

    /// World facade operation `toggleLODRendering` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn toggleLODRendering(self: IWorld) bool {
        return self.vtable.toggleLODRendering(self.ptr);
    }

    /// World facade operation `getChunkStateCounts` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getChunkStateCounts(self: IWorld) ChunkStateCounts {
        return self.vtable.getChunkStateCounts(self.ptr);
    }

    /// World facade operation `isStartupBusy` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn isStartupBusy(self: IWorld) bool {
        return self.vtable.isStartupBusy(self.ptr);
    }

    /// World facade operation `getWorldStateData` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getWorldStateData(self: IWorld) WorldStateData {
        return self.vtable.getWorldStateData(self.ptr);
    }

    /// World facade operation `lpvWorld` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn lpvWorld(self: IWorld) ILPVWorld {
        return self.vtable.lpvWorld(self.ptr);
    }

    /// World facade operation `graphicsRenderView` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn graphicsRenderView(self: IWorld) GraphicsWorldRenderView {
        return self.vtable.graphicsRenderView(self.ptr);
    }

    /// World facade operation `getGpuMeshDispatch` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getGpuMeshDispatch(self: IWorld) GpuMeshDispatch {
        return self.vtable.getGpuMeshDispatch(self.ptr);
    }

    /// World facade operation `simulation` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn simulation(self: IWorld) IWorldSimulation {
        return .{ .world = self };
    }

    /// World facade operation `renderView` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn renderView(self: IWorld) IWorldRenderView {
        return .{ .world = self };
    }

    /// World facade operation `telemetry` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn telemetry(self: IWorld) IWorldTelemetry {
        return .{ .world = self };
    }
};

pub const IWorldSimulation = struct {
    world: IWorld,

    /// World facade operation `update` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn update(self: IWorldSimulation, player_pos: Vec3, dt: f32) !void {
        try self.world.update(player_pos, dt);
    }

    /// World facade operation `deinit` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn deinit(self: IWorldSimulation) void {
        self.world.deinit();
    }

    /// World facade operation `enableSaveManager` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn enableSaveManager(self: IWorldSimulation, save_dir_path: []const u8, world_name: []const u8) !void {
        try self.world.enableSaveManager(save_dir_path, world_name);
    }

    /// World facade operation `pauseGeneration` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn pauseGeneration(self: IWorldSimulation) void {
        self.world.pauseGeneration();
    }

    /// World facade operation `isPaused` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn isPaused(self: IWorldSimulation) bool {
        return self.world.isPaused();
    }

    /// World facade operation `collisionWorld` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn collisionWorld(self: IWorldSimulation) VoxelCollisionWorld {
        return self.world.collisionWorld();
    }

    /// World facade operation `getBlock` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getBlock(self: IWorldSimulation, world_x: i32, world_y: i32, world_z: i32) BlockType {
        return self.world.getBlock(world_x, world_y, world_z);
    }

    /// World facade operation `setBlock` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn setBlock(self: IWorldSimulation, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        try self.world.setBlock(world_x, world_y, world_z, block);
    }

    /// World facade operation `getColumnInfo` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getColumnInfo(self: IWorldSimulation, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        return self.world.getColumnInfo(world_x, world_z);
    }
};

pub const IWorldRenderView = struct {
    world: IWorld,

    /// World facade operation `render` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn render(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.world.render(view_proj, camera_pos, render_lod);
    }

    /// World facade operation `renderOpaque` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn renderOpaque(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.world.renderOpaque(view_proj, camera_pos, render_lod);
    }

    /// World facade operation `renderFluid` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn renderFluid(self: IWorldRenderView, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        self.world.renderFluid(view_proj, camera_pos, render_lod);
    }

    /// World facade operation `shadowScene` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn shadowScene(self: IWorldRenderView) IShadowScene {
        return self.world.shadowScene();
    }

    /// World facade operation `lpvWorld` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn lpvWorld(self: IWorldRenderView) ILPVWorld {
        return self.world.lpvWorld();
    }

    /// World facade operation `graphicsRenderView` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn graphicsRenderView(self: IWorldRenderView) GraphicsWorldRenderView {
        return self.world.graphicsRenderView();
    }

    /// World facade operation `getGpuMeshDispatch` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getGpuMeshDispatch(self: IWorldRenderView) GpuMeshDispatch {
        return self.world.getGpuMeshDispatch();
    }
};

pub const IWorldTelemetry = struct {
    world: IWorld,

    /// World facade operation `getRenderStats` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getRenderStats(self: IWorldTelemetry) RenderStats {
        return self.world.getRenderStats();
    }

    /// World facade operation `getStats` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getStats(self: IWorldTelemetry) WorldStatsData {
        return self.world.getStats();
    }

    /// World facade operation `getLODStats` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getLODStats(self: IWorldTelemetry) ?@import("world-lod").LODStats {
        return self.world.getLODStats();
    }

    /// World facade operation `isLODEnabled` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn isLODEnabled(self: IWorldTelemetry) bool {
        return self.world.isLODEnabled();
    }

    /// World facade operation `getRenderDistance` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getRenderDistance(self: IWorldTelemetry) i32 {
        return self.world.getRenderDistance();
    }

    /// World facade operation `setRenderDistance` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn setRenderDistance(self: IWorldTelemetry, distance: i32) void {
        self.world.setRenderDistance(distance);
    }

    /// World facade operation `getHorizonDistance` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getHorizonDistance(self: IWorldTelemetry) i32 {
        return self.world.getHorizonDistance();
    }

    /// World facade operation `setHorizonDistance` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn setHorizonDistance(self: IWorldTelemetry, distance: i32) void {
        self.world.setHorizonDistance(distance);
    }

    /// World facade operation `isLODRenderingEnabled` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn isLODRenderingEnabled(self: IWorldTelemetry) bool {
        return self.world.isLODRenderingEnabled();
    }

    /// World facade operation `toggleLODRendering` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn toggleLODRendering(self: IWorldTelemetry) bool {
        return self.world.toggleLODRendering();
    }

    /// World facade operation `getChunkStateCounts` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getChunkStateCounts(self: IWorldTelemetry) ChunkStateCounts {
        return self.world.getChunkStateCounts();
    }

    /// World facade operation `isStartupBusy` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn isStartupBusy(self: IWorldTelemetry) bool {
        return self.world.isStartupBusy();
    }

    /// World facade operation `getWorldStateData` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getWorldStateData(self: IWorldTelemetry) WorldStateData {
        return self.world.getWorldStateData();
    }

    /// World facade operation `getGeneratorName` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getGeneratorName(self: IWorldTelemetry) []const u8 {
        return self.world.getGeneratorName();
    }

    /// World facade operation `getBlock` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getBlock(self: IWorldTelemetry, world_x: i32, world_y: i32, world_z: i32) BlockType {
        return self.world.getBlock(world_x, world_y, world_z);
    }

    /// World facade operation `getDebugLightInfo` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getDebugLightInfo(self: IWorldTelemetry, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        return self.world.getDebugLightInfo(world_x, world_y, world_z);
    }

    /// World facade operation `getRegionInfo` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getRegionInfo(self: IWorldTelemetry, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        return self.world.getRegionInfo(world_x, world_z);
    }

    /// World facade operation `getGenerator` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getGenerator(self: IWorldTelemetry) Generator {
        return self.world.getGenerator();
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
    horizon_distance: i32,
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

    // LPV lighting grid builder (Issue #789)
    lpv_grid_builder: LpvGridBuilder,

    /// World facade operation `init` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
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
            .horizon_distance = if (options.lod_config) |lod_config| lod_config.getRadii()[LODLevel.count - 1] else LODConfig.default_horizon_radius,
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
            .lpv_grid_builder = undefined,
        };
        errdefer world.generator.deinit(allocator);

        world.lpv_grid_builder = LpvGridBuilder.init(&world.storage);

        log.log.info("World.init: initializing WorldRenderer", .{});
        const culling_size = options.rhi.query().getRenderResolution();
        var culling_system = if (!safe_mode) blk: {
            break :blk options.rhi.cullingFactory().createCullingSystem(allocator, MAX_MDI_CHUNKS) catch |err| {
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
            world.lod = try WorldLOD.init(allocator, options.rhi, lod_config, lodGeneratorFromGenerator(world.generator), options.atlas);
            world.lod_enabled = true;
            world.streamer.setLODManager(world.lod.?.manager);
        }
        return world;
    }

    /// World facade operation `deinit` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn deinit(self: *World) void {
        // Pause generation first: clears the gen/mesh/LOD job queues so worker
        // threads stop pulling new jobs. (In-flight LOD heightmap jobs are
        // aborted later by LODManager.stop_flag, set at the top of lod.deinit().)
        self.pauseGeneration();

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

    /// World facade operation `pauseGeneration` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn pauseGeneration(self: *World) void {
        self.paused = true;
        self.streamer.setPaused(true);

        if (self.lod) |lod| {
            lod.pause();
        }
    }

    /// World facade operation `resumeGeneration` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn resumeGeneration(self: *World) void {
        self.paused = false;
        self.streamer.setPaused(false);

        if (self.lod) |lod| {
            lod.unpause();
        }
    }

    /// World facade operation `enableSaveManager` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn enableSaveManager(self: *World, save_dir_path: []const u8, world_name: []const u8) !void {
        const seed = self.generator.getSeed();
        const gen_name = self.generator.info.name;
        self.save_manager = try SaveManager.init(self.allocator, save_dir_path, world_name, seed, gen_name);
        self.streamer.setSaveManager(self.save_manager);
        if (self.lod) |lod| {
            try lod.enableCache(save_dir_path);
        }
    }

    /// World facade operation `takeSaveFailureWarningCount` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn takeSaveFailureWarningCount(self: *World) usize {
        const sm = self.save_manager orelse return 0;
        return sm.takePersistedFailedSaveCount();
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

    /// World facade operation `saveAllModifiedChunks` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn saveAllModifiedChunks(self: *World) void {
        const sm = self.save_manager orelse return;

        var dirty_keys = self.enqueueModifiedChunks(sm);
        defer dirty_keys.deinit(self.allocator);

        const failed = sm.flush();
        const failure_count = sm.takeFailedSaveCount();
        if (failure_count > 0) {
            log.log.warn("{} save failure(s) occurred while saving modified chunks", .{failure_count});
        }
        self.remarkFailedSaves(failed);
    }

    /// World facade operation `checkAutoSave` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn checkAutoSave(self: *World) void {
        const sm = self.save_manager orelse return;
        if (!sm.shouldAutoSave()) return;

        var dirty_keys = self.enqueueModifiedChunks(sm);
        defer dirty_keys.deinit(self.allocator);

        const failed = sm.flush();
        sm.markAutoSaved();
        const failure_count = sm.takeFailedSaveCount();
        if (failure_count > 0) {
            log.log.warn("{} save failure(s) occurred during auto-save", .{failure_count});
        }
        self.remarkFailedSaves(failed);
    }

    /// World facade operation `loadChunkFromSave` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
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
                const radii = LODConfig.radiiForDistances(target, self.horizon_distance);
                lod.setChunkRenderRadius(target);
                lod.setRadii(radii);
                lod.setActiveLODCount(LODConfig.activeCountForRenderDistance(target));
            }
        }
    }

    /// World facade operation `setHorizonDistance` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn setHorizonDistance(self: *World, distance: i32) void {
        const target = @max(distance, self.render_distance);
        if (self.horizon_distance == target) return;
        log.log.info("Horizon distance changed: {} -> {}", .{ self.horizon_distance, target });
        self.horizon_distance = target;
        if (self.lod) |lod| {
            lod.setRadii(LODConfig.radiiForDistances(self.render_distance, target));
            lod.setActiveLODCount(LODLevel.count);
        }
    }

    /// World facade operation `getOrCreateChunk` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getOrCreateChunk(self: *World, chunk_x: i32, chunk_z: i32) !*ChunkData {
        return self.storage.getOrCreate(chunk_x, chunk_z);
    }

    /// World facade operation `getBlock` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getBlock(self: *World, world_x: i32, world_y: i32, world_z: i32) BlockType {
        if (world_y < 0 or world_y >= CHUNK_SIZE_Y) return .air;
        const cp = worldToChunk(world_x, world_z);
        const data = self.getChunk(cp.chunk_x, cp.chunk_z) orelse return .air;
        const local = worldToLocal(world_x, world_z);
        return data.chunk.getBlock(local.x, @intCast(world_y), local.z);
    }

    /// World facade operation `getDebugLightInfo` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
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

    /// World facade operation `getColumnInfo` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getColumnInfo(self: *const World, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        return self.generator.getColumnInfo(@floatFromInt(world_x), @floatFromInt(world_z));
    }

    /// World facade operation `getRegionInfo` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getRegionInfo(self: *const World, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        return self.generator.getRegionInfo(world_x, world_z);
    }

    /// World facade operation `setBlock` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn setBlock(self: *World, world_x: i32, world_y: i32, world_z: i32, block: BlockType) !void {
        _ = try self.mutation.applyBlockMutation(world_x, world_y, world_z, block);
        // Notify the LOD system so distant terrain reflects player edits after
        // the player teleports away. Coalesced on a debounce inside LODManager.
        if (self.lod) |lod| {
            const wc = world_core.worldToChunk(world_x, world_z);
            lod.manager.markChunkEdited(wc.chunk_x, wc.chunk_z);
        }
    }

    /// Get chunk data at chunk coordinates.
    /// WARNING: Returned pointer is only guaranteed valid if called from the main thread
    /// and used before the next call to World.update (which may unload chunks).
    /// If accessing from a background thread, the chunk must be pinned first.
    pub fn getChunk(self: *World, cx: i32, cz: i32) ?*ChunkData {
        return self.storage.get(cx, cz);
    }

    /// World facade operation `update` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn update(self: *World, player_pos: Vec3, dt: f32) !void {
        try WorldOrchestration.update(self.renderer, self.streamer, self, player_pos, dt);
    }

    /// World facade operation `render` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn render(self: *World, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        WorldOrchestration.render(self.renderer, self.streamer, lod_mgr, self.lod_enabled, view_proj, camera_pos, render_lod, .all);
    }

    /// World facade operation `renderOpaque` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn renderOpaque(self: *World, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        WorldOrchestration.render(self.renderer, self.streamer, lod_mgr, self.lod_enabled, view_proj, camera_pos, render_lod, .terrain);
    }

    /// World facade operation `renderFluid` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn renderFluid(self: *World, view_proj: Mat4, camera_pos: Vec3, render_lod: bool) void {
        const lod_mgr: ?*LODManager = if (self.lod) |lod| lod.manager else null;
        WorldOrchestration.render(self.renderer, self.streamer, lod_mgr, self.lod_enabled, view_proj, camera_pos, render_lod, .fluid);
    }

    /// World facade operation `renderShadowPass` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn renderShadowPass(self: *World, light_space_matrix: Mat4, camera_pos: Vec3, shadow_config: ShadowConfig) void {
        self.renderer.renderShadowPass(light_space_matrix, camera_pos, shadow_config.caster_distance);
    }

    /// World facade operation `shadowScene` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn shadowScene(self: *World) IShadowScene {
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

    /// World facade operation `getRenderStats` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn getRenderStats(self: *const World) RenderStats {
        return self.renderer.last_render_stats;
    }

    /// World facade operation `collisionWorld` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn collisionWorld(self: *World) VoxelCollisionWorld {
        return .{ .ptr = self, .vtable = &COLLISION_VTABLE };
    }

    /// World facade operation `lpvWorld` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn lpvWorld(self: *World) ILPVWorld {
        return self.lpv_grid_builder.interface();
    }

    /// Shadow stats reset in `beginFrame()` and accumulate across all shadow passes until the next frame.
    /// Call `resetShadowStats()` manually if you need per-cascade stats.
    pub fn getShadowStats(self: *const World) ShadowStats {
        return self.renderer.last_shadow_stats;
    }

    /// World facade operation `resetShadowStats` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
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

    /// World facade operation `getStats` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
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

    /// World facade operation `isStartupBusy` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn isStartupBusy(self: *World) bool {
        return self.streamer.isStartupBusy(self.render_distance);
    }

    /// World facade operation `getWorldStateData` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
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

    /// World facade operation `interface` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn interface(self: *World) IWorld {
        return .{ .ptr = self, .vtable = &IWORLD_VTABLE };
    }

    /// World facade operation `renderView` coordinates simulation, streaming, rendering, or telemetry through runtime-owned world state.
    pub fn renderView(self: *World) GraphicsWorldRenderView {
        return .{ .ptr = self, .vtable = &WORLD_RENDER_VIEW_VTABLE };
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
        .enableSaveManager = ienableSaveManager,
        .takeSaveFailureWarningCount = itakeSaveFailureWarningCount,
        .pauseGeneration = ipauseGeneration,
        .isPaused = iisPaused,
        .collisionWorld = icollisionWorld,
        .getBlock = igetBlock,
        .setBlock = isetBlock,
        .getColumnInfo = igetColumnInfo,
        .getDebugLightInfo = igetDebugLightInfo,
        .getRegionInfo = igetRegionInfo,
        .getGenerator = igetGenerator,
        .getGeneratorName = igetGeneratorName,
        .getRenderDistance = igetRenderDistance,
        .setRenderDistance = isetRenderDistance,
        .getHorizonDistance = igetHorizonDistance,
        .setHorizonDistance = isetHorizonDistance,
        .isLODRenderingEnabled = iisLODRenderingEnabled,
        .toggleLODRendering = itoggleLODRendering,
        .getChunkStateCounts = igetChunkStateCounts,
        .isStartupBusy = iisStartupBusy,
        .getWorldStateData = igetWorldStateData,
        .lpvWorld = ilpvWorld,
        .graphicsRenderView = igraphicsRenderView,
        .getGpuMeshDispatch = igetGpuMeshDispatch,
    };

    const WORLD_RENDER_VIEW_VTABLE = GraphicsWorldRenderView.VTable{
        .render = irender,
        .renderOpaque = irenderOpaque,
        .renderFluid = irenderFluid,
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

    fn igetLODStats(ptr: *anyopaque) ?@import("world-lod").LODStats {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getLODStats();
    }

    fn iisLODEnabled(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.isLODEnabled();
    }

    fn ishadowScene(ptr: *anyopaque) IShadowScene {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.shadowScene();
    }

    fn ienableSaveManager(ptr: *anyopaque, save_dir_path: []const u8, world_name: []const u8) anyerror!void {
        const self: *World = @ptrCast(@alignCast(ptr));
        try self.enableSaveManager(save_dir_path, world_name);
    }

    fn itakeSaveFailureWarningCount(ptr: *anyopaque) usize {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.takeSaveFailureWarningCount();
    }

    fn ipauseGeneration(ptr: *anyopaque) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.pauseGeneration();
    }

    fn iisPaused(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.paused;
    }

    fn icollisionWorld(ptr: *anyopaque) VoxelCollisionWorld {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.collisionWorld();
    }

    fn igetBlock(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) BlockType {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getBlock(world_x, world_y, world_z);
    }

    fn isetBlock(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32, block: BlockType) anyerror!void {
        const self: *World = @ptrCast(@alignCast(ptr));
        try self.setBlock(world_x, world_y, world_z, block);
    }

    fn igetColumnInfo(ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.ColumnInfo {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getColumnInfo(world_x, world_z);
    }

    fn igetDebugLightInfo(ptr: *anyopaque, world_x: i32, world_y: i32, world_z: i32) ?DebugLightInfo {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getDebugLightInfo(world_x, world_y, world_z);
    }

    fn igetRegionInfo(ptr: *anyopaque, world_x: i32, world_z: i32) gen_interface.RegionInfo {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getRegionInfo(world_x, world_z);
    }

    fn igetGenerator(ptr: *anyopaque) Generator {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.generator;
    }

    fn igetGeneratorName(ptr: *anyopaque) []const u8 {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.generator.info.name;
    }

    fn igetRenderDistance(ptr: *anyopaque) i32 {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.render_distance;
    }

    fn isetRenderDistance(ptr: *anyopaque, distance: i32) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.setRenderDistance(distance);
    }

    fn igetHorizonDistance(ptr: *anyopaque) i32 {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.horizon_distance;
    }

    fn isetHorizonDistance(ptr: *anyopaque, distance: i32) void {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.setHorizonDistance(distance);
    }

    fn iisLODRenderingEnabled(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.lod_enabled;
    }

    fn itoggleLODRendering(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        self.lod_enabled = !self.lod_enabled;
        return self.lod_enabled;
    }

    fn igetChunkStateCounts(ptr: *anyopaque) ChunkStateCounts {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getChunkStateCounts();
    }

    fn iisStartupBusy(ptr: *anyopaque) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.isStartupBusy();
    }

    fn igetWorldStateData(ptr: *anyopaque) WorldStateData {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.getWorldStateData();
    }

    fn ilpvWorld(ptr: *anyopaque) ILPVWorld {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.lpvWorld();
    }

    fn igraphicsRenderView(ptr: *anyopaque) GraphicsWorldRenderView {
        const self: *World = @ptrCast(@alignCast(ptr));
        return self.renderView();
    }

    fn igetGpuMeshDispatch(ptr: *anyopaque) GpuMeshDispatch {
        const self: *World = @ptrCast(@alignCast(ptr));
        return if (self.renderer.getGpuMesher() != null)
            .{ .dispatch_fn = WorldRenderer.processGpuMeshing, .dispatch_ctx = @ptrCast(self.renderer) }
        else
            .{ .dispatch_fn = null, .dispatch_ctx = null };
    }

    const COLLISION_VTABLE = VoxelCollisionWorld.VTable{
        .isSolidAt = collisionIsSolidAt,
    };

    fn collisionIsSolidAt(ptr: *anyopaque, x: i32, y: i32, z: i32) bool {
        const self: *World = @ptrCast(@alignCast(ptr));
        const block = self.getBlock(x, y, z);
        return block_registry.getBlockDefinition(block).is_solid;
    }

    /// Get LOD system statistics (returns null if LOD not enabled)
    pub fn getLODStats(self: *World) ?@import("world-lod").LODStats {
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
