//! Project scaffolding: `zig build new -Dname=Foo [-Dworkspace=DIR]`.
//! Copies `template/game/`, substitutes placeholders, copies assets and
//! discovers the package fingerprint. Refuses to overwrite an existing dir.

const std = @import("std");

const TemplateFile = struct {
    src: []const u8,
    dst: []const u8,
    /// Which placeholders to expand in this file.
    name: bool = false,
    title: bool = false,
    engine_path: bool = false,
};

const template_files = [_]TemplateFile{
    .{ .src = "build.zig", .dst = "build.zig", .name = true },
    .{ .src = "build.zig.zon", .dst = "build.zig.zon", .name = true, .engine_path = true },
    .{ .src = "src/main.zig", .dst = "src/main.zig", .title = true },
    .{ .src = "src/scripts/player.zig", .dst = "src/scripts/player.zig" },
    .{ .src = "src/scripts/pickup.zig", .dst = "src/scripts/pickup.zig" },
    .{ .src = "project.json", .dst = "project.json", .name = true },
    .{ .src = "Scenes/editor_scene.json", .dst = "Scenes/editor_scene.json" },
    .{ .src = "README.md", .dst = "README.md", .name = true },
    .{ .src = ".gitignore", .dst = ".gitignore" },
};

fn fail(comptime fmt: []const u8, args: anytype) noreturn {
    std.debug.print("ez-new: " ++ fmt ++ "\n", args);
    std.process.exit(1);
}

/// Pure path math: relative path from absolute `from` to absolute `to`.
fn relativeTo(allocator: std.mem.Allocator, from: []const u8, to: []const u8) ![]u8 {
    var from_segs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer from_segs.deinit(allocator);
    var to_segs: std.ArrayListUnmanaged([]const u8) = .empty;
    defer to_segs.deinit(allocator);
    var it = std.mem.splitScalar(u8, from, '/');
    while (it.next()) |seg| {
        if (seg.len > 0) try from_segs.append(allocator, seg);
    }
    it = std.mem.splitScalar(u8, to, '/');
    while (it.next()) |seg| {
        if (seg.len > 0) try to_segs.append(allocator, seg);
    }
    var common: usize = 0;
    while (common < from_segs.items.len and common < to_segs.items.len and
        std.mem.eql(u8, from_segs.items[common], to_segs.items[common])) : (common += 1)
    {}
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    for (common..from_segs.items.len) |_| try out.appendSlice(allocator, "../");
    for (to_segs.items[common..], 0..) |seg, idx| {
        if (idx > 0) try out.append(allocator, '/');
        try out.appendSlice(allocator, seg);
    }
    if (out.items.len == 0) try out.appendSlice(allocator, ".");
    return out.toOwnedSlice(allocator);
}

fn absolutize(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    return std.fs.path.join(allocator, &.{ cwd, path });
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

fn identifier(allocator: std.mem.Allocator, slug: []const u8) ![]u8 {
    var out = try allocator.dupe(u8, slug);
    for (out) |*c| {
        if (c.* == '-') c.* = '_';
    }
    if (std.ascii.isDigit(out[0])) {
        const prefixed = try std.mem.concat(allocator, u8, &.{ "game_", out });
        allocator.free(out);
        out = prefixed;
    }
    if (out.len > 32) {
        allocator.free(out);
        return error.NameTooLong;
    }
    return out;
}

fn substitute(allocator: std.mem.Allocator, text: []const u8, file: TemplateFile, name: []const u8, title: []const u8, engine_path: []const u8) ![]u8 {
    var result = try allocator.dupe(u8, text);
    errdefer allocator.free(result);
    if (file.name) {
        const next = try std.mem.replaceOwned(u8, allocator, result, "@NAME@", name);
        allocator.free(result);
        result = next;
        // build.zig.zon uses an enum literal (.name) which cannot contain
        // "@NAME@" and still parse, so the template uses a valid identifier
        // placeholder there instead.
        const next_ident = try std.mem.replaceOwned(u8, allocator, result, "ez_template_game", name);
        allocator.free(result);
        result = next_ident;
    }
    if (file.title) {
        const next = try std.mem.replaceOwned(u8, allocator, result, "@TITLE@", title);
        allocator.free(result);
        result = next;
    }
    if (file.engine_path) {
        const next = try std.mem.replaceOwned(u8, allocator, result, "@ENGINE_PATH@", engine_path);
        allocator.free(result);
        result = next;
    }
    return result;
}

fn patchFingerprint(io: std.Io, allocator: std.mem.Allocator, target: []const u8) !void {
    const run = std.process.run(allocator, io, .{
        .argv = &.{ "zig", "build", "--help" },
        .cwd = .{ .path = target },
    }) catch return;
    defer allocator.free(run.stdout);
    defer allocator.free(run.stderr);
    const output = try std.mem.concat(allocator, u8, &.{ run.stdout, run.stderr });
    defer allocator.free(output);
    const marker = "suggested value: ";
    const at = std.mem.indexOf(u8, output, marker) orelse return;
    var end = at + marker.len;
    while (end < output.len and (std.ascii.isHex(output[end]) or (output[end] == 'x' and end == at + marker.len + 1))) : (end += 1) {}
    const value = output[at + marker.len .. end];
    if (value.len != 18) return;
    const zon_path = try std.fs.path.join(allocator, &.{ target, "build.zig.zon" });
    defer allocator.free(zon_path);
    const zon = try std.Io.Dir.cwd().readFileAlloc(io, zon_path, allocator, .limited(64 * 1024));
    defer allocator.free(zon);
    const anchor = "    .version = \"0.1.0\",\n";
    const pos = std.mem.indexOf(u8, zon, anchor) orelse return;
    var patched: std.ArrayListUnmanaged(u8) = .empty;
    errdefer patched.deinit(allocator);
    try patched.appendSlice(allocator, zon[0 .. pos + anchor.len]);
    const line = try std.fmt.allocPrint(allocator, "    .fingerprint = {s},\n", .{value});
    defer allocator.free(line);
    try patched.appendSlice(allocator, line);
    try patched.appendSlice(allocator, zon[pos + anchor.len ..]);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = zon_path, .data = patched.items });
    patched.deinit(allocator);
}

