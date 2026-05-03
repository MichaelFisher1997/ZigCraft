const std = @import("std");
const log = @import("engine-core").log;
const gen_interface = @import("generator_interface.zig");
const Generator = gen_interface.Generator;
const overworld = @import("worldgen-overworld");
const overworld_v2 = @import("worldgen-overworld-v2");
const flat_world = @import("worldgen-flat");
const shadow_test_world = @import("worldgen-test");
const worldgen_api = @import("worldgen-api");

pub const RegistryError = error{
    InvalidGeneratorIndex,
    InvalidGeneratorId,
    OutOfMemory,
};

pub const GeneratorType = struct {
    id: []const u8,
    aliases: []const []const u8 = &.{},
    info: gen_interface.GeneratorInfo,
    initFn: *const fn (seed: u64, allocator: std.mem.Allocator) RegistryError!Generator,
};

pub const GENERATORS = [_]GeneratorType{
    .{
        .id = overworld.descriptor.id,
        .aliases = overworld.descriptor.aliases,
        .info = overworld.descriptor.info,
        .initFn = initOverworld,
    },
    .{
        .id = flat_world.descriptor.id,
        .aliases = flat_world.descriptor.aliases,
        .info = flat_world.descriptor.info,
        .initFn = initFlatWorld,
    },
    .{
        .id = shadow_test_world.descriptor.id,
        .aliases = shadow_test_world.descriptor.aliases,
        .info = shadow_test_world.descriptor.info,
        .initFn = initShadowTestWorld,
    },
    .{
        .id = overworld_v2.descriptor.id,
        .aliases = overworld_v2.descriptor.aliases,
        .info = overworld_v2.descriptor.info,
        .initFn = initOverworldV2,
    },
};

fn initOverworld(seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    return overworld.descriptor.create(.{ .seed = seed, .allocator = allocator }) catch |err| return mapApiError(err);
}

fn initFlatWorld(seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    return flat_world.descriptor.create(.{ .seed = seed, .allocator = allocator }) catch |err| return mapApiError(err);
}

fn initShadowTestWorld(seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    return shadow_test_world.descriptor.create(.{ .seed = seed, .allocator = allocator }) catch |err| return mapApiError(err);
}

fn initOverworldV2(seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    return overworld_v2.descriptor.create(.{ .seed = seed, .allocator = allocator }) catch |err| return mapApiError(err);
}

fn mapApiError(err: worldgen_api.RegistryError) RegistryError {
    return switch (err) {
        error.InvalidGeneratorIndex => error.InvalidGeneratorIndex,
        error.InvalidGeneratorId => error.InvalidGeneratorId,
        error.OutOfMemory => error.OutOfMemory,
    };
}

pub fn getGeneratorCount() usize {
    return GENERATORS.len;
}

pub fn getGeneratorInfo(index: usize) gen_interface.GeneratorInfo {
    std.debug.assert(index < GENERATORS.len);
    return GENERATORS[index].info;
}

pub fn getGeneratorId(index: usize) []const u8 {
    std.debug.assert(index < GENERATORS.len);
    return GENERATORS[index].id;
}

pub fn findGeneratorIndex(id_or_alias: []const u8) ?usize {
    for (GENERATORS, 0..) |generator_type, index| {
        if (std.ascii.eqlIgnoreCase(id_or_alias, generator_type.id)) return index;
        for (generator_type.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(id_or_alias, alias)) return index;
        }
    }
    return null;
}

pub fn createGenerator(index: usize, seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    if (index >= GENERATORS.len) return error.InvalidGeneratorIndex;
    return GENERATORS[index].initFn(seed, allocator) catch |err| {
        log.log.err("Generator initialization failed for index {}: {}", .{ index, err });
        return err;
    };
}

pub fn createGeneratorById(id_or_alias: []const u8, seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    const index = findGeneratorIndex(id_or_alias) orelse return error.InvalidGeneratorId;
    return createGenerator(index, seed, allocator);
}
