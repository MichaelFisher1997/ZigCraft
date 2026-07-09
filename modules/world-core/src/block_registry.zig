//! Data-driven block registry.
//!
//! Replaces the "God Enum" pattern in BlockType by separating data from the enum.
//! Block properties are stored in a static registry indexed by BlockType.

const std = @import("std");
const BlockType = @import("block.zig").BlockType;
const Face = @import("block.zig").Face;

/// Rendering pass for the block
const MAX_BLOCK_TYPES = @import("chunk_constants.zig").MAX_BLOCK_TYPES;

pub const RenderPass = enum {
    /// Opaque blocks (e.g., stone, dirt).
    /// These are drawn first and obscure everything behind them.
    solid,

    /// Transparent blocks with alpha testing (e.g., leaves, grass, flowers).
    /// Pixels are either fully opaque or fully transparent.
    cutout,

    /// Translucent fluid blocks (e.g., water).
    /// Special handling for face culling between same-fluid blocks.
    fluid,

    /// Translucent blocks with alpha blending (e.g., glass).
    /// Drawn last, back-to-front sorted ideally.
    translucent,
};

pub const RenderShape = enum {
    /// Standard 6-face cube (default)
    cube,
    /// 2 diagonal quads crossing at center (flowers, saplings, dead bush)
    cross,
    /// Single horizontal quad (carpet, snow layers, floor vegetation)
    flat_quad,
    /// 2-block-high X-shaped billboard (tall plants)
    tall_cross,
    /// Face-attached non-cube geometry driven by RenderShapeData.attachment
    wall_attached,
    /// Block-specific custom mesh variants (slabs, stairs, doors, fences)
    custom_mesh,
};

/// Light lost when propagation enters this block. Air and cutout blocks use the
/// normal one-level falloff; water is the current translucent exception.
pub fn lightAttenuation(block: BlockType) u4 {
    return if (block == .water) 2 else 1;
}

pub const AttachmentFaces = packed struct {
    top: bool = false,
    bottom: bool = false,
    north: bool = false,
    south: bool = false,
    east: bool = false,
    west: bool = false,

    pub fn walls() AttachmentFaces {
        return .{ .north = true, .south = true, .east = true, .west = true };
    }

    pub fn contains(self: AttachmentFaces, face: Face) bool {
        return switch (face) {
            .top => self.top,
            .bottom => self.bottom,
            .north => self.north,
            .south => self.south,
            .east => self.east,
            .west => self.west,
        };
    }
};

pub const AttachmentSpec = struct {
    default_face: Face,
    allowed_faces: AttachmentFaces,
};

pub const CustomMeshVariant = enum {
    none,
    slab,
    stairs,
    door,
    fence,
};

pub const RenderShapeData = struct {
    attachment: ?AttachmentSpec = null,
    custom_mesh: CustomMeshVariant = .none,
};

pub const BlockDefinition = struct {
    id: BlockType,
    name: []const u8,
    is_solid: bool,
    is_transparent: bool,
    is_tintable: bool,
    is_fluid: bool,
    render_pass: RenderPass,
    render_shape: RenderShape,
    render_shape_data: RenderShapeData,
    light_emission: [3]u4,
    default_color: [3]f32,
    texture_top: []const u8,
    texture_bottom: []const u8,
    texture_side: []const u8,

    /// Check if this block occludes another block on a given face
    pub fn occludes(self: *const BlockDefinition, other_def: *const BlockDefinition, face: Face) bool {
        _ = face;
        if (self.id == .air) return false;

        // Fluid culling: Same fluids don't draw faces between them
        if (self.is_fluid and self.id == other_def.id) return true;

        // Same transparent types occlude each other (no internal glass faces)
        if (self.is_transparent and self.id == other_def.id) return true;

        // Only full cubes fully occlude neighboring cube faces.
        if (self.isFullCubeOccluder()) return true;

        return false;
    }

    pub fn isFullCubeOccluder(self: BlockDefinition) bool {
        return self.is_solid and !self.is_transparent and self.render_shape == .cube;
    }

    /// Get face color with shading based on normal direction
    pub fn getFaceColor(self: BlockDefinition, face: Face) [3]f32 {
        const shade = face.getShade();
        return .{
            self.default_color[0] * shade,
            self.default_color[1] * shade,
            self.default_color[2] * shade,
        };
    }

    /// Get maximum light emission level (0-15)
    pub fn getLightEmissionLevel(self: BlockDefinition) u4 {
        return @max(self.light_emission[0], @max(self.light_emission[1], self.light_emission[2]));
    }

    pub fn isOpaque(self: BlockDefinition) bool {
        return !self.is_transparent;
    }
};

