const std = @import("std");
const noise = @import("noise.zig");

pub const ClimateSample = struct {
    temperature: f32,
    humidity: f32,
};

pub fn sampleClimate(self: anytype, wx: i32, wz: i32) ClimateSample {
    const x: f32 = @floatFromInt(wx);
    const z: f32 = @floatFromInt(wz);
    const temp_raw = noise.noiseFractal2D(&self.noise_temperature, x, z, self.seed32);
    const humid_raw = noise.noiseFractal2D(&self.noise_humidity, x + 913.0, z - 719.0, self.seed32);
    return .{
        .temperature = std.math.clamp((temp_raw + 1.0) * 0.5, 0.0, 1.0),
        .humidity = std.math.clamp((humid_raw + 1.0) * 0.5, 0.0, 1.0),
    };
}
