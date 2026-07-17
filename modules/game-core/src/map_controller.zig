const std = @import("std");
const c = @import("c").c;
const Input = @import("engine-input").Input;
const IRawInputProvider = @import("engine-input").IRawInputProvider;
const WorldMap = @import("world-worldgen").WorldMap;
const Camera = @import("engine-camera").Camera;
const Generator = @import("world-worldgen").Generator;
const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Texture = @import("engine-rhi").Texture;
const Font = @import("engine-ui").font;
const log = @import("engine-core").log;
const Vec3 = @import("engine-math").Vec3;
const World = @import("world-runtime").World;

const input_mapper_pkg = @import("input_mapper.zig");
const InputMapper = input_mapper_pkg.InputMapper;
const IInputMapper = input_mapper_pkg.IInputMapper;
const GameAction = input_mapper_pkg.GameAction;

pub const MapController = struct {
    const MIN_ZOOM: f32 = 0.05;
    const MAX_ZOOM: f32 = 128.0;
    const MAP_REFERENCE_SIZE: f32 = 256.0;
    const MAP_SCREEN_FRACTION: f32 = 0.96;
    const MAP_PADDING: f32 = 16.0;
    const KEYBOARD_PAN_SPEED: f32 = 320.0;
    const DRAG_SENSITIVITY: f32 = 1.0;
    const KEY_ZOOM_RATE: f32 = 2.0;
    const WHEEL_ZOOM_RATE: f32 = 0.28;

    pub const MapRect = struct {
        x: f32,
        y: f32,
        size: f32,
    };

    pub const MarkerPosition = struct {
        x: f32,
        y: f32,
        visible: bool,
    };

    show_map: bool = false,
    map_needs_update: bool = true,
    map_zoom: f32 = 4.0,
    map_target_zoom: f32 = 4.0,
    map_pos_x: f32 = 0.0,
    map_pos_z: f32 = 0.0,
    map_target_pos_x: f32 = 0.0,
    map_target_pos_z: f32 = 0.0,
    last_mouse_x: f32 = 0.0,
    last_mouse_y: f32 = 0.0,
    vel_x: f32 = 0.0,
    vel_z: f32 = 0.0,
    is_dragging: bool = false,
    texture_center_x: f32 = 0.0,
    texture_center_z: f32 = 0.0,
    texture_scale: f32 = 1.0,
    has_texture_view: bool = false,
    last_surface_revision: u64 = 0,
    observed_residency_revision: u64 = 0,
    captured_residency_revision: u64 = 0,
    residency_stable_frames: u8 = 0,

    pub fn update(self: *MapController, input: IRawInputProvider, mapper: IInputMapper, camera: *const Camera, time_delta: f32, window: *c.SDL_Window, screen_w: f32, screen_h: f32) void {
        if (mapper.isActionPressed(input, .toggle_map)) {
            self.toggle(camera.position, input, window);
        }

        if (!self.show_map) return;

        const dt = @min(time_delta, 0.05);
        const rect = getMapRect(screen_w, screen_h);

        self.handleZoom(input, mapper, dt, rect);

        if (mapper.isActionPressed(input, .map_center)) {
            self.recenter(camera.position);
        }

        self.handlePan(input, mapper, dt, rect.size);
        self.smoothView(dt);
    }

    pub fn draw(self: *MapController, u: *UISystem, screen_w: f32, screen_h: f32, world_map: *WorldMap, world_map_texture: *const Texture, world: *World, generator: Generator, camera_pos: Vec3) !void {
        if (!self.show_map) return;

        const surface_revision = world.getMapSurfaceRevision();
        if (surface_revision != self.last_surface_revision) self.map_needs_update = true;
        const residency_revision = world.getMapResidencyRevision();
        if (residency_revision != self.observed_residency_revision) {
            self.observed_residency_revision = residency_revision;
            self.residency_stable_frames = 0;
        } else if (self.residency_stable_frames < 15) {
            self.residency_stable_frames += 1;
        }
        // Debounce streaming churn so refinement is not cancelled for every
        // arriving chunk, then refresh once the loaded set has settled.
        if (self.residency_stable_frames >= 15 and self.captured_residency_revision != residency_revision) {
            self.map_needs_update = true;
        }

        if (self.map_needs_update) {
            const sample_scale = textureSamplingScale(self.map_zoom, world_map.width);
            const overlay = try world_map.createLoadedSurfaceOverlay();
            world.captureLoadedMapSurface(overlay, self.map_pos_x, self.map_pos_z, sample_scale, world_map.width, world_map.height) catch |err| {
                overlay.deinit();
                return err;
            };
            try world_map.requestUpdate(generator, self.map_pos_x, self.map_pos_z, sample_scale, overlay);
            self.map_needs_update = false;
            self.last_surface_revision = surface_revision;
            self.captured_residency_revision = residency_revision;
        }
        if (world_map.consumeCompleted()) |view| {
            try world_map_texture.update(world_map.pixels);
            self.texture_center_x = view.center_x;
            self.texture_center_z = view.center_z;
            self.texture_scale = view.scale;
            self.has_texture_view = true;
        }

        const rect = getMapRect(screen_w, screen_h);
        self.drawBackdrop(u, screen_w, screen_h);
        self.drawFrame(u, rect);
        self.drawMapTexture(u, rect, world_map_texture, world_map.width);
        self.drawGrid(u, rect);
        self.drawScaleBar(u, rect);
        self.drawPlayerMarker(u, rect, world_map.width, world_map.height, camera_pos);
        self.drawHeader(u, rect);
        self.drawFooter(u, rect, camera_pos);
    }

    fn toggle(self: *MapController, camera_pos: Vec3, input: IRawInputProvider, window: *c.SDL_Window) void {
        self.show_map = !self.show_map;
        log.log.info("Toggle map: show={}", .{self.show_map});

        const any_window: ?*anyopaque = @ptrCast(@alignCast(window));
        input.setMouseCapture(any_window, !self.show_map);

        if (self.show_map) {
            self.openAt(camera_pos);
        } else {
            self.is_dragging = false;
        }
    }

    fn openAt(self: *MapController, camera_pos: Vec3) void {
        self.map_target_pos_x = camera_pos.x;
        self.map_target_pos_z = camera_pos.z;
        self.map_pos_x = self.map_target_pos_x;
        self.map_pos_z = self.map_target_pos_z;
        self.map_target_zoom = self.map_zoom;
        self.map_needs_update = true;
        self.vel_x = 0;
        self.vel_z = 0;
        self.is_dragging = false;
    }

    fn recenter(self: *MapController, camera_pos: Vec3) void {
        self.map_target_pos_x = camera_pos.x;
        self.map_target_pos_z = camera_pos.z;
        self.vel_x = 0;
        self.vel_z = 0;
        self.map_needs_update = true;
    }

    fn handleZoom(self: *MapController, input: IRawInputProvider, mapper: IInputMapper, dt: f32, rect: MapRect) void {
        const before = self.map_target_zoom;
        if (mapper.isActionActive(input, .map_zoom_in)) self.map_target_zoom /= @exp(KEY_ZOOM_RATE * dt);
        if (mapper.isActionActive(input, .map_zoom_out)) self.map_target_zoom *= @exp(KEY_ZOOM_RATE * dt);

        const scroll_y = input.getScrollDelta().y;
        if (scroll_y != 0) self.map_target_zoom /= @exp(scroll_y * WHEEL_ZOOM_RATE);

        self.map_target_zoom = std.math.clamp(self.map_target_zoom, MIN_ZOOM, MAX_ZOOM);
        if (scroll_y != 0 and self.map_target_zoom != before) {
            const mouse = input.getMousePosition();
            const cursor_x = @as(f32, @floatFromInt(mouse.x)) - (rect.x + rect.size * 0.5);
            const cursor_z = @as(f32, @floatFromInt(mouse.y)) - (rect.y + rect.size * 0.5);
            const old_world_per_pixel = screenPixelToWorldScale(self.map_zoom, rect.size);
            const new_world_per_pixel = screenPixelToWorldScale(self.map_target_zoom, rect.size);
            self.map_pos_x += cursor_x * (old_world_per_pixel - new_world_per_pixel);
            self.map_pos_z += cursor_z * (old_world_per_pixel - new_world_per_pixel);
            self.map_target_pos_x = self.map_pos_x;
            self.map_target_pos_z = self.map_pos_z;
            self.map_zoom = self.map_target_zoom;
            self.vel_x = 0;
            self.vel_z = 0;
        }
        if (self.map_target_zoom != before) self.map_needs_update = true;
    }

    fn handlePan(self: *MapController, input: IRawInputProvider, mapper: IInputMapper, dt: f32, map_ui_size: f32) void {
        const mouse_pos = input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const pixel_world_scale = screenPixelToWorldScale(self.map_zoom, map_ui_size);

        if (input.isMouseButtonPressed(.left)) {
            self.last_mouse_x = mouse_x;
            self.last_mouse_y = mouse_y;
            self.map_pos_x = self.map_target_pos_x;
            self.map_pos_z = self.map_target_pos_z;
            self.is_dragging = true;
            self.vel_x = 0;
            self.vel_z = 0;
        }

        if (input.isMouseButtonDown(.left)) {
            const drag_dx = mouse_x - self.last_mouse_x;
            const drag_dz = mouse_y - self.last_mouse_y;
            if (@abs(drag_dx) > 0.5 or @abs(drag_dz) > 0.5) {
                const pan_dx = drag_dx * pixel_world_scale * DRAG_SENSITIVITY;
                const pan_dz = drag_dz * pixel_world_scale * DRAG_SENSITIVITY;
                self.map_target_pos_x -= pan_dx;
                self.map_target_pos_z -= pan_dz;
                self.map_pos_x -= pan_dx;
                self.map_pos_z -= pan_dz;
                self.vel_x = 0;
                self.vel_z = 0;
                self.map_needs_update = true;
            }
            self.last_mouse_x = mouse_x;
            self.last_mouse_y = mouse_y;
            return;
        }

        self.is_dragging = false;
        self.applyInertia(dt);
        self.applyKeyboardPan(mapper, input, dt);
    }

    fn applyInertia(self: *MapController, dt: f32) void {
        if (self.vel_x == 0 and self.vel_z == 0) return;

        const friction = @exp(-12.0 * dt);
        self.vel_x *= friction;
        self.vel_z *= friction;
        if (@abs(self.vel_x) < 1.0 and @abs(self.vel_z) < 1.0) {
            self.vel_x = 0;
            self.vel_z = 0;
            return;
        }

        self.map_target_pos_x += self.vel_x * dt;
        self.map_target_pos_z += self.vel_z * dt;
        self.map_needs_update = true;
    }

    fn applyKeyboardPan(self: *MapController, mapper: IInputMapper, input: IRawInputProvider, dt: f32) void {
        const pan_kb_speed = KEYBOARD_PAN_SPEED * self.map_zoom;
        const move_vec = mapper.getMovementVector(input);
        if (move_vec.x == 0 and move_vec.z == 0) return;

        self.map_target_pos_x += move_vec.x * pan_kb_speed * dt;
        self.map_target_pos_z -= move_vec.z * pan_kb_speed * dt;
        self.map_needs_update = true;
    }

    fn smoothView(self: *MapController, dt: f32) void {
        const old_zoom = self.map_zoom;
        const zoom_t = 1.0 - @exp(-30.0 * dt);
        self.map_zoom = std.math.lerp(self.map_zoom, self.map_target_zoom, zoom_t);
        if (@abs(self.map_zoom - old_zoom) > 0.001 * self.map_zoom) self.map_needs_update = true;

        const pos_t = 1.0 - @exp(-35.0 * dt);
        self.map_pos_x = std.math.lerp(self.map_pos_x, self.map_target_pos_x, pos_t);
        self.map_pos_z = std.math.lerp(self.map_pos_z, self.map_target_pos_z, pos_t);
        if (@abs(self.map_pos_x - self.map_target_pos_x) > 0.5 or @abs(self.map_pos_z - self.map_target_pos_z) > 0.5) {
            self.map_needs_update = true;
        }
    }

    fn drawBackdrop(_: *MapController, u: *UISystem, screen_w: f32, screen_h: f32) void {
        u.drawRect(.{ .x = 0, .y = 0, .width = screen_w, .height = screen_h }, Color.rgba(0.02, 0.025, 0.035, 0.88));
    }

    fn drawFrame(_: *MapController, u: *UISystem, rect: MapRect) void {
        u.drawRect(.{ .x = rect.x - MAP_PADDING, .y = rect.y - MAP_PADDING, .width = rect.size + MAP_PADDING * 2.0, .height = rect.size + MAP_PADDING * 2.0 }, Color.rgba(0.04, 0.05, 0.06, 0.92));
        u.drawRectOutline(.{ .x = rect.x - MAP_PADDING, .y = rect.y - MAP_PADDING, .width = rect.size + MAP_PADDING * 2.0, .height = rect.size + MAP_PADDING * 2.0 }, Color.rgba(0.35, 0.45, 0.55, 1.0), 2.0);
        u.drawRectOutline(.{ .x = rect.x, .y = rect.y, .width = rect.size, .height = rect.size }, Color.white, 2.0);
    }

    fn drawGrid(self: *MapController, u: *UISystem, rect: MapRect) void {
        const world_per_pixel = screenPixelToWorldScale(self.map_zoom, rect.size);
        const spacing = gridSpacing(world_per_pixel, 112.0);
        const half_span = rect.size * world_per_pixel * 0.5;
        const min_x = self.map_pos_x - half_span;
        const max_x = self.map_pos_x + half_span;
        const min_z = self.map_pos_z - half_span;
        const max_z = self.map_pos_z + half_span;
        const grid_color = Color.rgba(0.92, 0.96, 1.0, 0.14);
        const label_color = Color.rgba(0.90, 0.95, 1.0, 0.72);

        var world_x = @floor(min_x / spacing) * spacing;
        while (world_x <= max_x) : (world_x += spacing) {
            const screen_x = rect.x + (world_x - min_x) / world_per_pixel;
            u.drawRect(.{ .x = screen_x, .y = rect.y, .width = 1, .height = rect.size }, grid_color);
            if (screen_x < rect.x + rect.size - 68) {
                var label_buf: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "X {d:.0}", .{world_x}) catch "X ?";
                Font.drawText(u, label, screen_x + 4, rect.y + 5, 1.15, label_color);
            }
        }

        var world_z = @floor(min_z / spacing) * spacing;
        while (world_z <= max_z) : (world_z += spacing) {
            const screen_y = rect.y + (world_z - min_z) / world_per_pixel;
            u.drawRect(.{ .x = rect.x, .y = screen_y, .width = rect.size, .height = 1 }, grid_color);
            if (screen_y < rect.y + rect.size - 16) {
                var label_buf: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buf, "Z {d:.0}", .{world_z}) catch "Z ?";
                Font.drawText(u, label, rect.x + 5, screen_y + 4, 1.15, label_color);
            }
        }
    }

    fn drawScaleBar(self: *MapController, u: *UISystem, rect: MapRect) void {
        const world_per_pixel = screenPixelToWorldScale(self.map_zoom, rect.size);
        const world_length = gridSpacing(world_per_pixel, 120.0);
        const pixel_length = world_length / world_per_pixel;
        const x = rect.x + 20;
        const y = rect.y + rect.size - 28;
        u.drawRect(.{ .x = x - 8, .y = y - 13, .width = pixel_length + 16, .height = 31 }, Color.rgba(0.015, 0.02, 0.025, 0.72));
        u.drawRect(.{ .x = x, .y = y, .width = pixel_length, .height = 3 }, Color.white);
        u.drawRect(.{ .x = x, .y = y - 4, .width = 2, .height = 11 }, Color.white);
        u.drawRect(.{ .x = x + pixel_length - 2, .y = y - 4, .width = 2, .height = 11 }, Color.white);

        var label_buf: [32]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "{d:.0} blocks", .{world_length}) catch "? blocks";
        Font.drawText(u, label, x + 4, y - 13, 1.15, Color.white);
    }

    fn gridSpacing(world_per_pixel: f32, target_pixels: f32) f32 {
        const target_world = @max(world_per_pixel * target_pixels, 1.0);
        var spacing: f32 = 1.0;
        while (spacing < target_world) spacing *= 2.0;
        return spacing;
    }

    fn drawMapTexture(self: *MapController, u: *UISystem, rect: MapRect, texture: *const Texture, texture_width: u32) void {
        // Unknown coverage uses a map-like ocean tint rather than flashing to
        // black while the tiny progressive preview is being generated.
        u.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.size, .height = rect.size }, Color.rgba(0.025, 0.10, 0.14, 1.0));
        if (!self.has_texture_view) return;

        const current_scale = textureSamplingScale(self.map_zoom, texture_width);
        const texture_width_f: f32 = @floatFromInt(texture_width);
        const world_per_screen_pixel = current_scale * texture_width_f / rect.size;
        const draw_size = rect.size * self.texture_scale / current_scale;
        const transformed_x = rect.x + rect.size * 0.5 + (self.texture_center_x - self.map_pos_x) / world_per_screen_pixel - draw_size * 0.5;
        const transformed_y = rect.y + rect.size * 0.5 + (self.texture_center_z - self.map_pos_z) / world_per_screen_pixel - draw_size * 0.5;

        const visible_x0 = @max(rect.x, transformed_x);
        const visible_y0 = @max(rect.y, transformed_y);
        const visible_x1 = @min(rect.x + rect.size, transformed_x + draw_size);
        const visible_y1 = @min(rect.y + rect.size, transformed_y + draw_size);
        if (visible_x1 <= visible_x0 or visible_y1 <= visible_y0) return;

        u.drawTextureRegion(
            @intCast(texture.handle),
            .{ .x = visible_x0, .y = visible_y0, .width = visible_x1 - visible_x0, .height = visible_y1 - visible_y0 },
            .{
                .u0 = (visible_x0 - transformed_x) / draw_size,
                .v0 = (visible_y0 - transformed_y) / draw_size,
                .u1 = (visible_x1 - transformed_x) / draw_size,
                .v1 = (visible_y1 - transformed_y) / draw_size,
            },
            Color.white,
        );
    }

    fn drawPlayerMarker(self: *MapController, u: *UISystem, rect: MapRect, map_width: u32, map_height: u32, camera_pos: Vec3) void {
        const marker = self.playerMarker(rect, map_width, map_height, camera_pos);
        if (!marker.visible) return;

        u.drawRect(.{ .x = marker.x - 8, .y = marker.y - 2, .width = 16, .height = 4 }, Color.red);
        u.drawRect(.{ .x = marker.x - 2, .y = marker.y - 8, .width = 4, .height = 16 }, Color.red);
        u.drawRectOutline(.{ .x = marker.x - 10, .y = marker.y - 10, .width = 20, .height = 20 }, Color.rgba(1.0, 0.15, 0.1, 1.0), 1.0);
    }

    fn drawHeader(self: *MapController, u: *UISystem, rect: MapRect) void {
        Font.drawText(u, "WORLD MAP", rect.x, rect.y - 48.0, 3.0, Color.white);
        Font.drawText(u, "Drag to pan  |  Scroll/+/- to zoom  |  Space to center  |  M to close", rect.x + 4.0, rect.y + rect.size + 16.0, 1.5, Color.rgba(0.78, 0.84, 0.9, 1.0));

        var buf: [48]u8 = undefined;
        const screen_scale = self.map_zoom * MAP_REFERENCE_SIZE / rect.size;
        const zoom_text = std.fmt.bufPrint(&buf, "scale: {d:.2} blocks/screen px", .{screen_scale}) catch "scale: ?";
        Font.drawText(u, zoom_text, rect.x + rect.size - 210.0, rect.y - 38.0, 1.5, Color.rgba(0.78, 0.84, 0.9, 1.0));
    }

    fn drawFooter(self: *MapController, u: *UISystem, rect: MapRect, camera_pos: Vec3) void {
        var buf: [96]u8 = undefined;
        const pos_text = std.fmt.bufPrint(&buf, "center: {d:.0}, {d:.0}    player: {d:.0}, {d:.0}", .{ self.map_pos_x, self.map_pos_z, camera_pos.x, camera_pos.z }) catch "center/player: ?";
        Font.drawText(u, pos_text, rect.x + 4.0, rect.y - 28.0, 1.5, Color.rgba(0.78, 0.84, 0.9, 1.0));
    }

    pub fn getMapRect(screen_w: f32, screen_h: f32) MapRect {
        const available_w = @max(screen_w - MAP_PADDING * 2.0, 64.0);
        // Keep enough room for the title and controls while using nearly the
        // full display height. Width remains square so map scale is uniform.
        const available_h = @max(screen_h - 100.0, 64.0);
        const size = @min(@min(available_w, available_h), @min(screen_w, screen_h) * MAP_SCREEN_FRACTION);
        return .{
            .x = (screen_w - size) * 0.5,
            .y = (screen_h - size) * 0.5 + 4.0,
            .size = size,
        };
    }

    pub fn screenPixelToWorldScale(zoom: f32, map_ui_size: f32) f32 {
        return zoom * MAP_REFERENCE_SIZE / map_ui_size;
    }

    pub fn textureSamplingScale(zoom: f32, texture_width: u32) f32 {
        return zoom * MAP_REFERENCE_SIZE / @as(f32, @floatFromInt(texture_width));
    }

    pub fn playerMarker(self: *const MapController, rect: MapRect, map_width: u32, map_height: u32, camera_pos: Vec3) MarkerPosition {
        const sample_scale = textureSamplingScale(self.map_zoom, map_width);
        const rx = (camera_pos.x - self.map_pos_x) / (sample_scale * @as(f32, @floatFromInt(map_width)));
        const rz = (camera_pos.z - self.map_pos_z) / (sample_scale * @as(f32, @floatFromInt(map_height)));
        const px = rect.x + (rx + 0.5) * rect.size;
        const py = rect.y + (rz + 0.5) * rect.size;

        return .{
            .x = px,
            .y = py,
            .visible = px >= rect.x and px <= rect.x + rect.size and py >= rect.y and py <= rect.y + rect.size,
        };
    }
};

