//! Game session - handles active gameplay state.

const std = @import("std");
const Vec3 = @import("engine-math").Vec3;
const World = @import("world-runtime").World;
const IWorldSimulation = @import("world-runtime").IWorldSimulation;
const WorldMap = @import("world-worldgen").WorldMap;
const MapController = @import("map_controller.zig").MapController;
const Player = @import("player.zig").Player;
const Inventory = @import("inventory.zig").Inventory;
const inventory_ui = @import("ui/inventory_ui.zig");
const BlockOutline = @import("block_outline.zig").BlockOutline;
const HandRenderer = @import("hand_renderer.zig").HandRenderer;
const Camera = @import("engine-camera").Camera;
const RHI = @import("engine-rhi").RHI;
const RenderContext = @import("engine-rhi").RenderContext;
const Texture = @import("engine-rhi").Texture;
const TextureAtlas = @import("engine-graphics").TextureAtlas;
const Input = @import("engine-input").Input;
const IRawInputProvider = @import("engine-input").IRawInputProvider;
const LODConfig = @import("world-lod").lod_chunk.LODConfig;
const LODLevel = @import("world-lod").LODLevel;
const render_settings = @import("engine-rhi").render_settings;
const RenderDistancePreset = render_settings.RenderDistancePreset;
const log = @import("engine-core").log;
const runtime_env = @import("engine-core").runtime_env;
const BlockType = @import("world-core").BlockType;
const input_mapper_pkg = @import("input_mapper.zig");
const InputMapper = input_mapper_pkg.InputMapper;
const IInputMapper = input_mapper_pkg.IInputMapper;
const GameAction = input_mapper_pkg.GameAction;

const CSM = @import("engine-graphics").csm;
const UISystem = @import("engine-ui").UISystem;
const session_hud = @import("ui/session_hud.zig");

fn getenv(name: [:0]const u8) ?[]const u8 {
    const value = std.c.getenv(name) orelse return null;
    return std.mem.span(value);
}

var phase5_capture_ready = std.atomic.Value(bool).init(false);

/// Narrow bridge from the production-world fixture session to App's screenshot
/// exit condition. Only deterministic Phase 5 captures consult this state.
pub fn phase5CaptureReady() bool {
    return phase5_capture_ready.load(.acquire);
}

fn resetPhase5CaptureReady() void {
    phase5_capture_ready.store(false, .release);
}

pub const BuildConfig = struct {
    auto_world: []const u8 = "",
    chunk_debug_enable: []const u8 = "",
    chunk_debug_mode: bool = false,
    screenshot_path: []const u8 = "",
    phase5_visual_scene: []const u8 = "",
    benchmark_fixture: []const u8 = "",
    phase5_visual_run_id: []const u8 = "",
    shadow_test_scene: bool = false,
    shadow_test_variant: []const u8 = "cave-entrance",
    startup_diagnostic_seconds: u32 = 0,
    /// This is injected only by the benchmark executable. Zero preserves the
    /// selected render-distance preset's normal production admission budget.
    benchmark_lod_memory_budget_mb: u32 = 0,
};

const ECSManager = @import("engine-ecs").manager;
const ECSRegistry = ECSManager.Registry;
const ECSComponents = @import("engine-ecs").components;
const ECSPhysicsSystem = @import("engine-ecs").PhysicsSystem;
const ECSRenderSystem = @import("engine-ecs").RenderSystem;

const Atmosphere = @import("engine-atmosphere").Atmosphere;

const SpawnColumn = struct {
    x: i32,
    z: i32,
    info: @import("world-worldgen").ColumnInfo,
};

/// The explicit numeric render-distance setting owns full-detail reach.
/// Quality and safe-mode profiles tune implementation budgets without silently
/// reducing the player's requested value.
pub fn fullDetailRenderDistance(render_distance: i32) i32 {
    return World.effectiveChunkRenderRadius(render_distance);
}

