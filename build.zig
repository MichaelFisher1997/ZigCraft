const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    const enable_debug_shadows = b.option(bool, "debug_shadows", "Enable debug shadow visualization resources") orelse false;
    options.addOption(bool, "debug_shadows", enable_debug_shadows);

    const smoke_test = b.option(bool, "smoke-test", "Enable automated smoke test mode (auto-loads world and exits)") orelse false;
    options.addOption(bool, "smoke_test", smoke_test);

    const chunk_debug_mode = b.option(bool, "chunk-debug-mode", "Disable LOD, water, caves, clouds, and decorations for chunk-only debugging") orelse false;
    options.addOption(bool, "chunk_debug_mode", chunk_debug_mode);

    const chunk_debug_enable = b.option([]const u8, "chunk-debug-enable", "Re-enable one subsystem in chunk-debug-mode (lod, water, caves, clouds, decorations)") orelse "";
    options.addOption([]const u8, "chunk_debug_enable", chunk_debug_enable);

    const auto_world = b.option([]const u8, "auto-world", "Auto-open a world generator directly (normal, overworld, flat)") orelse "";
    options.addOption([]const u8, "auto_world", auto_world);

    const startup_diagnostic_seconds = b.option(u32, "startup-diagnostic-seconds", "Wait N seconds after auto-world startup, log chunk counts, and exit") orelse 0;
    options.addOption(u32, "startup_diagnostic_seconds", startup_diagnostic_seconds);

    const skip_present = b.option(bool, "skip-present", "Skip presentation (headless mode) to avoid driver crashes") orelse false;
    options.addOption(bool, "skip_present", skip_present);

    const screenshot_path = b.option([]const u8, "screenshot-path", "Capture a PNG screenshot after N frames and exit") orelse "";
    options.addOption([]const u8, "screenshot_path", screenshot_path);

    const screenshot_frame = b.option(u32, "screenshot-frame", "Frame number to capture when screenshot-path is set") orelse 120;
    options.addOption(u32, "screenshot_frame", screenshot_frame);

    const screenshot_delay_seconds = b.option(u32, "screenshot-delay-seconds", "Seconds to wait after screenshot target is ready before capture") orelse 0;
    options.addOption(u32, "screenshot_delay_seconds", screenshot_delay_seconds);

    const shadow_test_scene = b.option(bool, "shadow-test-scene", "Launch the deterministic shadow/cave lighting test scene") orelse false;
    options.addOption(bool, "shadow_test_scene", shadow_test_scene);

    const shadow_test_variant = b.option([]const u8, "shadow-test-variant", "Shadow test scene variant (dug-cave, bend)") orelse "dug-cave";
    options.addOption([]const u8, "shadow_test_variant", shadow_test_variant);

    const benchmark = b.option(bool, "benchmark", "Enable benchmark mode") orelse false;
    options.addOption(bool, "benchmark", benchmark);

    const benchmark_preset = b.option([]const u8, "benchmark-preset", "Graphics preset to benchmark (low, medium, high, ultra, extreme)") orelse "medium";
    options.addOption([]const u8, "benchmark_preset", benchmark_preset);

    const benchmark_duration = b.option(u32, "benchmark-duration", "Benchmark duration in seconds") orelse 60;
    options.addOption(u32, "benchmark_duration", benchmark_duration);

    const benchmark_output = b.option([]const u8, "benchmark-output", "Benchmark JSON output path") orelse "benchmark_results.json";
    options.addOption([]const u8, "benchmark_output", benchmark_output);

    const zig_math = b.createModule(.{
        .root_source_file = b.path("libs/zig-math/math.zig"),
        .target = target,
        .optimize = optimize,
    });

    const zig_noise = b.createModule(.{
        .root_source_file = b.path("libs/zig-noise/noise.zig"),
        .target = target,
        .optimize = optimize,
    });

    const fs_module = b.createModule(.{
        .root_source_file = b.path("src/engine/core/fs.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sync_module = b.createModule(.{
        .root_source_file = b.path("src/engine/core/sync.zig"),
        .target = target,
        .optimize = optimize,
    });

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zig-math", zig_math);
    root_module.addImport("zig-noise", zig_noise);
    root_module.addImport("fs", fs_module);
    root_module.addImport("sync", sync_module);
    root_module.addOptions("build_options", options);
    root_module.addIncludePath(b.path("libs/stb"));

    const exe = b.addExecutable(.{
        .name = "zigcraft",
        .root_module = root_module,
    });

    exe.root_module.link_libc = true;
    exe.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });

    exe.root_module.linkSystemLibrary("sdl3", .{});
    exe.root_module.linkSystemLibrary("vulkan", .{});

    b.installArtifact(exe);

    const shader_cmd = b.addSystemCommand(&.{ "sh", "-c", "for f in assets/shaders/vulkan/*.vert assets/shaders/vulkan/*.frag assets/shaders/vulkan/*.comp; do glslangValidator -V \"$f\" -o \"$f.spv\"; done" });

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.step.dependOn(&shader_cmd.step);
    run_cmd.setCwd(b.path("."));

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const benchmark_options = b.addOptions();
    benchmark_options.addOption(bool, "debug_shadows", enable_debug_shadows);
    benchmark_options.addOption(bool, "smoke_test", false);
    benchmark_options.addOption(bool, "chunk_debug_mode", false);
    benchmark_options.addOption([]const u8, "chunk_debug_enable", "");
    benchmark_options.addOption([]const u8, "auto_world", "");
    benchmark_options.addOption(u32, "startup_diagnostic_seconds", 0);
    benchmark_options.addOption(bool, "skip_present", true);
    benchmark_options.addOption([]const u8, "screenshot_path", "");
    benchmark_options.addOption(u32, "screenshot_frame", 120);
    benchmark_options.addOption(u32, "screenshot_delay_seconds", 0);
    benchmark_options.addOption(bool, "shadow_test_scene", false);
    benchmark_options.addOption([]const u8, "shadow_test_variant", "dug-cave");
    benchmark_options.addOption(bool, "benchmark", true);
    benchmark_options.addOption([]const u8, "benchmark_preset", benchmark_preset);
    benchmark_options.addOption(u32, "benchmark_duration", benchmark_duration);
    benchmark_options.addOption([]const u8, "benchmark_output", benchmark_output);

    const benchmark_root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_root_module.addImport("zig-math", zig_math);
    benchmark_root_module.addImport("zig-noise", zig_noise);
    benchmark_root_module.addImport("fs", fs_module);
    benchmark_root_module.addImport("sync", sync_module);
    benchmark_root_module.addOptions("build_options", benchmark_options);
    benchmark_root_module.addIncludePath(b.path("libs/stb"));

    const benchmark_exe = b.addExecutable(.{
        .name = "benchmark",
        .root_module = benchmark_root_module,
    });

    benchmark_exe.root_module.link_libc = true;
    benchmark_exe.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });

    benchmark_exe.root_module.linkSystemLibrary("sdl3", .{});
    benchmark_exe.root_module.linkSystemLibrary("vulkan", .{});

    b.installArtifact(benchmark_exe);

    const benchmark_run_cmd = b.addRunArtifact(benchmark_exe);
    benchmark_run_cmd.step.dependOn(b.getInstallStep());
    benchmark_run_cmd.step.dependOn(&shader_cmd.step);
    benchmark_run_cmd.setCwd(b.path("."));

    const benchmark_step = b.step("benchmark", "Run benchmark harness");
    benchmark_step.dependOn(&benchmark_run_cmd.step);

    const test_root_module = b.createModule(.{
        .root_source_file = b.path("src/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_root_module.addImport("zig-math", zig_math);
    test_root_module.addImport("zig-noise", zig_noise);
    test_root_module.addImport("fs", fs_module);
    test_root_module.addImport("sync", sync_module);
    test_root_module.addOptions("build_options", options);

    const exe_tests = b.addTest(.{
        .root_module = test_root_module,
    });
    exe_tests.root_module.link_libc = true;
    exe_tests.root_module.linkSystemLibrary("sdl3", .{});
    exe_tests.root_module.linkSystemLibrary("vulkan", .{});
    exe_tests.root_module.addIncludePath(b.path("libs/stb"));

    const test_step = b.step("test", "Run unit tests");
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.step.dependOn(&shader_cmd.step);
    test_step.dependOn(&run_exe_tests.step);

    const integration_root_module = b.createModule(.{
        .root_source_file = b.path("src/integration_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    integration_root_module.addImport("zig-math", zig_math);
    integration_root_module.addImport("zig-noise", zig_noise);
    integration_root_module.addImport("fs", fs_module);
    integration_root_module.addImport("sync", sync_module);
    integration_root_module.addOptions("build_options", options);
    integration_root_module.addIncludePath(b.path("libs/stb"));

    const exe_integration_tests = b.addTest(.{
        .root_module = integration_root_module,
    });
    exe_integration_tests.root_module.link_libc = true;
    exe_integration_tests.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_image_impl.c"),
        .flags = &.{"-std=c99"},
    });
    exe_integration_tests.root_module.linkSystemLibrary("sdl3", .{});
    exe_integration_tests.root_module.linkSystemLibrary("vulkan", .{});

    const test_integration_step = b.step("test-integration", "Run integration smoke test");
    const run_integration_tests = b.addRunArtifact(exe_integration_tests);
    run_integration_tests.stdio_limit = .unlimited;
    run_integration_tests.step.dependOn(&shader_cmd.step);
    test_integration_step.dependOn(&run_integration_tests.step);

    // Robust Vulkan demo executable
    const robust_demo = b.addExecutable(.{
        .name = "robust-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/robust_demo.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    robust_demo.root_module.addOptions("build_options", options);
    robust_demo.root_module.addImport("fs", fs_module);
    robust_demo.root_module.addImport("sync", sync_module);

    robust_demo.root_module.link_libc = true;
    robust_demo.root_module.linkSystemLibrary("sdl3", .{});
    robust_demo.root_module.linkSystemLibrary("vulkan", .{});
    robust_demo.root_module.addIncludePath(b.path("libs/stb"));

    b.installArtifact(robust_demo);

    const integration_robustness = b.addExecutable(.{
        .name = "test-robustness",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/integration_test_robustness.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    integration_robustness.root_module.addOptions("build_options", options);
    integration_robustness.root_module.addImport("fs", fs_module);
    integration_robustness.root_module.addImport("sync", sync_module);
    integration_robustness.root_module.link_libc = true;
    integration_robustness.root_module.linkSystemLibrary("sdl3", .{}); // Needed for C imports if any

    const test_robustness_run = b.addRunArtifact(integration_robustness);
    // Ensure robust-demo is built first
    test_robustness_run.step.dependOn(&b.addInstallArtifact(robust_demo, .{}).step);

    const test_robustness_step = b.step("test-robustness", "Run robustness integration test");
    test_robustness_step.dependOn(&test_robustness_run.step);

    const run_robust_cmd = b.addRunArtifact(robust_demo);
    run_robust_cmd.step.dependOn(b.getInstallStep());

    const run_robust_step = b.step("run-robust", "Run the GPU robustness demo");
    run_robust_step.dependOn(&run_robust_cmd.step);

    const validate_vulkan_terrain_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/terrain.vert" });
    const validate_vulkan_terrain_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/terrain.frag" });
    const validate_vulkan_shadow_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/shadow.vert" });
    const validate_vulkan_shadow_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/shadow.frag" });
    const validate_vulkan_sky_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/sky.vert" });
    const validate_vulkan_sky_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/sky.frag" });
    const validate_vulkan_ui_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ui.vert" });
    const validate_vulkan_ui_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ui.frag" });
    const validate_vulkan_ui_tex_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ui_tex.vert" });
    const validate_vulkan_ui_tex_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ui_tex.frag" });
    const validate_vulkan_cloud_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/cloud.vert" });
    const validate_vulkan_cloud_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/cloud.frag" });
    const validate_vulkan_debug_shadow_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/debug_shadow.vert" });
    const validate_vulkan_debug_shadow_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/debug_shadow.frag" });
    const validate_vulkan_ssao_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ssao.vert" });
    const validate_vulkan_ssao_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ssao.frag" });
    const validate_vulkan_ssao_blur_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/ssao_blur.frag" });
    const validate_vulkan_g_pass_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/g_pass.frag" });
    const validate_vulkan_taa_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/taa.vert" });
    const validate_vulkan_taa_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/taa.frag" });
    const validate_vulkan_lpv_inject_comp = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/lpv_inject.comp" });
    const validate_vulkan_lpv_propagate_comp = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/lpv_propagate.comp" });
    const validate_vulkan_culling_comp = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/culling.comp" });
    const validate_vulkan_depth_pyramid_comp = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/depth_pyramid.comp" });
    const validate_vulkan_water_vert = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/water.vert" });
    const validate_vulkan_water_frag = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/water.frag" });
    const validate_vulkan_mesh_comp = b.addSystemCommand(&.{ "glslangValidator", "-V", "assets/shaders/vulkan/mesh.comp" });

    test_step.dependOn(&validate_vulkan_terrain_vert.step);
    test_step.dependOn(&validate_vulkan_terrain_frag.step);
    test_step.dependOn(&validate_vulkan_shadow_vert.step);
    test_step.dependOn(&validate_vulkan_shadow_frag.step);
    test_step.dependOn(&validate_vulkan_sky_vert.step);
    test_step.dependOn(&validate_vulkan_sky_frag.step);
    test_step.dependOn(&validate_vulkan_ui_vert.step);
    test_step.dependOn(&validate_vulkan_ui_frag.step);
    test_step.dependOn(&validate_vulkan_ui_tex_vert.step);
    test_step.dependOn(&validate_vulkan_ui_tex_frag.step);
    test_step.dependOn(&validate_vulkan_cloud_vert.step);
    test_step.dependOn(&validate_vulkan_cloud_frag.step);
    test_step.dependOn(&validate_vulkan_debug_shadow_vert.step);
    test_step.dependOn(&validate_vulkan_debug_shadow_frag.step);
    test_step.dependOn(&validate_vulkan_ssao_vert.step);
    test_step.dependOn(&validate_vulkan_ssao_frag.step);
    test_step.dependOn(&validate_vulkan_ssao_blur_frag.step);
    test_step.dependOn(&validate_vulkan_g_pass_frag.step);
    test_step.dependOn(&validate_vulkan_taa_vert.step);
    test_step.dependOn(&validate_vulkan_taa_frag.step);
    test_step.dependOn(&validate_vulkan_lpv_inject_comp.step);
    test_step.dependOn(&validate_vulkan_lpv_propagate_comp.step);
    test_step.dependOn(&validate_vulkan_culling_comp.step);
    test_step.dependOn(&validate_vulkan_depth_pyramid_comp.step);
    test_step.dependOn(&validate_vulkan_water_vert.step);
    test_step.dependOn(&validate_vulkan_water_frag.step);
    test_step.dependOn(&validate_vulkan_mesh_comp.step);
}
