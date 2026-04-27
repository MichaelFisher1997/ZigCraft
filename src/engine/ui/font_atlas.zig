//! TrueType font atlas for screen-space UI text.

const std = @import("std");
const c = @import("../../c.zig").c;
const fs = @import("fs");
const rhi = @import("../graphics/rhi.zig");
const UISystem = @import("ui_system.zig").UISystem;
const Color = @import("ui_system.zig").Color;
const Rect = @import("ui_system.zig").Rect;
const UVRect = @import("ui_system.zig").UVRect;

const FIRST_CHAR: u8 = 32;
const CHAR_COUNT: usize = 95;
const ATLAS_WIDTH: u32 = 512;
const ATLAS_HEIGHT: u32 = 512;
const BAKE_PIXEL_HEIGHT: f32 = 24.0;
const LEGACY_PIXEL_HEIGHT: f32 = 7.0;
const LEGACY_COMPAT_SCALE: f32 = 1.55;

pub const FontAtlas = struct {
    allocator: std.mem.Allocator,
    texture: rhi.TextureHandle,
    glyphs: [CHAR_COUNT]c.stbtt_bakedchar,
    atlas_width: f32,
    atlas_height: f32,

    pub fn init(allocator: std.mem.Allocator, resources: rhi.ResourceManager, font_path: []const u8) !FontAtlas {
        const font_data = try fs.cwd().readFileAlloc(font_path, allocator, 16 * 1024 * 1024);
        defer allocator.free(font_data);

        const bitmap_len = ATLAS_WIDTH * ATLAS_HEIGHT;
        const bitmap = try allocator.alloc(u8, bitmap_len);
        defer allocator.free(bitmap);
        @memset(bitmap, 0);

        var glyphs: [CHAR_COUNT]c.stbtt_bakedchar = undefined;
        const baked = c.stbtt_BakeFontBitmap(
            font_data.ptr,
            0,
            BAKE_PIXEL_HEIGHT,
            bitmap.ptr,
            ATLAS_WIDTH,
            ATLAS_HEIGHT,
            FIRST_CHAR,
            CHAR_COUNT,
            &glyphs,
        );
        if (baked <= 0) return error.FontBakeFailed;

        const texture = try resources.createTexture(ATLAS_WIDTH, ATLAS_HEIGHT, .red, .{
            .min_filter = .linear,
            .mag_filter = .linear,
            .wrap_s = .clamp_to_edge,
            .wrap_t = .clamp_to_edge,
            .generate_mipmaps = false,
        }, bitmap);

        return .{
            .allocator = allocator,
            .texture = texture,
            .glyphs = glyphs,
            .atlas_width = @floatFromInt(ATLAS_WIDTH),
            .atlas_height = @floatFromInt(ATLAS_HEIGHT),
        };
    }

    pub fn deinit(self: *FontAtlas, resources: rhi.ResourceManager) void {
        if (self.texture != rhi.InvalidTextureHandle) {
            resources.destroyTexture(self.texture);
            self.texture = rhi.InvalidTextureHandle;
        }
    }

    pub fn drawText(self: *const FontAtlas, ui: *UISystem, text: []const u8, x: f32, y: f32, legacy_scale: f32, color: Color) bool {
        var cx = x;
        const scale = renderScale(legacy_scale);

        for (text) |ch| {
            if (ch < FIRST_CHAR or ch >= FIRST_CHAR + CHAR_COUNT) return false;
            const glyph = self.glyphs[ch - FIRST_CHAR];
            const w: f32 = @floatFromInt(glyph.x1 - glyph.x0);
            const h: f32 = @floatFromInt(glyph.y1 - glyph.y0);
            if (w > 0 and h > 0) {
                const rect = Rect{
                    .x = cx + glyph.xoff * scale,
                    .y = y + glyph.yoff * scale + LEGACY_PIXEL_HEIGHT * legacy_scale,
                    .width = w * scale,
                    .height = h * scale,
                };
                const uv = UVRect{
                    .u0 = @as(f32, @floatFromInt(glyph.x0)) / self.atlas_width,
                    .v0 = @as(f32, @floatFromInt(glyph.y0)) / self.atlas_height,
                    .u1 = @as(f32, @floatFromInt(glyph.x1)) / self.atlas_width,
                    .v1 = @as(f32, @floatFromInt(glyph.y1)) / self.atlas_height,
                };
                ui.drawTextureRegion(self.texture, rect, uv, color);
            }
            cx += glyph.xadvance * scale;
        }

        return true;
    }

    pub fn measureTextWidth(self: *const FontAtlas, text: []const u8, legacy_scale: f32) ?f32 {
        var width: f32 = 0.0;
        const scale = renderScale(legacy_scale);
        for (text) |ch| {
            if (ch < FIRST_CHAR or ch >= FIRST_CHAR + CHAR_COUNT) return null;
            width += self.glyphs[ch - FIRST_CHAR].xadvance * scale;
        }
        return width;
    }

    fn renderScale(legacy_scale: f32) f32 {
        return (LEGACY_PIXEL_HEIGHT * LEGACY_COMPAT_SCALE * legacy_scale) / BAKE_PIXEL_HEIGHT;
    }
};
