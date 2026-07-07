const std = @import("std");
const gen_interface = @import("worldgen-api");
const Generator = gen_interface.Generator;
const ColumnInfo = gen_interface.ColumnInfo;

pub const WorldMap = struct {
    allocator: std.mem.Allocator,
    pixels: []u8,
    width: u32,
    height: u32,

    pub fn init(allocator: std.mem.Allocator, width: u32, height: u32) !WorldMap {
        // Safety: ensure texture size is within typical hardware limits
        const safe_w = @min(width, 4096);
        const safe_h = @min(height, 4096);
        const pixel_bytes = @as(usize, safe_w) * @as(usize, safe_h) * 4;
        const pixels = try allocator.alloc(u8, pixel_bytes);
        @memset(pixels, 0);

        return .{
            .allocator = allocator,
            .pixels = pixels,
            .width = safe_w,
            .height = safe_h,
        };
    }

    pub fn deinit(self: *WorldMap) void {
        self.allocator.free(self.pixels);
        self.pixels = &.{};
    }

    pub fn update(self: *WorldMap, generator: Generator, center_x: f32, center_z: f32, scale: f32) void {
        const hw = @as(f32, @floatFromInt(self.width)) * 0.5;
        const hh = @as(f32, @floatFromInt(self.height)) * 0.5;
        const start_x = center_x - (hw * scale);
        const start_z = center_z - (hh * scale);

        var py: u32 = 0;
        while (py < self.height) : (py += 1) {
            const wz = start_z + @as(f32, @floatFromInt(py)) * scale;
            var px: u32 = 0;
            while (px < self.width) : (px += 1) {
                const wx = start_x + @as(f32, @floatFromInt(px)) * scale;

                const info = generator.getColumnInfo(wx, wz);
                const color = shadeColor(getBiomeColor(info), info.height);

                const idx = (px + py * self.width) * 4;
                self.pixels[idx + 0] = @intFromFloat(color[0] * 255.0);
                self.pixels[idx + 1] = @intFromFloat(color[1] * 255.0);
                self.pixels[idx + 2] = @intFromFloat(color[2] * 255.0);
                self.pixels[idx + 3] = 255;
            }
        }
    }

    fn getBiomeColor(info: ColumnInfo) [3]f32 {
        if (info.is_ocean) {
            const depth = @as(f32, @floatFromInt(64 - info.height));
            const t = std.math.clamp(depth / 40.0, 0.0, 1.0);
            return .{
                std.math.lerp(0.18, 0.02, t),
                std.math.lerp(0.48, 0.16, t),
                std.math.lerp(0.86, 0.52, t),
            };
        }

        return switch (info.biome) {
            .deep_ocean => .{ 0.03, 0.18, 0.48 },
            .frozen_ocean => .{ 0.62, 0.80, 0.88 },
            .cold_ocean => .{ 0.05, 0.27, 0.55 },
            .ocean => .{ 0.06, 0.34, 0.72 },
            .warm_ocean => .{ 0.08, 0.50, 0.82 },
            .tropical => .{ 0.14, 0.72, 0.58 },
            .river => .{ 0.12, 0.46, 0.86 },
            .frozen_river => .{ 0.66, 0.82, 0.91 },
            .beach, .coastal_plains => .{ 0.90, 0.78, 0.48 },
            .stony_shore => .{ 0.48, 0.49, 0.47 },
            .snowy_beach => .{ 0.86, 0.92, 0.94 },
            .desert => .{ 0.86, 0.66, 0.30 },
            .badlands => .{ 0.76, 0.34, 0.16 },
            .snow_tundra => .{ 0.78, 0.88, 0.92 },
            .snowy_mountains => .{ 0.90, 0.94, 0.98 },
            .mountains => .{ 0.47, 0.38, 0.27 },
            .meadow => .{ 0.40, 0.67, 0.28 },
            .grove => .{ 0.20, 0.36, 0.22 },
            .snowy_slopes => .{ 0.84, 0.90, 0.95 },
            .jagged_peaks => .{ 0.55, 0.55, 0.52 },
            .frozen_peaks => .{ 0.72, 0.87, 0.96 },
            .stony_peaks => .{ 0.58, 0.53, 0.42 },
            .foothills => .{ 0.40, 0.56, 0.26 },
            .plains => .{ 0.38, 0.68, 0.25 },
            .dry_plains => .{ 0.64, 0.62, 0.31 },
            .forest => .{ 0.13, 0.43, 0.17 },
            .birch_forest => .{ 0.20, 0.55, 0.16 },
            .dark_forest => .{ 0.08, 0.26, 0.10 },
            .flower_forest => .{ 0.28, 0.62, 0.20 },
            .jungle => .{ 0.08, 0.50, 0.18 },
            .bamboo_jungle => .{ 0.12, 0.58, 0.10 },
            .sparse_jungle => .{ 0.16, 0.54, 0.16 },
            .taiga => .{ 0.18, 0.38, 0.31 },
            .snowy_taiga => .{ 0.50, 0.64, 0.58 },
            .old_growth_taiga => .{ 0.12, 0.32, 0.22 },
            .savanna => .{ 0.68, 0.66, 0.28 },
            .savanna_plateau => .{ 0.70, 0.67, 0.30 },
            .windswept_savanna => .{ 0.58, 0.58, 0.24 },
            .wooded_badlands => .{ 0.64, 0.39, 0.18 },
            .eroded_badlands => .{ 0.82, 0.30, 0.10 },
            .swamp, .marsh => .{ 0.20, 0.34, 0.18 },
            .mangrove_swamp => .{ 0.16, 0.30, 0.22 },
            .mushroom_fields => .{ 0.56, 0.38, 0.62 },
        };
    }

    fn shadeColor(color: [3]f32, height: i32) [3]f32 {
        const normalized_height = std.math.clamp((@as(f32, @floatFromInt(height)) - 48.0) / 96.0, 0.0, 1.0);
        const shade = std.math.lerp(0.82, 1.18, normalized_height);
        return .{
            std.math.clamp(color[0] * shade, 0.0, 1.0),
            std.math.clamp(color[1] * shade, 0.0, 1.0),
            std.math.clamp(color[2] * shade, 0.0, 1.0),
        };
    }
};
