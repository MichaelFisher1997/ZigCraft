const std = @import("std");
const testing = std.testing;
const presets = @import("json_presets.zig");
const PresetConfig = presets.PresetConfig;
const Settings = @import("data.zig").Settings;
const RenderDistancePreset = @import("../../engine/graphics/render_settings.zig").RenderDistancePreset;

test "getPresetName returns correct name for valid index" {
    const allocator = testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    const name = presets.getPresetName(0);
    try testing.expect(name.len > 0);
}

test "getPresetName returns CUSTOM for out of bounds index" {
    const allocator = testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    const name = presets.getPresetName(999);
    try testing.expectEqualStrings("CUSTOM", name);

    const name_at_len = presets.getPresetName(presets.graphics_presets.items.len);
    try testing.expectEqualStrings("CUSTOM", name_at_len);
}

test "getIndex returns 0 for first preset settings" {
    const allocator = testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    var settings = Settings{};
    presets.apply(&settings, 0);

    try testing.expectEqual(@as(usize, 0), presets.getIndex(&settings));
}

test "getIndex returns len (Custom) when settings don't match any preset" {
    const allocator = testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    var settings = Settings{};
    settings.shadow_quality = 99;

    try testing.expectEqual(presets.graphics_presets.items.len, presets.getIndex(&settings));
}

test "getIndex returns correct index for each preset when exactly matching" {
    const allocator = testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    for (0..presets.graphics_presets.items.len) |i| {
        var settings = Settings{};
        presets.apply(&settings, i);
        try testing.expectEqual(@as(usize, i), presets.getIndex(&settings));
    }
}

test "apply ignores out of bounds index" {
    const allocator = testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    var settings = Settings{};
    const original_shadow_quality = settings.shadow_quality;

    presets.apply(&settings, 999);

    try testing.expectEqual(original_shadow_quality, settings.shadow_quality);
}

test "apply sets all fields from preset" {
    const allocator = testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    if (presets.graphics_presets.items.len == 0) {
        return;
    }

    var settings = Settings{};
    presets.apply(&settings, 0);

    const preset = presets.graphics_presets.items[0];

    try testing.expectEqual(preset.shadow_quality, settings.shadow_quality);
    try testing.expectEqual(preset.shadow_distance, settings.shadow_distance);
    try testing.expectEqual(preset.shadow_pcf_samples, settings.shadow_pcf_samples);
    try testing.expectEqual(preset.shadow_cascade_blend, settings.shadow_cascade_blend);
    try testing.expectEqual(preset.shadow_caster_distance, settings.shadow_caster_distance);
    try testing.expectEqual(preset.pbr_enabled, settings.pbr_enabled);
    try testing.expectEqual(preset.pbr_quality, settings.pbr_quality);
    try testing.expectEqual(preset.msaa_samples, settings.msaa_samples);
    try testing.expectEqual(preset.taa_enabled, settings.taa_enabled);
    try testing.expectEqual(preset.taa_blend_factor, settings.taa_blend_factor);
    try testing.expectEqual(preset.taa_velocity_rejection, settings.taa_velocity_rejection);
    try testing.expectEqual(preset.anisotropic_filtering, settings.anisotropic_filtering);
    try testing.expectEqual(preset.max_texture_resolution, settings.max_texture_resolution);
    try testing.expectEqual(preset.cloud_shadows_enabled, settings.cloud_shadows_enabled);
    try testing.expectEqual(preset.exposure, settings.exposure);
    try testing.expectEqual(preset.saturation, settings.saturation);
    try testing.expectEqual(preset.volumetric_lighting_enabled, settings.volumetric_lighting_enabled);
    try testing.expectEqual(preset.volumetric_density, settings.volumetric_density);
    try testing.expectEqual(preset.volumetric_steps, settings.volumetric_steps);
    try testing.expectEqual(preset.volumetric_scattering, settings.volumetric_scattering);
    try testing.expectEqual(preset.ssao_enabled, settings.ssao_enabled);
    try testing.expectEqual(preset.lpv_quality_preset, settings.lpv_quality_preset);
    try testing.expectEqual(preset.lpv_enabled, settings.lpv_enabled);
    try testing.expectEqual(preset.lpv_intensity, settings.lpv_intensity);
    try testing.expectEqual(preset.lpv_cell_size, settings.lpv_cell_size);
    try testing.expectEqual(preset.lpv_grid_size, settings.lpv_grid_size);
    try testing.expectEqual(preset.lpv_propagation_iterations, settings.lpv_propagation_iterations);
    try testing.expectEqual(preset.lod_enabled, settings.lod_enabled);
    try testing.expectEqual(preset.render_distance, settings.render_distance);
    try testing.expectEqual(preset.render_distance_preset, settings.render_distance_preset);
    try testing.expectEqual(preset.fxaa_enabled, settings.fxaa_enabled);
    try testing.expectEqual(preset.bloom_enabled, settings.bloom_enabled);
    try testing.expectEqual(preset.bloom_intensity, settings.bloom_intensity);
}

test "apply sets fxaa_enabled to false when taa_enabled is true" {
    const allocator = testing.allocator;
    try presets.initPresets(allocator);
    defer presets.deinitPresets(allocator);

    if (presets.graphics_presets.items.len < 2) {
        return;
    }

    var settings = Settings{};
    settings.taa_enabled = false;
    settings.fxaa_enabled = true;

    presets.apply(&settings, 0);

    if (presets.graphics_presets.items[0].taa_enabled) {
        try testing.expect(!settings.fxaa_enabled);
    }
}