pub const GameSession = struct {
    allocator: std.mem.Allocator,
    world: *World,
    world_map: WorldMap,
    world_map_texture: Texture,
    map_controller: MapController,

    player: Player,
    inventory: Inventory,
    inventory_ui_state: inventory_ui.InventoryUI,
    block_outline: BlockOutline,
    hand_renderer: HandRenderer,
    camera: Camera, // References player camera, but we might want a decoupled camera if player is null (e.g. spectator) - for now keep it simple and match App

    ecs_registry: ECSRegistry,
    ecs_render_system: ECSRenderSystem,
    rhi: *RHI,

    atmosphere: Atmosphere,

    lod_config: LODConfig,
    creative_mode: bool,

    debug_show_fps: bool = false,
    debug_show_block_info: bool = false,
    debug_shadows: bool = false,
    debug_cascade_idx: usize = 0,
    build_config: BuildConfig = .{},
    phase5_water_fixture_observations: u32 = 0,
    phase5_water_fixture_evidence_emitted: bool = false,
    phase5_fixture_applied: bool = false,
    phase5_gpu_evidence_emitted: bool = false,
    phase5_settle_frames: u32 = 0,
    phase5_ready_evidence_emitted: bool = false,
    phase5_gpu_validation_complete_emitted: bool = false,
    phase5_save_flushed: bool = false,
    phase5_save_loaded: bool = false,
    phase5_compact_wet_dry_evidence_emitted: bool = false,
    phase5_motion_frames: u32 = 0,
    phase5_motion_complete: bool = false,
    phase5_motion_evidence_emitted: bool = false,
    gpu_culling_scale_fixture_installed: bool = false,

    pub fn init(allocator: std.mem.Allocator, rhi: *RHI, atlas: *const TextureAtlas, seed: u64, render_distance: i32, horizon_distance: i32, lod_enabled: bool, compact_tiles_enabled: bool, generator_index: usize, render_distance_preset: RenderDistancePreset, build_config: BuildConfig) !*GameSession {
        const session = try allocator.create(GameSession);
        errdefer allocator.destroy(session);
        if (phase5EvidenceEnabled(build_config)) resetPhase5CaptureReady();

        const safe_mode = runtime_env.safeModeEnabled();
        const strict_safe_mode = runtime_env.strictSafeModeEnabled();
        const effective_render_distance: i32 = @max(render_distance, 2);
        const chunk_debug_restore_lod = chunkDebugRestoreEnabled(build_config, "lod");
        const effective_lod_enabled = if (build_config.chunk_debug_mode)
            chunk_debug_restore_lod
        else
            lod_enabled;

        if (strict_safe_mode) {
            log.log.warn("ZIGCRAFT_SAFE_MODE enabled: keeping render distance {} with reduced GPU pressure", .{effective_render_distance});
        } else if (safe_mode) {
            log.log.warn("Wayland stability profile active: keeping configured render distance {} and LOD behavior", .{effective_render_distance});
        }
        if (build_config.chunk_debug_mode) {
            log.log.warn("CHUNK DEBUG MODE enabled: restore='{s}'", .{build_config.chunk_debug_enable});
        }

        const preset_cfg = render_settings.getPresetConfig(render_distance_preset);

        const effective_horizon_distance = LODConfig.normalizeHorizonDistance(effective_render_distance, horizon_distance);
        const manual_distance_expanded = effective_render_distance > preset_cfg.lod_radii[0] or effective_horizon_distance != preset_cfg.horizon_radius;
        const chunk_render_radius = fullDetailRenderDistance(effective_render_distance);
        var preset_radii = if (strict_safe_mode)
            LODConfig.radiiForDistances(chunk_render_radius, @max(effective_horizon_distance, 64))
        else if (effective_lod_enabled and manual_distance_expanded)
            LODConfig.radiiForDistances(effective_render_distance, effective_horizon_distance)
        else
            preset_cfg.lod_radii;

        const active_count = if (effective_lod_enabled and manual_distance_expanded)
            LODConfig.activeCountForRadii(preset_radii)
        else
            preset_cfg.active_lod_count;
        if (active_count < LODLevel.count) {
            var i: usize = active_count;
            while (i < LODLevel.count) : (i += 1) {
                preset_radii[i] = preset_radii[active_count - 1];
            }
        }

        var lod_config = if (strict_safe_mode)
            LODConfig{
                .chunk_render_radius = chunk_render_radius,
                .radii = preset_radii,
                .memory_budget_mb = @min(preset_cfg.memory_budget_mb, 256),
                .max_uploads_per_frame = @min(preset_cfg.max_uploads_per_frame, 8),
                .compact_tiles_enabled = compact_tiles_enabled,
            }
        else
            LODConfig{
                .chunk_render_radius = chunk_render_radius,
                .radii = preset_radii,
                .fog_start_percent = preset_cfg.fog_start_percent,
                .horizontal_detail = preset_cfg.horizontal_detail,
                .sample_density = preset_cfg.sample_density,
                .compact_tiles_enabled = compact_tiles_enabled,
                .vertical_span_budget = preset_cfg.vertical_span_budget,
                .mesh_path = preset_cfg.mesh_path,
                .qem_triangle_targets = preset_cfg.qem_targets,
                .memory_budget_mb = preset_cfg.memory_budget_mb,
                .lod_store_size_cap_mb = preset_cfg.lod_store_size_cap_mb,
                .max_uploads_per_frame = preset_cfg.max_uploads_per_frame,
                .skip_cutout_lod2 = preset_cfg.skip_cutout_lod2,
                .skip_lighting_lod3 = preset_cfg.skip_lighting_lod3,
                .active_lod_count = active_count,
            };

        if (build_config.benchmark_lod_memory_budget_mb > 0) {
            lod_config.memory_budget_mb = build_config.benchmark_lod_memory_budget_mb;
            log.log.info("BENCHMARK: overriding LOD memory budget to {} MiB", .{lod_config.memory_budget_mb});
        }

        session.* = undefined;
        session.lod_config = lod_config;

        const world = try World.init(.{
            .allocator = allocator,
            .render_distance = effective_render_distance,
            .seed = seed,
            .rhi = rhi.*,
            .atlas = atlas,
            .generator_index = generator_index,
            .lod_config = if (effective_lod_enabled) session.lod_config.interface() else null,
        });
        errdefer world.deinit();

        // Keep source texels near 1:1 with the fullscreen map on common
        // displays. At the default zoom this also samples one world block per
        // texel, so individual builds and canopy shapes remain visible.
        var world_map = try WorldMap.init(allocator, 1024, 1024);
        errdefer world_map.deinit();

        var world_map_texture = try Texture.initEmpty(rhi.resourceManager(), world_map.width, world_map.height, .rgba, .{
            .min_filter = .linear,
            .mag_filter = .linear,
            .generate_mipmaps = false,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
        });
        errdefer world_map_texture.deinit();

        var block_outline = try BlockOutline.init(rhi.resourceManager());
        errdefer block_outline.deinit();

        var hand_renderer = try HandRenderer.init(rhi.resourceManager());
        errdefer hand_renderer.deinit();

        var ecs_render_system = try ECSRenderSystem.init(rhi.resourceManager());
        errdefer ecs_render_system.deinit();

        const world_sim = world.interface().simulation();
        const seed_spawn = findSpawnColumn(world_sim, build_config, 8, 8);
        const spawn = findActualSpawnColumn(world_sim, seed_spawn.x, seed_spawn.z) orelse seed_spawn;
        const spawn_y: f32 = @floatFromInt(spawn.info.height + 16);
        var player = Player.init(Vec3.init(@floatFromInt(spawn.x), spawn_y, @floatFromInt(spawn.z)), true);
        // Aim toward the terrain so the first frame shows the ground.
        player.camera.setYawPitch(player.camera.yaw, -std.math.degreesToRadians(35.0));

        var atmosphere = Atmosphere.init();
        atmosphere.setTimeOfDay(0.5);
        if (build_config.shadow_test_scene) {
            const scene = lightingBaselineScene(build_config.shadow_test_variant);
            atmosphere.setTimeOfDay(scene.time_of_day);
            atmosphere.time.time_scale = 0.0;
            player.position = scene.position;
            player.camera.position = player.getEyePosition();
            player.camera.setYawPitch(scene.yaw, scene.pitch);
        } else if (phase5VisualScene(build_config.phase5_visual_scene)) |scene| {
            atmosphere.time.time_scale = 0.0;
            player.position = scene.position;
            player.camera.position = player.getEyePosition();
            player.camera.setYawPitch(scene.yaw, scene.pitch);
        }

        session.* = .{
            .allocator = allocator,
            .world = world,
            .world_map = world_map,
            .world_map_texture = world_map_texture,
            .map_controller = .{},
            .player = player,
            .inventory = Inventory.init(),
            .inventory_ui_state = .{},
            .block_outline = block_outline,
            .hand_renderer = hand_renderer,
            .camera = player.camera,
            .ecs_registry = ECSRegistry.init(allocator),
            .ecs_render_system = ecs_render_system,
            .rhi = rhi,
            .atmosphere = atmosphere,
            .lod_config = session.lod_config,
            .creative_mode = true,
            .build_config = build_config,
        };

        const save_env = getenv("ZIGCRAFT_SAVE_DIR");
        if (save_env) |save_path| {
            world.interface().simulation().enableSaveManager(save_path, "world") catch |err| {
                log.log.warn("Failed to initialize save manager: {}", .{err});
            };
        }

        // Force map update initially
        session.map_controller.map_needs_update = true;

        return session;
    }

    pub fn deinit(self: *GameSession) void {
        self.ecs_render_system.deinit();
        self.ecs_registry.deinit();
        // The map worker reads the generator, so it must join before World.
        self.world_map.deinit();
        self.world.interface().deinit();
        self.world_map_texture.deinit();
        self.block_outline.deinit();
        self.hand_renderer.deinit();
        self.allocator.destroy(self);
    }

    pub fn update(self: *GameSession, dt: f32, total_time: f32, input: IRawInputProvider, mapper: IInputMapper, atlas: *TextureAtlas, window: anytype, paused: bool, skip_world: bool, benchmark_mode: bool) !void {
        self.atmosphere.update(dt);

        // Update Camera from Player
        self.camera = self.player.camera;

        const screen_w: f32 = @floatFromInt(input.getWindowWidth());
        const screen_h: f32 = @floatFromInt(input.getWindowHeight());

        if (!paused) {
            if (benchmark_mode) {
                self.hand_renderer.update(dt);
                try self.hand_renderer.updateMesh(self.inventory, atlas);
            } else {
                if (mapper.isActionPressed(input, .toggle_fps)) self.debug_show_fps = !self.debug_show_fps;
                if (mapper.isActionPressed(input, .toggle_block_info)) self.debug_show_block_info = !self.debug_show_block_info;
                if (mapper.isActionPressed(input, .toggle_shadows)) self.debug_shadows = !self.debug_shadows;
                if (self.debug_shadows and mapper.isActionPressed(input, .cycle_cascade)) self.debug_cascade_idx = (self.debug_cascade_idx + 1) % 3;
                if (mapper.isActionPressed(input, .toggle_time_scale)) {
                    self.atmosphere.time.time_scale = if (self.atmosphere.time.time_scale > 0) @as(f32, 0.0) else @as(f32, 1.0);
                }
                if (mapper.isActionPressed(input, .toggle_creative)) {
                    self.creative_mode = !self.creative_mode;
                    self.player.setCreativeMode(self.creative_mode);
                }

                if (mapper.isActionPressed(input, .inventory)) {
                    self.inventory_ui_state.toggle();
                    input.setMouseCapture(@ptrCast(@alignCast(window)), !self.inventory_ui_state.visible);
                }

                if (!self.inventory_ui_state.visible and !self.map_controller.show_map) {
                    if (mapper.isActionPressed(input, .slot_1)) self.inventory.selectSlot(0);
                    if (mapper.isActionPressed(input, .slot_2)) self.inventory.selectSlot(1);
                    if (mapper.isActionPressed(input, .slot_3)) self.inventory.selectSlot(2);
                    if (mapper.isActionPressed(input, .slot_4)) self.inventory.selectSlot(3);
                    if (mapper.isActionPressed(input, .slot_5)) self.inventory.selectSlot(4);
                    if (mapper.isActionPressed(input, .slot_6)) self.inventory.selectSlot(5);
                    if (mapper.isActionPressed(input, .slot_7)) self.inventory.selectSlot(6);
                    if (mapper.isActionPressed(input, .slot_8)) self.inventory.selectSlot(7);
                    if (mapper.isActionPressed(input, .slot_9)) self.inventory.selectSlot(8);
                    const scroll_y = input.getScrollDelta().y;
                    if (scroll_y != 0) {
                        self.inventory.scrollSelection(@intFromFloat(scroll_y));
                    }
                }

                self.map_controller.update(input, mapper, &self.camera, dt, window, screen_w, screen_h);

                if (self.map_controller.show_map) {
                    // map open – skip player/world update
                } else if (!skip_world) {
                    const world_sim = self.world.interface().simulation();
                    if (!self.inventory_ui_state.visible) {
                        self.player.update(input, mapper, world_sim, dt, total_time);

                        // Handle interaction
                        if (mapper.isActionPressed(input, .interact_primary)) {
                            self.player.breakTargetBlock(world_sim);
                            self.hand_renderer.swing();
                        }
                        if (mapper.isActionPressed(input, .interact_secondary)) {
                            if (self.inventory.getSelectedBlock()) |block_type| {
                                self.player.placeBlock(world_sim, block_type);
                                self.hand_renderer.swing();
                            }
                        }
                    }

                    self.hand_renderer.update(dt);
                    try self.hand_renderer.updateMesh(self.inventory, atlas);
                } else {
                    const world_sim = self.world.interface().simulation();
                    if (!world_sim.isPaused()) world_sim.pauseGeneration();
                }
            }

            if (!skip_world) {
                if (!self.gpu_culling_scale_fixture_installed and std.ascii.eqlIgnoreCase(self.build_config.benchmark_fixture, "gpu-culling-scale")) {
                    // The Vulkan transfer queue is frame-owned. Install after
                    // App begins this frame so all 1024 compact-pool uploads
                    // use the production lifetime/synchronization path.
                    try self.world.installGpuCullingScaleFixture();
                    self.gpu_culling_scale_fixture_installed = true;
                }
                if (phase5VisualScene(self.build_config.phase5_visual_scene)) |scene| {
                    // This is a production flat-world launch, not the shadow
                    // test renderer. Reapply the deterministic pose because
                    // normal player simulation is still active in captures.
                    // Motion scenes advance a bounded frame-script here rather
                    // than being static labels passed to the capture runner.
                    self.applyPhase5VisualPose(scene);
                }
                const world_sim = self.world.interface().simulation();
                try world_sim.update(self.player.camera.position, dt);

                if (!self.phase5_fixture_applied and (self.build_config.phase5_visual_scene.len > 0 or (self.build_config.benchmark_fixture.len > 0 and !std.ascii.eqlIgnoreCase(self.build_config.benchmark_fixture, "gpu-culling-scale")))) {
                    try self.applyPhase5VisualFixture(world_sim);
                }

                // The Phase 5 visual gate uses the fixed test-world pool as a
                // full-detail fluid fixture. Count resident water cells before
                // capture so its image ROI is backed by runtime evidence, not
                // merely a requested camera pose.
                if (self.build_config.screenshot_path.len > 0 and (std.ascii.eqlIgnoreCase(self.build_config.phase5_visual_scene, "water") or isSavedWorldScene(self.build_config.phase5_visual_scene))) {
                    const fixture = if (std.ascii.eqlIgnoreCase(self.build_config.phase5_visual_scene, "water")) waterFixtureCells() else savedWorldWetCells();
                    var observed: u32 = 0;
                    for (fixture) |cell| {
                        if (world_sim.getBlock(cell[0], cell[1], cell[2]) == .water) observed += 1;
                    }
                    self.phase5_water_fixture_observations +%= observed;
                    if (!self.phase5_water_fixture_evidence_emitted and self.phase5_water_fixture_observations >= @as(u32, @intCast(fixture.len))) {
                        if (phase5EvidenceEnabled(self.build_config)) {
                            log.log.warn("PHASE5_WATER_FIXTURE: run={s} scene={s} observations={} fixture_cells={}", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, self.phase5_water_fixture_observations, fixture.len });
                            std.debug.print("PHASE5_WATER_FIXTURE: run={s} scene={s} observations={} fixture_cells={}\n", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, self.phase5_water_fixture_observations, fixture.len });
                        }
                        self.phase5_water_fixture_evidence_emitted = true;
                    }
                }

                if (!self.phase5_gpu_evidence_emitted and phase5SceneRequiresGpuValidation(self.build_config.phase5_visual_scene) and (!phase5SceneHasMotion(self.build_config.phase5_visual_scene) or self.phase5_motion_complete)) {
                    if (self.world.getLODStats()) |lod_stats| {
                        const candidates = lod_stats.gpu_terrain_candidates + lod_stats.gpu_fluid_candidates;
                        if (candidates > 0) {
                            if (phase5EvidenceEnabled(self.build_config)) {
                                log.log.warn("PHASE5_GPU_CULLING: run={s} scene={s} candidates={} validation_mismatches={} overflows={}", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, candidates, lod_stats.gpu_culling_validation_mismatches, lod_stats.gpu_culling_overflows });
                                std.debug.print("PHASE5_GPU_CULLING: run={s} scene={s} candidates={} validation_mismatches={} overflows={}\n", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, candidates, lod_stats.gpu_culling_validation_mismatches, lod_stats.gpu_culling_overflows });
                            }
                            self.phase5_gpu_evidence_emitted = true;
                        }
                    }
                }

                if (self.phase5_gpu_evidence_emitted and !self.phase5_gpu_validation_complete_emitted and getenv("ZIGCRAFT_LOD_GPU_CULLING_VALIDATE") != null) {
                    // A queued generation is not validation evidence. The RHI
                    // advances these counters only after consuming the mapped
                    // readback when its frame slot is reused.
                    if (phase5EvidenceEnabled(self.build_config)) if (self.world.getLODStats()) |lod_stats| {
                        const completed_generation = lod_stats.gpu_culling_validation_completed_generation;
                        const completed_count = lod_stats.gpu_culling_validation_completed_count;
                        if (completed_generation > 0 and completed_count > 0 and completed_generation <= lod_stats.gpu_culling_validation_generation) {
                            log.log.warn("PHASE5_GPU_VALIDATION_COMPLETE: run={s} scene={s} generation={} validations={} validation_mismatches={}", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, completed_generation, completed_count, lod_stats.gpu_culling_validation_mismatches });
                            std.debug.print("PHASE5_GPU_VALIDATION_COMPLETE: run={s} scene={s} generation={} validations={} validation_mismatches={}\n", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, completed_generation, completed_count, lod_stats.gpu_culling_validation_mismatches });
                            self.phase5_gpu_validation_complete_emitted = true;
                        }
                    };
                }

                if (isSavedWorldReloadScene(self.build_config.phase5_visual_scene) and self.phase5_save_loaded and !self.phase5_compact_wet_dry_evidence_emitted) {
                    if (self.world.getLODStats()) |lod_stats| {
                        // The persisted wet fixture proves reload from the
                        // save, while direct-mesh bytes keep unsupported
                        // shoreline topology on the expanded fallback. Dry
                        // distant terrain must have live compact residency.
                        if (lod_stats.compact_pool_allocated_bytes > 0 and lod_stats.direct_mesh_gpu_bytes > 0) {
                            if (phase5EvidenceEnabled(self.build_config)) {
                                log.log.warn("PHASE5_COMPACT_WET_DRY: run={s} scene={s} dry_compact_bytes={} wet_fallback_bytes={} wet_cells={} dry_cells={}", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, lod_stats.compact_pool_allocated_bytes, lod_stats.direct_mesh_gpu_bytes, savedWorldWetCells().len, savedWorldDryCells().len });
                                std.debug.print("PHASE5_COMPACT_WET_DRY: run={s} scene={s} dry_compact_bytes={} wet_fallback_bytes={} wet_cells={} dry_cells={}\n", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, lod_stats.compact_pool_allocated_bytes, lod_stats.direct_mesh_gpu_bytes, savedWorldWetCells().len, savedWorldDryCells().len });
                            }
                            self.phase5_compact_wet_dry_evidence_emitted = true;
                        }
                    }
                }

                self.updatePhase5CaptureReadiness();

                // ECS Updates
                ECSPhysicsSystem.update(&self.ecs_registry, world_sim.collisionWorld(), dt);
            }
        }
    }

    pub fn renderEntities(self: *GameSession, ctx: RenderContext, camera_pos: Vec3) void {
        self.ecs_render_system.render(ctx, &self.ecs_registry, camera_pos);
    }

    pub fn renderEntityShadowCasters(self: *GameSession, ctx: RenderContext, camera_pos: Vec3, caster_min: Vec3, caster_max: Vec3) void {
        self.ecs_render_system.renderShadowCasters(ctx, &self.ecs_registry, camera_pos, caster_min, caster_max);
    }

    pub fn drawHUD(self: *GameSession, ui: *UISystem, atlas: *const TextureAtlas, active_pack: ?[]const u8, fps: f32, screen_w: f32, screen_h: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool) !void {
        try session_hud.draw(self, ui, atlas, active_pack, fps, screen_w, screen_h, mouse_x, mouse_y, mouse_clicked);
    }

    fn applyPhase5VisualFixture(self: *GameSession, world_sim: IWorldSimulation) !void {
        const scene = if (self.build_config.phase5_visual_scene.len > 0) self.build_config.phase5_visual_scene else self.build_config.benchmark_fixture;
        // Mutations are deliberately small, local, and above the flat-world
        // grass. They make the production launch visually identifiable while
        // retaining the normal generator, streamer, mesher, and LOD pipeline.
        if (std.ascii.eqlIgnoreCase(scene, "saved-world-reload")) {
            const wet_loaded = fixtureCellsMatch(world_sim, savedWorldWetCells(), .water);
            const dry_loaded = fixtureCellsMatch(world_sim, savedWorldDryCells(), .white_terracotta);
            if (wet_loaded and dry_loaded) {
                self.phase5_fixture_applied = true;
                self.phase5_save_loaded = true;
                if (phase5EvidenceEnabled(self.build_config)) {
                    log.log.warn("PHASE5_SAVE_LOADED: run={s} scene={s} wet_cells={} dry_cells={}", .{ self.build_config.phase5_visual_run_id, scene, savedWorldWetCells().len, savedWorldDryCells().len });
                    std.debug.print("PHASE5_SAVE_LOADED: run={s} scene={s} wet_cells={} dry_cells={}\n", .{ self.build_config.phase5_visual_run_id, scene, savedWorldWetCells().len, savedWorldDryCells().len });
                    log.log.warn("PHASE5_FIXTURE: run={s} scene={s} applied=1", .{ self.build_config.phase5_visual_run_id, scene });
                    std.debug.print("PHASE5_FIXTURE: run={s} scene={s} applied=1\n", .{ self.build_config.phase5_visual_run_id, scene });
                }
            }
            return;
        } else if (std.ascii.eqlIgnoreCase(scene, "seam")) {
            for (15..17) |x| for (4..12) |z| for (65..70) |y| {
                try world_sim.setBlock(@intCast(x), @intCast(y), @intCast(z), if (x == 15) .stone else .white_terracotta);
            };
        } else if (std.ascii.eqlIgnoreCase(scene, "water")) {
            for (20..31) |x| for (0..10) |z| {
                try world_sim.setBlock(@intCast(x), 65, @intCast(z), .water);
            };
        } else if (std.ascii.eqlIgnoreCase(scene, "lod-handoff") or std.ascii.eqlIgnoreCase(scene, "lod-handoff-traversal") or std.ascii.eqlIgnoreCase(scene, "teleport-handoff")) {
            const motion_scene = std.ascii.eqlIgnoreCase(scene, "lod-handoff-traversal") or std.ascii.eqlIgnoreCase(scene, "teleport-handoff");
            const base_x: i32 = if (motion_scene) -130 else -2;
            const base_z: i32 = if (motion_scene) -24 else 8;
            for (0..5) |x| for (0..5) |z| for (65..76) |y| {
                if (x == 0 or x == 4 or z == 0 or z == 4 or y == 75) try world_sim.setBlock(base_x + @as(i32, @intCast(x)), @intCast(y), base_z + @as(i32, @intCast(z)), .stone);
            };
        } else if (std.ascii.eqlIgnoreCase(scene, "fog-rapid-turn")) {
            // A fixed horizon landmark makes the rotation exercise visible in
            // the production world while the changing view drives frustum/fog
            // churn through the normal renderer.
            for (0..5) |x| for (65..82) |y| {
                try world_sim.setBlock(@as(i32, @intCast(x)) - 2, @intCast(y), 32, if (y % 2 == 0) .stone else .white_terracotta);
            };
        } else if (std.ascii.eqlIgnoreCase(scene, "saved-world-create")) {
            for (18..33) |x| for (0..12) |z_offset| {
                try world_sim.setBlock(@intCast(x), 65, @as(i32, @intCast(z_offset)) - 76, .water);
            };
            for (0..10) |x| for (0..4) |z_offset| for (65..71) |y| {
                try world_sim.setBlock(@intCast(x), @intCast(y), @as(i32, @intCast(z_offset)) - 64, .white_terracotta);
            };
            for (savedWorldWetCells()) |cell| try world_sim.setBlock(cell[0], cell[1], cell[2], .water);
            for (savedWorldDryCells()) |cell| try world_sim.setBlock(cell[0], cell[1], cell[2], .white_terracotta);
        } else {
            log.log.warn("Unknown Phase 5 visual scene '{s}'", .{scene});
            return;
        }
        const fixture_applied = if (std.ascii.eqlIgnoreCase(scene, "saved-world-create"))
            fixtureCellsMatch(world_sim, savedWorldWetCells(), .water) and fixtureCellsMatch(world_sim, savedWorldDryCells(), .white_terracotta)
        else blk: {
            const expected = if (std.ascii.eqlIgnoreCase(scene, "seam")) BlockType.stone else if (std.ascii.eqlIgnoreCase(scene, "water")) BlockType.water else BlockType.stone;
            const probe = if (std.ascii.eqlIgnoreCase(scene, "seam")) [3]i32{ 15, 65, 4 } else if (std.ascii.eqlIgnoreCase(scene, "water")) [3]i32{ 25, 65, 4 } else if (std.ascii.eqlIgnoreCase(scene, "fog-rapid-turn")) [3]i32{ -2, 66, 32 } else if (std.ascii.eqlIgnoreCase(scene, "lod-handoff-traversal") or std.ascii.eqlIgnoreCase(scene, "teleport-handoff")) [3]i32{ -130, 65, -24 } else [3]i32{ -2, 65, 8 };
            break :blk world_sim.getBlock(probe[0], probe[1], probe[2]) == expected;
        };
        if (fixture_applied) {
            self.phase5_fixture_applied = true;
            if (phase5EvidenceEnabled(self.build_config)) {
                log.log.warn("PHASE5_FIXTURE: run={s} scene={s} applied=1", .{ self.build_config.phase5_visual_run_id, scene });
                std.debug.print("PHASE5_FIXTURE: run={s} scene={s} applied=1\n", .{ self.build_config.phase5_visual_run_id, scene });
            }
            if (std.ascii.eqlIgnoreCase(scene, "saved-world-create")) {
                self.world.saveAllModifiedChunks();
                const failures = self.world.takeSaveFailureWarningCount();
                if (failures == 0) {
                    self.phase5_save_flushed = true;
                    if (phase5EvidenceEnabled(self.build_config)) {
                        log.log.warn("PHASE5_SAVE_FLUSH: run={s} scene={s} saved=1 failures=0", .{ self.build_config.phase5_visual_run_id, scene });
                        std.debug.print("PHASE5_SAVE_FLUSH: run={s} scene={s} saved=1 failures=0\n", .{ self.build_config.phase5_visual_run_id, scene });
                    }
                }
            }
        }
    }

    fn updatePhase5CaptureReadiness(self: *GameSession) void {
        if (self.build_config.phase5_visual_scene.len == 0) return;
        const scene = phase5VisualScene(self.build_config.phase5_visual_scene) orelse {
            self.phase5_settle_frames = 0;
            return;
        };

        const world_stats = self.world.getStats();
        const render_stats = self.world.getRenderStats();
        const lod_stats = self.world.getLODStats() orelse {
            self.phase5_settle_frames = 0;
            return;
        };
        const queues_settled = world_stats.gen_queue == 0 and world_stats.mesh_queue == 0 and world_stats.upload_queue == 0 and
            allZero(lod_stats.generating) and allZero(lod_stats.generated) and allZero(lod_stats.meshing) and allZero(lod_stats.mesh_ready) and allZero(lod_stats.uploading) and
            allZero(lod_stats.gen_queue_depth) and allZero(lod_stats.upload_queue_depth) and lod_stats.upgrades_pending == 0 and lod_stats.downgrades_pending == 0 and lod_stats.ingestion_backlog == 0;
        const renderable = render_stats.chunks_rendered > 0 and lod_stats.totalLoaded() > 0;
        const motion_ready = scene.motion == .fixed or self.phase5_motion_complete;
        const saved_world_ready = if (std.ascii.eqlIgnoreCase(self.build_config.phase5_visual_scene, "saved-world-create"))
            self.phase5_save_flushed
        else if (isSavedWorldReloadScene(self.build_config.phase5_visual_scene))
            self.phase5_save_loaded and self.phase5_compact_wet_dry_evidence_emitted and self.phase5_gpu_validation_complete_emitted
        else if (phase5SceneRequiresGpuValidation(self.build_config.phase5_visual_scene))
            self.phase5_gpu_validation_complete_emitted
        else
            true;
        if (!self.phase5_fixture_applied or !motion_ready or !queues_settled or !renderable or !saved_world_ready) {
            self.phase5_settle_frames = 0;
            return;
        }

        self.phase5_settle_frames +|= 1;
        if (self.phase5_settle_frames < phase5SettleFrameTarget()) return;
        phase5_capture_ready.store(true, .release);
        if (!self.phase5_ready_evidence_emitted and phase5EvidenceEnabled(self.build_config)) {
            log.log.warn("PHASE5_READY: run={s} scene={s} stable_frames={} chunks_rendered={} lod_loaded={}", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, self.phase5_settle_frames, render_stats.chunks_rendered, lod_stats.totalLoaded() });
            std.debug.print("PHASE5_READY: run={s} scene={s} stable_frames={} chunks_rendered={} lod_loaded={}\n", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, self.phase5_settle_frames, render_stats.chunks_rendered, lod_stats.totalLoaded() });
            self.phase5_ready_evidence_emitted = true;
        }
    }

    fn applyPhase5VisualPose(self: *GameSession, scene: Phase5VisualScene) void {
        const pose = phase5VisualPoseAtFrame(scene, self.phase5_motion_frames);
        self.player.position = pose.position;
        self.player.camera.position = self.player.getEyePosition();
        self.player.camera.setYawPitch(pose.yaw, pose.pitch);
        self.camera = self.player.camera;

        // Hold the initial pose until the identifying fixture is actually
        // resident and verified. Advancing immediately can stream the origin
        // out before `setBlock` succeeds, making readiness impossible no
        // matter how long the screenshot waits.
        if (scene.motion == .fixed or self.phase5_motion_complete or !self.phase5_fixture_applied) return;

        self.phase5_motion_frames +|= 1;
        if (self.phase5_motion_frames < phase5MotionFrameTarget(scene.motion)) return;

        self.phase5_motion_complete = true;
        if (!self.phase5_motion_evidence_emitted and phase5EvidenceEnabled(self.build_config)) {
            const movement = phase5MotionEvidence(scene.motion);
            log.log.warn("PHASE5_MOTION: run={s} scene={s} kind={s} completed=1 frames={} distance={d:.1} yaw_degrees={d:.1}", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, scene.motion.name(), self.phase5_motion_frames, movement.distance, movement.yaw_degrees });
            std.debug.print("PHASE5_MOTION: run={s} scene={s} kind={s} completed=1 frames={} distance={d:.1} yaw_degrees={d:.1}\n", .{ self.build_config.phase5_visual_run_id, self.build_config.phase5_visual_scene, scene.motion.name(), self.phase5_motion_frames, movement.distance, movement.yaw_degrees });
            self.phase5_motion_evidence_emitted = true;
        }
    }
};

