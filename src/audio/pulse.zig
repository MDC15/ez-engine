const std = @import("std");

pub const PulseError = error{
    AudioLibraryMissing,
    MissingPulseSymbol,
    NoAudioServer,
    PulseWriteFailed,
};

/// `pa_sample_format_t` value for 32-bit little-endian float.
pub const FLOAT32LE: c_int = 5;
/// `pa_stream_direction_t` value for playback.
pub const PLAYBACK: c_int = 1;

/// C layout of `pa_sample_spec` (12 bytes: i32 + u32 + u8 + padding).
pub const SampleSpec = extern struct {
    format: c_int,
    rate: u32,
    channels: u8,
};

pub const NewFn = fn (
    server: ?[*:0]const u8,
    name: ?[*:0]const u8,
    dir: c_int,
    dev: ?[*:0]const u8,
    stream_name: ?[*:0]const u8,
    ss: *const SampleSpec,
    map: ?*const anyopaque,
    attr: ?*const anyopaque,
    err: *c_int,
) callconv(.c) ?*anyopaque;

pub const WriteFn = fn (
    stream: *anyopaque,
    data: [*]const u8,
    bytes: usize,
    err: *c_int,
) callconv(.c) c_int;

pub const DrainFn = fn (stream: *anyopaque, err: *c_int) callconv(.c) c_int;
pub const FreeFn = fn (stream: *anyopaque) callconv(.c) void;

/// `pa_strerror` is intentionally NOT bound: all failures surface as the
/// `PulseError` codes above, so callers never format C strings.
pub const FnTable = struct {
    pa_new: *const NewFn,
    pa_write: *const WriteFn,
    pa_drain: *const DrainFn,
    pa_free: *const FreeFn,
};

/// Runtime-loaded `libpulse-simple`. No headers or link dependency.
pub const PulseLib = struct {
    lib: std.DynLib,
    fns: FnTable,

    pub fn load(path: []const u8) PulseError!PulseLib {
        var lib = std.DynLib.open(path) catch return PulseError.AudioLibraryMissing;
        errdefer lib.close();
        return .{ .lib = lib, .fns = try loadFns(&lib) };
    }

    pub fn loadFns(lib: *std.DynLib) PulseError!FnTable {
        return .{
            .pa_new = lib.lookup(*const NewFn, "pa_simple_new") orelse
                return PulseError.MissingPulseSymbol,
            .pa_write = lib.lookup(*const WriteFn, "pa_simple_write") orelse
                return PulseError.MissingPulseSymbol,
            .pa_drain = lib.lookup(*const DrainFn, "pa_simple_drain") orelse
                return PulseError.MissingPulseSymbol,
            .pa_free = lib.lookup(*const FreeFn, "pa_simple_free") orelse
                return PulseError.MissingPulseSymbol,
        };
    }

    pub fn close(self: *PulseLib) void {
        self.lib.close();
    }
};

test "loader reports a missing library without crashing" {
    try std.testing.expectError(error.AudioLibraryMissing, PulseLib.load("libpulse-simple-does-not-exist.so.0"));
}

test "loader reports a missing symbol without crashing" {
    // libc never exports pa_simple_* symbols. Probe well-known absolute
    // paths (bare sonames are not resolved by DynLib.open); skip cleanly
    // where none exists (non-glibc, non-Linux runners).
    if (@import("builtin").os.tag != .linux) return error.SkipZigTest;
    const candidates = [_][]const u8{
        "/usr/lib/x86_64-linux-gnu/libc.so.6",
        "/lib/x86_64-linux-gnu/libc.so.6",
        "/lib64/libc.so.6",
        "/usr/lib/libc.so.6",
    };
    var raw: ?std.DynLib = null;
    for (candidates) |path| {
        raw = std.DynLib.open(path) catch continue;
        break;
    }
    var lib = raw orelse return error.SkipZigTest;
    defer lib.close();
    try std.testing.expectError(error.MissingPulseSymbol, PulseLib.loadFns(&lib));
}

test "sample spec matches the C ABI" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(SampleSpec));
    try std.testing.expectEqual(@as(c_int, 5), FLOAT32LE);
    try std.testing.expectEqual(@as(c_int, 1), PLAYBACK);
}
