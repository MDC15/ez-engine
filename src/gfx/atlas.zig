const std = @import("std");
const UVRect = @import("render_components.zig").UVRect;
const Vec2 = @import("../math/vec2.zig").Vec2;
const AtlasHandle = @import("../core/handle.zig").AtlasHandle;
const Components = @import("render_components.zig");
const World = @import("../ecs/world.zig").World;
const Entity = @import("../ecs/entity.zig").Entity;
const Manager = @import("../asset/manager.zig").Manager;

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

/// Resolves a named clip eagerly and attaches a fresh `AtlasPlayer`.
/// Returns `UnknownAtlasFrame` before touching the entity when the atlas
/// handle is stale or the clip name is unknown.
pub fn playAtlas(manager: *Manager, world: *World, entity: Entity, atlas: AtlasHandle, clip_name: []const u8) !void {
    const entry = manager.getAtlas(atlas) orelse return Error.UnknownAtlasFrame;
    var clip_index: u32 = 0;
    var found = false;
    for (entry.atlas.clips, 0..) |*clip, index| {
        if (std.mem.eql(u8, clip.name, clip_name)) {
            clip_index = @intCast(index);
            found = true;
            break;
        }
    }
    if (!found) return Error.UnknownAtlasFrame;
    try world.add(entity, Components.AtlasPlayer{ .atlas = atlas, .clip_index = clip_index });
}

/// ECS system that advances every entity with atlas-clip and sprite data.
/// A stale atlas handle (or hand-built invalid indices) leaves the sprite
/// untouched without error — the frame loop never breaks on bad data.
pub const AtlasSystem = struct {
    manager: *Manager,

    pub fn init(manager: *Manager) AtlasSystem {
        return .{ .manager = manager };
    }

    pub fn updateSystem(context: ?*anyopaque, world: *World, dt: f32) anyerror!void {
        const self: *AtlasSystem = @ptrCast(@alignCast(context.?));
        try self.update(world, dt);
    }

    pub fn update(self: *AtlasSystem, world: *World, dt: f32) !void {
        if (!std.math.isFinite(dt) or dt < 0) return error.InvalidDeltaTime;
        var players = world.query(.{ Components.AtlasPlayer, Components.SpriteRenderer });
        while (players.next()) |item| {
            const entry = self.manager.getAtlas(item.AtlasPlayer.atlas) orelse continue;
            if (item.AtlasPlayer.clip_index >= entry.atlas.clips.len) continue;
            const clip = &entry.atlas.clips[item.AtlasPlayer.clip_index];
            if (clip.frames.len == 0) continue;
            const texture = self.manager.getTexture(entry.texture) orelse continue;
            const tex_w: f32 = @floatFromInt(texture.width);
            const tex_h: f32 = @floatFromInt(texture.height);

            if (item.AtlasPlayer.playing and dt > 0) {
                var elapsed = item.AtlasPlayer.elapsed_seconds + dt;
                if (!std.math.isFinite(elapsed) or elapsed < 0) elapsed = dt;
                var frame_index: usize = item.AtlasPlayer.frame_index;
                while (true) {
                    if (frame_index >= clip.frames.len) frame_index = clip.frames.len - 1;
                    const ref = &clip.frames[frame_index];
                    const duration = ref.duration_s orelse @as(f32, 1) / clip.fps;
                    if (elapsed < duration) break;
                    elapsed -= duration;
                    frame_index += 1;
                    if (frame_index >= clip.frames.len) {
                        if (clip.looping) {
                            frame_index = 0;
                        } else {
                            frame_index = clip.frames.len - 1;
                            item.AtlasPlayer.playing = false;
                            elapsed = 0;
                            break;
                        }
                    }
                }
                item.AtlasPlayer.frame_index = @intCast(@min(frame_index, std.math.maxInt(u16)));
                item.AtlasPlayer.elapsed_seconds = elapsed;
            }

            const ref = &clip.frames[item.AtlasPlayer.frame_index % clip.frames.len];
            const uv = try entry.atlas.frameUv(ref.frame);
            item.SpriteRenderer.source_rect = uv;
            const offset = atlasFrameOffset(&entry.atlas, ref.frame);
            item.SpriteRenderer.draw_offset = .{
                .x = offset.x / tex_w * item.SpriteRenderer.size.x,
                .y = offset.y / tex_h * item.SpriteRenderer.size.y,
            };
        }
    }
};

fn atlasFrameOffset(atlas: *const OwnedAtlas, name: []const u8) Vec2 {
    for (atlas.frames) |frame| {
        if (std.mem.eql(u8, frame.name, name)) return frame.offset;
    }
    return .zero;
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

test "atlas clip advances named frames and applies draw offset" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    const h = try manager.loadAtlasFile(io, "assets/atlas_test.json", "assets/atlas_test.ztex", 1024 * 1024);
    const tex = try manager.loadTextureFile(io, "assets/atlas_test.ztex", 1024 * 1024);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try world.add(e, Components.Transform{});
    try world.add(e, Components.SpriteRenderer{ .texture = tex, .size = .{ .x = 64, .y = 64 } });
    try playAtlas(&manager, &world, e, h, "ab");
    var system = AtlasSystem.init(&manager);
    try system.update(&world, 1.0 / 8.0);
    const sprite = try world.get(e, Components.SpriteRenderer);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sprite.source_rect.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 32), sprite.draw_offset.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0), sprite.draw_offset.y, 1e-5);
}

test "playAtlas with unknown clip leaves the entity untouched" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    const h = try manager.loadAtlasFile(io, "assets/atlas_test.json", "assets/atlas_test.ztex", 1024 * 1024);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try std.testing.expectError(error.UnknownAtlasFrame, playAtlas(&manager, &world, e, h, "nope"));
    try std.testing.expect(!world.has(e, Components.AtlasPlayer));
}

test "system with released atlas leaves the sprite untouched" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    const h = try manager.loadAtlasFile(io, "assets/atlas_test.json", "assets/atlas_test.ztex", 1024 * 1024);
    const tex = try manager.loadTextureFile(io, "assets/atlas_test.ztex", 1024 * 1024);
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try world.add(e, Components.Transform{});
    try world.add(e, Components.SpriteRenderer{ .texture = tex, .size = .{ .x = 64, .y = 64 } });
    try playAtlas(&manager, &world, e, h, "ab");
    const before = (try world.get(e, Components.SpriteRenderer)).source_rect;
    try manager.releaseAtlas(h);
    var system = AtlasSystem.init(&manager);
    try system.update(&world, 1.0);
    const after = (try world.get(e, Components.SpriteRenderer)).source_rect;
    try std.testing.expectEqual(before, after);
}