fn allZero(values: anytype) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

fn waterFixtureCells() []const [3]i32 {
    return &.{ .{ 22, 65, 4 }, .{ 25, 65, 4 }, .{ 28, 65, 4 } };
}

/// These cells span a wet pool and a contrasting dry wall in two persisted
/// chunks. Reload probes every one, so generated-world coincidence cannot
/// satisfy the saved-world qualification.
fn savedWorldWetCells() []const [3]i32 {
    return &.{ .{ 20, 65, -72 }, .{ 25, 65, -72 }, .{ 30, 65, -72 } };
}

fn savedWorldDryCells() []const [3]i32 {
    return &.{ .{ 0, 65, -64 }, .{ 4, 67, -64 }, .{ 8, 69, -64 } };
}

fn fixtureCellsMatch(world_sim: IWorldSimulation, cells: []const [3]i32, expected: BlockType) bool {
    for (cells) |cell| {
        if (world_sim.getBlock(cell[0], cell[1], cell[2]) != expected) return false;
    }
    return true;
}

fn isSavedWorldScene(scene: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scene, "saved-world-create") or isSavedWorldReloadScene(scene);
}

fn isSavedWorldReloadScene(scene: []const u8) bool {
    return std.ascii.eqlIgnoreCase(scene, "saved-world-reload");
}

