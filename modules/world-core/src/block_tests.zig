const std = @import("std");
const testing = std.testing;
const Face = @import("block.zig").Face;
const ALL_FACES = @import("block.zig").ALL_FACES;

test "Face.getNormal top" {
    const n = Face.top.getNormal();
    try testing.expectEqual(@as(i8, 0), n[0]);
    try testing.expectEqual(@as(i8, 1), n[1]);
    try testing.expectEqual(@as(i8, 0), n[2]);
}

test "Face.getNormal bottom" {
    const n = Face.bottom.getNormal();
    try testing.expectEqual(@as(i8, 0), n[0]);
    try testing.expectEqual(@as(i8, -1), n[1]);
    try testing.expectEqual(@as(i8, 0), n[2]);
}

test "Face.getNormal north" {
    const n = Face.north.getNormal();
    try testing.expectEqual(@as(i8, 0), n[0]);
    try testing.expectEqual(@as(i8, 0), n[1]);
    try testing.expectEqual(@as(i8, -1), n[2]);
}

test "Face.getNormal south" {
    const n = Face.south.getNormal();
    try testing.expectEqual(@as(i8, 0), n[0]);
    try testing.expectEqual(@as(i8, 0), n[1]);
    try testing.expectEqual(@as(i8, 1), n[2]);
}

test "Face.getNormal east" {
    const n = Face.east.getNormal();
    try testing.expectEqual(@as(i8, 1), n[0]);
    try testing.expectEqual(@as(i8, 0), n[1]);
    try testing.expectEqual(@as(i8, 0), n[2]);
}

test "Face.getNormal west" {
    const n = Face.west.getNormal();
    try testing.expectEqual(@as(i8, -1), n[0]);
    try testing.expectEqual(@as(i8, 0), n[1]);
    try testing.expectEqual(@as(i8, 0), n[2]);
}

test "Face.getOffset matches normal" {
    for (ALL_FACES) |face| {
        const normal = face.getNormal();
        const offset = face.getOffset();
        try testing.expectEqual(normal[0], offset.x);
        try testing.expectEqual(normal[1], offset.y);
        try testing.expectEqual(normal[2], offset.z);
    }
}

test "Face.getShade top is brightest" {
    const shade = Face.top.getShade();
    try testing.expectEqual(@as(f32, 1.0), shade);
}

test "Face.getShade bottom is darkest" {
    const shade = Face.bottom.getShade();
    try testing.expectEqual(@as(f32, 0.5), shade);
}

test "Face.getShade sides are intermediate" {
    const north_shade = Face.north.getShade();
    const east_shade = Face.east.getShade();
    try testing.expectEqual(@as(f32, 0.8), north_shade);
    try testing.expectEqual(@as(f32, 0.7), east_shade);
}

test "ALL_FACES contains all 6 faces" {
    try testing.expectEqual(@as(usize, 6), ALL_FACES.len);
}

test "ALL_FACES each face has unique normal" {
    var normals: [6][3]i8 = undefined;
    for (ALL_FACES, 0..) |face, i| {
        normals[i] = face.getNormal();
    }
    for (0..6) |i| {
        for (0..6) |j| {
            if (i != j) {
                try testing.expect(normals[i][0] != normals[j][0] or
                    normals[i][1] != normals[j][1] or
                    normals[i][2] != normals[j][2]);
            }
        }
    }
}
