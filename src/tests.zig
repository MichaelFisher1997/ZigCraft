//! Test aggregator for ZigCraft.
//!
//! This file imports all test modules. Individual tests live in their
//! respective modules (math_tests, noise_tests, etc.) or in dedicated
//! test files alongside the source they validate.
//!
//! Run with: zig build test

const std = @import("std");

pub const std_options: std.Options = .{
    .log_level = .err,
};

test {
    // Inline module test files (Issue #551)
    _ = @import("math_tests.zig");
    _ = @import("noise_tests.zig");
    _ = @import("worldgen_tests.zig");
    _ = @import("shadow_cascade_tests.zig");
    _ = @import("interface_mock_tests.zig");
    _ = @import("world_inline_tests.zig");

    // ECS and engine tests
    _ = @import("ecs_tests.zig");
    _ = @import("engine/graphics/vulkan_device.zig");
    _ = @import("engine/graphics/vulkan_device_tests.zig");
    _ = @import("engine/graphics/vulkan_device_internal_tests.zig");
    _ = @import("engine/graphics/vulkan_device_edge_tests.zig");
    _ = @import("engine/graphics/vulkan/rhi_state_control_tests.zig");
    _ = @import("engine/graphics/vulkan/ssao_system_tests.zig");
    _ = @import("engine/graphics/vulkan/pipeline_manager_tests.zig");
    _ = @import("engine/graphics/vulkan/pipeline_manager_edge_tests.zig");
    _ = @import("engine/graphics/vulkan/pipeline_specialized_tests.zig");
    _ = @import("engine/graphics/vulkan/pipeline_specialized_edge_tests.zig");
    _ = @import("engine/graphics/vulkan/descriptor_bindings_tests.zig");
    _ = @import("engine/graphics/vulkan/descriptor_bindings_edge_tests.zig");
    _ = @import("engine/graphics/vulkan/descriptor_manager_tests.zig");
    _ = @import("engine/graphics/vulkan/descriptor_manager_error_tests.zig");
    _ = @import("engine/graphics/vulkan/shader_registry_tests.zig");
    _ = @import("engine/graphics/vulkan/frame_manager_tests.zig");
    _ = @import("engine/graphics/vulkan/render_pass_manager_tests.zig");
    _ = @import("engine/graphics/vulkan/rhi_frame_orchestration_tests.zig");
    _ = @import("engine/graphics/vulkan/rhi_pass_orchestration_tests.zig");
    _ = @import("engine/graphics/vulkan/vulkan_frame_tests.zig");
    _ = @import("engine/graphics/vulkan/utils_tests.zig");
    _ = @import("vulkan_tests.zig");
    _ = @import("engine/graphics/rhi_tests.zig");
    _ = @import("engine/graphics/cloud_system.zig");
    _ = @import("engine/graphics/shadow_cascade_tests.zig");
    _ = @import("engine/graphics/shadow_tests.zig");
    _ = @import("engine/graphics/shadow_system_tests.zig");
    _ = @import("engine/math/utils_tests.zig");
    _ = @import("engine/math/frustum_tests.zig");
    _ = @import("engine/math/mat4_tests.zig");
    _ = @import("world/world_tests.zig");
    _ = @import("world/worldgen/schematics.zig");
    _ = @import("world/worldgen/tree_registry.zig");
    _ = @import("world/worldgen/caves_tests.zig");
    _ = @import("world/worldgen/coastal_generator_tests.zig");
    _ = @import("world/worldgen/biome_registry_tests.zig");
    _ = @import("world/worldgen/biome_selector_tests.zig");
    _ = @import("world/worldgen/height_sampler_tests.zig");
    _ = @import("world/worldgen/terrain_shape_generator_tests.zig");
    _ = @import("world/lod_manager_tests.zig");
    _ = @import("world/lod_seam.zig");
    _ = @import("world/lod_renderer.zig");
    _ = @import("engine/atmosphere/tests.zig");
    _ = @import("game/settings/tests.zig");
    _ = @import("game/input_settings.zig");
    _ = @import("game/player_tests.zig");
    _ = @import("game/inventory_tests.zig");
    _ = @import("game/screen_tests.zig");
    _ = @import("game/world_list_tests.zig");
    _ = @import("game/input_mapper_tests.zig");
    _ = @import("game/settings/persistence_tests.zig");
    _ = @import("world/persistence/region_file.zig");
    _ = @import("world/persistence/chunk_serializer.zig");
    _ = @import("world/persistence/level_data.zig");
    _ = @import("world/persistence/save_manager.zig");
    _ = @import("world/meshing/quadric_simplifier.zig");
    _ = @import("world/chunk_storage_tests.zig");
    _ = @import("world/chunk_storage_extended_tests.zig");
    _ = @import("world/block_tests.zig");
    _ = @import("world/block_registry_tests.zig");
    _ = @import("world/block_biome_tests.zig");
    _ = @import("world/chunk_tests.zig");
    _ = @import("world/chunk_fill_tests.zig");
    _ = @import("world/chunk_mesh_tests.zig");
    _ = @import("world/chunk_storage_interface_tests.zig");
    _ = @import("world/biome_and_block_tests.zig");
    _ = @import("world/packed_light_tests.zig");
    _ = @import("world/meshing/boundary_tests.zig");
    _ = @import("world/world_coord_tests.zig");
    _ = @import("world/world_block_fill_tests.zig");
    _ = @import("world/world_interface_vtable_tests.zig");
    _ = @import("world/world_mutation.zig");
}
