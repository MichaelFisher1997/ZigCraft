const std = @import("std");
const world_core = @import("world-core");
const Chunk = world_core.Chunk;
const BlockType = world_core.BlockType;
const BiomeId = world_core.BiomeId;

/// Abstraction for decoration placement logic.
/// Allows OverworldGenerator to be decoupled from specific decoration implementations.
///
/// Note: Decorations are typically placed once per column. Providers should
/// break after the first valid decoration to prevent overlap and unintended density.
pub const DecorationProvider = struct {
    ptr: ?*anyopaque,
    vtable: *const VTable,

    pub const DecorationContext = struct {
        chunk: *Chunk,
        local_x: u32,
        local_z: u32,
        surface_y: i32,
        surface_block: BlockType,
        water_depth: u8,
        biome: BiomeId,
        variant: f32,
        allow_subbiomes: bool,
        veg_mult: f32,
        random: std.Random,
    };

    pub const VTable = struct {
        decorate: *const fn (
            ptr: ?*anyopaque,
            ctx: DecorationContext,
        ) void,
    };

    pub fn decorate(self: DecorationProvider, ctx: DecorationContext) void {
        self.vtable.decorate(self.ptr, ctx);
    }
};
