const std = @import("std");
const world_core = @import("world-core");
const registry = @import("world-worldgen");

test "fuzz corpus: generators handle extreme chunk coordinates" {
    const coords = [_]i32{
        std.math.minInt(i32),
        std.math.minInt(i32) + 1,
        -1_048_576,
        -1,
        0,
        1,
        1_048_576,
        std.math.maxInt(i32) - 1,
        std.math.maxInt(i32),
    };
    const seeds = [_]u64{ 0, 1, std.math.maxInt(u64), 0x9e3779b97f4a7c15 };

    var generator_index: usize = 0;
    while (generator_index < registry.getGeneratorCount()) : (generator_index += 1) {
        for (seeds) |seed| {
            var generator = try registry.createGenerator(generator_index, seed, std.testing.allocator);
            defer generator.deinit(std.testing.allocator);

            for (coords) |chunk_x| {
                for (coords) |chunk_z| {
                    var chunk = world_core.Chunk.init(chunk_x, chunk_z);
                    try generator.generate(&chunk, null);
                    try std.testing.expectEqual(chunk_x, chunk.chunk_x);
                    try std.testing.expectEqual(chunk_z, chunk.chunk_z);
                }
            }
        }
    }
}
