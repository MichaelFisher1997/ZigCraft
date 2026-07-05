//! Shared LOD identifiers used by renderer and world systems.

pub const LODLevel = enum(u3) {
    lod0 = 0,
    lod1 = 1,
    lod2 = 2,
    lod3 = 3,
    lod4 = 4,

    pub const count = 5;

    pub fn scale(self: LODLevel) u32 {
        return @as(u32, 1) << @intFromEnum(self);
    }

    pub fn chunksPerSide(self: LODLevel) u32 {
        return self.scale() * 2;
    }

    pub fn totalChunks(self: LODLevel) u32 {
        const side = self.chunksPerSide();
        return side * side;
    }

    pub fn blockSize(self: LODLevel) u32 {
        return self.scale();
    }

    pub fn regionSizeBlocks(self: LODLevel, chunk_size_x: u32) u32 {
        return chunk_size_x * self.chunksPerSide();
    }
};
