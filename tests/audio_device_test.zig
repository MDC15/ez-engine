const std = @import("std");
const ez = @import("ez_engine");

test "resample 24000Hz mono to 48000Hz doubles frames" {
    const source = [_]f32{ 0, 0.5, -0.5, 1 };
    const clip = ez.AudioClip{ .sample_rate = 24000, .channels = 1, .samples = &source };
    var owned = try ez.Audio.resample(std.testing.allocator, clip, 48000);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 48000), owned.clip.sample_rate);
    try std.testing.expectEqual(@as(usize, 8), owned.clip.samples.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0), owned.clip.samples[0], 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), owned.clip.samples[7], 1e-5);
}

test "resample rejects zero target rate" {
    const source = [_]f32{0};
    const clip = ez.AudioClip{ .sample_rate = 48000, .channels = 1, .samples = &source };
    try std.testing.expectError(error.InvalidSampleRate, ez.Audio.resample(std.testing.allocator, clip, 0));
}

test "NullDevice drains mixer without error" {
    var audio = try ez.Audio.init(std.testing.allocator, 1);
    defer audio.deinit();
    const source = [_]f32{ 0.5, -0.5 };
    const clip = ez.AudioClip{ .sample_rate = 48000, .channels = 1, .samples = &source };
    _ = try audio.play(&clip, 1);
    var null_device = ez.Audio.NullDevice{ .audio = &audio };
    var device = null_device.device();
    try device.write(2);
    // Voice finished; second drain is a no-op but must not error.
    try device.write(2);
}
