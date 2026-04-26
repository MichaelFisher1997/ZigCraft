pub const AtmosphereConfig = struct {
    pub const DAWN_START: f32 = 0.20;
    pub const DAWN_END: f32 = 0.30;
    pub const DUSK_START: f32 = 0.70;
    pub const DUSK_END: f32 = 0.80;

    pub const DAY_TRANSITION: f32 = 0.35;
    pub const NIGHT_TRANSITION: f32 = 0.75;

    pub const MOON_INTENSITY_FACTOR: f32 = 0.15;
    pub const AMBIENT_DAY: f32 = 1.0;
    pub const AMBIENT_NIGHT: f32 = 0.28;

    pub const FOG_DENSITY_MAX: f32 = 0.00045;
    pub const FOG_DENSITY_MIN: f32 = 0.00020;
};
