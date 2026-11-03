const std = @import("std");
const ez = @import("ez_engine");

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var args = std.process.Args.Iterator.init(init.minimal.args);
    defer args.deinit();
    _ = args.skip();
    const path = args.next() orelse {
        std.debug.print("usage: ez-audio <sound.wav>\n", .{});
        return error.MissingWavPath;
    };

    const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(bytes);
    var decoded = try ez.Audio.decodeWav(allocator, bytes);
    defer decoded.deinit(allocator);

    var converted: ?ez.Audio.OwnedClip = null;
    defer if (converted) |*clip| clip.deinit(allocator);

    var audio = try ez.Audio.initConfigured(allocator, 2, 48000);
    defer audio.deinit();

    if (decoded.clip.sample_rate != audio.output_sample_rate) {
        converted = try ez.Audio.resample(allocator, decoded.clip, audio.output_sample_rate);
    }
    const clip: *const ez.AudioClip = if (converted) |*owned| &owned.clip else &decoded.clip;
    const voice = try audio.play(clip, 1);
    var device = try ez.Audio.PulseDevice.init(&audio, "ez-engine", "WAV playback example", null);
    defer device.deinit();

    var remaining_frames = clip.samples.len / clip.channels;
    while (remaining_frames > 0) {
        const frames: u32 = @intCast(@min(remaining_frames, 512));
        try device.write(frames);
        remaining_frames -= frames;
    }
    try audio.stop(voice);
}
