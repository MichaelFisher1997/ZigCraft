const texture_atlas = @import("engine-graphics").texture_atlas;
const block_registry = @import("world-core").block_registry;

pub const BLOCK_TEXTURE_DEFINITIONS = makeBlockTextureDefinitions();

fn makeBlockTextureDefinitions() [texture_atlas.MAX_BLOCK_TYPES]texture_atlas.BlockTextureDefinition {
    var defs: [texture_atlas.MAX_BLOCK_TYPES]texture_atlas.BlockTextureDefinition = undefined;
    for (&defs, 0..) |*def, i| {
        def.* = .{
            .id = @intCast(i),
            .name = "unknown",
            .default_color = .{ 1.0, 1.0, 1.0 },
            .texture_top = "missing",
            .texture_bottom = "missing",
            .texture_side = "missing",
        };
    }
    for (block_registry.BLOCK_REGISTRY, 0..) |block_def, i| {
        defs[i] = .{
            .id = @intFromEnum(block_def.id),
            .name = block_def.name,
            .default_color = block_def.default_color,
            .texture_top = block_def.texture_top,
            .texture_bottom = block_def.texture_bottom,
            .texture_side = block_def.texture_side,
        };
    }
    return defs;
}
