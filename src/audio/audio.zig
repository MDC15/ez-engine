const std = @import("std");

pub const Clip = struct {
    sample_rate: u32,
    channels: u8,
    samples: []const f32,
};

pub const OwnedClip = struct {
    clip: Clip,
    samples: []f32,

    pub fn deinit(self: *OwnedClip, allocator: std.mem.Allocator) void {
        allocator.free(self.samples);
        self.samples = &.{};
        self.clip.samples = self.samples;
    }
};

pub fn decodeWav(allocator: std.mem.Allocator, bytes: []const u8) !OwnedClip {
    if (bytes.len < 12 or !std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WAVE"))
        return error.InvalidWav;
    var channels: u16 = 0;
    var sample_rate: u32 = 0;
    var encoding: u16 = 0;
    var bits_per_sample: u16 = 0;
    var sample_bytes: ?[]const u8 = null;
    var offset: usize = 12;

    while (offset < bytes.len) {
        if (bytes.len - offset < 8) return error.InvalidWav;
        const chunk_id = bytes[offset .. offset + 4];
        const chunk_size = std.mem.readInt(u32, bytes[offset + 4 ..][0..4], .little);
        const chunk_start = offset + 8;
        const chunk_end = try std.math.add(usize, chunk_start, chunk_size);
        const next_offset = try std.math.add(usize, chunk_end, chunk_size & 1);
        if (next_offset > bytes.len) return error.InvalidWav;
        if (std.mem.eql(u8, chunk_id, "fmt ")) {
            if (chunk_size < 16) return error.InvalidWav;
            encoding = std.mem.readInt(u16, bytes[chunk_start..][0..2], .little);
            channels = std.mem.readInt(u16, bytes[chunk_start + 2 ..][0..2], .little);
            sample_rate = std.mem.readInt(u32, bytes[chunk_start + 4 ..][0..4], .little);
            bits_per_sample = std.mem.readInt(u16, bytes[chunk_start + 14 ..][0..2], .little);
        } else if (std.mem.eql(u8, chunk_id, "data")) {
            sample_bytes = bytes[chunk_start..chunk_end];
        }
        offset = next_offset;
    }

    const data = sample_bytes orelse return error.MissingWavData;
    if (channels == 0 or channels > 2 or sample_rate == 0) return error.UnsupportedWavFormat;
    const bytes_per_sample: usize = switch (encoding) {
        1 => if (bits_per_sample == 16) 2 else return error.UnsupportedWavFormat,
        3 => if (bits_per_sample == 32) 4 else return error.UnsupportedWavFormat,
        else => return error.UnsupportedWavFormat,
    };
    if (data.len % bytes_per_sample != 0 or data.len / bytes_per_sample % channels != 0)
        return error.InvalidWav;

    const samples = try allocator.alloc(f32, data.len / bytes_per_sample);
    errdefer allocator.free(samples);
    if (encoding == 1) {
        for (samples, 0..) |*sample, index| {
            const pcm = std.mem.readInt(i16, data[index * 2 ..][0..2], .little);
            sample.* = @as(f32, @floatFromInt(pcm)) / 32768.0;
        }
    } else {
        for (samples, 0..) |*sample, index| {
            const bits = std.mem.readInt(u32, data[index * 4 ..][0..4], .little);
            const value: f32 = @bitCast(bits);
            if (!std.math.isFinite(value)) return error.InvalidWavSample;
            sample.* = std.math.clamp(value, -1, 1);
        }
    }
    return .{
        .clip = .{ .sample_rate = sample_rate, .channels = @intCast(channels), .samples = samples },
        .samples = samples,
    };
}

const Voice = struct {
    clip: *const Clip,
    cursor: usize = 0,
    volume: f32 = 1,
    active: bool = true,
};

/// Allocation-free software PCM mixer. A platform audio device callback
/// should call mix() with interleaved float output; device setup is separate.
pub const Audio = struct {
    allocator: std.mem.Allocator,
    voices: std.ArrayListUnmanaged(Voice) = .empty,
    output_channels: u8,
    output_sample_rate: u32,

    pub fn init(allocator: std.mem.Allocator, output_channels: u8) !Audio {
        return initConfigured(allocator, output_channels, 48000);
    }

    pub fn initConfigured(allocator: std.mem.Allocator, output_channels: u8, output_sample_rate: u32) !Audio {
        if (output_channels == 0 or output_channels > 2) return error.UnsupportedChannelCount;
        if (output_sample_rate == 0) return error.InvalidSampleRate;
        return .{ .allocator = allocator, .output_channels = output_channels, .output_sample_rate = output_sample_rate };
    }

    pub fn deinit(self: *Audio) void {
        self.voices.deinit(self.allocator);
    }

    pub fn play(self: *Audio, clip: *const Clip, volume: f32) !usize {
        if (clip.channels == 0 or clip.channels > 2 or clip.sample_rate == 0)
            return error.InvalidClip;
        if (clip.sample_rate != self.output_sample_rate) return error.SampleRateMismatch;
        if (clip.samples.len % clip.channels != 0) return error.InvalidClip;
        for (self.voices.items, 0..) |*voice, index| {
            if (!voice.active) {
                voice.* = .{ .clip = clip, .volume = volume };
                return index;
            }
        }
        const index = self.voices.items.len;
        try self.voices.append(self.allocator, .{ .clip = clip, .volume = volume });
        return index;
    }

    pub fn stop(self: *Audio, voice_index: usize) error{InvalidVoice}!void {
        if (voice_index >= self.voices.items.len or !self.voices.items[voice_index].active)
            return error.InvalidVoice;
        self.voices.items[voice_index].active = false;
    }

    /// Mixes the next frames into output and clamps the result to [-1, 1].
    /// Clip/output sample rates must match; resampling is intentionally
    /// performed by asset preparation, not from the real-time callback.
    pub fn mix(self: *Audio, output: []f32) !void {
        if (output.len % self.output_channels != 0) return error.InvalidOutput;
        @memset(output, 0);
        const frames = output.len / self.output_channels;
        for (self.voices.items) |*voice| {
            if (!voice.active) continue;
            const clip = voice.clip;
            if (clip.channels == 0 or clip.channels > 2 or clip.samples.len % clip.channels != 0)
                return error.InvalidClip;
            if (clip.sample_rate != self.output_sample_rate) return error.SampleRateMismatch;
            const source_frames = clip.samples.len / clip.channels;
            for (0..frames) |frame| {
                if (voice.cursor >= source_frames) {
                    voice.active = false;
                    break;
                }
                const source_offset = voice.cursor * clip.channels;
                const output_offset = frame * self.output_channels;
                if (self.output_channels == 1) {
                    const sample = if (clip.channels == 1)
                        clip.samples[source_offset]
                    else
                        (clip.samples[source_offset] + clip.samples[source_offset + 1]) * 0.5;
                    output[output_offset] += sample * voice.volume;
                } else if (clip.channels == 1) {
                    const sample = clip.samples[source_offset] * voice.volume;
                    output[output_offset] += sample;
                    output[output_offset + 1] += sample;
                } else {
                    output[output_offset] += clip.samples[source_offset] * voice.volume;
                    output[output_offset + 1] += clip.samples[source_offset + 1] * voice.volume;
                }
                voice.cursor += 1;
            }
        }
        for (output) |*sample| sample.* = std.math.clamp(sample.*, -1, 1);
    }
};

test "software mixer sums voices and clamps output" {
    var audio = try Audio.init(std.testing.allocator, 1);
    defer audio.deinit();
    const clip = Clip{ .sample_rate = 48000, .channels = 1, .samples = &.{ 0.75, -0.75 } };
    _ = try audio.play(&clip, 1);
    _ = try audio.play(&clip, 1);
    var output: [2]f32 = undefined;
    try audio.mix(&output);
    try std.testing.expectEqualSlices(f32, &.{ 1, -1 }, &output);
}

test "WAV decoder reads little-endian signed PCM" {
    var wav: [48]u8 = @splat(0);
    @memcpy(wav[0..4], "RIFF");
    std.mem.writeInt(u32, wav[4..8], 40, .little);
    @memcpy(wav[8..12], "WAVE");
    @memcpy(wav[12..16], "fmt ");
    std.mem.writeInt(u32, wav[16..20], 16, .little);
    std.mem.writeInt(u16, wav[20..22], 1, .little);
    std.mem.writeInt(u16, wav[22..24], 1, .little);
    std.mem.writeInt(u32, wav[24..28], 48000, .little);
    std.mem.writeInt(u32, wav[28..32], 96000, .little);
    std.mem.writeInt(u16, wav[32..34], 2, .little);
    std.mem.writeInt(u16, wav[34..36], 16, .little);
    @memcpy(wav[36..40], "data");
    std.mem.writeInt(u32, wav[40..44], 4, .little);
    std.mem.writeInt(i16, wav[44..46], -32768, .little);
    std.mem.writeInt(i16, wav[46..48], 16384, .little);
    var clip = try decodeWav(std.testing.allocator, &wav);
    defer clip.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 1), clip.clip.channels);
    try std.testing.expectEqualSlices(f32, &.{ -1, 0.5 }, clip.clip.samples);
}