fn phase5SceneRequiresGpuValidation(scene: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(scene, "lod-handoff") or isSavedWorldReloadScene(scene)) return true;
    if (phase5VisualScene(scene)) |visual_scene| return visual_scene.motion != .fixed;
    return false;
}

fn phase5SceneHasMotion(scene: []const u8) bool {
    if (phase5VisualScene(scene)) |visual_scene| return visual_scene.motion != .fixed;
    return false;
}

fn phase5SettleFrameTarget() u32 {
    if (getenv("ZIGCRAFT_PHASE5_SETTLE_FRAMES")) |value| {
        return std.fmt.parseInt(u32, value, 10) catch 180;
    }
    return 180;
}

fn phase5EvidenceEnabled(build_config: BuildConfig) bool {
    return build_config.phase5_visual_scene.len > 0 and build_config.phase5_visual_run_id.len > 0;
}

const LightingBaselineScene = struct {
    position: Vec3,
    yaw: f32,
    pitch: f32,
    time_of_day: f32,
};

pub const Phase5VisualMotion = enum {
    fixed,
    lod_handoff_traversal,
    fog_rapid_turn,
    teleport_handoff,

    pub fn name(self: Phase5VisualMotion) []const u8 {
        return switch (self) {
            .fixed => "fixed",
            .lod_handoff_traversal => "traversal",
            .fog_rapid_turn => "rapid-turn",
            .teleport_handoff => "teleport",
        };
    }
};

