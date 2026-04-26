const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;
const utils = @import("../math/utils.zig");
const Config = @import("config.zig").AtmosphereConfig;

pub const SkyColorPalette = struct {
    // Linear color storage
    day_sky: Vec3,
    day_horizon: Vec3,
    night_sky: Vec3,
    night_horizon: Vec3,
    dawn_sky: Vec3,
    dawn_horizon: Vec3,
    dusk_sky: Vec3,
    dusk_horizon: Vec3,

    day_sun: Vec3,
    dawn_sun: Vec3,
    dusk_sun: Vec3,
    night_sun: Vec3,

    pub fn init() SkyColorPalette {
        return .{
            .day_sky = Vec3.init(97.0 / 255.0, 181.0 / 255.0, 245.0 / 255.0).toLinear(),
            .day_horizon = Vec3.init(144.0 / 255.0, 211.0 / 255.0, 246.0 / 255.0).toLinear(),
            .night_sky = Vec3.init(0.015, 0.055, 0.12).toLinear(),
            .night_horizon = Vec3.init(0.06, 0.12, 0.24).toLinear(),
            .dawn_sky = Vec3.init(180.0 / 255.0, 186.0 / 255.0, 250.0 / 255.0).toLinear(),
            .dawn_horizon = Vec3.init(186.0 / 255.0, 193.0 / 255.0, 240.0 / 255.0).toLinear(),
            .dusk_sky = Vec3.init(180.0 / 255.0, 172.0 / 255.0, 230.0 / 255.0).toLinear(),
            .dusk_horizon = Vec3.init(230.0 / 255.0, 172.0 / 255.0, 125.0 / 255.0).toLinear(),

            .day_sun = Vec3.init(1.0, 0.96, 0.86).toLinear(),
            .dawn_sun = Vec3.init(1.0, 0.82, 0.56).toLinear(),
            .dusk_sun = Vec3.init(1.0, 0.72, 0.42).toLinear(),
            .night_sun = Vec3.init(0.10, 0.13, 0.22).toLinear(),
        };
    }

    pub const SkyColors = struct {
        sky: Vec3,
        horizon: Vec3,
        sun: Vec3,
    };

    pub fn interpolate(self: *const SkyColorPalette, t: f32) SkyColors {
        var colors: SkyColors = undefined;

        if (t < Config.DAWN_START) {
            colors.sky = self.night_sky;
            colors.horizon = self.night_horizon;
            colors.sun = self.night_sun;
        } else if (t < Config.DAWN_END) {
            const blend = utils.smoothstep(Config.DAWN_START, Config.DAWN_END, t);
            colors.sky = utils.lerpVec3(self.night_sky, self.dawn_sky, blend);
            colors.horizon = utils.lerpVec3(self.night_horizon, self.dawn_horizon, blend);
            colors.sun = utils.lerpVec3(self.night_sun, self.dawn_sun, blend);
        } else if (t < Config.DAY_TRANSITION) {
            const blend = utils.smoothstep(Config.DAWN_END, Config.DAY_TRANSITION, t);
            colors.sky = utils.lerpVec3(self.dawn_sky, self.day_sky, blend);
            colors.horizon = utils.lerpVec3(self.dawn_horizon, self.day_horizon, blend);
            colors.sun = utils.lerpVec3(self.dawn_sun, self.day_sun, blend);
        } else if (t < Config.DUSK_START) {
            colors.sky = self.day_sky;
            colors.horizon = self.day_horizon;
            colors.sun = self.day_sun;
        } else if (t < Config.NIGHT_TRANSITION) {
            const blend = utils.smoothstep(Config.DUSK_START, Config.NIGHT_TRANSITION, t);
            colors.sky = utils.lerpVec3(self.day_sky, self.dusk_sky, blend);
            colors.horizon = utils.lerpVec3(self.day_horizon, self.dusk_horizon, blend);
            colors.sun = utils.lerpVec3(self.day_sun, self.dusk_sun, blend);
        } else if (t < Config.DUSK_END) {
            const blend = utils.smoothstep(Config.NIGHT_TRANSITION, Config.DUSK_END, t);
            colors.sky = utils.lerpVec3(self.dusk_sky, self.night_sky, blend);
            colors.horizon = utils.lerpVec3(self.dusk_horizon, self.night_horizon, blend);
            colors.sun = utils.lerpVec3(self.dusk_sun, self.night_sun, blend);
        } else {
            colors.sky = self.night_sky;
            colors.horizon = self.night_horizon;
            colors.sun = self.night_sun;
        }

        return colors;
    }
};
