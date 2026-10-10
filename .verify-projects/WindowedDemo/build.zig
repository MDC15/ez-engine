const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64) return;

    const engine = b.dependency("ez_engine", .{ .target = target, .optimize = optimize });
    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize, .shared = true });
    const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });
    const dawn = b.dependency("dawn_x86_64_linux_gnu", .{});

    const glfw_window = b.createModule(.{
        .root_source_file = b.path("src/glfw_window.zig"),
        .target = target,
        .optimize = optimize,
    });
    glfw_window.addImport("game_lib", engine.module("game_lib"));
    glfw_window.addImport("zglfw", zglfw.module("root"));

    const game_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    game_module.addImport("game_lib", engine.module("game_lib"));
    game_module.addImport("zglfw", zglfw.module("root"));
    game_module.addImport("zgpu", zgpu.module("root"));
    game_module.addImport("glfw_window", glfw_window);

    const game = b.addExecutable(.{
        .name = "game",
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