pub const Phase5VisualScene = struct {
    position: Vec3,
    yaw: f32,
    pitch: f32,
    motion: Phase5VisualMotion = .fixed,
};

pub fn parsePhase5VisualScene(name: []const u8) ?Phase5VisualScene {
    const forward_z = std.math.pi / 2.0;
    if (std.ascii.eqlIgnoreCase(name, "seam")) return .{ .position = Vec3.init(16.0, 74.0, -18.0), .yaw = forward_z, .pitch = -std.math.degreesToRadians(15.0) };
    if (std.ascii.eqlIgnoreCase(name, "water")) return .{ .position = Vec3.init(25.0, 75.0, -16.0), .yaw = forward_z, .pitch = -std.math.degreesToRadians(17.0) };
    if (std.ascii.eqlIgnoreCase(name, "lod-handoff")) return .{ .position = Vec3.init(0.0, 110.0, -80.0), .yaw = forward_z, .pitch = -std.math.degreesToRadians(13.0) };
    if (std.ascii.eqlIgnoreCase(name, "saved-world-create") or std.ascii.eqlIgnoreCase(name, "saved-world-reload")) return .{ .position = Vec3.init(8.0, 78.0, -88.0), .yaw = forward_z, .pitch = -std.math.degreesToRadians(18.0) };
    if (std.ascii.eqlIgnoreCase(name, "lod-handoff-traversal")) return .{ .position = Vec3.init(-128.0, 110.0, -32.0), .yaw = 0.0, .pitch = -std.math.degreesToRadians(13.0), .motion = .lod_handoff_traversal };
    if (std.ascii.eqlIgnoreCase(name, "fog-rapid-turn")) return .{ .position = Vec3.init(0.0, 110.0, 0.0), .yaw = -std.math.pi, .pitch = -std.math.degreesToRadians(10.0), .motion = .fog_rapid_turn };
    if (std.ascii.eqlIgnoreCase(name, "teleport-handoff")) return .{ .position = Vec3.init(-128.0, 110.0, -32.0), .yaw = 0.0, .pitch = -std.math.degreesToRadians(13.0), .motion = .teleport_handoff };
    return null;
}

