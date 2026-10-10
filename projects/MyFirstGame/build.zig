const std = @import("std");

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
        .name = "MyFirstGame",
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
}
