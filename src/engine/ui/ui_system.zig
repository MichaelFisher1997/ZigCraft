//! UI System for rendering 2D interface elements.
//! Uses orthographic projection and immediate-mode style rendering.
//! Now abstracted through UIRenderer for backend-agnostic rendering.

const std = @import("std");
const rhi = @import("../graphics/rhi.zig");

pub const Color = rhi.Color;
pub const Rect = rhi.Rect;
pub const UVRect = rhi.UVRect;

pub const UISystem = struct {
    renderer: rhi.UIRenderer,
    screen_width: f32,
    screen_height: f32,

    pub fn init(renderer: rhi.UIRenderer, width: u32, height: u32) !UISystem {
        return .{
            .renderer = renderer,
            .screen_width = @floatFromInt(width),
            .screen_height = @floatFromInt(height),
        };
    }

    pub fn deinit(self: *UISystem) void {
        _ = self;
    }

    pub fn resize(self: *UISystem, width: u32, height: u32) void {
        self.screen_width = @floatFromInt(width);
        self.screen_height = @floatFromInt(height);
    }

    pub fn begin(self: *UISystem) void {
        self.renderer.beginPass(self.screen_width, self.screen_height);
    }

    pub fn end(self: *UISystem) void {
        self.renderer.endPass();
    }

    pub fn drawRect(self: *UISystem, rect: Rect, color: Color) void {
        self.renderer.drawRect(rect, color);
    }

    pub fn drawTexture(self: *UISystem, texture_id: rhi.TextureHandle, rect: Rect) void {
        self.renderer.drawTexture(texture_id, rect);
    }

    pub fn drawTextureRegion(self: *UISystem, texture_id: rhi.TextureHandle, rect: Rect, uv: UVRect, color: Color) void {
        self.renderer.drawTextureRegion(texture_id, rect, uv, color);
    }

    pub fn drawDepthTexture(self: *UISystem, texture: rhi.TextureHandle, rect: Rect) void {
        self.renderer.drawDepthTexture(texture, rect);
    }

    /// Draw a rectangle outline
    pub fn drawRectOutline(self: *UISystem, rect: Rect, color: Color, thickness: f32) void {
        // Top
        self.drawRect(.{ .x = rect.x, .y = rect.y, .width = rect.width, .height = thickness }, color);
        // Bottom
        self.drawRect(.{ .x = rect.x, .y = rect.y + rect.height - thickness, .width = rect.width, .height = thickness }, color);
        // Left
        self.drawRect(.{ .x = rect.x, .y = rect.y, .width = thickness, .height = rect.height }, color);
        // Right
        self.drawRect(.{ .x = rect.x + rect.width - thickness, .y = rect.y, .width = thickness, .height = rect.height }, color);
    }
};

/// Base widget structure (implement interface pattern)
pub const Widget = struct {
    bounds: Rect,
    visible: bool = true,
    enabled: bool = true,

    // Virtual functions
    drawFn: *const fn (*Widget) void,
    handleInputFn: *const fn (*Widget, InputEvent) bool,

    pub fn draw(self: *Widget, widget: *Widget) void {
        if (self.visible) {
            self.drawFn(widget);
        }
    }

    pub fn handleInput(self: *Widget, widget: *Widget, event: InputEvent) bool {
        if (self.enabled) {
            return self.handleInputFn(widget, event);
        }
        return false;
    }
};

pub const InputEvent = @import("../core/interfaces.zig").InputEvent;