fn phase5VisualScene(name: []const u8) ?Phase5VisualScene {
    return parsePhase5VisualScene(name);
}

fn phase5VisualPoseAtFrame(scene: Phase5VisualScene, frame: u32) Phase5VisualScene {
    const target_frames = phase5MotionFrameTarget(scene.motion);
    const clamped_frame = @min(frame, target_frames);
    const progress: f32 = @as(f32, @floatFromInt(clamped_frame)) / @as(f32, @floatFromInt(target_frames));
    var pose = scene;
    switch (scene.motion) {
        .fixed => {},
        .lod_handoff_traversal => pose.position.x += 256.0 * progress,
        .fog_rapid_turn => pose.yaw += std.math.tau * 2.0 * progress,
        .teleport_handoff => {
            if (frame >= 60) pose.position = Vec3.init(128.0, 110.0, 32.0);
        },
    }
    return pose;
}

fn phase5MotionFrameTarget(motion: Phase5VisualMotion) u32 {
    return switch (motion) {
        .fixed => 1,
        .lod_handoff_traversal => 180,
        .fog_rapid_turn => 160,
        .teleport_handoff => 120,
    };
}

fn phase5MotionEvidence(motion: Phase5VisualMotion) struct { distance: f32, yaw_degrees: f32 } {
    return switch (motion) {
        .fixed => .{ .distance = 0.0, .yaw_degrees = 0.0 },
        .lod_handoff_traversal => .{ .distance = 256.0, .yaw_degrees = 0.0 },
        .fog_rapid_turn => .{ .distance = 0.0, .yaw_degrees = 720.0 },
        .teleport_handoff => .{ .distance = 262.9, .yaw_degrees = 0.0 },
    };
}

