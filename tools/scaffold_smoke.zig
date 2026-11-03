const std = @import("std");

fn runCommand(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, cwd: []const u8) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = .{ .path = cwd },
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    std.debug.print("{s}{s}", .{ result.stdout, result.stderr });
    switch (result.term) {
        .exited => |code| if (code != 0) return error.SubprocessFailed,
        else => return error.SubprocessFailed,
    }
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, std.heap.page_allocator);
    defer args.deinit();
    _ = args.skip();
    const engine_root = args.next() orelse return error.MissingEnginePath;
    const zig_executable = args.next() orelse return error.MissingZigExecutable;
    const allocator = std.heap.page_allocator;
    const stamp = std.Io.Clock.awake.now(init.io).nanoseconds;
    const workspace = try std.fmt.allocPrint(
        allocator,
        "{s}/.zig-cache/scaffold-smoke-{d}",
        .{ engine_root, stamp },
    );
    defer allocator.free(workspace);
    const workspace_arg = try std.fmt.allocPrint(allocator, "-Dworkspace={s}", .{workspace});
    defer allocator.free(workspace_arg);
    const project = try std.fs.path.join(allocator, &.{ workspace, "P2Smoke" });
    defer allocator.free(project);
    defer std.Io.Dir.cwd().deleteTree(init.io, workspace) catch |err| {
        if (err != error.FileNotFound) {
            std.log.err("failed to remove generated smoke-test workspace {s}: {s}", .{ workspace, @errorName(err) });
        }
    };

    try runCommand(allocator, init.io, &.{
        zig_executable,
        "build",
        "new",
        "-Dname=P2Smoke",
        workspace_arg,
    }, engine_root);
    try runCommand(allocator, init.io, &.{ zig_executable, "build" }, project);
    try runCommand(allocator, init.io, &.{ zig_executable, "build", "test" }, project);
}
