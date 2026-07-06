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

pub const BuildConfig = struct {
    auto_world: []const u8 = "",
    chunk_debug_enable: []const u8 = "",
    chunk_debug_mode: bool = false,
    screenshot_path: []const u8 = "",
    shadow_test_scene: bool = false,
    shadow_test_variant: []const u8 = "dug-cave",
    startup_diagnostic_seconds: u32 = 0,
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

pub const GameSession = struct {
    allocator: std.mem.Allocator,
    world: *World,
    world_map: WorldMap,
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

    pub fn init(allocator: std.mem.Allocator, rhi: *RHI, atlas: *const TextureAtlas, seed: u64, render_distance: i32, horizon_distance: i32, lod_enabled: bool, generator_index: usize, render_distance_preset: RenderDistancePreset, build_config: BuildConfig) !*GameSession {
        const session = try allocator.create(GameSession);
        errdefer allocator.destroy(session);

        const safe_mode = runtime_env.safeModeEnabled();
        const strict_safe_mode = runtime_env.strictSafeModeEnabled();
        const effective_render_distance: i32 = render_distance;
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

        const effective_horizon_distance = @max(horizon_distance, effective_render_distance);
        const manual_distance_expanded = effective_render_distance > preset_cfg.lod_radii[0] or effective_horizon_distance != preset_cfg.horizon_radius;
        const chunk_render_radius = if (strict_safe_mode)
            @min(effective_render_distance, 8)
        else
            effective_render_distance;
        var preset_radii = if (strict_safe_mode)
            LODConfig.radiiForDistances(chunk_render_radius, @max(effective_horizon_distance, 64))
        else
            LODConfig.radiiForDistances(effective_render_distance, effective_horizon_distance);

        const active_count = if (!strict_safe_mode and manual_distance_expanded)
            LODConfig.activeCountForRenderDistance(effective_render_distance)
        else
            preset_cfg.active_lod_count;
        if (active_count < LODLevel.count) {
            var i: usize = active_count;
            while (i < LODLevel.count) : (i += 1) {
                preset_radii[i] = preset_radii[active_count - 1];
            }
        }

        const lod_config = if (strict_safe_mode)
            LODConfig{
                .chunk_render_radius = chunk_render_radius,
                .radii = preset_radii,
            }
        else
            LODConfig{
                .chunk_render_radius = chunk_render_radius,
                .radii = preset_radii,
                .fog_start_percent = preset_cfg.fog_start_percent,
                .horizontal_detail = preset_cfg.horizontal_detail,
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

        var world_map = try WorldMap.init(rhi.resourceManager(), 256, 256);
        errdefer world_map.deinit();

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
            atmosphere.time.time_scale = 0.0;
            player.position = if (std.ascii.eqlIgnoreCase(build_config.shadow_test_variant, "bend"))
                Vec3.init(5.5, 65.0, -14.0)
            else
                Vec3.init(0.0, 65.0, -16.0);
            player.camera.position = player.getEyePosition();
            player.camera.setYawPitch(std.math.pi / 2.0, if (std.ascii.eqlIgnoreCase(build_config.shadow_test_variant, "bend")) -std.math.degreesToRadians(8.0) else -std.math.degreesToRadians(5.0));
        }

        session.* = .{
            .allocator = allocator,
            .world = world,
            .world_map = world_map,
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
        self.world.deinit();
        self.world_map.deinit();
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

                if (!self.inventory_ui_state.visible) {
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

                self.map_controller.update(input, mapper, &self.camera, dt, window, screen_w, screen_h, self.world_map.width);

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
                const world_sim = self.world.interface().simulation();
                try world_sim.update(self.player.camera.position, dt);

                // ECS Updates
                ECSPhysicsSystem.update(&self.ecs_registry, world_sim.collisionWorld(), dt);
            }
        }
    }

    pub fn renderEntities(self: *GameSession, ctx: RenderContext, camera_pos: Vec3) void {
        self.ecs_render_system.render(ctx, &self.ecs_registry, camera_pos);
    }

    pub fn drawHUD(self: *GameSession, ui: *UISystem, atlas: *const TextureAtlas, active_pack: ?[]const u8, fps: f32, screen_w: f32, screen_h: f32, mouse_x: f32, mouse_y: f32, mouse_clicked: bool) !void {
        try session_hud.draw(self, ui, atlas, active_pack, fps, screen_w, screen_h, mouse_x, mouse_y, mouse_clicked);
    }
};

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
