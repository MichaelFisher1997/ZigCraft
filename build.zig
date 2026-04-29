const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    const enable_debug_shadows = b.option(bool, "debug_shadows", "Enable debug shadow visualization resources") orelse false;
    options.addOption(bool, "debug_shadows", enable_debug_shadows);

    const enable_imgui = b.option(bool, "imgui", "Enable Dear ImGui debug UI integration") orelse true;
    options.addOption(bool, "imgui", enable_imgui);
    const engine_ui_options = b.addOptions();
    engine_ui_options.addOption(bool, "imgui", enable_imgui);

    const smoke_test = b.option(bool, "smoke-test", "Enable automated smoke test mode (auto-loads world and exits)") orelse false;
    options.addOption(bool, "smoke_test", smoke_test);

    const chunk_debug_mode = b.option(bool, "chunk-debug-mode", "Disable LOD, water, caves, and decorations for chunk-only debugging") orelse false;
    options.addOption(bool, "chunk_debug_mode", chunk_debug_mode);

    const chunk_debug_enable = b.option([]const u8, "chunk-debug-enable", "Re-enable one subsystem in chunk-debug-mode (lod, water, caves, decorations)") orelse "";
    options.addOption([]const u8, "chunk_debug_enable", chunk_debug_enable);
    const world_worldgen_options = b.addOptions();
    world_worldgen_options.addOption(bool, "chunk_debug_mode", chunk_debug_mode);
    world_worldgen_options.addOption([]const u8, "chunk_debug_enable", chunk_debug_enable);
    const auto_world = b.option([]const u8, "auto-world", "Auto-open a world generator directly (normal, overworld, flat)") orelse "";
    options.addOption([]const u8, "auto_world", auto_world);

    const auto_preset = b.option([]const u8, "auto-preset", "Graphics preset to apply for auto-world launches (low, medium, high, ultra, extreme)") orelse "";
    options.addOption([]const u8, "auto_preset", auto_preset);

    const startup_diagnostic_seconds = b.option(u32, "startup-diagnostic-seconds", "Wait N seconds after auto-world startup, log chunk counts, and exit") orelse 0;
    options.addOption(u32, "startup_diagnostic_seconds", startup_diagnostic_seconds);
    const world_lod_options = b.addOptions();
    world_lod_options.addOption(u32, "startup_diagnostic_seconds", startup_diagnostic_seconds);
    const world_runtime_options = b.addOptions();
    world_runtime_options.addOption(u32, "startup_diagnostic_seconds", startup_diagnostic_seconds);
    world_runtime_options.addOption(bool, "world_runtime_module", true);

    const skip_present = b.option(bool, "skip-present", "Skip presentation (headless mode) to avoid driver crashes") orelse false;
    options.addOption(bool, "skip_present", skip_present);
    const engine_graphics_options = b.addOptions();
    engine_graphics_options.addOption(bool, "debug_shadows", enable_debug_shadows);
    engine_graphics_options.addOption(bool, "chunk_debug_mode", chunk_debug_mode);
    engine_graphics_options.addOption([]const u8, "chunk_debug_enable", chunk_debug_enable);
    engine_graphics_options.addOption(bool, "skip_present", skip_present);

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
    world_worldgen_options.addOption([]const u8, "shadow_test_variant", shadow_test_variant);

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
        .root_source_file = b.path("modules/engine-core/src/fs.zig"),
        .target = target,
        .optimize = optimize,
    });

    const sync_module = b.createModule(.{
        .root_source_file = b.path("modules/engine-core/src/sync.zig"),
        .target = target,
        .optimize = optimize,
    });

    const c_module = b.createModule(.{
        .root_source_file = b.path("src/c.zig"),
        .target = target,
        .optimize = optimize,
    });
    c_module.addIncludePath(b.path("libs/stb"));
    c_module.linkSystemLibrary("sdl3", .{});
    c_module.linkSystemLibrary("vulkan", .{});

    const engine_math = b.createModule(.{ .root_source_file = b.path("modules/engine-math/src/root.zig"), .target = target, .optimize = optimize });
    const engine_audio = b.createModule(.{ .root_source_file = b.path("modules/engine-audio/src/root.zig"), .target = target, .optimize = optimize });
    const engine_core = b.createModule(.{ .root_source_file = b.path("modules/engine-core/src/root.zig"), .target = target, .optimize = optimize });
    const engine_ecs = b.createModule(.{ .root_source_file = b.path("modules/engine-ecs/src/root.zig"), .target = target, .optimize = optimize });
    const engine_input = b.createModule(.{ .root_source_file = b.path("modules/engine-input/src/root.zig"), .target = target, .optimize = optimize });
    const engine_physics = b.createModule(.{ .root_source_file = b.path("modules/engine-physics/src/root.zig"), .target = target, .optimize = optimize });
    const engine_rhi = b.createModule(.{ .root_source_file = b.path("modules/engine-rhi/src/root.zig"), .target = target, .optimize = optimize });
    const engine_graphics = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/root.zig"), .target = target, .optimize = optimize });
    const engine_assets_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/assets_root.zig"), .target = target, .optimize = optimize });
    const engine_camera_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/camera_root.zig"), .target = target, .optimize = optimize });
    const engine_clouds_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/clouds_root.zig"), .target = target, .optimize = optimize });
    const engine_atmosphere_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/atmosphere_root.zig"), .target = target, .optimize = optimize });
    const engine_shadows_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/shadows_root.zig"), .target = target, .optimize = optimize });
    const engine_lighting_impl = b.createModule(.{ .root_source_file = b.path("modules/engine-graphics/src/lighting_root.zig"), .target = target, .optimize = optimize });
    const engine_assets = b.createModule(.{ .root_source_file = b.path("modules/engine-assets/src/root.zig"), .target = target, .optimize = optimize });
    const engine_camera = b.createModule(.{ .root_source_file = b.path("modules/engine-camera/src/root.zig"), .target = target, .optimize = optimize });
    const engine_clouds = b.createModule(.{ .root_source_file = b.path("modules/engine-clouds/src/root.zig"), .target = target, .optimize = optimize });
    const engine_atmosphere = b.createModule(.{ .root_source_file = b.path("modules/engine-atmosphere/src/root.zig"), .target = target, .optimize = optimize });
    const engine_shadows = b.createModule(.{ .root_source_file = b.path("modules/engine-shadows/src/root.zig"), .target = target, .optimize = optimize });
    const engine_lighting = b.createModule(.{ .root_source_file = b.path("modules/engine-lighting/src/root.zig"), .target = target, .optimize = optimize });
    const engine_ui = b.createModule(.{ .root_source_file = b.path("modules/engine-ui/src/root.zig"), .target = target, .optimize = optimize });
    const world_core = b.createModule(.{ .root_source_file = b.path("modules/world-core/src/root.zig"), .target = target, .optimize = optimize });
    const world_worldgen = b.createModule(.{ .root_source_file = b.path("modules/world-worldgen/src/root.zig"), .target = target, .optimize = optimize });
    const world_meshing = b.createModule(.{ .root_source_file = b.path("modules/world-meshing/src/root.zig"), .target = target, .optimize = optimize });
    const world_lod = b.createModule(.{ .root_source_file = b.path("modules/world-lod/src/root.zig"), .target = target, .optimize = optimize });
    const world_runtime = b.createModule(.{ .root_source_file = b.path("modules/world-runtime/src/root.zig"), .target = target, .optimize = optimize });
    const world_persistence = b.createModule(.{ .root_source_file = b.path("modules/world-persistence/src/root.zig"), .target = target, .optimize = optimize });

    addSharedImports(engine_math, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    addSharedImports(engine_audio, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_audio.addImport("engine-math", engine_math);
    engine_audio.addImport("engine-core", engine_core);
    addSharedImports(engine_core, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    addSharedImports(engine_ecs, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_ecs.addImport("engine-core", engine_core);
    engine_ecs.addImport("engine-math", engine_math);
    engine_ecs.addImport("engine-physics", engine_physics);
    engine_ecs.addImport("engine-rhi", engine_rhi);
    addSharedImports(engine_input, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_input.addImport("engine-core", engine_core);

    addSharedImports(engine_physics, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    addSharedImports(engine_rhi, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_rhi.addImport("engine-math", engine_math);
    engine_rhi.addImport("engine-core", engine_core);
    addSharedImports(engine_assets_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_assets_impl.addImport("engine-core", engine_core);
    engine_assets_impl.addImport("engine-rhi", engine_rhi);
    addSharedImports(engine_assets, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_assets.addImport("engine-assets-impl", engine_assets_impl);
    addSharedImports(engine_camera_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_camera_impl.addImport("engine-core", engine_core);
    engine_camera_impl.addImport("engine-input", engine_input);
    engine_camera_impl.addImport("engine-math", engine_math);
    addSharedImports(engine_camera, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_camera.addImport("engine-camera-impl", engine_camera_impl);
    addSharedImports(engine_clouds_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_clouds_impl.addImport("engine-math", engine_math);
    engine_clouds_impl.addImport("engine-rhi", engine_rhi);
    addSharedImports(engine_clouds, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_clouds.addImport("engine-clouds-impl", engine_clouds_impl);
    addSharedImports(engine_atmosphere_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_atmosphere_impl.addImport("engine-core", engine_core);
    engine_atmosphere_impl.addImport("engine-math", engine_math);
    engine_atmosphere_impl.addImport("engine-rhi", engine_rhi);
    addSharedImports(engine_atmosphere, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_atmosphere.addImport("engine-atmosphere-impl", engine_atmosphere_impl);
    addSharedImports(engine_shadows_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_shadows_impl.addImport("engine-core", engine_core);
    engine_shadows_impl.addImport("engine-math", engine_math);
    engine_shadows_impl.addImport("engine-rhi", engine_rhi);
    addSharedImports(engine_shadows, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_shadows.addImport("engine-shadows-impl", engine_shadows_impl);
    addSharedImports(engine_lighting_impl, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_lighting_impl.addImport("engine-core", engine_core);
    engine_lighting_impl.addImport("engine-math", engine_math);
    engine_lighting_impl.addImport("engine-rhi", engine_rhi);
    addSharedImports(engine_lighting, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_lighting.addImport("engine-lighting-impl", engine_lighting_impl);
    addSharedImports(engine_graphics, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_graphics.addImport("engine-assets", engine_assets);
    engine_graphics.addImport("engine-atmosphere", engine_atmosphere);
    engine_graphics.addImport("engine-camera", engine_camera);
    engine_graphics.addImport("engine-clouds", engine_clouds);
    engine_graphics.addImport("engine-lighting", engine_lighting);
    engine_graphics.addImport("engine-math", engine_math);
    engine_graphics.addImport("engine-core", engine_core);
    engine_graphics.addImport("engine-input", engine_input);
    engine_graphics.addImport("engine-rhi", engine_rhi);
    engine_graphics.addImport("engine-shadows", engine_shadows);
    engine_graphics.addOptions("engine_graphics_options", engine_graphics_options);
    addSharedImports(engine_ui, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    engine_ui.addImport("engine-math", engine_math);
    engine_ui.addImport("engine-core", engine_core);
    engine_ui.addImport("engine-rhi", engine_rhi);
    engine_ui.addOptions("engine_ui_options", engine_ui_options);
    engine_ui.linkSystemLibrary("sdl3", .{});
    engine_ui.linkSystemLibrary("vulkan", .{});
    if (enable_imgui) {
        engine_ui.linkSystemLibrary("cimgui", .{ .use_pkg_config = .force });
        engine_ui.link_libcpp = true;
    }
    addSharedImports(world_core, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    world_core.addImport("engine-core", engine_core);
    world_core.addImport("engine-math", engine_math);
    addSharedImports(world_worldgen, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    addSharedImports(world_meshing, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    world_meshing.addImport("engine-core", engine_core);
    world_meshing.addImport("engine-assets", engine_assets);
    world_meshing.addImport("engine-graphics", engine_graphics);
    world_meshing.addImport("engine-rhi", engine_rhi);
    world_meshing.addImport("world-core", world_core);
    addSharedImports(world_lod, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    world_lod.addImport("engine-core", engine_core);
    world_lod.addImport("engine-assets", engine_assets);
    world_lod.addImport("engine-graphics", engine_graphics);
    world_lod.addImport("engine-math", engine_math);
    world_lod.addImport("engine-rhi", engine_rhi);
    world_lod.addImport("world-meshing", world_meshing);
    world_lod.addImport("world-core", world_core);
    world_lod.addOptions("world_lod_options", world_lod_options);
    addSharedImports(world_persistence, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    world_persistence.addImport("engine-core", engine_core);
    world_persistence.addImport("world-core", world_core);
    world_worldgen.addImport("engine-core", engine_core);
    world_worldgen.addImport("engine-rhi", engine_rhi);
    world_worldgen.addImport("world-core", world_core);
    world_worldgen.addOptions("world_worldgen_options", world_worldgen_options);

    addSharedImports(world_runtime, zig_math, zig_noise, fs_module, sync_module, c_module, options);
    world_runtime.addImport("engine-core", engine_core);
    world_runtime.addImport("engine-assets", engine_assets);
    world_runtime.addImport("engine-lighting", engine_lighting);
    world_runtime.addImport("engine-shadows", engine_shadows);
    world_runtime.addImport("engine-graphics", engine_graphics);
    world_runtime.addImport("engine-math", engine_math);
    world_runtime.addImport("engine-physics", engine_physics);
    world_runtime.addImport("engine-rhi", engine_rhi);
    world_runtime.addImport("engine-ui", engine_ui);
    world_runtime.addImport("world-core", world_core);
    world_runtime.addImport("world-lod", world_lod);
    world_runtime.addImport("world-meshing", world_meshing);
    world_runtime.addImport("world-persistence", world_persistence);
    world_runtime.addImport("world-worldgen", world_worldgen);
    world_runtime.addOptions("world_runtime_options", world_runtime_options);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addImport("zig-math", zig_math);
    root_module.addImport("zig-noise", zig_noise);
    root_module.addImport("fs", fs_module);
    root_module.addImport("sync", sync_module);
    root_module.addImport("c", c_module);
    addProjectModuleImports(root_module, engine_math, engine_audio, engine_core, engine_ecs, engine_input, engine_physics, engine_rhi, engine_graphics, engine_assets, engine_camera, engine_clouds, engine_atmosphere, engine_shadows, engine_lighting, engine_ui, world_core, world_worldgen, world_meshing, world_lod, world_runtime, world_persistence);
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
    exe.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_truetype_impl.c"),
        .flags = &.{"-std=c99"},
    });

    exe.root_module.linkSystemLibrary("sdl3", .{});
    exe.root_module.linkSystemLibrary("vulkan", .{});
    if (enable_imgui) addCimgui(b, exe);

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
    benchmark_options.addOption(bool, "imgui", enable_imgui);
    benchmark_options.addOption(bool, "smoke_test", false);
    benchmark_options.addOption(bool, "chunk_debug_mode", false);
    benchmark_options.addOption([]const u8, "chunk_debug_enable", "");
    benchmark_options.addOption([]const u8, "auto_world", "");
    benchmark_options.addOption([]const u8, "auto_preset", "");
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
    benchmark_root_module.addImport("c", c_module);
    addProjectModuleImports(benchmark_root_module, engine_math, engine_audio, engine_core, engine_ecs, engine_input, engine_physics, engine_rhi, engine_graphics, engine_assets, engine_camera, engine_clouds, engine_atmosphere, engine_shadows, engine_lighting, engine_ui, world_core, world_worldgen, world_meshing, world_lod, world_runtime, world_persistence);
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
    benchmark_exe.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_truetype_impl.c"),
        .flags = &.{"-std=c99"},
    });

    benchmark_exe.root_module.linkSystemLibrary("sdl3", .{});
    benchmark_exe.root_module.linkSystemLibrary("vulkan", .{});
    if (enable_imgui) addCimgui(b, benchmark_exe);

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
    test_root_module.addImport("c", c_module);
    addProjectModuleImports(test_root_module, engine_math, engine_audio, engine_core, engine_ecs, engine_input, engine_physics, engine_rhi, engine_graphics, engine_assets, engine_camera, engine_clouds, engine_atmosphere, engine_shadows, engine_lighting, engine_ui, world_core, world_worldgen, world_meshing, world_lod, world_runtime, world_persistence);
    test_root_module.addOptions("build_options", options);

    const test_filters: []const []const u8 = if (b.option([]const u8, "test-filter", "Only run unit tests whose name contains this filter")) |filter|
        &.{filter}
    else if (b.args) |args|
        if (args.len >= 2 and std.mem.eql(u8, args[0], "--test-filter")) &.{args[1]} else &.{}
    else
        &.{};
    const exe_tests = b.addTest(.{
        .root_module = test_root_module,
        .filters = test_filters,
    });
    exe_tests.root_module.link_libc = true;
    exe_tests.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_truetype_impl.c"),
        .flags = &.{"-std=c99"},
    });
    exe_tests.root_module.linkSystemLibrary("sdl3", .{});
    exe_tests.root_module.linkSystemLibrary("vulkan", .{});
    exe_tests.root_module.addIncludePath(b.path("libs/stb"));
    if (enable_imgui) addCimgui(b, exe_tests);

    const test_step = b.step("test", "Run unit tests");
    const run_exe_tests = b.addRunArtifact(exe_tests);
    run_exe_tests.setEnvironmentVariable("ZIGCRAFT_LOG_LEVEL", "fatal");
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
    integration_root_module.addImport("c", c_module);
    addProjectModuleImports(integration_root_module, engine_math, engine_audio, engine_core, engine_ecs, engine_input, engine_physics, engine_rhi, engine_graphics, engine_assets, engine_camera, engine_clouds, engine_atmosphere, engine_shadows, engine_lighting, engine_ui, world_core, world_worldgen, world_meshing, world_lod, world_runtime, world_persistence);
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
    exe_integration_tests.root_module.addCSourceFile(.{
        .file = b.path("libs/stb/stb_truetype_impl.c"),
        .flags = &.{"-std=c99"},
    });
    exe_integration_tests.root_module.linkSystemLibrary("sdl3", .{});
    exe_integration_tests.root_module.linkSystemLibrary("vulkan", .{});
    if (enable_imgui) addCimgui(b, exe_integration_tests);

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
    robust_demo.root_module.addImport("c", c_module);
    robust_demo.root_module.addImport("engine-core", engine_core);
    robust_demo.root_module.addImport("engine-graphics", engine_graphics);

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
    integration_robustness.root_module.addImport("c", c_module);
    integration_robustness.root_module.addImport("engine-core", engine_core);
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

fn addCimgui(_: *std.Build, compile: *std.Build.Step.Compile) void {
    compile.root_module.linkSystemLibrary("cimgui", .{ .use_pkg_config = .force });
    compile.root_module.link_libcpp = true;
}

fn addSharedImports(module: *std.Build.Module, zig_math: *std.Build.Module, zig_noise: *std.Build.Module, fs_module: *std.Build.Module, sync_module: *std.Build.Module, c_module: *std.Build.Module, options: *std.Build.Step.Options) void {
    module.addImport("zig-math", zig_math);
    module.addImport("zig-noise", zig_noise);
    module.addImport("fs", fs_module);
    module.addImport("sync", sync_module);
    module.addImport("c", c_module);
    module.addOptions("build_options", options);
}

fn addProjectModuleImports(
    module: *std.Build.Module,
    engine_math: *std.Build.Module,
    engine_audio: *std.Build.Module,
    engine_core: *std.Build.Module,
    engine_ecs: *std.Build.Module,
    engine_input: *std.Build.Module,
    engine_physics: *std.Build.Module,
    engine_rhi: *std.Build.Module,
    engine_graphics: *std.Build.Module,
    engine_assets: *std.Build.Module,
    engine_camera: *std.Build.Module,
    engine_clouds: *std.Build.Module,
    engine_atmosphere: *std.Build.Module,
    engine_shadows: *std.Build.Module,
    engine_lighting: *std.Build.Module,
    engine_ui: *std.Build.Module,
    world_core: *std.Build.Module,
    world_worldgen: *std.Build.Module,
    world_meshing: *std.Build.Module,
    world_lod: *std.Build.Module,
    world_runtime: *std.Build.Module,
    world_persistence: *std.Build.Module,
) void {
    module.addImport("engine-math", engine_math);
    module.addImport("engine-audio", engine_audio);
    module.addImport("engine-core", engine_core);
    module.addImport("engine-ecs", engine_ecs);
    module.addImport("engine-input", engine_input);
    module.addImport("engine-physics", engine_physics);
    module.addImport("engine-rhi", engine_rhi);
    module.addImport("engine-graphics", engine_graphics);
    module.addImport("engine-assets", engine_assets);
    module.addImport("engine-camera", engine_camera);
    module.addImport("engine-clouds", engine_clouds);
    module.addImport("engine-atmosphere", engine_atmosphere);
    module.addImport("engine-shadows", engine_shadows);
    module.addImport("engine-lighting", engine_lighting);
    module.addImport("engine-ui", engine_ui);
    module.addImport("world-core", world_core);
    module.addImport("world-worldgen", world_worldgen);
    module.addImport("world-meshing", world_meshing);
    module.addImport("world-lod", world_lod);
    module.addImport("world-runtime", world_runtime);
    module.addImport("world-persistence", world_persistence);
}
