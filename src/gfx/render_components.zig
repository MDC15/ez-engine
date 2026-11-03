const std = @import("std");
const Handles = @import("../core/handle.zig");
const Vec3 = @import("../math/vec3.zig").Vec3;
const Vec2 = @import("../math/vec2.zig").Vec2;
const Vec4 = @import("../math/vec4.zig").Vec4;
const Quat = @import("../math/quat.zig").Quat;
const Entity = @import("../ecs/entity.zig").Entity;

pub const Transform = struct {
    position: Vec3 = .zero,
    rotation: Quat = .identity,
    scale: Vec3 = .one,
};

/// Normalized texture coordinates with a top-left origin.
pub const UVRect = struct {
    x: f32 = 0,
    y: f32 = 0,
    width: f32 = 1,
    height: f32 = 1,

    pub const full: UVRect = .{};
};

/// Uniform row-major sprite grid. Frame zero is the top-left cell.
pub const SpriteSheet = struct {
    columns: u32,
    rows: u32,

    pub fn frameUv(self: SpriteSheet, frame_index: u32) error{InvalidSpriteSheet}!UVRect {
        const frame_capacity = @as(u64, self.columns) * self.rows;
        if (self.columns == 0 or self.rows == 0 or frame_index >= frame_capacity)
            return error.InvalidSpriteSheet;
        const column = frame_index % self.columns;
        const row = frame_index / self.columns;
        const columns: f32 = @floatFromInt(self.columns);
        const rows: f32 = @floatFromInt(self.rows);
        return .{
            .x = @as(f32, @floatFromInt(column)) / columns,
            .y = @as(f32, @floatFromInt(row)) / rows,
            .width = 1 / columns,
            .height = 1 / rows,
        };
    }
};

/// Plays a clip from a row-major sprite sheet; frame_index is clip-relative.
pub const SpriteAnimation = struct {
    pub const Clip = struct {
        first_frame: u32 = 0,
        frame_count: u16 = 1,
        frames_per_second: f32 = 8,
        looping: bool = true,
    };

    sheet: SpriteSheet,
    clip: Clip = .{},
    frame_index: u16 = 0,
    elapsed_seconds: f32 = 0,
    playing: bool = true,

    /// Selects a clip, restarting only when its configuration changes.
    pub fn play(self: *SpriteAnimation, clip: Clip) void {
        if (std.meta.eql(self.clip, clip)) return;
        self.clip = clip;
        self.frame_index = 0;
        self.elapsed_seconds = 0;
        self.playing = true;
    }

    pub fn update(self: *SpriteAnimation, sprite: *SpriteRenderer, dt: f32) !void {
        const sheet_size = @as(u64, self.sheet.columns) * self.sheet.rows;
        const animation_end = @as(u64, self.clip.first_frame) + self.clip.frame_count;
        if (self.sheet.columns == 0 or self.sheet.rows == 0 or self.clip.frame_count == 0 or
            animation_end > sheet_size or animation_end > @as(u64, std.math.maxInt(u32)) + 1 or
            self.frame_index >= self.clip.frame_count or !std.math.isFinite(self.clip.frames_per_second) or
            self.clip.frames_per_second <= 0 or !std.math.isFinite(dt) or dt < 0 or
            !std.math.isFinite(self.elapsed_seconds) or self.elapsed_seconds < 0)
            return error.InvalidSpriteAnimation;

        if (self.playing and dt > 0) {
            const elapsed = @as(f64, self.elapsed_seconds) + dt;
            const frame_duration_f64: f64 = 1 / self.clip.frames_per_second;
            const frames_to_advance = @floor(elapsed / frame_duration_f64);
            if (frames_to_advance >= 1) {
                if (self.clip.looping) {
                    const wrapped_steps: u32 = @intFromFloat(@mod(
                        frames_to_advance,
                        @as(f64, @floatFromInt(self.clip.frame_count)),
                    ));
                    self.frame_index = @intCast((@as(u32, self.frame_index) + wrapped_steps) % self.clip.frame_count);
                    self.elapsed_seconds = @floatCast(@mod(elapsed, frame_duration_f64));
                } else {
                    const remaining = self.clip.frame_count - self.frame_index;
                    if (frames_to_advance >= remaining) {
                        self.frame_index = self.clip.frame_count - 1;
                        self.elapsed_seconds = 0;
                        self.playing = false;
                    } else {
                        self.frame_index += @intFromFloat(frames_to_advance);
                        self.elapsed_seconds = @floatCast(@mod(elapsed, frame_duration_f64));
                    }
                }
            } else {
                self.elapsed_seconds = @floatCast(elapsed);
            }
        }

        sprite.source_rect = try self.sheet.frameUv(self.clip.first_frame + self.frame_index);
    }
};

/// Draws a texture as a camera-facing 2D quad. `size` is in world units and
/// `z_index` controls painter's order (lower values are drawn first).
/// `draw_offset` shifts the quad in world units without touching gameplay
/// state (used by atlas animation to compensate per-frame drift).
pub const SpriteRenderer = struct {
    texture: Handles.TextureHandle,
    size: Vec2 = .one,
    tint: Vec4 = .one,
    source_rect: UVRect = .full,
    z_index: i32 = 0,
    draw_offset: Vec2 = .zero,
};

/// Plays a named packed-atlas clip; advanced by `AtlasSystem`.
/// Plain data: the atlas handle + clip/frame indices resolve through the
/// asset manager at update time (see `playAtlas`).
pub const AtlasPlayer = struct {
    atlas: Handles.AtlasHandle,
    clip_index: u32 = 0,
    frame_index: u16 = 0,
    elapsed_seconds: f32 = 0,
    playing: bool = true,
};

pub const Align = enum { left, center, right };

/// Bounded, plain-data text content rendered by `Font.TextSystem`.
pub const Text = struct {
    font: Handles.FontHandle,
    content: [256]u8 = .{0} ** 256,
    len: usize = 0,
    size: f32 = 16,
    tint: Vec4 = .one,
    z_index: i32 = 0,
    alignment: Align = .left,

    pub fn setText(self: *Text, value: []const u8) error{TextTooLong}!void {
        if (value.len > self.content.len) return error.TextTooLong;
        @memset(&self.content, 0);
        @memcpy(self.content[0..value.len], value);
        self.len = value.len;
    }
};

/// Marks an implementation-owned glyph sprite and its parent text entity.
pub const GlyphOf = struct {
    parent: Entity,
};

pub const Static = struct {};
