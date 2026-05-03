//! Unit tests for the cave generation system
//!
//! Tests focus on:
//! - CaveCarveMap operations (init, deinit, get, set)
//! - CaveSystem initialization and determinism
//! - Cave region detection and thresholds
//! - Edge cases and boundary conditions

const std = @import("std");
const testing = std.testing;
const caves = @import("caves.zig");
const CaveCarveMap = caves.CaveCarveMap;
const CaveSystem = caves.CaveSystem;
const CaveParams = caves.CaveParams;

const CHUNK_SIZE_X = @import("world-core").CHUNK_SIZE_X;
const CHUNK_SIZE_Y = @import("world-core").CHUNK_SIZE_Y;
const CHUNK_SIZE_Z = @import("world-core").CHUNK_SIZE_Z;

// ============================================================================
// CaveCarveMap Tests
// ============================================================================

test "CaveCarveMap initialization zeros all values" {
    var carve_map = try CaveCarveMap.init(testing.allocator);
    defer carve_map.deinit();

    // All values should be initialized to false
    var x: u32 = 0;
    while (x < CHUNK_SIZE_X) : (x += 1) {
        var y: u32 = 0;
        while (y < CHUNK_SIZE_Y) : (y += 1) {
            var z: u32 = 0;
            while (z < CHUNK_SIZE_Z) : (z += 1) {
                try testing.expectEqual(false, carve_map.get(x, y, z));
            }
        }
    }
}

test "CaveCarveMap set and get operations" {
    var carve_map = try CaveCarveMap.init(testing.allocator);
    defer carve_map.deinit();

    // Set a single cell
    carve_map.set(5, 64, 7, true);
    try testing.expectEqual(true, carve_map.get(5, 64, 7));

    // Neighboring cells should be unaffected
    try testing.expectEqual(false, carve_map.get(4, 64, 7));
    try testing.expectEqual(false, carve_map.get(5, 63, 7));
    try testing.expectEqual(false, carve_map.get(5, 64, 6));

    // Set and unset
    carve_map.set(5, 64, 7, false);
    try testing.expectEqual(false, carve_map.get(5, 64, 7));
}

test "CaveCarveMap bounds checking - out of bounds returns false" {
    var carve_map = try CaveCarveMap.init(testing.allocator);
    defer carve_map.deinit();

    // Set should silently ignore out-of-bounds
    carve_map.set(100, 64, 7, true);
    carve_map.set(5, 300, 7, true);
    carve_map.set(5, 64, 100, true);

    // Get should return false for out-of-bounds
    try testing.expectEqual(false, carve_map.get(100, 64, 7));
    try testing.expectEqual(false, carve_map.get(5, 300, 7));
    try testing.expectEqual(false, carve_map.get(5, 64, 100));
}

test "CaveCarveMap bounds checking - boundary values" {
    var carve_map = try CaveCarveMap.init(testing.allocator);
    defer carve_map.deinit();

    // Set at exact boundaries
    carve_map.set(0, 0, 0, true);
    carve_map.set(CHUNK_SIZE_X - 1, CHUNK_SIZE_Y - 1, CHUNK_SIZE_Z - 1, true);

    try testing.expectEqual(true, carve_map.get(0, 0, 0));
    try testing.expectEqual(true, carve_map.get(CHUNK_SIZE_X - 1, CHUNK_SIZE_Y - 1, CHUNK_SIZE_Z - 1));

    // Just outside boundaries should return false
    try testing.expectEqual(false, carve_map.get(CHUNK_SIZE_X, 0, 0));
    try testing.expectEqual(false, carve_map.get(0, CHUNK_SIZE_Y, 0));
    try testing.expectEqual(false, carve_map.get(0, 0, CHUNK_SIZE_Z));
}

test "CaveCarveMap multiple cells independently tracked" {
    var carve_map = try CaveCarveMap.init(testing.allocator);
    defer carve_map.deinit();

    // Set a pattern of cells
    carve_map.set(0, 10, 0, true);
    carve_map.set(8, 64, 8, true);
    carve_map.set(15, 128, 15, true);

    // Verify all are set independently
    try testing.expectEqual(true, carve_map.get(0, 10, 0));
    try testing.expectEqual(true, carve_map.get(8, 64, 8));
    try testing.expectEqual(true, carve_map.get(15, 128, 15));

    // Verify unset cells remain false
    try testing.expectEqual(false, carve_map.get(1, 10, 0));
    try testing.expectEqual(false, carve_map.get(8, 65, 8));
    try testing.expectEqual(false, carve_map.get(14, 128, 15));
}

