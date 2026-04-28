const std = @import("std");
const log = @import("engine-core").log;
const gen_interface = @import("generator_interface.zig");
const Generator = gen_interface.Generator;
const overworld = @import("overworld_generator.zig");
const OverworldGenerator = overworld.OverworldGenerator;
const FlatWorldGenerator = @import("flat_world.zig").FlatWorldGenerator;
const ShadowTestWorldGenerator = @import("shadow_test_world.zig").ShadowTestWorldGenerator;
const deco_registry = @import("decoration_registry.zig");
const build_options = @import("world_worldgen_options");

pub const RegistryError = error{
    InvalidGeneratorIndex,
    OutOfMemory,
};

pub const GeneratorType = struct {
    info: gen_interface.GeneratorInfo,
    initFn: *const fn (seed: u64, allocator: std.mem.Allocator) RegistryError!Generator,
};

pub const GENERATORS = [_]GeneratorType{
    .{
        .info = OverworldGenerator.INFO,
        .initFn = initOverworld,
    },
    .{
        .info = FlatWorldGenerator.INFO,
        .initFn = initFlatWorld,
    },
    .{
        .info = ShadowTestWorldGenerator.INFO,
        .initFn = initShadowTestWorld,
    },
};

fn initOverworld(seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    const gen = allocator.create(OverworldGenerator) catch return error.OutOfMemory;
    const restore_water = chunkDebugRestoreEnabled("water") or chunkDebugRestoreEnabled("watergen");
    const restore_caves = chunkDebugRestoreEnabled("caves");
    const restore_decorations = chunkDebugRestoreEnabled("decorations");
    gen.* = if (build_options.chunk_debug_mode)
        OverworldGenerator.initWithParams(seed, allocator, deco_registry.StandardDecorationProvider.provider(), .{
            .terrain_shape = .{
                .sea_level = if (restore_water) 64 else -1,
                .ocean_threshold = if (restore_water) 0.35 else -1.0,
                .disable_caves = !restore_caves,
            },
            .basic_chunks_only = !restore_decorations,
        })
    else
        OverworldGenerator.init(seed, allocator, deco_registry.StandardDecorationProvider.provider());
    return gen.generator();
}

fn initFlatWorld(seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    const gen = allocator.create(FlatWorldGenerator) catch return error.OutOfMemory;
    gen.* = FlatWorldGenerator.init(seed, allocator);
    return gen.generator();
}

fn initShadowTestWorld(seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    const gen = allocator.create(ShadowTestWorldGenerator) catch return error.OutOfMemory;
    gen.* = ShadowTestWorldGenerator.init(seed, allocator);
    return gen.generator();
}

pub fn getGeneratorCount() usize {
    return GENERATORS.len;
}

pub fn getGeneratorInfo(index: usize) gen_interface.GeneratorInfo {
    std.debug.assert(index < GENERATORS.len);
    return GENERATORS[index].info;
}

pub fn createGenerator(index: usize, seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    if (index >= GENERATORS.len) return error.InvalidGeneratorIndex;
    return GENERATORS[index].initFn(seed, allocator) catch |err| {
        log.log.err("Generator initialization failed for index {}: {}", .{ index, err });
        return err;
    };
}

fn chunkDebugRestoreEnabled(name: []const u8) bool {
    if (!build_options.chunk_debug_mode) return false;

    var it = std.mem.tokenizeScalar(u8, build_options.chunk_debug_enable, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (std.ascii.eqlIgnoreCase(trimmed, name)) return true;
    }
    return false;
}
