const std = @import("std");
const UVRect = @import("render_components.zig").UVRect;
const Vec2 = @import("../math/vec2.zig").Vec2;

pub const Error = error{
    UnsupportedAtlasVersion,
    InvalidAtlasRegion,
    UnknownAtlasFrame,
    InvalidAtlasClip,
};

pub const Frame = struct {
    name: []const u8,
    uv: UVRect,
    offset: Vec2,
};

pub const ClipFrame = struct {
    frame: []const u8,
    duration_s: ?f32 = null,
};

pub const Clip = struct {
    name: []const u8,
    frames: []ClipFrame,
    fps: f32 = 8,
    looping: bool = true,
};

const SerializedFrame = struct {
    name: []const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    offset: ?[2]f32 = null,
    rotated: ?bool = null,
    trimmed: ?bool = null,
};

const SerializedClipFrame = struct {
    frame: []const u8,
    duration_s: ?f32 = null,
};

const SerializedClip = struct {
    name: []const u8,
    fps: f32 = 8,
    looping: bool = true,
    frames: []SerializedClipFrame,
};

const SerializedAtlas = struct {
    version: u32 = 1,
    frames: []SerializedFrame,
    clips: []SerializedClip = &.{},
};

/// Parsed atlas: named pixel regions as UV rects plus named clips.
/// All names and slices live in an internal arena; `deinit` frees everything.
pub const OwnedAtlas = struct {
    arena: std.heap.ArenaAllocator,
    frames: []Frame,
    clips: []Clip,

    pub fn deinit(self: *OwnedAtlas, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.arena.deinit();
        self.frames = &.{};
        self.clips = &.{};
    }

    pub fn frameUv(self: *const OwnedAtlas, name: []const u8) Error!UVRect {
        for (self.frames) |frame| {
            if (std.mem.eql(u8, frame.name, name)) return frame.uv;
        }
        return Error.UnknownAtlasFrame;
    }

    pub fn findClip(self: *const OwnedAtlas, name: []const u8) ?*const Clip {
        for (self.clips) |*clip| {
            if (std.mem.eql(u8, clip.name, name)) return clip;
        }
        return null;
    }
};

/// Parses atlas JSON against texture dimensions. Pixel rects become normalized
/// UVs (top-left origin, same convention as `SpriteSheet.frameUv`).
pub fn load(allocator: std.mem.Allocator, json_bytes: []const u8, texture_width: u32, texture_height: u32) !OwnedAtlas {
    if (texture_width == 0 or texture_height == 0) return Error.InvalidAtlasRegion;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const parsed = try std.json.parseFromSlice(SerializedAtlas, arena.allocator(), json_bytes, .{});
    // No parsed.deinit(): the arena takes ownership of all parsed strings/slices.
    if (parsed.value.version != 1) return Error.UnsupportedAtlasVersion;

    const tex_w: f32 = @floatFromInt(texture_width);
    const tex_h: f32 = @floatFromInt(texture_height);
    var frames = try arena.allocator().alloc(Frame, parsed.value.frames.len);
    for (parsed.value.frames, 0..) |input, index| {
        if (input.rotated orelse false) return Error.InvalidAtlasRegion;
        if (input.trimmed orelse false) return Error.InvalidAtlasRegion;
        if (!std.math.isFinite(input.x) or !std.math.isFinite(input.y) or
            !std.math.isFinite(input.w) or !std.math.isFinite(input.h) or
            input.x < 0 or input.y < 0 or input.w <= 0 or input.h <= 0 or
            input.x + input.w > tex_w or input.y + input.h > tex_h)
            return Error.InvalidAtlasRegion;
        for (frames[0..index]) |existing| {
            if (std.mem.eql(u8, existing.name, input.name)) return Error.InvalidAtlasRegion;
        }
        const offset = input.offset orelse .{ 0, 0 };
        if (!std.math.isFinite(offset[0]) or !std.math.isFinite(offset[1]))
            return Error.InvalidAtlasRegion;
        frames[index] = .{
            .name = input.name,
            .uv = .{
                .x = input.x / tex_w,
                .y = input.y / tex_h,
                .width = input.w / tex_w,
                .height = input.h / tex_h,
            },
            .offset = .{ .x = offset[0], .y = offset[1] },
        };
    }

    var clips = try arena.allocator().alloc(Clip, parsed.value.clips.len);
    for (parsed.value.clips, 0..) |input, index| {
        if (input.frames.len == 0) return Error.InvalidAtlasClip;
        if (!std.math.isFinite(input.fps) or input.fps <= 0) return Error.InvalidAtlasClip;
        for (clips[0..index]) |existing| {
            if (std.mem.eql(u8, existing.name, input.name)) return Error.InvalidAtlasClip;
        }
        var clip_frames = try arena.allocator().alloc(ClipFrame, input.frames.len);
        for (input.frames, 0..) |ref, ref_index| {
            var known = false;
            for (frames) |frame| {
                if (std.mem.eql(u8, frame.name, ref.frame)) {
                    known = true;
                    break;
                }
            }
            if (!known) return Error.UnknownAtlasFrame;
            if (ref.duration_s) |duration| {
                if (!std.math.isFinite(duration) or duration <= 0) return Error.InvalidAtlasClip;
            }
            clip_frames[ref_index] = .{ .frame = ref.frame, .duration_s = ref.duration_s };
        }
        clips[index] = .{
            .name = input.name,
            .frames = clip_frames,
            .fps = input.fps,
            .looping = input.looping,
        };
    }

    return .{ .arena = arena, .frames = frames, .clips = clips };
}

test "atlas load resolves named frames to UV and rejects out-of-bounds rect" {
    const json =
        \\{"version":1,"frames":[{"name":"a","x":0,"y":0,"w":2,"h":2},{"name":"b","x":2,"y":0,"w":2,"h":2}],
        \\ "clips":[{"name":"ab","fps":8,"looping":true,"frames":[{"frame":"a"},{"frame":"b","duration_s":0.5}]}]}
    ;
    var owned = try load(std.testing.allocator, json, 4, 2);
    defer owned.deinit(std.testing.allocator);
    const uv = try owned.frameUv("b");
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), uv.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), uv.width, 1e-5);
    try std.testing.expectError(error.UnknownAtlasFrame, owned.frameUv("nope"));
    const bad_json =
        \\{"version":1,"frames":[{"name":"o","x":3,"y":0,"w":2,"h":2}],"clips":[]}
    ;
    try std.testing.expectError(error.InvalidAtlasRegion, load(std.testing.allocator, bad_json, 4, 2));
}

test "atlas rejects rotated frames and zero texture size" {
    const rotated =
        \\{"version":1,"frames":[{"name":"r","x":0,"y":0,"w":2,"h":2,"rotated":true}],"clips":[]}
    ;
    try std.testing.expectError(error.InvalidAtlasRegion, load(std.testing.allocator, rotated, 4, 2));
    const json =
        \\{"version":1,"frames":[{"name":"a","x":0,"y":0,"w":2,"h":2}],"clips":[]}
    ;
    try std.testing.expectError(error.InvalidAtlasRegion, load(std.testing.allocator, json, 0, 2));
}