// ============================================================================
// CaveSystem Initialization Tests
// ============================================================================

test "CaveSystem initialization with seed" {
    const cave_system = CaveSystem.init(12345);

    // Verify seed is stored
    try testing.expectEqual(@as(u64, 12345), cave_system.seed);

    // Verify default params are set
    try testing.expectEqual(@as(f32, 1.0 / 900.0), cave_system.params.region_scale);
    try testing.expectEqual(@as(f32, 0.42), cave_system.params.region_threshold);
    try testing.expectEqual(@as(i32, 8), cave_system.params.min_surface_depth);
}

test "CaveSystem initialization produces different seeds for sub-noises" {
    // Different seeds should produce different internal noise states
    const cs1 = CaveSystem.init(100);
    const cs2 = CaveSystem.init(200);

    // The internal noise generators should have different states
    // This is verified by checking different outputs at same position
    const val1 = cs1.getCaveRegionValue(100.0, 100.0);
    const val2 = cs2.getCaveRegionValue(100.0, 100.0);

    try testing.expect(val1 != val2);
}

test "CaveSystem deterministic with same seed" {
    const cs1 = CaveSystem.init(54321);
    const cs2 = CaveSystem.init(54321);

    // Same seed should produce identical outputs
    const val1 = cs1.getCaveRegionValue(50.0, 50.0);
    const val2 = cs2.getCaveRegionValue(50.0, 50.0);

    try testing.expectEqual(val1, val2);
}

// ============================================================================
// Cave Region Detection Tests
// ============================================================================

test "CaveSystem getCaveRegionValue returns value in valid range" {
    const cave_system = CaveSystem.init(42);

    // Sample multiple positions
    var x: f32 = 0;
    while (x < 1000) : (x += 100) {
        var z: f32 = 0;
        while (z < 1000) : (z += 100) {
            const val = cave_system.getCaveRegionValue(x, z);
            // fBm normalized should be in [0, 1]
            try testing.expect(val >= 0.0);
            try testing.expect(val <= 1.0);
        }
    }
}

test "CaveSystem isCaveRegion respects threshold" {
    // Use a fixed seed and check behavior
    const cave_system = CaveSystem.init(99999);

    // The threshold is 0.42 by default
    // We can't predict exact values, but we can verify consistency
    var cave_count: u32 = 0;
    var total_samples: u32 = 0;

    var x: f32 = 0;
    while (x < 5000) : (x += 50) {
        var z: f32 = 0;
        while (z < 5000) : (z += 50) {
            total_samples += 1;
            if (cave_system.isCaveRegion(x, z)) {
                cave_count += 1;
                // If isCaveRegion returns true, value must be >= threshold
                try testing.expect(cave_system.getCaveRegionValue(x, z) >= cave_system.params.region_threshold);
            }
        }
    }

    // Some regions should have caves (not all or none)
    try testing.expect(cave_count > 0);
    try testing.expect(cave_count < total_samples);
}

test "CaveSystem cave region detection is deterministic" {
    const cs1 = CaveSystem.init(77777);
    const cs2 = CaveSystem.init(77777);

    // Same positions should give same region results
    var x: f32 = 0;
    while (x < 1000) : (x += 100) {
        var z: f32 = 0;
        while (z < 1000) : (z += 100) {
            try testing.expectEqual(cs1.isCaveRegion(x, z), cs2.isCaveRegion(x, z));
        }
    }
}

// ============================================================================
// CaveParams Tests
// ============================================================================

