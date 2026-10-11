const std = @import("std");

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
    inline for (.{ "ecs_test.zig", "query_test.zig", "math_test.zig", "render_world_sprite_test.zig", "backend_iface_test.zig", "script_test.zig", "mover_test.zig", "input_test.zig", "loop_reclaim_test.zig", "physics_layers_test.zig" }) |file| {
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

    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/sandbox/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_module.addImport("ez_engine", game);
    const example = b.addExecutable(.{
        .name = "sandbox",
        .root_module = example_module,
        .use_llvm = true,
    });
    const example_step = b.step("example", "Run the headless sandbox example");
    example_step.dependOn(&b.addRunArtifact(example).step);

    const install_docs = b.addInstallDirectory(.{
        .source_dir = library.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });
    const docs_step = b.step("docs", "Emit API documentation");
    docs_step.dependOn(&install_docs.step);

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

    const desktop_supported = target.result.os.tag == .linux and target.result.cpu.arch == .x86_64;
    if (!desktop_supported) {
        std.log.warn("the wgpu-clear sample requires Linux x86_64; only the library and tests are available", .{});
        return;
    }

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
    const wgpu_module = b.createModule(.{
        .root_source_file = b.path("examples/wgpu_clear/main.zig"),
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
        .name = "wgpu-clear",
        .root_module = wgpu_module,
        .use_llvm = true,
    });
    wgpu.root_module.linkLibrary(zglfw.artifact("glfw"));
    wgpu.root_module.linkLibrary(zgpu.artifact("zdawn"));
    wgpu.root_module.linkSystemLibrary("X11", .{});

    const dawn = b.lazyDependency("dawn_x86_64_linux_gnu", .{}) orelse return;
    wgpu.root_module.addLibraryPath(dawn.path(""));
    wgpu.root_module.linkSystemLibrary("dawn", .{});

    const build_wgpu = b.step("wgpu-clear", "Build the WGPU sprite sample");
    build_wgpu.dependOn(&wgpu.step);
    const run_wgpu = b.step("wgpu-clear-run", "Run the WGPU sprite sample");
    run_wgpu.dependOn(&b.addRunArtifact(wgpu).step);
}
