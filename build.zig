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
    platform.addImport("input_module", input);

    const game = b.addModule("game_lib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    game.addImport("platform", platform);
    game.addImport("input_module", input);
    game.addImport("zigimg_image", zigimg_image);

    const library = b.addLibrary(.{
        .name = "game_lib",
        .linkage = .static,
        .root_module = game,
    });
    b.installArtifact(library);

    const test_step = b.step("test", "Run unit tests");
    const library_tests = b.addTest(.{ .root_module = game, .use_llvm = true });
    test_step.dependOn(&b.addRunArtifact(library_tests).step);
    inline for (.{ "ecs_test.zig", "query_test.zig", "math_test.zig", "render_world_sprite_test.zig" }) |file| {
        const test_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("tests/{s}", .{file})),
            .target = target,
            .optimize = optimize,
        });
        test_module.addImport("game_lib", game);
        const tests = b.addTest(.{ .root_module = test_module });
        test_step.dependOn(&b.addRunArtifact(tests).step);
    }
    const editor_scene_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("examples/editor/scene.zig"),
        .target = target,
        .optimize = optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(editor_scene_tests).step);

    const example_module = b.createModule(.{
        .root_source_file = b.path("examples/sandbox/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    example_module.addImport("game_lib", game);
    const example = b.addExecutable(.{
        .name = "sandbox",
        .root_module = example_module,
        .use_llvm = true,
    });
    const example_step = b.step("example", "Run the headless sandbox example");
    example_step.dependOn(&b.addRunArtifact(example).step);

    if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64) return;

    const zglfw = b.dependency("zglfw", .{
        .target = target,
        .optimize = optimize,
        .shared = true,
    });
    const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });
    const wgpu_module = b.createModule(.{
        .root_source_file = b.path("examples/wgpu_clear/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    wgpu_module.addImport("game_lib", game);
    wgpu_module.addImport("zglfw", zglfw.module("root"));
    wgpu_module.addImport("zgpu", zgpu.module("root"));
    const glfw_window = b.createModule(.{
        .root_source_file = b.path("src/platform/glfw_window.zig"),
        .target = target,
        .optimize = optimize,
    });
    glfw_window.addImport("game_lib", game);
    glfw_window.addImport("zglfw", zglfw.module("root"));
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

    const zgui = b.dependency("zgui", .{ .backend = .glfw_wgpu });
    const editor_module = b.createModule(.{
        .root_source_file = b.path("examples/editor/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    editor_module.addImport("zglfw", zglfw.module("root"));
    editor_module.addImport("zgpu", zgpu.module("root"));
    editor_module.addImport("zgui", zgui.module("root"));
    editor_module.addImport("game_lib", game);
    editor_module.addImport("glfw_window", glfw_window);

    const editor = b.addExecutable(.{
        .name = "ez-engine-editor",
        .root_module = editor_module,
        .use_llvm = true,
    });
    editor.root_module.linkLibrary(zglfw.artifact("glfw"));
    editor.root_module.linkLibrary(zgpu.artifact("zdawn"));
    editor.root_module.linkLibrary(zgui.artifact("imgui"));
    editor.root_module.linkSystemLibrary("X11", .{});
    editor.root_module.addLibraryPath(dawn.path(""));
    editor.root_module.linkSystemLibrary("dawn", .{});

    const install_editor = b.addInstallArtifact(editor, .{});
    const build_editor = b.step("editor", "Build the editor");
    build_editor.dependOn(&install_editor.step);
    const run_editor = b.step("editor-run", "Run the editor (requires WSLg on WSL)");
    run_editor.dependOn(&b.addRunArtifact(editor).step);
}