test "CaveParams default values" {
    const params = CaveParams{};

    // Region mask
    try testing.expectEqual(@as(f32, 1.0 / 900.0), params.region_scale);
    try testing.expectEqual(@as(f32, 0.42), params.region_threshold);

    // Surface protection
    try testing.expectEqual(@as(i32, 8), params.min_surface_depth);

    // Worm cave parameters
    try testing.expectEqual(@as(u32, 1), params.worms_per_chunk_min);
    try testing.expectEqual(@as(u32, 3), params.worms_per_chunk_max);
    try testing.expectEqual(@as(i32, 15), params.worm_y_min);
    try testing.expectEqual(@as(i32, 110), params.worm_y_max);
    try testing.expectEqual(@as(f32, 2.5), params.worm_radius_min);
    try testing.expectEqual(@as(f32, 5.0), params.worm_radius_max);

    // Cavern parameters
    try testing.expectEqual(@as(f32, 0.6), params.cavern_threshold);
    try testing.expectEqual(@as(i32, 32), params.cavern_y_max);

    // Sea level
    try testing.expectEqual(@as(i32, 64), params.sea_level);
}

test "CaveParams custom values" {
    const params = CaveParams{
        .region_scale = 0.001,
        .region_threshold = 0.5,
        .min_surface_depth = 12,
        .worms_per_chunk_min = 2,
        .worms_per_chunk_max = 5,
        .worm_y_min = 20,
        .worm_y_max = 100,
        .sea_level = 62,
    };

    try testing.expectEqual(@as(f32, 0.001), params.region_scale);
    try testing.expectEqual(@as(f32, 0.5), params.region_threshold);
    try testing.expectEqual(@as(i32, 12), params.min_surface_depth);
    try testing.expectEqual(@as(u32, 2), params.worms_per_chunk_min);
    try testing.expectEqual(@as(u32, 5), params.worms_per_chunk_max);
    try testing.expectEqual(@as(i32, 20), params.worm_y_min);
    try testing.expectEqual(@as(i32, 100), params.worm_y_max);
    try testing.expectEqual(@as(i32, 62), params.sea_level);
}

// ============================================================================
// Edge Case Tests
// ============================================================================

test "CaveSystem handles large coordinates" {
    const cave_system = CaveSystem.init(12345);

    // Large coordinates should not panic or produce invalid values
    // Note: The noise library uses i64 internally, so stay within safe range
    const large_coords = [_][2]f32{
        .{ 100000.0, 100000.0 },
        .{ -100000.0, -100000.0 },
        .{ 500000.0, -250000.0 },
        .{ 1000000.0, 0 },
    };

    for (large_coords) |coord| {
        const val = cave_system.getCaveRegionValue(coord[0], coord[1]);
        // Should still be in valid range
        try testing.expect(val >= 0.0);
        try testing.expect(val <= 1.0);
    }
}

test "CaveSystem handles zero coordinates" {
    const cave_system = CaveSystem.init(42);

    const val = cave_system.getCaveRegionValue(0.0, 0.0);
    try testing.expect(val >= 0.0);
    try testing.expect(val <= 1.0);
}

test "CaveCarveMap handles all chunk coordinates" {
    var carve_map = try CaveCarveMap.init(testing.allocator);
    defer carve_map.deinit();

    // Set every possible coordinate
    var x: u32 = 0;
    while (x < CHUNK_SIZE_X) : (x += 1) {
        var y: u32 = 0;
        while (y < CHUNK_SIZE_Y) : (y += 1) {
            var z: u32 = 0;
            while (z < CHUNK_SIZE_Z) : (z += 1) {
                // Set alternating pattern
                const should_set = (x + y + z) % 2 == 0;
                carve_map.set(x, y, z, should_set);
            }
        }
    }

    // Verify all values
    x = 0;
    while (x < CHUNK_SIZE_X) : (x += 1) {
        var y: u32 = 0;
        while (y < CHUNK_SIZE_Y) : (y += 1) {
            var z: u32 = 0;
            while (z < CHUNK_SIZE_Z) : (z += 1) {
                const expected = (x + y + z) % 2 == 0;
                try testing.expectEqual(expected, carve_map.get(x, y, z));
            }
        }
    }
}

// ============================================================================
// Memory Safety Tests
// ============================================================================

test "CaveCarveMap memory allocation succeeds" {
    // This test verifies that allocation doesn't fail
    var carve_map = try CaveCarveMap.init(testing.allocator);
    defer carve_map.deinit();

    // Verify the allocation succeeded by checking we can use it
    carve_map.set(0, 0, 0, true);
    try testing.expectEqual(true, carve_map.get(0, 0, 0));
}
