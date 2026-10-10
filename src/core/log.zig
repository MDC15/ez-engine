const std = @import("std");

pub const Level = enum(u8) { trace, debug, info, warning, err };

/// A sink can route messages to stderr, a file, an editor console or a test.
pub const Sink = *const fn (
    context: ?*anyopaque,
    level: Level,
    category: []const u8,
    message: []const u8,
) void;

pub const Logger = struct {
    sink: Sink = defaultSink,
    context: ?*anyopaque = null,
    min_level: Level = .info,

    pub fn enabled(self: Logger, level: Level) bool {
        return @intFromEnum(level) >= @intFromEnum(self.min_level);
    }

    pub fn write(self: Logger, level: Level, message: []const u8) void {
        self.writeCategory(level, "game", message);
    }

    pub fn writeCategory(self: Logger, level: Level, category: []const u8, message: []const u8) void {
        if (self.enabled(level)) self.sink(self.context, level, category, message);
    }

    pub fn format(
        self: Logger,
        allocator: std.mem.Allocator,
        level: Level,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        try self.formatCategory(allocator, level, "game", fmt, args);
    }

    pub fn formatCategory(
        self: Logger,
        allocator: std.mem.Allocator,
        level: Level,
        category: []const u8,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        if (!self.enabled(level)) return;
        const message = try std.fmt.allocPrint(allocator, fmt, args);
        defer allocator.free(message);
        self.writeCategory(level, category, message);
    }
};

fn defaultSink(_: ?*anyopaque, level: Level, category: []const u8, message: []const u8) void {
    var remaining = message;
    while (true) {
        const newline = std.mem.indexOfScalar(u8, remaining, '\n');
        var line = if (newline) |index| remaining[0..index] else remaining;
        if (std.mem.endsWith(u8, line, "\r")) line = line[0 .. line.len - 1];
        std.debug.print("[{s}] [{s}] {s}\n", .{ levelLabel(level), category, line });
        if (newline) |index| {
            remaining = remaining[index + 1 ..];
            if (remaining.len == 0) break;
        } else break;
    }
}

fn levelLabel(level: Level) []const u8 {
    return switch (level) {
        .trace => "TRACE",
        .debug => "DEBUG",
        .info => "INFO ",
        .warning => "WARN ",
        .err => "ERROR",
    };
}

test "log levels use aligned readable labels" {
    try std.testing.expectEqualStrings("TRACE", levelLabel(.trace));
    try std.testing.expectEqualStrings("DEBUG", levelLabel(.debug));
    try std.testing.expectEqualStrings("INFO ", levelLabel(.info));
    try std.testing.expectEqualStrings("WARN ", levelLabel(.warning));
    try std.testing.expectEqualStrings("ERROR", levelLabel(.err));
}

test "logger filters levels and forwards category" {
    const State = struct {
        calls: usize = 0,
        last_level: Level = .trace,
        last_category: []const u8 = "",
        last_message: []const u8 = "",

        fn sink(context: ?*anyopaque, level: Level, category: []const u8, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.last_level = level;
            self.last_category = category;
            self.last_message = message;
        }
    };

    var state: State = .{};
    const logger = Logger{ .sink = State.sink, .context = &state, .min_level = .warning };
    logger.writeCategory(.info, "input", "filtered");
    logger.writeCategory(.warning, "input", "key event");
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(Level.warning, state.last_level);
    try std.testing.expectEqualStrings("input", state.last_category);
    try std.testing.expectEqualStrings("key event", state.last_message);
}

test "logger formats messages only when enabled" {
    const State = struct {
        buffer: [64]u8 = undefined,
        message_len: usize = 0,
        fn sink(context: ?*anyopaque, _: Level, _: []const u8, message: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.message_len = @min(message.len, self.buffer.len);
            @memcpy(self.buffer[0..self.message_len], message[0..self.message_len]);
        }
    };

    var state: State = .{};
    const logger = Logger{ .sink = State.sink, .context = &state, .min_level = .debug };
    try logger.formatCategory(std.testing.allocator, .info, "asset", "loaded texture {d}", .{7});
    try std.testing.expectEqualStrings("loaded texture 7", state.buffer[0..state.message_len]);
}
