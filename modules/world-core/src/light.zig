/// Packed light value: upper 4 bits = skylight, then 4 bits each for R, G, B block light
pub const PackedLight = packed struct {
    block_light_b: u4 = 0, // Bits 0-3
    block_light_g: u4 = 0, // Bits 4-7
    block_light_r: u4 = 0, // Bits 8-11
    sky_light: u4 = 0, // Bits 12-15

    pub fn init(sky: u4, block: u4) PackedLight {
        return .{
            .sky_light = sky,
            .block_light_r = block,
            .block_light_g = block,
            .block_light_b = block,
        };
    }

    pub fn initRGB(sky: u4, r: u4, g: u4, b: u4) PackedLight {
        return .{
            .sky_light = sky,
            .block_light_r = r,
            .block_light_g = g,
            .block_light_b = b,
        };
    }

    pub fn getSkyLight(self: PackedLight) u4 {
        return self.sky_light;
    }

    pub fn getBlockLight(self: PackedLight) u4 {
        // Max is safest for legacy intensity checks.
        return @max(self.block_light_r, @max(self.block_light_g, self.block_light_b));
    }

    pub fn getBlockLightR(self: PackedLight) u4 {
        return self.block_light_r;
    }

    pub fn getBlockLightG(self: PackedLight) u4 {
        return self.block_light_g;
    }

    pub fn getBlockLightB(self: PackedLight) u4 {
        return self.block_light_b;
    }

    pub fn setSkyLight(self: *PackedLight, val: u4) void {
        self.sky_light = val;
    }

    pub fn setBlockLight(self: *PackedLight, val: u4) void {
        self.block_light_r = val;
        self.block_light_g = val;
        self.block_light_b = val;
    }

    pub fn setBlockLightRGB(self: *PackedLight, r: u4, g: u4, b: u4) void {
        self.block_light_r = r;
        self.block_light_g = g;
        self.block_light_b = b;
    }

    /// Get maximum of sky and block light channels
    pub fn getMaxLight(self: PackedLight) u4 {
        return @max(self.sky_light, @max(self.block_light_r, @max(self.block_light_g, self.block_light_b)));
    }

    /// Get normalized brightness (0.0 - 1.0)
    pub fn getBrightness(self: PackedLight) f32 {
        return @as(f32, @floatFromInt(self.getMaxLight())) / 15.0;
    }
};