test "MapController getMapRect fits display" {
    const rect = MapController.getMapRect(1280, 720);
    try std.testing.expect(rect.size > 0);
    try std.testing.expect(rect.x >= 0);
    try std.testing.expect(rect.y >= 0);
    try std.testing.expect(rect.x + rect.size <= 1280);
    try std.testing.expect(rect.y + rect.size <= 720);
}

test "MapController screenPixelToWorldScale includes zoom and texture ratio" {
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), MapController.screenPixelToWorldScale(4.0, 512.0), 0.001);
}

test "MapController textureSamplingScale preserves map span at higher resolution" {
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), MapController.textureSamplingScale(4.0, 512), 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), MapController.textureSamplingScale(4.0, 1024), 0.001);
}

test "MapController grid spacing stays legible across zoom levels" {
    try std.testing.expectEqual(@as(f32, 128), MapController.gridSpacing(1.0, 112.0));
    try std.testing.expectEqual(@as(f32, 512), MapController.gridSpacing(4.0, 112.0));
}

test "MapController playerMarker centers player at map center" {
    var controller = MapController{};
    controller.map_pos_x = 100;
    controller.map_pos_z = -50;
    controller.map_zoom = 4;

    const rect = MapController.MapRect{ .x = 10, .y = 20, .size = 200 };
    const marker = controller.playerMarker(rect, 256, 256, Vec3.init(100, 70, -50));
    try std.testing.expect(marker.visible);
    try std.testing.expectApproxEqAbs(@as(f32, 110), marker.x, 0.001);
    try std.testing.expectApproxEqAbs(@as(f32, 120), marker.y, 0.001);
}
