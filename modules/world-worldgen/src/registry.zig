const std = @import("std");
const log = @import("engine-core").log;
const gen_interface = @import("generator_interface.zig");
const Generator = gen_interface.Generator;
const GeneratorDescriptor = gen_interface.GeneratorDescriptor;
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

pub const DESCRIPTORS = [_]*const GeneratorDescriptor{
    &overworld.descriptor,
    &flat_world.descriptor,
    &shadow_test_world.descriptor,
    &overworld_v2.descriptor,
};

fn mapApiError(err: worldgen_api.RegistryError) RegistryError {
    return switch (err) {
        error.InvalidGeneratorIndex => error.InvalidGeneratorIndex,
        error.InvalidGeneratorId => error.InvalidGeneratorId,
        error.OutOfMemory => error.OutOfMemory,
    };
}

pub fn getGeneratorCount() usize {
    return DESCRIPTORS.len;
}

pub fn getGeneratorInfo(index: usize) gen_interface.GeneratorInfo {
    std.debug.assert(index < DESCRIPTORS.len);
    return DESCRIPTORS[index].info;
}

pub fn getGeneratorId(index: usize) []const u8 {
    std.debug.assert(index < DESCRIPTORS.len);
    return DESCRIPTORS[index].id;
}

pub fn findGeneratorIndex(id_or_alias: []const u8) ?usize {
    for (DESCRIPTORS, 0..) |descriptor, index| {
        if (std.ascii.eqlIgnoreCase(id_or_alias, descriptor.id)) return index;
        for (descriptor.aliases) |alias| {
            if (std.ascii.eqlIgnoreCase(id_or_alias, alias)) return index;
        }
    }
    return null;
}

pub fn createGenerator(index: usize, seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    if (index >= DESCRIPTORS.len) return error.InvalidGeneratorIndex;
    return DESCRIPTORS[index].create(.{ .seed = seed, .allocator = allocator }) catch |api_err| {
        const err = mapApiError(api_err);
        log.log.err("Generator initialization failed for index {}: {}", .{ index, err });
        return err;
    };
}

pub fn createGeneratorById(id_or_alias: []const u8, seed: u64, allocator: std.mem.Allocator) RegistryError!Generator {
    const index = findGeneratorIndex(id_or_alias) orelse return error.InvalidGeneratorId;
    return createGenerator(index, seed, allocator);
}