fn copyAssetTree(io: std.Io, allocator: std.mem.Allocator, source_path: []const u8, destination_path: []const u8) !void {
    try std.Io.Dir.cwd().createDirPath(io, destination_path);
    var source_dir = try std.Io.Dir.cwd().openDir(io, source_path, .{ .iterate = true });
    defer source_dir.close(io);
    var iterator = source_dir.iterate();
    while (try iterator.next(io)) |entry| {
        const source_entry = try std.fs.path.join(allocator, &.{ source_path, entry.name });
        defer allocator.free(source_entry);
        const destination_entry = try std.fs.path.join(allocator, &.{ destination_path, entry.name });
        defer allocator.free(destination_entry);
        switch (entry.kind) {
            .directory => try copyAssetTree(io, allocator, source_entry, destination_entry),
            .file => try std.Io.Dir.copyFileAbsolute(source_entry, destination_entry, io, .{}),
            else => {},
        }
    }
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.page_allocator;
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    defer arg_it.deinit();
    _ = arg_it.skip();
    var name: ?[]const u8 = null;
    var workspace: ?[]const u8 = null;
    var engine: ?[]const u8 = null;
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--name")) {
            name = arg_it.next() orelse fail("missing value for --name", .{});
        } else if (std.mem.eql(u8, arg, "--workspace")) {
            workspace = arg_it.next() orelse fail("missing value for --workspace", .{});
        } else if (std.mem.eql(u8, arg, "--engine")) {
            engine = arg_it.next() orelse fail("missing value for --engine", .{});
        } else fail("unknown argument: {s}", .{arg});
    }
    const display = name orelse fail("missing required --name", .{});
    const engine_arg = engine orelse fail("missing required --engine", .{});
    const slug = slugify(allocator, display) catch fail("project name must contain letters or numbers", .{});
    const ident = identifier(allocator, slug) catch fail("project name must fit a 32-char Zig identifier", .{});

    const cwd = try std.process.currentPathAlloc(io, allocator);
    const root = try absolutize(allocator, cwd, engine_arg);
    const ws = workspace orelse try std.fs.path.join(allocator, &.{ root, "projects" });
    const ws_abs = try absolutize(allocator, cwd, ws);
    const target = try std.fs.path.join(allocator, &.{ ws_abs, slug });
    std.Io.Dir.cwd().access(io, target, .{}) catch |err| switch (err) {
        error.FileNotFound => {},
        else => fail("cannot stat {s}: {}", .{ target, err }),
    };
    if (std.Io.Dir.cwd().access(io, target, .{})) {
        fail("project directory already exists: {s}", .{target});
    } else |_| {}

    const engine_path = try relativeTo(allocator, target, root);

    const template_dir = try std.fs.path.join(allocator, &.{ root, "template", "game" });
    for (template_files) |file| {
        const src_path = try std.fs.path.join(allocator, &.{ template_dir, file.src });
        const dst_path = try std.fs.path.join(allocator, &.{ target, file.dst });
        if (std.fs.path.dirname(dst_path)) |dir| try std.Io.Dir.cwd().createDirPath(io, dir);
        const text = try std.Io.Dir.cwd().readFileAlloc(io, src_path, allocator, .limited(256 * 1024));
        defer allocator.free(text);
        const filled = try substitute(allocator, text, file, ident, display, engine_path);
        defer allocator.free(filled);
        if (std.mem.indexOf(u8, filled, "@NAME@") != null or
            std.mem.indexOf(u8, filled, "ez_template_game") != null or
            std.mem.indexOf(u8, filled, "@TITLE@") != null or
            std.mem.indexOf(u8, filled, "@ENGINE_PATH@") != null)
            fail("unsubstituted placeholder left in {s}", .{file.dst});
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = dst_path, .data = filled });
    }

    try std.Io.Dir.cwd().createDirPath(io, try std.fs.path.join(allocator, &.{ target, "Scenes" }));
    const source_assets = try std.fs.path.join(allocator, &.{ root, "assets" });
    const destination_assets = try std.fs.path.join(allocator, &.{ target, "Assets" });
    try copyAssetTree(io, allocator, source_assets, destination_assets);

    patchFingerprint(io, allocator, target) catch |err| {
        std.debug.print("ez-new: warning: fingerprint discovery failed ({}), run `zig build` in {s} to fix\n", .{ err, target });
    };
    const rel = try relativeTo(allocator, cwd, target);
    const shown = if (std.mem.startsWith(u8, rel, "..")) target else rel;
    std.debug.print(
        "Created {s} in {s}\n\nNext steps:\n  cd {s}\n  zig build run\n",
        .{ slug, shown, shown },
    );
}