test "Phase 5 visual scene parser exposes bounded motion poses" {
    const traversal = parsePhase5VisualScene("lod-handoff-traversal").?;
    const turn = parsePhase5VisualScene("fog-rapid-turn").?;
    const teleport = parsePhase5VisualScene("teleport-handoff").?;
    try std.testing.expectEqual(Phase5VisualMotion.lod_handoff_traversal, traversal.motion);
    try std.testing.expectEqual(Phase5VisualMotion.fog_rapid_turn, turn.motion);
    try std.testing.expectEqual(Phase5VisualMotion.teleport_handoff, teleport.motion);
    try std.testing.expect(parsePhase5VisualScene("unbounded-motion") == null);

    const traversal_end = phase5VisualPoseAtFrame(traversal, phase5MotionFrameTarget(traversal.motion));
    try std.testing.expect(traversal_end.position.x > traversal.position.x);
    const turn_end = phase5VisualPoseAtFrame(turn, phase5MotionFrameTarget(turn.motion));
    try std.testing.expect(turn_end.yaw > turn.yaw);
    const teleport_end = phase5VisualPoseAtFrame(teleport, phase5MotionFrameTarget(teleport.motion));
    try std.testing.expect(teleport_end.position.x != teleport.position.x);
}

fn lightingBaselineScene(name: []const u8) LightingBaselineScene {
    const forward_z = std.math.pi / 2.0;
    const slight_down = -std.math.degreesToRadians(8.0);

    if (std.ascii.eqlIgnoreCase(name, "low-sun")) return .{ .position = Vec3.init(0.0, 68.0, 18.0), .yaw = forward_z, .pitch = slight_down, .time_of_day = 0.30 };
    if (std.ascii.eqlIgnoreCase(name, "sealed-cave")) return .{ .position = Vec3.init(-25.0, 65.0, -4.0), .yaw = forward_z, .pitch = 0.0, .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "rgb-emitter")) return .{ .position = Vec3.init(-46.0, 65.0, -5.0), .yaw = forward_z, .pitch = 0.0, .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "foliage-cutout")) return .{ .position = Vec3.init(12.0, 67.0, 10.0), .yaw = forward_z, .pitch = slight_down, .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "water")) return .{ .position = Vec3.init(25.0, 68.0, -12.0), .yaw = forward_z, .pitch = -std.math.degreesToRadians(18.0), .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "cross-chunk-corridor")) return .{ .position = Vec3.init(10.0, 65.0, 32.0), .yaw = 0.0, .pitch = 0.0, .time_of_day = 0.5 };
    // Looks over the authored fixtures from a resident full-detail area into
    // the LOD horizon. The scene keeps time fixed and has no input-driven pose.
    if (std.ascii.eqlIgnoreCase(name, "lod-handoff")) return .{ .position = Vec3.init(0.0, 112.0, -96.0), .yaw = forward_z, .pitch = -std.math.degreesToRadians(12.0), .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "bend")) return .{ .position = Vec3.init(5.5, 65.0, -14.0), .yaw = forward_z, .pitch = slight_down, .time_of_day = 0.5 };
    if (std.ascii.eqlIgnoreCase(name, "noon")) return .{ .position = Vec3.init(0.0, 68.0, 18.0), .yaw = forward_z, .pitch = slight_down, .time_of_day = 0.5 };
    return .{ .position = Vec3.init(0.0, 65.0, -16.0), .yaw = forward_z, .pitch = -std.math.degreesToRadians(5.0), .time_of_day = 0.5 };
}

