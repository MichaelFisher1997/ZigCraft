//! Opt-in RmlUi adapter backed by ZigCraft's existing UI pass and RHI.
//!
//! The bridge owns RmlUi's process-global runtime; this module owns the
//! heap-stable callback target and retained CPU geometry used by that runtime.

const std = @import("std");
const build_options = @import("engine_ui_options");
const rhi = @import("engine-rhi").rhi;
const sdl = @import("c").c;

pub const available = build_options.rmlui;

const c = if (available) @cImport({
    @cInclude("zigcraft/zigcraft_rmlui.h");
}) else struct {};

const NativeRuntime = if (available) c.ZigCraftRmlUi else opaque {};
const NativeContext = if (available) c.ZigCraftRmlUiContext else opaque {};
const NativeDocument = if (available) c.ZigCraftRmlUiDocument else opaque {};
const NativeAction = if (available) c.ZigCraftRmlUiAction else opaque {};

pub const Document = struct {
    native: *NativeDocument,
};

pub const Action = struct {
    native: *NativeAction,
    data: *ActionData,
};

pub const ActionCallback = *const fn (context: *anyopaque, event_type: []const u8, target_id: []const u8) void;

const Geometry = struct {
    vertices: []rhi.UiVertex,
    indices: []u32,
};

/// Retained RmlUi geometry and generated texture ownership for one context.
/// Allocate this object once and retain its pointer for the life of the UI
/// manager: C callbacks use the pointer as their user data.
pub const RmlUi = struct {
    allocator: std.mem.Allocator,
    renderer: rhi.UIRenderer,
    resources: rhi.ResourceManager,
    runtime: *NativeRuntime,
    context: *NativeContext,
    geometries: std.AutoHashMapUnmanaged(usize, Geometry) = .empty,
    generated_textures: std.AutoHashMapUnmanaged(rhi.TextureHandle, void) = .empty,
    next_geometry: usize = 1,
    screen_width: u32,
    screen_height: u32,
    scissor_enabled: bool = false,
    frame_geometry_draws: usize = 0,

    pub fn init(allocator: std.mem.Allocator, renderer: rhi.UIRenderer, resources: rhi.ResourceManager, window: *sdl.SDL_Window, width: u32, height: u32) !*RmlUi {
        if (!available) return error.RmlUiDisabled;

        const self = try allocator.create(RmlUi);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .renderer = renderer,
            .resources = resources,
            .runtime = undefined,
            .context = undefined,
            .screen_width = width,
            .screen_height = height,
        };

        const callbacks = c.ZigCraftRmlUiRenderCallbacks{
            .user_data = self,
            .compile_geometry = compileGeometry,
            .render_geometry = renderGeometry,
            .release_geometry = releaseGeometry,
            .load_texture = loadTexture,
            .generate_texture = generateTexture,
            .release_texture = releaseTexture,
            .enable_scissor = enableScissor,
            .set_scissor = setScissor,
        };
        self.runtime = c.zigcraft_rmlui_init(&callbacks) orelse return error.RmlUiInitFailed;
        errdefer c.zigcraft_rmlui_destroy(self.runtime);
        c.zigcraft_rmlui_set_sdl_window(self.runtime, @as(?*c.SDL_Window, @ptrCast(window)));
        self.context = c.zigcraft_rmlui_context_create(self.runtime, "zigcraft", @intCast(width), @intCast(height)) orelse return error.RmlUiContextInitFailed;
        errdefer c.zigcraft_rmlui_context_destroy(self.runtime, self.context);

        if (!c.zigcraft_rmlui_load_font_face("assets/fonts/Inter-Regular.ttf", true)) return error.RmlUiFontLoadFailed;
        return self;
    }

    pub fn deinit(self: *RmlUi) void {
        if (available) {
            c.zigcraft_rmlui_context_destroy(self.runtime, self.context);
            c.zigcraft_rmlui_destroy(self.runtime);
        }

        var geometry_iterator = self.geometries.valueIterator();
        while (geometry_iterator.next()) |geometry| self.releaseOwnedGeometry(geometry.*);
        self.geometries.deinit(self.allocator);

        var texture_iterator = self.generated_textures.keyIterator();
        while (texture_iterator.next()) |texture| self.resources.destroyTexture(texture.*);
        self.generated_textures.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn resize(self: *RmlUi, width: u32, height: u32) void {
        self.screen_width = width;
        self.screen_height = height;
        if (available) c.zigcraft_rmlui_context_resize(self.context, @intCast(width), @intCast(height));
    }

    pub fn processEvent(self: *RmlUi, window: *sdl.SDL_Window, event: *const sdl.SDL_Event) bool {
        if (!available) return false;
        const not_consumed = c.zigcraft_rmlui_process_sdl_event(self.runtime, self.context, @as(?*c.SDL_Window, @ptrCast(window)), @ptrCast(event));
        return !not_consumed;
    }

    pub fn loadDocument(self: *RmlUi, path: [*:0]const u8) !Document {
        if (!available) return error.RmlUiDisabled;
        return .{ .native = c.zigcraft_rmlui_context_load_document(self.context, path) orelse return error.RmlUiDocumentLoadFailed };
    }

    pub fn showDocument(self: *RmlUi, document: Document) void {
        _ = self;
        if (available) c.zigcraft_rmlui_document_show(document.native);
    }

    pub fn closeDocument(self: *RmlUi, document: Document) void {
        if (available) {
            c.zigcraft_rmlui_document_close(self.runtime, document.native);
            // RmlUi defers Close() cleanup until the next context update.
            _ = c.zigcraft_rmlui_context_update(self.context);
        }
    }

    pub fn addAction(self: *RmlUi, document: Document, event_type: [*:0]const u8, callback: ActionCallback, context: *anyopaque) !Action {
        if (!available) return error.RmlUiDisabled;
        const data = try self.allocator.create(ActionData);
        errdefer self.allocator.destroy(data);
        data.* = .{ .context = context, .callback = callback };
        const native = c.zigcraft_rmlui_document_add_action(self.runtime, document.native, event_type, actionCallback, data) orelse return error.RmlUiActionAttachFailed;
        return .{ .native = native, .data = data };
    }

    pub fn removeAction(self: *RmlUi, action: Action) void {
        if (available) c.zigcraft_rmlui_action_remove(self.runtime, action.native);
        self.allocator.destroy(action.data);
    }

    /// Called inside a caller-owned `UISystem.begin()` / `end()` pair.
    pub fn updateAndRender(self: *RmlUi) usize {
        if (!available) return 0;
        self.frame_geometry_draws = 0;
        _ = c.zigcraft_rmlui_context_update(self.context);
        _ = c.zigcraft_rmlui_context_render(self.context);
        return self.frame_geometry_draws;
    }

    fn compileGeometry(user_data: ?*anyopaque, vertices: [*c]const c.ZigCraftRmlUiVertex, vertex_count: usize, indices: [*c]const i32, index_count: usize) callconv(.c) usize {
        const self = fromUserData(user_data) orelse return 0;
        const source_vertices = vertices[0..vertex_count];
        const source_indices = indices[0..index_count];
        if (!validateIndices(vertex_count, source_indices)) return 0;

        const owned_vertices = self.allocator.alloc(rhi.UiVertex, vertex_count) catch return 0;
        for (source_vertices, owned_vertices) |source, *destination| {
            destination.* = .{ .position = .{ source.x, source.y }, .color = source.color, .uv = .{ source.u, source.v } };
        }

        const owned_indices = self.allocator.alloc(u32, index_count) catch {
            self.allocator.free(owned_vertices);
            return 0;
        };
        for (source_indices, owned_indices) |source, *destination| destination.* = @intCast(source);

        const handle = self.next_geometry;
        self.next_geometry +|= 1;
        self.geometries.put(self.allocator, handle, .{ .vertices = owned_vertices, .indices = owned_indices }) catch {
            self.allocator.free(owned_indices);
            self.allocator.free(owned_vertices);
            return 0;
        };
        return handle;
    }

    fn renderGeometry(user_data: ?*anyopaque, geometry_handle: usize, translation_x: f32, translation_y: f32, texture_handle: usize) callconv(.c) void {
        const self = fromUserData(user_data) orelse return;
        const geometry = self.geometries.get(geometry_handle) orelse return;
        const texture: rhi.TextureHandle = std.math.cast(rhi.TextureHandle, texture_handle) orelse return;
        self.renderer.drawIndexedGeometry(geometry.vertices, geometry.indices, texture, .{ translation_x, translation_y });
        self.frame_geometry_draws += 1;
    }

    fn releaseGeometry(user_data: ?*anyopaque, geometry_handle: usize) callconv(.c) void {
        const self = fromUserData(user_data) orelse return;
        if (self.geometries.fetchRemove(geometry_handle)) |entry| self.releaseOwnedGeometry(entry.value);
    }

    fn loadTexture(_: ?*anyopaque, _: [*c]const u8, out_width: [*c]c_int, out_height: [*c]c_int) callconv(.c) usize {
        // This vertical slice intentionally uses generated glyph textures only.
        // Returning zero makes RmlUi handle missing decorative image assets.
        out_width.* = 0;
        out_height.* = 0;
        return 0;
    }

    fn generateTexture(user_data: ?*anyopaque, pixels: [*c]const u8, size: usize, width: c_int, height: c_int) callconv(.c) usize {
        const self = fromUserData(user_data) orelse return 0;
        if (width <= 0 or height <= 0) return 0;
        const width_u32: u32 = @intCast(width);
        const height_u32: u32 = @intCast(height);
        const expected_size = std.math.mul(usize, std.math.mul(usize, width_u32, height_u32) catch return 0, 4) catch return 0;
        if (size != expected_size) return 0;
        const texture = self.resources.createTexture(width_u32, height_u32, .rgba, .{ .min_filter = .linear, .mag_filter = .linear, .wrap_s = .clamp_to_edge, .wrap_t = .clamp_to_edge, .generate_mipmaps = false }, pixels[0..size]) catch return 0;
        self.generated_textures.put(self.allocator, texture, {}) catch {
            self.resources.destroyTexture(texture);
            return 0;
        };
        return texture;
    }

    fn releaseTexture(user_data: ?*anyopaque, texture_handle: usize) callconv(.c) void {
        const self = fromUserData(user_data) orelse return;
        const texture: rhi.TextureHandle = std.math.cast(rhi.TextureHandle, texture_handle) orelse return;
        if (self.generated_textures.remove(texture)) self.resources.destroyTexture(texture);
    }

    fn enableScissor(user_data: ?*anyopaque, enable: bool) callconv(.c) void {
        const self = fromUserData(user_data) orelse return;
        self.scissor_enabled = enable;
        if (!enable) self.renderer.setScissorRegion(fullScissor(self.screen_width, self.screen_height));
    }

    fn setScissor(user_data: ?*anyopaque, x: c_int, y: c_int, width: c_int, height: c_int) callconv(.c) void {
        const self = fromUserData(user_data) orelse return;
        self.renderer.setScissorRegion(mapScissor(self.screen_width, self.screen_height, self.scissor_enabled, x, y, width, height));
    }

    fn actionCallback(user_data: ?*anyopaque, event_type: [*c]const u8, target_id: [*c]const u8) callconv(.c) void {
        const action: *const ActionData = @ptrCast(@alignCast(user_data orelse return));
        action.callback(action.context, cString(event_type), cString(target_id));
    }

    fn fromUserData(user_data: ?*anyopaque) ?*RmlUi {
        return @ptrCast(@alignCast(user_data orelse return null));
    }

    fn releaseOwnedGeometry(self: *RmlUi, geometry: Geometry) void {
        self.allocator.free(geometry.vertices);
        self.allocator.free(geometry.indices);
    }
};

