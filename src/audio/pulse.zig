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
/// Note: `DynLib.open` does not consult the loader cache in all link modes,
/// so `loadDefault` also probes well-known absolute paths.
pub const PulseLib = struct {
    lib: std.DynLib,
    fns: FnTable,

    const default_candidates = [_][]const u8{
        "libpulse-simple.so.0",
        "/usr/lib/x86_64-linux-gnu/libpulse-simple.so.0",
        "/usr/lib64/libpulse-simple.so.0",
        "/usr/lib/libpulse-simple.so.0",
        "/usr/local/lib/libpulse-simple.so.0",
    };
    // NOTE: libpulse symbols are versioned (pa_simple_new@@PULSE_0). Binaries
    // that link libc resolve them through the system dlopen; libc-less
    // binaries use Zig's ELF loader, whose plain lookup skips versioned
    // symbols — keep the MissingPulseSymbol path honest for both.

    pub fn load(path: []const u8) PulseError!PulseLib {
        var lib = std.DynLib.open(path) catch return PulseError.AudioLibraryMissing;
        errdefer lib.close();
        return .{ .lib = lib, .fns = try loadFns(&lib) };
    }

    pub fn loadDefault() PulseError!PulseLib {
        for (default_candidates) |path| {
            if (load(path)) |lib| return lib else |_| continue;
        }
        return PulseError.AudioLibraryMissing;
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

/// PulseAudio playback device: a drop-in `Audio.Device` whose `write`
/// mixes into a stack buffer and performs one blocking `pa_simple_write`
/// per chunk. Borrowed `*Audio` must outlive the device; destroy before
/// `Game.audio` (same order as renderer-before-subsystems).
pub const PulseDevice = struct {
    audio: *Audio,
    fns: FnTable,
    lib: ?PulseLib = null,
    stream: ?*anyopaque = null,

    pub fn init(audio: *Audio, app_name: [:0]const u8, stream_name: [:0]const u8, server: ?[:0]const u8) PulseError!PulseDevice {
        var lib = try PulseLib.loadDefault();
        const spec = SampleSpec{
            .format = FLOAT32LE,
            .rate = audio.output_sample_rate,
            .channels = audio.output_channels,
        };
        var err: c_int = 0;
        const stream = lib.fns.pa_new(
            if (server) |s| s.ptr else null,
            app_name.ptr,
            PLAYBACK,
            null,
            stream_name.ptr,
            &spec,
            null,
            null,
            &err,
        ) orelse {
            lib.close();
            return PulseError.NoAudioServer;
        };
        return .{ .audio = audio, .fns = lib.fns, .lib = lib, .stream = stream };
    }

    /// Test/headless constructor: fake function table, no library or server.
    pub fn initTest(audio: *Audio, fns: FnTable) PulseDevice {
        return .{ .audio = audio, .fns = fns, .stream = @ptrFromInt(0x5678) };
    }

    const vtable: Audio.DeviceVTable = .{ .write = writeImpl, .deinit = deinitImpl };

    pub fn device(self: *PulseDevice) Audio.Device {
        return .{ .context = self, .vtable = &vtable };
    }

    pub fn write(self: *PulseDevice, frames: u32) !void {
        if (frames == 0) return;
        var buffer: [512 * 2]f32 = undefined;
        const channels: usize = self.audio.output_channels;
        var remaining: usize = frames;
        var err: c_int = 0;
        while (remaining > 0) {
            const chunk: usize = @min(remaining, 512);
            const slice = buffer[0 .. chunk * channels];
            try self.audio.mix(slice);
            const rc = self.fns.pa_write(self.stream.?, @ptrCast(slice.ptr), slice.len * 4, &err);
            if (rc != 0) return PulseError.PulseWriteFailed;
            remaining -= chunk;
        }
    }

    pub fn deinit(self: *PulseDevice) void {
        var err: c_int = 0;
        if (self.stream) |s| {
            if (self.fns.pa_drain(s, &err) != 0) {
                std.log.warn("PulseAudio stream drain failed during shutdown (code {d})", .{err});
            }
            self.fns.pa_free(s);
            self.stream = null;
        }
        if (self.lib) |*lib| {
            lib.close();
            self.lib = null;
        }
    }

    fn writeImpl(context: *anyopaque, frames: u32) anyerror!void {
        const self: *PulseDevice = @ptrCast(@alignCast(context));
        try self.write(frames);
    }

    fn deinitImpl(context: *anyopaque) void {
        const self: *PulseDevice = @ptrCast(@alignCast(context));
        self.deinit();
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

const Audio = @import("audio.zig").Audio;
const Clip = @import("audio.zig").Clip;

var active_fake: ?*FakePulse = null;

const FakePulse = struct {
    write_count: usize = 0,
    drain_count: usize = 0,
    free_count: usize = 0,
    drained_before_freed: bool = false,
    write_result: c_int = 0,
    drain_result: c_int = 0,
    captured: [16]f32 = [_]f32{0} ** 16,
    captured_len: usize = 0,

    fn fns(self: *FakePulse) FnTable {
        active_fake = self;
        return .{
            .pa_new = fakeNew,
            .pa_write = fakeWrite,
            .pa_drain = fakeDrain,
            .pa_free = fakeFree,
        };
    }
};

fn fakeNew(_: ?[*:0]const u8, _: ?[*:0]const u8, _: c_int, _: ?[*:0]const u8, _: ?[*:0]const u8, _: *const SampleSpec, _: ?*const anyopaque, _: ?*const anyopaque, _: *c_int) callconv(.c) ?*anyopaque {
    return @ptrFromInt(0x1234);
}

fn fakeWrite(_: *anyopaque, data: [*]const u8, bytes: usize, _: *c_int) callconv(.c) c_int {
    const f = active_fake.?;
    f.write_count += 1;
    const n = @min(bytes / 4, f.captured.len);
    const samples: [*]const f32 = @ptrCast(@alignCast(data));
    @memcpy(f.captured[0..n], samples[0..n]);
    f.captured_len = n;
    return f.write_result;
}

fn fakeDrain(_: *anyopaque, err: *c_int) callconv(.c) c_int {
    const f = active_fake.?;
    f.drain_count += 1;
    f.drained_before_freed = f.free_count == 0;
    if (f.drain_result != 0) err.* = 17;
    return f.drain_result;
}

fn fakeFree(_: *anyopaque) callconv(.c) void {
    active_fake.?.free_count += 1;
}

test "device writes mixed frames and drains on deinit" {
    var audio = try Audio.init(std.testing.allocator, 1);
    defer audio.deinit();
    const clip = Clip{ .sample_rate = 48000, .channels = 1, .samples = &.{ 0.5, -0.5 } };
    _ = try audio.play(&clip, 1);
    var fake = FakePulse{};
    var dev = PulseDevice.initTest(&audio, fake.fns());
    var device = dev.device();
    try device.write(2);
    try std.testing.expectEqual(@as(usize, 1), fake.write_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fake.captured[0], 1e-5);
    device.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.drain_count);
    try std.testing.expect(fake.drained_before_freed);
}

test "write error propagates and zero write is a no-op" {
    var audio = try Audio.init(std.testing.allocator, 1);
    defer audio.deinit();
    const clip = Clip{ .sample_rate = 48000, .channels = 1, .samples = &.{0.5} };
    _ = try audio.play(&clip, 1);
    var fake = FakePulse{ .write_result = -1 };
    var dev = PulseDevice.initTest(&audio, fake.fns());
    var device = dev.device();
    try std.testing.expectError(error.PulseWriteFailed, device.write(2));
    var clean = FakePulse{};
    var dev2 = PulseDevice.initTest(&audio, clean.fns());
    try dev2.device().write(0);
    try std.testing.expectEqual(@as(usize, 0), clean.write_count);
}

test "device chunks long writes and frees stream after drain errors" {
    var audio = try Audio.init(std.testing.allocator, 1);
    defer audio.deinit();
    const samples = [_]f32{0.25} ** 513;
    const clip = Clip{ .sample_rate = 48000, .channels = 1, .samples = &samples };
    _ = try audio.play(&clip, 1);
    var fake = FakePulse{ .drain_result = -1 };
    var device = PulseDevice.initTest(&audio, fake.fns());

    try device.write(513);
    try std.testing.expectEqual(@as(usize, 2), fake.write_count);
    device.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.drain_count);
    try std.testing.expectEqual(@as(usize, 1), fake.free_count);
}

test "init against a bogus server fails cleanly" {
    var audio = try Audio.init(std.testing.allocator, 2);
    defer audio.deinit();
    for ([_]void{ {}, {} }) |_| {
        if (PulseDevice.init(&audio, "ez-test", "sfx", "unix:/nonexistent-pulse-socket-xyz")) |d| {
            var dev = d;
            dev.deinit();
            try std.testing.expect(false);
        } else |err| {
            try std.testing.expect(err == error.NoAudioServer or err == error.AudioLibraryMissing);
        }
    }
}
