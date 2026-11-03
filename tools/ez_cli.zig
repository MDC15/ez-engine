const std = @import("std");

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ez: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

const Command = enum {
    new,
    delete,
    list,
    help,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.page_allocator;
    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer arg_it.deinit();
    _ = arg_it.skip();

    var cmd: Command = .help;
    var name: ?[]const u8 = null;
    var workspace: ?[]const u8 = null;

    const first = arg_it.next();
    if (first) |arg| {
        const command = if (std.mem.eql(u8, arg, "build"))
            arg_it.next() orelse fail("missing command. Usage: ez build <command>", .{})
        else
            arg;

        if (std.mem.eql(u8, command, "new")) {
            cmd = .new;
            name = arg_it.next();
        } else if (std.mem.eql(u8, command, "delete")) {
            cmd = .delete;
            name = arg_it.next();
        } else if (std.mem.eql(u8, command, "list")) {
            cmd = .list;
        } else if (std.mem.eql(u8, command, "help")) {
            cmd = .help;
        } else {
            fail("unknown command: {s}", .{command});
        }
    }

    // Process remaining args for options
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--workspace") or std.mem.eql(u8, arg, "-w")) {
            workspace = arg_it.next() orelse fail("missing value for --workspace", .{});
        } else if (std.mem.startsWith(u8, arg, "--workspace=")) {
            workspace = arg["--workspace=".len..];
            if (workspace.?.len == 0) fail("missing value for --workspace", .{});
        } else if (std.mem.startsWith(u8, arg, "-w=")) {
            workspace = arg["-w=".len..];
            if (workspace.?.len == 0) fail("missing value for --workspace", .{});
        } else if (std.mem.eql(u8, arg, "--name") or std.mem.eql(u8, arg, "-n")) {
            name = arg_it.next() orelse fail("missing value for --name", .{});
        } else if (std.mem.startsWith(u8, arg, "--name=")) {
            name = arg["--name=".len..];
            if (name.?.len == 0) fail("missing value for --name", .{});
        } else if (std.mem.startsWith(u8, arg, "-n=")) {
            name = arg["-n=".len..];
            if (name.?.len == 0) fail("missing value for --name", .{});
        } else {
            fail("unexpected argument: {s}", .{arg});
        }
    }

    switch (cmd) {
        .new => {
            const n = name orelse fail("missing project name. Usage: ez build new <name>", .{});
            try createProject(io, allocator, n, workspace);
        },
        .delete => {
            const n = name orelse fail("missing project name to delete. Usage: ez build delete <name>", .{});
            try deleteProject(io, allocator, n, workspace);
        },
        .list => {
            try listProjects(io, allocator, workspace);
        },
        .help => {
            showHelp();
        },
    }
}

fn showHelp() void {
    std.debug.print(
        \\ez-engine Project Manager
        \\
        \\Usage: ez build <command> [arguments] [options]
        \\
        \\Commands:
        \\  ez build new <name>       Create a new game project
        \\  ez build delete <name>    Delete a project
        \\  ez build list             List all projects in the workspace
        \\
        \\Options:
        \\  -w, --workspace <dir>  Set the workspace directory (default: ./projects)
        \\
    , .{});
}

fn getWorkspace(io: std.Io, allocator: std.mem.Allocator, workspace: ?[]const u8) ![]const u8 {
    if (workspace) |w| return allocator.dupe(u8, w);
    const cwd = try std.process.currentPathAlloc(io, allocator);
    return std.fs.path.join(allocator, &.{ cwd, "projects" });
}

fn slugify(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var last_dash = true;
    for (name) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        if (!ok or ((c == '-' or c == '_') and last_dash)) {
            if (!last_dash) try out.append(allocator, '-');
            last_dash = true;
            continue;
        }
        try out.append(allocator, c);
        last_dash = false;
    }
    while (out.items.len > 0 and (out.items[out.items.len - 1] == '-' or out.items[out.items.len - 1] == '_')) {
        out.items.len -= 1;
    }
    if (out.items.len == 0) return error.InvalidName;
    return out.toOwnedSlice(allocator);
}

fn createProject(io: std.Io, allocator: std.mem.Allocator, name: []const u8, workspace: ?[]const u8) !void {
    const ws = try getWorkspace(io, allocator, workspace);
    defer allocator.free(ws);

    const name_arg = try std.fmt.allocPrint(allocator, "-Dname={s}", .{name});
    defer allocator.free(name_arg);
    const ws_arg = try std.fmt.allocPrint(allocator, "-Dworkspace={s}", .{ws});
    defer allocator.free(ws_arg);

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build", "new", name_arg, ws_arg },
    }) catch |err| switch (err) {
        error.StreamTooLong => return err,
        else => fail("failed to create project: {s}", .{@errorName(err)}),
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    std.debug.print("{s}{s}", .{ result.stdout, result.stderr });

    switch (result.term) {
        .exited => |code| if (code != 0) fail("failed to create project (zig build new exited with code {d})", .{code}),
        else => fail("failed to create project", .{}),
    }
}

fn deleteProject(io: std.Io, allocator: std.mem.Allocator, name: []const u8, workspace: ?[]const u8) !void {
    const ws = try getWorkspace(io, allocator, workspace);
    defer allocator.free(ws);

    const slug = try slugify(allocator, name);
    defer allocator.free(slug);
    const target = try std.fs.path.join(allocator, &.{ ws, slug });
    defer allocator.free(target);

    std.debug.print("Deleting project at {s}...\n", .{target});

    const result = std.process.run(allocator, io, .{
        .argv = &.{ "rm", "-rf", target },
    }) catch |err| switch (err) {
        error.StreamTooLong => return err,
        else => fail("failed to delete project: {s}", .{@errorName(err)}),
    };
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .exited => |code| {
            if (code == 0) {
                std.debug.print("Project deleted.\n", .{});
            } else {
                std.debug.print("Failed to delete project.\n", .{});
            }
        },
        else => std.debug.print("Failed to delete project.\n", .{}),
    }
}

fn listProjects(io: std.Io, allocator: std.mem.Allocator, workspace: ?[]const u8) !void {
    const ws = try getWorkspace(io, allocator, workspace);

    var dir = std.Io.Dir.cwd().openDir(io, ws, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound) {
            std.debug.print("No workspace found at {s}\n", .{ws});
            return;
        }
        return err;
    };
    defer dir.close(io);

    std.debug.print("Projects in {s}:\n", .{ws});
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) {
            std.debug.print("  - {s}\n", .{entry.name});
        }
    }
}
