const std = @import("std");
const c = @import("c").c;
const Input = @import("engine-input").Input;
const IRawInputProvider = @import("engine-input").IRawInputProvider;
const WorldMap = @import("world-worldgen").WorldMap;
const Camera = @import("engine-camera").Camera;
const Generator = @import("world-worldgen").Generator;
const UISystem = @import("engine-ui").UISystem;
const Color = @import("engine-ui").Color;
const Font = @import("engine-ui").font;
const log = @import("engine-core").log;
const Vec3 = @import("engine-math").Vec3;

const input_mapper_pkg = @import("input_mapper.zig");
const InputMapper = input_mapper_pkg.InputMapper;
const IInputMapper = input_mapper_pkg.IInputMapper;
const GameAction = input_mapper_pkg.GameAction;

pub const MapController = struct {
    const MIN_ZOOM: f32 = 0.05;
    const MAX_ZOOM: f32 = 128.0;
    const MAP_SCREEN_FRACTION: f32 = 0.82;
    const MAP_PADDING: f32 = 28.0;

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

    pub fn update(self: *MapController, input: IRawInputProvider, mapper: IInputMapper, camera: *const Camera, time_delta: f32, window: *c.SDL_Window, screen_w: f32, screen_h: f32, world_map_width: u32) void {
        if (mapper.isActionPressed(input, .toggle_map)) {
            self.toggle(camera.position, input, window);
        }

        if (!self.show_map) return;

        const dt = @min(time_delta, 0.05);
        const rect = getMapRect(screen_w, screen_h);

        self.handleZoom(input, mapper, dt);

        if (mapper.isActionPressed(input, .map_center)) {
            self.recenter(camera.position);
        }

        self.handlePan(input, mapper, dt, rect.size, world_map_width);
        self.smoothView(dt);
    }

    pub fn draw(self: *MapController, u: *UISystem, screen_w: f32, screen_h: f32, world_map: *WorldMap, generator: Generator, camera_pos: Vec3, allocator: std.mem.Allocator) !void {
        if (!self.show_map) return;

        if (self.map_needs_update) {
            try world_map.update(generator, self.map_pos_x, self.map_pos_z, self.map_zoom, allocator);
            self.map_needs_update = false;
        }

        const rect = getMapRect(screen_w, screen_h);
        self.drawBackdrop(u, screen_w, screen_h);
        self.drawFrame(u, rect);
        u.drawTexture(@intCast(world_map.texture.handle), .{ .x = rect.x, .y = rect.y, .width = rect.size, .height = rect.size });
        self.drawGrid(u, rect);
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

    fn handleZoom(self: *MapController, input: IRawInputProvider, mapper: IInputMapper, dt: f32) void {
        const before = self.map_target_zoom;
        if (mapper.isActionActive(input, .map_zoom_in)) self.map_target_zoom /= @exp(3.0 * dt);
        if (mapper.isActionActive(input, .map_zoom_out)) self.map_target_zoom *= @exp(3.0 * dt);

        const scroll_y = input.getScrollDelta().y;
        if (scroll_y != 0) self.map_target_zoom /= @exp(scroll_y * 0.45);

        self.map_target_zoom = std.math.clamp(self.map_target_zoom, MIN_ZOOM, MAX_ZOOM);
        if (self.map_target_zoom != before) self.map_needs_update = true;
    }

    fn handlePan(self: *MapController, input: IRawInputProvider, mapper: IInputMapper, dt: f32, map_ui_size: f32, world_map_width: u32) void {
        const mouse_pos = input.getMousePosition();
        const mouse_x: f32 = @floatFromInt(mouse_pos.x);
        const mouse_y: f32 = @floatFromInt(mouse_pos.y);
        const safe_dt = @max(dt, 0.001);
        const pixel_world_scale = screenPixelToWorldScale(self.map_zoom, map_ui_size, world_map_width);

        if (input.isMouseButtonPressed(.left)) {
            self.last_mouse_x = mouse_x;
            self.last_mouse_y = mouse_y;
            self.is_dragging = true;
            self.vel_x = 0;
            self.vel_z = 0;
        }

        if (input.isMouseButtonDown(.left)) {
            const drag_dx = mouse_x - self.last_mouse_x;
            const drag_dz = mouse_y - self.last_mouse_y;
            if (@abs(drag_dx) > 0.5 or @abs(drag_dz) > 0.5) {
                const pan_dx = drag_dx * pixel_world_scale;
                const pan_dz = drag_dz * pixel_world_scale;
                self.map_target_pos_x -= pan_dx;
                self.map_target_pos_z -= pan_dz;
                self.vel_x = -pan_dx / safe_dt;
                self.vel_z = -pan_dz / safe_dt;
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
        const pan_kb_speed = 1600.0 * self.map_zoom;
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

    fn drawGrid(_: *MapController, u: *UISystem, rect: MapRect) void {
        const grid_color = Color.rgba(1.0, 1.0, 1.0, 0.12);
        var i: u32 = 1;
        while (i < 4) : (i += 1) {
            const offset = rect.size * @as(f32, @floatFromInt(i)) * 0.25;
            u.drawRect(.{ .x = rect.x + offset, .y = rect.y, .width = 1, .height = rect.size }, grid_color);
            u.drawRect(.{ .x = rect.x, .y = rect.y + offset, .width = rect.size, .height = 1 }, grid_color);
        }
    }

    fn drawPlayerMarker(self: *MapController, u: *UISystem, rect: MapRect, map_width: u32, map_height: u32, camera_pos: Vec3) void {
        const marker = self.playerMarker(rect, map_width, map_height, camera_pos);
        if (!marker.visible) return;

        u.drawRect(.{ .x = marker.x - 8, .y = marker.y - 2, .width = 16, .height = 4 }, Color.red);
        u.drawRect(.{ .x = marker.x - 2, .y = marker.y - 8, .width = 4, .height = 16 }, Color.red);
        u.drawRectOutline(.{ .x = marker.x - 10, .y = marker.y - 10, .width = 20, .height = 20 }, Color.rgba(1.0, 0.15, 0.1, 1.0), 1.0);
    }

    fn drawHeader(self: *MapController, u: *UISystem, rect: MapRect) void {
        Font.drawText(u, "WORLD MAP", rect.x, rect.y - 58.0, 3.0, Color.white);
        Font.drawText(u, "Drag to pan  |  Scroll/+/- to zoom  |  Space to center  |  M to close", rect.x + 4.0, rect.y + rect.size + 16.0, 1.5, Color.rgba(0.78, 0.84, 0.9, 1.0));

        var buf: [48]u8 = undefined;
        const zoom_text = std.fmt.bufPrint(&buf, "scale: {d:.2} blocks/px", .{self.map_zoom}) catch "scale: ?";
        Font.drawText(u, zoom_text, rect.x + rect.size - 210.0, rect.y - 38.0, 1.5, Color.rgba(0.78, 0.84, 0.9, 1.0));
    }

    fn drawFooter(self: *MapController, u: *UISystem, rect: MapRect, camera_pos: Vec3) void {
        var buf: [96]u8 = undefined;
        const pos_text = std.fmt.bufPrint(&buf, "center: {d:.0}, {d:.0}    player: {d:.0}, {d:.0}", .{ self.map_pos_x, self.map_pos_z, camera_pos.x, camera_pos.z }) catch "center/player: ?";
        Font.drawText(u, pos_text, rect.x + 4.0, rect.y - 28.0, 1.5, Color.rgba(0.78, 0.84, 0.9, 1.0));
    }

    pub fn getMapRect(screen_w: f32, screen_h: f32) MapRect {
        const available_w = @max(screen_w - MAP_PADDING * 2.0, 64.0);
        const available_h = @max(screen_h - 150.0, 64.0);
        const size = @min(@min(available_w, available_h), @min(screen_w, screen_h) * MAP_SCREEN_FRACTION);
        return .{
            .x = (screen_w - size) * 0.5,
            .y = (screen_h - size) * 0.5 + 10.0,
            .size = size,
        };
    }

    pub fn screenPixelToWorldScale(zoom: f32, map_ui_size: f32, world_map_width: u32) f32 {
        return zoom * @as(f32, @floatFromInt(world_map_width)) / map_ui_size;
    }

    pub fn playerMarker(self: *const MapController, rect: MapRect, map_width: u32, map_height: u32, camera_pos: Vec3) MarkerPosition {
        const rx = (camera_pos.x - self.map_pos_x) / (self.map_zoom * @as(f32, @floatFromInt(map_width)));
        const rz = (camera_pos.z - self.map_pos_z) / (self.map_zoom * @as(f32, @floatFromInt(map_height)));
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
    try std.testing.expectApproxEqAbs(@as(f32, 2.0), MapController.screenPixelToWorldScale(4.0, 512.0, 256), 0.001);
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
