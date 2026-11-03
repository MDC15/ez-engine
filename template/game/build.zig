const std = @import("std");

fn readProjectFile(b: *std.Build, path: []const u8) [:0]const u8 {
    const contents = std.Io.Dir.cwd().readFileAlloc(
        b.graph.io,
        b.path(path).getPath(b),
        b.allocator,
        .limited(256 * 1024),
    ) catch @panic("unable to read project shader source file");
    return b.allocator.dupeZ(u8, contents) catch @panic("unable to allocate project shader source");
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64) {
        @panic("this starter requires Linux x86_64 (needs Dawn/WebGPU)");
    }

    const engine = b.dependency("ez_engine", .{ .target = target, .optimize = optimize });
    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize, .shared = true });
    const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });
    const dawn = b.dependency("dawn_x86_64_linux_gnu", .{});

    const wgpu_backend = b.createModule(.{
        .root_source_file = engine.path("src/gfx/wgpu/backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    wgpu_backend.addImport("ez_engine", engine.module("ez_engine"));
    wgpu_backend.addImport("zgpu", zgpu.module("root"));
    const shader_sources = b.addOptions();
    shader_sources.addOption([:0]const u8, "gl_sprite_vertex", readProjectFile(b, "Assets/Shaders/gl_sprite.vert"));
    shader_sources.addOption([:0]const u8, "gl_sprite_fragment", readProjectFile(b, "Assets/Shaders/gl_sprite.frag"));
    shader_sources.addOption([:0]const u8, "gl_post_process_vertex", readProjectFile(b, "Assets/Shaders/gl_post_process.vert"));
    shader_sources.addOption([:0]const u8, "gl_post_process_fragment", readProjectFile(b, "Assets/Shaders/gl_post_process.frag"));
    shader_sources.addOption([:0]const u8, "wgpu_sprite", readProjectFile(b, "Assets/Shaders/wgpu_sprite.wgsl"));
    shader_sources.addOption([:0]const u8, "wgpu_post_process", readProjectFile(b, "Assets/Shaders/wgpu_post_process.wgsl"));
    wgpu_backend.addOptions("shader_sources", shader_sources);

    const glfw_window = b.createModule(.{
        .root_source_file = engine.path("src/platform/glfw_window.zig"),
        .target = target,
        .optimize = optimize,
    });
    glfw_window.addImport("ez_engine", engine.module("ez_engine"));
    glfw_window.addImport("zglfw", zglfw.module("root"));

    const ez_app = b.createModule(.{
        .root_source_file = engine.path("src/app/desktop.zig"),
        .target = target,
        .optimize = optimize,
    });
    ez_app.addImport("ez_engine", engine.module("ez_engine"));
    ez_app.addImport("zglfw", zglfw.module("root"));
    ez_app.addImport("zgpu", zgpu.module("root"));
    ez_app.addImport("glfw_window", glfw_window);
    ez_app.addImport("wgpu_backend", wgpu_backend);

    const game_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    game_module.addImport("ez_engine", engine.module("ez_engine"));
    game_module.addImport("ez_app", ez_app);

    const game = b.addExecutable(.{
        .name = "@NAME@",
        .root_module = game_module,
        .use_llvm = true,
    });
    game.root_module.linkLibrary(zglfw.artifact("glfw"));
    game.root_module.linkLibrary(zgpu.artifact("zdawn"));
    game.root_module.linkSystemLibrary("X11", .{});
    game.root_module.addLibraryPath(dawn.path(""));
    game.root_module.linkSystemLibrary("dawn", .{});
    const run = b.addRunArtifact(game);
    const run_step = b.step("run", "Build and run the game");
    run_step.dependOn(&run.step);

    const tests_module = b.createModule(.{
        .root_source_file = b.path("tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests_module.addImport("ez_engine", engine.module("ez_engine"));
    const tests = b.addTest(.{ .root_module = tests_module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run game tests");
    test_step.dependOn(&run_tests.step);
}