/// Global static registry of block definitions
pub const BLOCK_REGISTRY = blk: {
    // Validate that BlockType is backed by u8 to ensure registry fits
    // Comptime validation at lines 80-88 below
    if (@typeInfo(BlockType).@"enum".tag_type != u8) {
        @compileError("BlockType must be backed by u8 for BLOCK_REGISTRY safety");
    }

    // Validate that all enum fields are covered by the registry size
    if (@typeInfo(BlockType).@"enum".fields.len > MAX_BLOCK_TYPES) {
        @compileError("BlockType has more fields than BLOCK_REGISTRY size");
    }

    var definitions = [_]BlockDefinition{undefined} ** MAX_BLOCK_TYPES; // Max u8 blocks

    // Default "Air" definition for all slots first
    for (0..MAX_BLOCK_TYPES) |i| {
        definitions[i] = .{
            .id = .air,
            .name = "unknown",
            .is_solid = false,
            .is_transparent = true,
            .is_tintable = false,
            .is_fluid = false,
            .render_pass = .solid,
            .render_shape = .cube,
            .render_shape_data = .{},
            .light_emission = .{ 0, 0, 0 },
            .default_color = .{ 1, 0, 1 },
            .texture_top = "unknown",
            .texture_bottom = "unknown",
            .texture_side = "unknown",
        };
    }

    // Populate known blocks
    // We construct this at compile time / comptime.

    // Helper to shorten the definition list
    const fields = @typeInfo(BlockType).@"enum".fields;
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "_")) continue;

        const id = @field(BlockType, field.name);
        const int_id = @intFromEnum(id);

        var def = BlockDefinition{
            .id = id,
            .name = field.name,
            .is_solid = true,
            .is_transparent = false,
            .is_tintable = false,
            .is_fluid = false,
            .render_pass = .solid,
            .render_shape = .cube,
            .render_shape_data = .{},
            .light_emission = .{ 0, 0, 0 },
            .default_color = .{ 1, 1, 1 },
            .texture_top = field.name,
            .texture_bottom = field.name,
            .texture_side = field.name,
        };

        // Apply specific properties based on the original switch statements

        // 1. Textures
        switch (id) {
            .air => {
                def.texture_top = "air";
                def.texture_bottom = "air";
                def.texture_side = "air";
            },
            .grass => {
                def.texture_top = "grass_top";
                def.texture_bottom = "dirt";
                def.texture_side = "grass_side";
            },
            .wood => {
                def.texture_top = "wood_top";
                def.texture_bottom = "wood_top";
                def.texture_side = "wood_side";
            },
            .cactus => {
                def.texture_top = "cactus_top";
                def.texture_bottom = "cactus_top";
                def.texture_side = "cactus_side";
            },
            .mangrove_log => {
                def.texture_top = "mangrove_log_top";
                def.texture_bottom = "mangrove_log_top";
                def.texture_side = "mangrove_log_side";
            },
            .jungle_log => {
                def.texture_top = "jungle_log_top";
                def.texture_bottom = "jungle_log_top";
                def.texture_side = "jungle_log_side";
            },
            .melon => {
                def.texture_top = "melon_top";
                def.texture_bottom = "melon_top";
                def.texture_side = "melon_side";
            },
            .acacia_log => {
                def.texture_top = "acacia_log_top";
                def.texture_bottom = "acacia_log_top";
                def.texture_side = "acacia_log_side";
            },
            .mycelium => {
                def.texture_top = "mycelium_top";
                def.texture_bottom = "dirt";
                def.texture_side = "mycelium_side";
            },
            .red_mushroom_block => {
                def.texture_top = "red_mushroom_block";
                def.texture_bottom = "mushroom_stem";
                def.texture_side = "red_mushroom_block";
            },
            .brown_mushroom_block => {
                def.texture_top = "brown_mushroom_block";
                def.texture_bottom = "mushroom_stem";
                def.texture_side = "brown_mushroom_block";
            },
            .birch_log => {
                def.texture_top = "birch_log_top";
                def.texture_bottom = "birch_log_top";
                def.texture_side = "birch_log_side";
            },
            .spruce_log => {
                def.texture_top = "spruce_log_top";
                def.texture_bottom = "spruce_log_top";
                def.texture_side = "spruce_log_side";
            },
            .torch => {
                def.texture_top = "torch";
                def.texture_bottom = "torch";
                def.texture_side = "torch";
            },
            .lava => {
                def.texture_top = "lava";
                def.texture_bottom = "lava";
                def.texture_side = "lava";
            },
            .snow_layer => {
                def.texture_top = "snow";
                def.texture_bottom = "snow";
                def.texture_side = "snow";
            },
            .podzol => {
                def.texture_top = "podzol_top";
                def.texture_bottom = "dirt";
                def.texture_side = "podzol_side";
            },
            .stone_slab, .stone_stairs => {
                def.texture_top = "stone";
                def.texture_bottom = "stone";
                def.texture_side = "stone";
            },
            else => {},
        }

        // 2. Color
        def.default_color = switch (id) {
            .air => .{ 0, 0, 0 },
            .stone => .{ 0.5, 0.5, 0.5 },
            .dirt => .{ 0.55, 0.35, 0.2 },
            .grass => .{ 0.22, 0.72, 0.16 },
            .sand => .{ 0.9, 0.85, 0.6 },
            .water => .{ 0.2, 0.4, 0.8 },
            .wood => .{ 0.55, 0.35, 0.15 },
            .leaves => .{ 0.14, 0.58, 0.12 },
            .cobblestone => .{ 0.4, 0.4, 0.4 },
            .bedrock => .{ 0.28, 0.28, 0.30 },
            .gravel => .{ 0.45, 0.42, 0.4 },
            .glass => .{ 0.8, 0.9, 0.95 },
            .snow_block => .{ 0.95, 0.95, 1.0 },
            .cactus => .{ 0.1, 0.6, 0.1 },
            .coal_ore => .{ 0.28, 0.28, 0.28 },
            .iron_ore => .{ 0.6, 0.5, 0.4 },
            .gold_ore => .{ 0.9, 0.8, 0.2 },
            .clay => .{ 0.6, 0.6, 0.7 },
            .glowstone => .{ 1.0, 0.9, 0.5 },
            .mud => .{ 0.35, 0.30, 0.30 },
            .mangrove_log => .{ 0.45, 0.25, 0.25 },
            .mangrove_leaves => .{ 0.18, 0.52, 0.14 },
            .mangrove_roots => .{ 0.4, 0.3, 0.2 },
            .jungle_log => .{ 0.5, 0.3, 0.1 },
            .jungle_leaves => .{ 0.10, 0.62, 0.08 },
            .melon => .{ 0.6, 0.8, 0.2 },
            .bamboo => .{ 0.28, 0.82, 0.16 },
            .acacia_log => .{ 0.6, 0.55, 0.5 },
            .acacia_leaves => .{ 0.28, 0.54, 0.18 },
            .acacia_sapling => .{ 0.3, 0.6, 0.2 },
            .terracotta => .{ 0.7, 0.4, 0.3 },
            .red_sand => .{ 0.8, 0.4, 0.1 },
            .mycelium => .{ 0.4, 0.3, 0.4 },
            .mushroom_stem => .{ 0.9, 0.9, 0.85 },
            .red_mushroom_block => .{ 0.8, 0.2, 0.2 },
            .brown_mushroom_block => .{ 0.6, 0.4, 0.3 },
            .tall_grass => .{ 0.20, 0.70, 0.14 },
            .flower_red => .{ 0.9, 0.1, 0.1 },
            .flower_yellow => .{ 0.9, 0.9, 0.1 },
            .dead_bush => .{ 0.4, 0.3, 0.1 },
            .birch_log => .{ 0.8, 0.8, 0.75 },
            .birch_leaves => .{ 0.24, 0.72, 0.16 },
            .spruce_log => .{ 0.35, 0.25, 0.15 },
            .spruce_leaves => .{ 0.12, 0.46, 0.14 },
            .vine => .{ 0.12, 0.56, 0.08 },
            .torch => .{ 1.0, 0.8, 0.4 },
            .lava => .{ 1.0, 0.4, 0.1 },
            .seagrass => .{ 0.12, 0.55, 0.16 },
            .tall_seagrass => .{ 0.10, 0.50, 0.14 },
            .kelp => .{ 0.08, 0.36, 0.12 },
            .seaweed => .{ 0.18, 0.42, 0.16 },
            .coral_block => .{ 0.95, 0.35, 0.45 },
            .coral_fan => .{ 1.0, 0.45, 0.50 },
            .snow_layer => .{ 0.95, 0.95, 1.0 },
            .ice => .{ 0.65, 0.85, 1.0 },
            .packed_ice => .{ 0.45, 0.70, 0.95 },
            .blue_ice => .{ 0.25, 0.55, 1.0 },
            .coarse_dirt => .{ 0.48, 0.32, 0.18 },
            .rooted_dirt => .{ 0.42, 0.30, 0.18 },
            .podzol => .{ 0.36, 0.24, 0.14 },
            .mossy_cobblestone => .{ 0.32, 0.42, 0.28 },
            .white_terracotta => .{ 0.82, 0.68, 0.61 },
            .orange_terracotta => .{ 0.64, 0.32, 0.16 },
            .magenta_terracotta => .{ 0.58, 0.32, 0.39 },
            .light_blue_terracotta => .{ 0.45, 0.42, 0.55 },
            .yellow_terracotta => .{ 0.73, 0.52, 0.22 },
            .lime_terracotta => .{ 0.40, 0.48, 0.24 },
            .pink_terracotta => .{ 0.63, 0.30, 0.32 },
            .gray_terracotta => .{ 0.22, 0.18, 0.16 },
            .light_gray_terracotta => .{ 0.53, 0.42, 0.36 },
            .cyan_terracotta => .{ 0.34, 0.36, 0.36 },
            .purple_terracotta => .{ 0.45, 0.25, 0.36 },
            .blue_terracotta => .{ 0.30, 0.22, 0.42 },
            .brown_terracotta => .{ 0.30, 0.18, 0.12 },
            .green_terracotta => .{ 0.30, 0.35, 0.18 },
            .red_terracotta => .{ 0.56, 0.24, 0.18 },
            .black_terracotta => .{ 0.16, 0.10, 0.08 },
            .stone_slab, .stone_stairs => .{ 0.5, 0.5, 0.5 },
            else => .{ 1, 0, 1 },
        };

        // 2. Solid
        def.is_solid = switch (id) {
            .air, .water, .lava, .snow_layer, .tall_grass, .flower_red, .flower_yellow, .dead_bush, .vine, .torch, .seagrass, .tall_seagrass, .kelp, .seaweed, .coral_fan => false,
            else => true,
        };

        // 3. Transparent
        def.is_transparent = switch (id) {
            .air, .water, .lava, .glass, .ice, .packed_ice, .blue_ice, .snow_layer, .leaves, .mangrove_leaves, .mangrove_roots, .jungle_leaves, .bamboo, .acacia_leaves, .acacia_sapling, .birch_leaves, .spruce_leaves, .vine, .tall_grass, .flower_red, .flower_yellow, .dead_bush, .cactus, .melon, .torch, .seagrass, .tall_seagrass, .kelp, .seaweed, .coral_fan => true,
            else => false,
        };

        // 4. Tintable
        def.is_tintable = switch (id) {
            .leaves, .mangrove_leaves, .jungle_leaves, .acacia_leaves, .birch_leaves, .spruce_leaves, .vine, .tall_grass, .seagrass, .tall_seagrass, .kelp, .seaweed, .water => true,
            else => false,
        };

        // 5. Is Fluid
        def.is_fluid = switch (id) {
            .water, .lava => true,
            else => false,
        };

        // 6. Render Pass
        def.render_pass = switch (id) {
            .water, .lava => .fluid,
            .glass, .ice, .packed_ice, .blue_ice => .translucent,
            .snow_layer, .leaves, .mangrove_leaves, .jungle_leaves, .acacia_leaves, .birch_leaves, .spruce_leaves, .mangrove_roots, .bamboo, .acacia_sapling, .vine, .tall_grass, .flower_red, .flower_yellow, .dead_bush, .cactus, .melon, .torch, .seagrass, .tall_seagrass, .kelp, .seaweed, .coral_fan => .cutout,
            else => .solid,
        };

        // 7. Light Emission (RGB values 0-15)
        def.light_emission = switch (id) {
            .glowstone => .{ 15, 14, 10 },
            .torch => .{ 15, 11, 6 },
            .lava => .{ 15, 8, 3 },
            else => .{ 0, 0, 0 },
        };

        // 8. Render Shape
        def.render_shape = switch (id) {
            .tall_grass, .tall_seagrass, .kelp => .tall_cross,
            .flower_red, .flower_yellow, .dead_bush, .acacia_sapling, .bamboo, .torch, .seagrass, .seaweed => .cross,
            .coral_fan => .flat_quad,
            .snow_layer => .flat_quad,
            .vine => .wall_attached,
            .stone_slab, .stone_stairs => .custom_mesh,
            else => .cube,
        };

        def.render_shape_data = switch (id) {
            .vine => .{
                .attachment = .{
                    .default_face = .north,
                    .allowed_faces = AttachmentFaces.walls(),
                },
            },
            .stone_slab => .{ .custom_mesh = .slab },
            .stone_stairs => .{ .custom_mesh = .stairs },
            else => .{},
        };

        definitions[int_id] = def;
    }

    // Validate that all known block types have been registered (no "unknown" left)
    for (fields) |field| {
        if (std.mem.eql(u8, field.name, "_")) continue;
        const id = @field(BlockType, field.name);
        const idx = @intFromEnum(id);
        if (std.mem.eql(u8, definitions[idx].name, "unknown")) {
            @compileError("Missing block registry definition for: " ++ field.name);
        }
    }

    break :blk definitions;
};

/// Get the block definition for a given block type
pub fn getBlockDefinition(block: BlockType) *const BlockDefinition {
    const idx = @intFromEnum(block);
    // Bounds check is implicit for u8 indexing into [256] array,
    // and we validated BlockType is u8 backed at comptime.
    return &BLOCK_REGISTRY[idx];
}
