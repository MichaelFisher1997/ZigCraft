const std = @import("std");
const ssao = @import("ssao_system.zig");

test "SSAOSystem noise generation" {
    var rng = std.Random.DefaultPrng.init(12345);
    const data1 = ssao.SSAOSystem.generateNoiseData(&rng);
    rng = std.Random.DefaultPrng.init(12345);
    const data2 = ssao.SSAOSystem.generateNoiseData(&rng);

    try std.testing.expectEqual(data1, data2);

    for (0..ssao.NOISE_SIZE * ssao.NOISE_SIZE) |i| {
        try std.testing.expectEqual(@as(u8, 0), data1[i * 4 + 2]);
        try std.testing.expectEqual(@as(u8, 255), data1[i * 4 + 3]);
    }
}

test "SSAOSystem kernel generation" {
    var rng = std.Random.DefaultPrng.init(67890);
    const samples1 = ssao.SSAOSystem.generateKernelSamples(&rng);
    rng = std.Random.DefaultPrng.init(67890);
    const samples2 = ssao.SSAOSystem.generateKernelSamples(&rng);

    for (0..ssao.KERNEL_SIZE) |i| {
        try std.testing.expectEqual(samples1[i][0], samples2[i][0]);
        try std.testing.expectEqual(samples1[i][1], samples2[i][1]);
        try std.testing.expectEqual(samples1[i][2], samples2[i][2]);
        try std.testing.expectEqual(samples1[i][3], samples2[i][3]);

        try std.testing.expect(samples1[i][2] >= 0.0);
        const len = @sqrt(samples1[i][0] * samples1[i][0] + samples1[i][1] * samples1[i][1] + samples1[i][2] * samples1[i][2]);
        try std.testing.expect(len <= 1.0);
    }
}
