const world_core = @import("world-core");
const noise = @import("noise.zig");
const terrain_shape = @import("terrain_shape.zig");

const Chunk = world_core.Chunk;
const CHUNK_SIZE_Y = world_core.CHUNK_SIZE_Y;
const BlockType = world_core.BlockType;

pub fn carveNoiseCavesColumn(self: anytype, chunk: *Chunk, local_x: u32, local_z: u32, wx: i32, wz: i32, terrain_height: i32) void {
    if (terrain_height <= 2) return;

    var y: u32 = 1;
    while (y < CHUNK_SIZE_Y) : (y += 1) {
        const yi: i32 = @intCast(y);
        if (yi > terrain_height + 8) break;

        const idx = Chunk.getIndex(local_x, y, local_z);
        if (!isCaveCarvable(chunk.blocks[idx])) continue;

        const ly = terrain_shape.toLuantiY(self, yi);
        const d1 = contour(noise.noiseFractal3D(&self.noise_cave1, @floatFromInt(wx), ly, @floatFromInt(wz), self.seed32));
        const d2 = contour(noise.noiseFractal3D(&self.noise_cave2, @floatFromInt(wx), ly, @floatFromInt(wz), self.seed32));
        if (d1 * d2 > self.params.cave_width) {
            chunk.blocks[idx] = .air;
        }
    }
}

pub fn isCaveCarvable(block: BlockType) bool {
    return switch (block) {
        .stone, .dirt, .grass, .sand, .gravel, .snow_block, .clay, .mud, .terracotta, .red_sand, .packed_ice => true,
        else => false,
    };
}

fn contour(v_in: f32) f32 {
    const v = @abs(v_in);
    if (v >= 1.0) return 0.0;
    return 1.0 - v;
}