const ActionData = struct {
    context: *anyopaque,
    callback: ActionCallback,
};

fn cString(value: [*c]const u8) []const u8 {
    if (value == null) return "";
    return std.mem.span(@as([*:0]const u8, @ptrCast(value)));
}

/// Pure validation kept separate from GPU-facing compilation for unit tests.
pub fn validateIndices(vertex_count: usize, indices: []const i32) bool {
    for (indices) |index| {
        if (index < 0 or @as(usize, @intCast(index)) >= vertex_count) return false;
    }
    return true;
}

/// Maps RmlUi's signed rectangle to a safe framebuffer scissor. Disabling
/// clipping deliberately restores the full current framebuffer.
pub fn mapScissor(screen_width: u32, screen_height: u32, enabled: bool, x: i32, y: i32, width: i32, height: i32) rhi.UiScissor {
    if (!enabled) return fullScissor(screen_width, screen_height);
    const max_x: i32 = @intCast(screen_width);
    const max_y: i32 = @intCast(screen_height);
    const left = std.math.clamp(x, 0, max_x);
    const top = std.math.clamp(y, 0, max_y);
    const right = std.math.clamp(x +| @max(width, 0), 0, max_x);
    const bottom = std.math.clamp(y +| @max(height, 0), 0, max_y);
    return .{ .x = left, .y = top, .width = @intCast(@max(right - left, 0)), .height = @intCast(@max(bottom - top, 0)) };
}

fn fullScissor(screen_width: u32, screen_height: u32) rhi.UiScissor {
    return .{ .x = 0, .y = 0, .width = screen_width, .height = screen_height };
}

test "RmlUi geometry index validation rejects invalid source indices" {
    try std.testing.expect(validateIndices(3, &.{ 0, 1, 2 }));
    try std.testing.expect(!validateIndices(3, &.{ 0, -1, 2 }));
    try std.testing.expect(!validateIndices(3, &.{ 0, 3, 2 }));
}

test "RmlUi disabled scissor restores the full framebuffer" {
    const clipped = mapScissor(1280, 720, true, -20, 10, 100, 30);
    try std.testing.expectEqual(rhi.UiScissor{ .x = 0, .y = 10, .width = 80, .height = 30 }, clipped);
    try std.testing.expectEqual(rhi.UiScissor{ .x = 0, .y = 0, .width = 1280, .height = 720 }, mapScissor(1280, 720, false, 5, 5, 1, 1));
}