fn chunkDebugRestoreEnabled(build_config: BuildConfig, name: []const u8) bool {
    if (!build_config.chunk_debug_mode) return false;

    var it = std.mem.tokenizeScalar(u8, build_config.chunk_debug_enable, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }
    return false;
}

fn findSpawnColumn(world: IWorldSimulation, build_config: BuildConfig, default_x: i32, default_z: i32) SpawnColumn {
    const sea_level = 64;
    const default_info = world.getColumnInfo(default_x, default_z);
    const needs_dry_spawn = build_config.chunk_debug_mode and (chunkDebugRestoreEnabled(build_config, "water") or chunkDebugRestoreEnabled(build_config, "watergen") or chunkDebugRestoreEnabled(build_config, "waterrender"));
    if ((!needs_dry_spawn or (!default_info.is_ocean and default_info.height >= sea_level)) and isSpawnPatchStable(world, default_x, default_z, default_info, sea_level)) {
        return .{ .x = default_x, .z = default_z, .info = default_info };
    }

    var radius: i32 = 1;
    while (radius <= 64) : (radius += 1) {
        var dz: i32 = -radius;
        while (dz <= radius) : (dz += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                if (@max(@abs(dx), @abs(dz)) != radius) continue;

                const x = default_x + dx;
                const z = default_z + dz;
                const info = world.getColumnInfo(x, z);
                if (!info.is_ocean and info.height >= sea_level and isSpawnPatchStable(world, x, z, info, sea_level)) {
                    log.log.info("Chunk debug water spawn moved from ({},{}) to ({},{})", .{ default_x, default_z, x, z });
                    return .{ .x = x, .z = z, .info = info };
                }
            }
        }
    }

    return .{ .x = default_x, .z = default_z, .info = default_info };
}

fn findActualSpawnColumn(world: IWorldSimulation, default_x: i32, default_z: i32) ?SpawnColumn {
    var radius: i32 = 0;
    while (radius <= 64) : (radius += 1) {
        var dz: i32 = -radius;
        while (dz <= radius) : (dz += 1) {
            var dx: i32 = -radius;
            while (dx <= radius) : (dx += 1) {
                if (@max(@abs(dx), @abs(dz)) != radius) continue;

                const x = default_x + dx;
                const z = default_z + dz;
                const surface_y = findActualSurfaceY(world, x, z) orelse continue;
                const info = world.getColumnInfo(x, z);
                if (isActualSpawnAreaStable(world, x, z, surface_y)) {
                    if (x != default_x or z != default_z) {
                        log.log.info("Actual spawn moved from ({},{}) to ({},{})", .{ default_x, default_z, x, z });
                    }
                    return .{ .x = x, .z = z, .info = info };
                }
            }
        }
    }
    return null;
}

fn isActualSpawnAreaStable(world: IWorldSimulation, spawn_x: i32, spawn_z: i32, center_y: i32) bool {
    const patch_radius = 4;
    const step = 2;
    const max_height_delta = 4;

    var dz: i32 = -patch_radius;
    while (dz <= patch_radius) : (dz += step) {
        var dx: i32 = -patch_radius;
        while (dx <= patch_radius) : (dx += step) {
            const surface_y = findActualSurfaceY(world, spawn_x + dx, spawn_z + dz) orelse return false;
            if (@abs(surface_y - center_y) > max_height_delta) return false;
        }
    }
    return true;
}

fn findActualSurfaceY(world: IWorldSimulation, x: i32, z: i32) ?i32 {
    var y: i32 = 255;
    while (y >= 0) : (y -= 1) {
        const block = world.getBlock(x, y, z);
        switch (block) {
            .air,
            .water,
            .lava,
            .leaves,
            .mangrove_leaves,
            .jungle_leaves,
            .acacia_leaves,
            .birch_leaves,
            .spruce_leaves,
            .tall_grass,
            .flower_red,
            .flower_yellow,
            .dead_bush,
            .vine,
            .torch,
            .cactus,
            .bamboo,
            .acacia_sapling,
            .wood,
            .mangrove_log,
            .jungle_log,
            .acacia_log,
            .birch_log,
            .spruce_log,
            .mangrove_roots,
            .melon,
            => continue,
            else => return y,
        }
    }
    return null;
}

fn isSpawnPatchStable(world: IWorldSimulation, spawn_x: i32, spawn_z: i32, center_info: @import("world-worldgen").ColumnInfo, sea_level: i32) bool {
    if (!checkSpawnArea(world, spawn_x, spawn_z, center_info, sea_level, 1, 1, 2)) return false;
    if (!checkSpawnArea(world, spawn_x, spawn_z, center_info, sea_level, 8, 4, 8)) return false;
    return true;
}

fn checkSpawnArea(world: IWorldSimulation, spawn_x: i32, spawn_z: i32, center_info: @import("world-worldgen").ColumnInfo, sea_level: i32, radius: i32, step: i32, max_height_delta: i32) bool {
    var dz: i32 = -radius;
    while (dz <= radius) : (dz += step) {
        var dx: i32 = -radius;
        while (dx <= radius) : (dx += step) {
            const info = world.getColumnInfo(spawn_x + dx, spawn_z + dz);
            if (info.is_ocean or info.height < sea_level) return false;
            if (@abs(info.height - center_info.height) > max_height_delta) return false;

            const surface_block = world.getBlock(spawn_x + dx, info.height, spawn_z + dz);
            if (surface_block == .air or surface_block == .water) return false;
        }
    }
    return true;
}
