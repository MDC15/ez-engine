const std = @import("std");

fn readBuildFile(b: *std.Build, path: std.Build.LazyPath) [:0]const u8 {
    const contents = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        path.getPath(b),
        b.allocator,
        .limited(256 * 1024),
    ) catch @panic("unable to read shader source file");
    return b.allocator.dupeZ(u8, contents) catch @panic("unable to allocate shader source");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Import only the decoder module; the package root also includes its own test suite.
    const zigimg = b.dependency("zigimg", .{ .target = target, .optimize = optimize });
    const zigimg_image = b.createModule(.{
        .root_source_file = zigimg.path("src/Image.zig"),
        .target = target,
        .optimize = optimize,
    });

    const input = b.createModule(.{
        .root_source_file = b.path("src/input/input.zig"),
        .target = target,
        .optimize = optimize,
    });
    const platform = b.createModule(.{
        .root_source_file = b.path("src/gfx/platform.zig"),
        .target = target,
        .optimize = optimize,
    });
    platform.addImport("ez_input", input);

    const game = b.addModule("ez_engine", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    game.addImport("ez_platform", platform);
    game.addImport("ez_input", input);
    game.addImport("ez_zigimg", zigimg_image);

    const library = b.addLibrary(.{
        .name = "ez_engine",
        .linkage = .static,
        .root_module = game,
    });
    b.installArtifact(library);

    const test_step = b.step("test", "Run unit tests");
    const library_tests = b.addTest(.{ .root_module = game, .use_llvm = true });
    test_step.dependOn(&b.addRunArtifact(library_tests).step);
    const input_tests = b.addTest(.{ .root_module = input, .use_llvm = true });
    test_step.dependOn(&b.addRunArtifact(input_tests).step);
    inline for (.{ "ecs_test.zig", "query_test.zig", "math_test.zig", "render_world_sprite_test.zig", "backend_iface_test.zig", "script_test.zig", "mover_test.zig", "input_test.zig", "loop_reclaim_test.zig", "physics_layers_test.zig", "scene_spawn_test.zig", "ecs_lifetime_test.zig", "audio_device_test.zig" }) |file| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}", .{file})),
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport("ez_engine", game);
        const tests = b.addTest(.{ .root_module = test_module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const editor_scene_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/scene/scene.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(editor_scene_tests).step);
    const app_init_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/app/init_stages.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(app_init_tests).step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Emit API documentation");
    docs_step.dependOn(&install_docs.step);

    const benchmark_module = b.createModule(.{
        .root_source_file = b.path("benchmarks/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    benchmark_module.addImport("ez_engine", game);
    const benchmark = b.addExecutable(.{
        .name = "ez-engine-bench",
        .root_module = benchmark_module,
    });
    const run_benchmark = b.addRunArtifact(benchmark);
    const benchmark_step = b.step("bench", "Run repeatable core performance benchmarks");
    benchmark_step.dependOn(&run_benchmark.step);

    const new_name = b.option([]const u8, "name", "Project name for `zig build new`");
    const new_workspace = b.option([]const u8, "workspace", "Projects folder for `zig build new` (default: projects/)");
    const scaffold = b.addExecutable(.{
        .name = "ez-new",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scaffold.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const new_run = b.addRunArtifact(scaffold);
    if (new_name) |n| {
        new_run.addArg("--name");
        new_run.addArg(n);
    }
    if (new_workspace) |w| {
        new_run.addArg("--workspace");
        new_run.addArg(w);
    }
    const new_step = b.step("new", "Scaffold a new game project (requires -Dname=...)");
    new_step.dependOn(&new_run.step);
    new_run.addArg("--engine");
    new_run.addArg(b.build_root.path orelse ".");

    const cli = b.addExecutable(.{
        .name = "ez",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/ez_cli.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(cli);
    const cli_run = b.addRunArtifact(cli);
    const cli_step = b.step("ez", "Run the project management CLI");
    cli_step.dependOn(&cli_run.step);

    const desktop_supported = target.result.os.tag == .linux and target.result.cpu.arch == .x86_64;
    if (!desktop_supported) {
        std.log.warn("desktop window, graphics, and PulseAudio examples require Linux x86_64; building core targets only", .{});
        return;
    }

    const scaffold_smoke = b.addExecutable(.{
        .name = "ez-scaffold-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/scaffold_smoke.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_scaffold_smoke = b.addRunArtifact(scaffold_smoke);
    run_scaffold_smoke.addArg(b.build_root.path orelse ".");
    run_scaffold_smoke.addArg(b.graph.zig_exe);
    const scaffold_smoke_step = b.step("scaffold-smoke", "Generate a clean game project and build its tests");
    scaffold_smoke_step.dependOn(&run_scaffold_smoke.step);

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
        .shared = true,
    });
    const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });
    const wgpu_backend = b.createModule(.{
        .root_source_file = b.path("src/gfx/wgpu/backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    wgpu_backend.addImport("ez_engine", game);
    wgpu_backend.addImport("zgpu", zgpu.module("root"));
    const glfw_window = b.createModule(.{
        .root_source_file = b.path("src/platform/glfw_window.zig"),
        .target = target,
        .optimize = optimize,
    });
    glfw_window.addImport("ez_engine", game);
    glfw_window.addImport("zglfw", zglfw.module("root"));
    const ez_app = b.createModule(.{
        .root_source_file = b.path("src/app/desktop.zig"),
        .target = target,
        .optimize = optimize,
    });
    ez_app.addImport("ez_engine", game);
    ez_app.addImport("zglfw", zglfw.module("root"));
    ez_app.addImport("zgpu", zgpu.module("root"));
    ez_app.addImport("glfw_window", glfw_window);
    ez_app.addImport("wgpu_backend", wgpu_backend);

    const gl_backend = b.createModule(.{
        .root_source_file = b.path("src/gfx/gl/backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    gl_backend.addImport("ez_engine", game);
    gl_backend.addImport("zglfw", zglfw.module("root"));
    const shader_sources = b.addOptions();
    shader_sources.addOption([:0]const u8, "gl_sprite_vertex", readBuildFile(b, b.path("assets/Shaders/gl_sprite.vert")));
    shader_sources.addOption([:0]const u8, "gl_sprite_fragment", readBuildFile(b, b.path("assets/Shaders/gl_sprite.frag")));
    shader_sources.addOption([:0]const u8, "gl_post_process_vertex", readBuildFile(b, b.path("assets/Shaders/gl_post_process.vert")));
    shader_sources.addOption([:0]const u8, "gl_post_process_fragment", readBuildFile(b, b.path("assets/Shaders/gl_post_process.frag")));
    shader_sources.addOption([:0]const u8, "wgpu_sprite", readBuildFile(b, b.path("assets/Shaders/wgpu_sprite.wgsl")));
    shader_sources.addOption([:0]const u8, "wgpu_post_process", readBuildFile(b, b.path("assets/Shaders/wgpu_post_process.wgsl")));
    gl_backend.addOptions("shader_sources", shader_sources);
    wgpu_backend.addOptions("shader_sources", shader_sources);
    const gl_app = b.createModule(.{
        .root_source_file = b.path("src/app/gl_desktop.zig"),
        .target = target,
        .optimize = optimize,
    });
    gl_app.addImport("ez_engine", game);
    gl_app.addImport("zglfw", zglfw.module("root"));
    gl_app.addImport("glfw_window", glfw_window);
    gl_app.addImport("gl_backend", gl_backend);
    const gl_module = b.createModule(.{
        .root_source_file = b.path("examples/gl/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    gl_module.addImport("ez_engine", game);
    gl_module.addImport("gl_app", gl_app);

    const gl = b.addExecutable(.{
        .name = "gl",
        .root_module = gl_module,
        .use_llvm = true,
    });
    gl.root_module.linkLibrary(zglfw.artifact("glfw"));
    gl.root_module.linkSystemLibrary("GL", .{});
    gl.root_module.linkSystemLibrary("X11", .{});

    const build_gl = b.step("gl", "Build the OpenGL sprite sample");
    build_gl.dependOn(&gl.step);
    const run_gl_command = b.addRunArtifact(gl);
    if (b.graph.environ_map.get("DRI_PRIME") == null) {
        run_gl_command.setEnvironmentVariable("DRI_PRIME", "1");
    }
    if (b.graph.environ_map.get("WSL_DISTRO_NAME") != null) {
        run_gl_command.setEnvironmentVariable("XDG_SESSION_TYPE", "x11");
        if (b.graph.environ_map.get("GALLIUM_DRIVER") == null) {
            run_gl_command.setEnvironmentVariable("GALLIUM_DRIVER", "d3d12");
        }
        if (b.graph.environ_map.get("MESA_D3D12_DEFAULT_ADAPTER_NAME") == null) {
            run_gl_command.setEnvironmentVariable("MESA_D3D12_DEFAULT_ADAPTER_NAME", "NVIDIA");
        }
    }
    const run_gl = b.step("gl-run", "Run the OpenGL sprite sample");
    run_gl.dependOn(&run_gl_command.step);

    const gl_pixel_test_module = b.createModule(.{
        .root_source_file = b.path("tests/gl_pixel_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    gl_pixel_test_module.addImport("ez_engine", game);
    gl_pixel_test_module.addImport("gl_app", gl_app);
    const gl_pixel_fixture = b.createModule(.{
        .root_source_file = b.path("tests/render_pixel_fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    gl_pixel_fixture.addImport("ez_engine", game);
    gl_pixel_test_module.addImport("render_pixel_fixture.zig", gl_pixel_fixture);
    const gl_pixel_tests = b.addTest(.{ .root_module = gl_pixel_test_module, .use_llvm = true });
    gl_pixel_tests.root_module.linkLibrary(zglfw.artifact("glfw"));
    gl_pixel_tests.root_module.linkSystemLibrary("GL", .{});
    gl_pixel_tests.root_module.linkSystemLibrary("X11", .{});
    const run_gl_pixel_tests = b.addRunArtifact(gl_pixel_tests);
    if (b.graph.environ_map.get("DRI_PRIME") == null) run_gl_pixel_tests.setEnvironmentVariable("DRI_PRIME", "1");
    if (b.graph.environ_map.get("WSL_DISTRO_NAME") != null) {
        run_gl_pixel_tests.setEnvironmentVariable("XDG_SESSION_TYPE", "x11");
        if (b.graph.environ_map.get("GALLIUM_DRIVER") == null) run_gl_pixel_tests.setEnvironmentVariable("GALLIUM_DRIVER", "d3d12");
        if (b.graph.environ_map.get("MESA_D3D12_DEFAULT_ADAPTER_NAME") == null) {
            run_gl_pixel_tests.setEnvironmentVariable("MESA_D3D12_DEFAULT_ADAPTER_NAME", "NVIDIA");
        }
    }
    const gl_pixel_test_step = b.step("gl-render-test", "Run OpenGL pixel-level rendering regression");
    gl_pixel_test_step.dependOn(&run_gl_pixel_tests.step);

    const wgpu_module = b.createModule(.{
        .root_source_file = b.path("examples/wgpu/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    wgpu_module.addImport("ez_engine", game);
    wgpu_module.addImport("zglfw", zglfw.module("root"));
    wgpu_module.addImport("zgpu", zgpu.module("root"));
    wgpu_module.addImport("wgpu_backend", wgpu_backend);
    wgpu_module.addImport("ez_app", ez_app);
    wgpu_module.addImport("glfw_window", glfw_window);

    const wgpu = b.addExecutable(.{
        .name = "wgpu",
        .root_module = wgpu_module,
        .use_llvm = true,
    });
    wgpu.root_module.linkLibrary(zglfw.artifact("glfw"));
    wgpu.root_module.linkLibrary(zgpu.artifact("zdawn"));
    wgpu.root_module.linkSystemLibrary("X11", .{});

    const dawn = b.lazyDependency("dawn_x86_64_linux_gnu", .{}) orelse return;
    wgpu.root_module.addLibraryPath(dawn.path(""));
    wgpu.root_module.linkSystemLibrary("dawn", .{});

    const build_wgpu = b.step("wgpu", "Build the WGPU sprite sample");
    build_wgpu.dependOn(&wgpu.step);
    const run_wgpu_command = b.addRunArtifact(wgpu);
    if (b.graph.environ_map.get("DRI_PRIME") == null) {
        run_wgpu_command.setEnvironmentVariable("DRI_PRIME", "1");
    }
    const run_wgpu = b.step("wgpu-run", "Run the WGPU sprite sample");
    run_wgpu.dependOn(&run_wgpu_command.step);

    const wgpu_pixel_test_module = b.createModule(.{
        .root_source_file = b.path("tests/wgpu_pixel_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    wgpu_pixel_test_module.addImport("ez_engine", game);
    wgpu_pixel_test_module.addImport("ez_app", ez_app);
    const wgpu_pixel_fixture = b.createModule(.{
        .root_source_file = b.path("tests/render_pixel_fixture.zig"),
        .target = target,
        .optimize = optimize,
    });
    wgpu_pixel_fixture.addImport("ez_engine", game);
    wgpu_pixel_test_module.addImport("render_pixel_fixture.zig", wgpu_pixel_fixture);
    const wgpu_pixel_tests = b.addTest(.{ .root_module = wgpu_pixel_test_module, .use_llvm = true });
    wgpu_pixel_tests.root_module.linkLibrary(zglfw.artifact("glfw"));
    wgpu_pixel_tests.root_module.linkLibrary(zgpu.artifact("zdawn"));
    wgpu_pixel_tests.root_module.linkSystemLibrary("X11", .{});
    wgpu_pixel_tests.root_module.addLibraryPath(dawn.path(""));
    wgpu_pixel_tests.root_module.linkSystemLibrary("dawn", .{});
    const run_wgpu_pixel_tests = b.addRunArtifact(wgpu_pixel_tests);
    if (b.graph.environ_map.get("DRI_PRIME") == null) run_wgpu_pixel_tests.setEnvironmentVariable("DRI_PRIME", "1");
    const wgpu_pixel_test_step = b.step("wgpu-render-test", "Run WGPU pixel-level rendering regression");
    wgpu_pixel_test_step.dependOn(&run_wgpu_pixel_tests.step);

    const audio_example = b.addExecutable(.{
        .name = "ez-audio",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/audio/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    audio_example.root_module.addImport("ez_engine", game);
    b.installArtifact(audio_example);
    const audio_example_step = b.step("audio-example", "Build the WAV playback example");
    audio_example_step.dependOn(&audio_example.step);
}
