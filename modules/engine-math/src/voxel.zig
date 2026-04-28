//! Voxel-space primitives that are independent of concrete world block types.

pub const Face = enum(u3) {
    top = 0,
    bottom = 1,
    north = 2,
    south = 3,
    east = 4,
    west = 5,

    pub fn getShade(self: Face) f32 {
        return switch (self) {
            .top => 1.0,
            .bottom => 0.5,
            .north, .south => 0.8,
            .east, .west => 0.7,
        };
    }

    pub fn getNormal(self: Face) [3]i8 {
        return switch (self) {
            .top => .{ 0, 1, 0 },
            .bottom => .{ 0, -1, 0 },
            .north => .{ 0, 0, -1 },
            .south => .{ 0, 0, 1 },
            .east => .{ 1, 0, 0 },
            .west => .{ -1, 0, 0 },
        };
    }

    pub fn getOffset(self: Face) struct { x: i32, y: i32, z: i32 } {
        const n = self.getNormal();
        return .{ .x = n[0], .y = n[1], .z = n[2] };
    }
};

pub const ALL_FACES = [_]Face{ .top, .bottom, .north, .south, .east, .west };
