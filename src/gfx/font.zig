const std = @import("std");
const UVRect = @import("render_components.zig").UVRect;
const Vec2 = @import("../math/vec2.zig").Vec2;
const Components = @import("render_components.zig");
const Handles = @import("../core/handle.zig");
const Entity = @import("../ecs/entity.zig").Entity;
const World = @import("../ecs/world.zig").World;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Manager = @import("../asset/manager.zig").Manager;

pub const Error = error{
    UnsupportedFontVersion,
    InvalidFontGlyph,
    UnknownFontGlyph,
};

pub const Glyph = struct {
    codepoint: u21,
    uv: UVRect,
    offset: Vec2,
    advance: f32,
};

const SerializedGlyph = struct {
    ch: []const u8,
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    advance: f32,
    offset: ?[2]f32 = null,
};

const SerializedFont = struct {
    version: u32 = 1,
    size_px: f32,
    line_height_px: f32,
    glyphs: []SerializedGlyph,
};

pub const OwnedFont = struct {
    arena: std.heap.ArenaAllocator,
    size_px: f32,
    line_height_px: f32,
    glyphs: []Glyph,

    pub const Fallback = union(enum) {
        skip: f32,
        glyph: *const Glyph,
    };

    pub fn deinit(self: *OwnedFont, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.arena.deinit();
        self.glyphs = &.{};
    }

    pub fn glyph(self: *const OwnedFont, codepoint: u21) ?*const Glyph {
        for (self.glyphs) |*item| {
            if (item.codepoint == codepoint) return item;
        }
        return null;
    }

    /// Resolves an unsupported codepoint to U+FFFD, '?', a space advance,
    /// or a half-em skip. Skip advances are returned in world units.
    pub fn fallback(self: *const OwnedFont, codepoint: u21, size: f32) Fallback {
        if (self.glyph(codepoint)) |item| return .{ .glyph = item };
        if (self.glyph(0xfffd)) |item| return .{ .glyph = item };
        if (self.glyph('?')) |item| return .{ .glyph = item };
        if (self.glyph(' ')) |item| return .{ .skip = item.advance * (size / self.size_px) };
        return .{ .skip = size * 0.5 };
    }
};

/// Parses a versioned bitmap-font JSON document against its texture size.
pub fn load(allocator: std.mem.Allocator, json_bytes: []const u8, texture_width: u32, texture_height: u32) !OwnedFont {
    if (texture_width == 0 or texture_height == 0) return Error.InvalidFontGlyph;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const parsed = try std.json.parseFromSlice(SerializedFont, arena.allocator(), json_bytes, .{});
    if (parsed.value.version != 1) return Error.UnsupportedFontVersion;
    if (!std.math.isFinite(parsed.value.size_px) or parsed.value.size_px <= 0 or
        !std.math.isFinite(parsed.value.line_height_px) or parsed.value.line_height_px <= 0)
        return Error.InvalidFontGlyph;

    const tex_w: f32 = @floatFromInt(texture_width);
    const tex_h: f32 = @floatFromInt(texture_height);
    const glyphs = try arena.allocator().alloc(Glyph, parsed.value.glyphs.len);
    for (parsed.value.glyphs, 0..) |input, index| {
        const codepoint = try decodeSingleCodepoint(input.ch);
        const is_space = codepoint == ' ';
        if (!std.math.isFinite(input.x) or !std.math.isFinite(input.y) or
            !std.math.isFinite(input.w) or !std.math.isFinite(input.h) or
            !std.math.isFinite(input.advance) or input.x < 0 or input.y < 0 or
            input.w < 0 or input.h < 0 or input.x + input.w > tex_w or
            input.y + input.h > tex_h or input.advance <= 0 or
            ((!is_space) and (input.w == 0 or input.h == 0)) or
            (is_space and ((input.w == 0) != (input.h == 0)))) return Error.InvalidFontGlyph;
        for (glyphs[0..index]) |existing| {
            if (existing.codepoint == codepoint) return Error.InvalidFontGlyph;
        }
        const offset = input.offset orelse .{ 0, 0 };
        if (!std.math.isFinite(offset[0]) or !std.math.isFinite(offset[1]))
            return Error.InvalidFontGlyph;
        glyphs[index] = .{
            .codepoint = codepoint,
            .uv = .{
                .x = input.x / tex_w,
                .y = input.y / tex_h,
                .width = input.w / tex_w,
                .height = input.h / tex_h,
            },
            .offset = .{ .x = offset[0], .y = offset[1] },
            .advance = input.advance,
        };
    }
    return .{
        .arena = arena,
        .size_px = parsed.value.size_px,
        .line_height_px = parsed.value.line_height_px,
        .glyphs = glyphs,
    };
}

fn decodeSingleCodepoint(bytes: []const u8) Error!u21 {
    if (bytes.len == 0) return Error.InvalidFontGlyph;
    const view = std.unicode.Utf8View.init(bytes) catch return Error.InvalidFontGlyph;
    var iterator = view.iterator();
    const codepoint = iterator.nextCodepoint() orelse return Error.InvalidFontGlyph;
    if (iterator.nextCodepoint() != null) return Error.InvalidFontGlyph;
    return codepoint;
}

pub const PlacedGlyph = struct {
    uv: UVRect,
    quad_w: f32,
    quad_h: f32,
    pen_x: f32,
    pen_y: f32,
};

/// Lays out UTF-8 bytes in world units. Malformed sequences consume one byte
/// and use the font's replacement fallback, so later characters stay aligned.
pub fn layout(
    allocator: std.mem.Allocator,
    font: *const OwnedFont,
    text: []const u8,
    size: f32,
    alignment: Components.Align,
    texture_width: f32,
    texture_height: f32,
) ![]PlacedGlyph {
    if (!std.math.isFinite(size) or size <= 0 or
        !std.math.isFinite(texture_width) or texture_width <= 0 or
        !std.math.isFinite(texture_height) or texture_height <= 0)
        return error.InvalidTextSize;

    const scale = size / font.size_px;
    if (!std.math.isFinite(scale) or scale <= 0) return error.InvalidTextSize;
    const line_count = 1 + std.mem.count(u8, text, "\n");
    const line_widths = try allocator.alloc(f32, line_count);
    defer allocator.free(line_widths);
    @memset(line_widths, 0);

    var codepoint_index: usize = 0;
    var line_index: usize = 0;
    while (nextCodepoint(text, &codepoint_index)) |codepoint| {
        if (codepoint == '\n') {
            line_index += 1;
            continue;
        }
        line_widths[line_index] += advanceFor(font, codepoint, size, scale);
        if (!std.math.isFinite(line_widths[line_index])) return error.InvalidTextSize;
    }

    var alignment_width: f32 = 0;
    for (line_widths) |line_width| alignment_width = @max(alignment_width, line_width);

    var placements: std.ArrayListUnmanaged(PlacedGlyph) = .empty;
    errdefer placements.deinit(allocator);
    codepoint_index = 0;
    var pen_x: f32 = 0;
    var pen_y: f32 = 0;
    const line_origin_x = alignmentOffset(alignment, alignment_width);
    while (nextCodepoint(text, &codepoint_index)) |codepoint| {
        if (codepoint == '\n') {
            pen_x = 0;
            pen_y -= font.line_height_px * scale;
            if (!std.math.isFinite(pen_y)) return error.InvalidTextSize;
            continue;
        }
        switch (font.fallback(codepoint, size)) {
            .skip => |advance| pen_x += advance,
            .glyph => |glyph| {
                const quad_w = glyph.uv.width * texture_width * scale;
                const quad_h = glyph.uv.height * texture_height * scale;
                if (!std.math.isFinite(quad_w) or !std.math.isFinite(quad_h))
                    return error.InvalidTextSize;
                if (quad_w > 0 and quad_h > 0) {
                    const offset_x = glyph.offset.x / texture_width * quad_w;
                    const offset_y = glyph.offset.y / texture_height * quad_h;
                    const placed_x = line_origin_x + pen_x + offset_x;
                    const placed_y = pen_y + offset_y;
                    if (!std.math.isFinite(placed_x) or !std.math.isFinite(placed_y))
                        return error.InvalidTextSize;
                    try placements.append(allocator, .{
                        .uv = glyph.uv,
                        .quad_w = quad_w,
                        .quad_h = quad_h,
                        .pen_x = placed_x,
                        .pen_y = placed_y,
                    });
                }
                pen_x += glyph.advance * scale;
            },
        }
        if (!std.math.isFinite(pen_x) or !std.math.isFinite(pen_y))
            return error.InvalidTextSize;
    }
    return placements.toOwnedSlice(allocator);
}

fn alignmentOffset(alignment: Components.Align, line_width: f32) f32 {
    return switch (alignment) {
        .left => 0,
        .center => -line_width * 0.5,
        .right => -line_width,
    };
}

fn advanceFor(font: *const OwnedFont, codepoint: u21, size: f32, scale: f32) f32 {
    return switch (font.fallback(codepoint, size)) {
        .skip => |advance| advance,
        .glyph => |glyph| glyph.advance * scale,
    };
}

fn nextCodepoint(bytes: []const u8, index: *usize) ?u21 {
    if (index.* >= bytes.len) return null;
    const start = index.*;
    const length = std.unicode.utf8ByteSequenceLength(bytes[start]) catch {
        index.* += 1;
        return 0xfffd;
    };
    const end = start + length;
    if (end > bytes.len) {
        index.* += 1;
        return 0xfffd;
    }
    const sequence = bytes[start..end];
    const decoded: ?u21 = switch (length) {
        1 => sequence[0],
        2 => std.unicode.utf8Decode2(sequence[0..2].*) catch null,
        3 => std.unicode.utf8Decode3(sequence[0..3].*) catch null,
        4 => std.unicode.utf8Decode4(sequence[0..4].*) catch null,
        else => null,
    };
    if (decoded) |codepoint| {
        index.* = end;
        return codepoint;
    }
    index.* += 1;
    return 0xfffd;
}

const TextEntry = struct {
    parent: Entity,
    children: std.ArrayListUnmanaged(Entity) = .empty,
    placements: []PlacedGlyph,
    hash: u64,
};

/// Converts text components to ordinary sprite entities. Call `deinit`
/// before deinitializing the world so generated glyph entities are removed.
pub const TextSystem = struct {
    manager: *Manager,
    allocator: std.mem.Allocator,
    world: ?*World = null,
    entries: std.AutoHashMapUnmanaged(u64, TextEntry) = .empty,

    pub fn init(manager: *Manager) TextSystem {
        return .{ .manager = manager, .allocator = manager.allocator };
    }

    pub fn deinit(self: *TextSystem) void {
        if (self.world) |world| {
            var iterator = self.entries.valueIterator();
            while (iterator.next()) |entry| {
                for (entry.children.items) |child| {
                    if (world.isAlive(child)) {
                        world.destroy(child) catch |err| {
                            std.log.err("failed to destroy text glyph entity: {}", .{err});
                        };
                    }
                }
            }
        }
        var iterator = self.entries.valueIterator();
        while (iterator.next()) |entry| deinitEntry(self.allocator, entry);
        self.entries.deinit(self.allocator);
    }

    pub fn updateSystem(context: ?*anyopaque, world: *World, dt: f32) anyerror!void {
        const self: *TextSystem = @ptrCast(@alignCast(context.?));
        try self.update(world, dt);
    }

    pub fn update(self: *TextSystem, world: *World, dt: f32) !void {
        _ = dt;
        self.world = world;
        defer world.flushDeferred();
        var texts = world.query(.{ Components.Text, Components.Transform });
        while (texts.next()) |item| {
            const text = item.Text.*;
            const transform = item.Transform.*;
            if (text.len > text.content.len or !std.math.isFinite(text.size) or text.size <= 0)
                continue;
            const font_entry = self.manager.getFont(text.font) orelse continue;
            const texture = self.manager.getTexture(font_entry.texture) orelse continue;
            const key = entityKey(item.entity);
            const hash = textHash(&text);
            var entry = self.entries.getPtr(key);
            var must_respawn = entry == null;
            if (entry) |current| {
                must_respawn = current.hash != hash or current.children.items.len != current.placements.len;
                for (current.children.items) |child| {
                    if (!world.isAlive(child) or !world.has(child, Components.Transform) or
                        !world.has(child, Components.SpriteRenderer) or !world.has(child, Components.GlyphOf))
                    {
                        must_respawn = true;
                        break;
                    }
                }
            }
            if (must_respawn) {
                const tex_w: f32 = @floatFromInt(texture.width);
                const tex_h: f32 = @floatFromInt(texture.height);
                const placements = layout(
                    self.allocator,
                    &font_entry.font,
                    text.content[0..text.len],
                    text.size,
                    text.alignment,
                    tex_w,
                    tex_h,
                ) catch |err| switch (err) {
                    error.InvalidTextSize => continue,
                    else => return err,
                };
                try self.respawn(world, item.entity, font_entry.texture, &text, placements, hash, key);
                entry = self.entries.getPtr(key);
            }
            const current = entry orelse continue;
            try self.syncChildren(world, current, &text, &transform, font_entry.texture);
        }
        try self.removeOrphans(world);
    }

    fn respawn(
        self: *TextSystem,
        world: *World,
        parent: Entity,
        texture: Handles.TextureHandle,
        text: *const Components.Text,
        placements: []PlacedGlyph,
        hash: u64,
        key: u64,
    ) !void {
        var placements_transferred = false;
        errdefer if (!placements_transferred) self.allocator.free(placements);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        var replacement = TextEntry{
            .parent = parent,
            .placements = placements,
            .hash = hash,
        };
        errdefer {
            cleanupNewChildren(world, &replacement);
            deinitEntry(self.allocator, &replacement);
            placements_transferred = true;
        }
        try replacement.children.ensureTotalCapacity(self.allocator, placements.len);
        for (placements) |_| {
            const child = try world.create();
            replacement.children.appendAssumeCapacity(child);
            try world.add(child, Components.Transform{});
            try world.add(child, Components.SpriteRenderer{
                .texture = texture,
                .tint = text.tint,
                .z_index = text.z_index,
            });
            try world.add(child, Components.GlyphOf{ .parent = parent });
        }

        if (self.entries.getPtr(key)) |old| {
            try queueChildrenForDestroy(world, old);
            deinitEntry(self.allocator, old);
            old.* = replacement;
        } else {
            self.entries.putAssumeCapacityNoClobber(key, replacement);
        }
        placements_transferred = true;
        replacement.placements = &.{};
        replacement.children = .empty;
    }

    fn syncChildren(
        _: *TextSystem,
        world: *World,
        entry: *const TextEntry,
        text: *const Components.Text,
        parent: *const Components.Transform,
        texture: Handles.TextureHandle,
    ) !void {
        for (entry.children.items, entry.placements) |child, placement| {
            const local = Vec3{
                .x = placement.pen_x * parent.scale.x,
                .y = placement.pen_y * parent.scale.y,
            };
            const position = Vec3.add(parent.position, parent.rotation.rotate(local));
            const glyph_transform = try world.get(child, Components.Transform);
            glyph_transform.* = .{
                .position = position,
                .rotation = parent.rotation,
                .scale = parent.scale,
            };
            const sprite = try world.get(child, Components.SpriteRenderer);
            sprite.* = .{
                .texture = texture,
                .size = .{ .x = placement.quad_w, .y = placement.quad_h },
                .tint = text.tint,
                .source_rect = placement.uv,
                .z_index = text.z_index,
            };
        }
    }

    fn removeOrphans(self: *TextSystem, world: *World) !void {
        var stale_keys: std.ArrayListUnmanaged(u64) = .empty;
        defer stale_keys.deinit(self.allocator);
        var iterator = self.entries.iterator();
        while (iterator.next()) |entry| {
            const parent = entry.value_ptr.parent;
            if (world.isAlive(parent) and world.has(parent, Components.Text) and
                world.has(parent, Components.Transform)) continue;
            try stale_keys.append(self.allocator, entry.key_ptr.*);
            try queueChildrenForDestroy(world, entry.value_ptr);
        }
        for (stale_keys.items) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                var entry = removed.value;
                deinitEntry(self.allocator, &entry);
            }
        }
    }
};

fn entityKey(entity: Entity) u64 {
    return (@as(u64, entity.id) << 32) | entity.generation;
}

fn textHash(text: *const Components.Text) u64 {
    var hasher = std.hash.Wyhash.init(0);
    hasher.update(text.content[0..text.len]);
    hasher.update(std.mem.asBytes(&text.font.index));
    hasher.update(std.mem.asBytes(&text.font.generation));
    hasher.update(std.mem.asBytes(&text.size));
    hasher.update(std.mem.asBytes(&text.z_index));
    hasher.update(std.mem.asBytes(&text.alignment));
    return hasher.final();
}

fn queueChildrenForDestroy(world: *World, entry: *const TextEntry) !void {
    for (entry.children.items) |child| {
        if (world.isAlive(child)) try world.destroyDeferred(child);
    }
}

fn cleanupNewChildren(world: *World, entry: *TextEntry) void {
    for (entry.children.items) |child| {
        if (world.isAlive(child)) {
            world.destroy(child) catch |err| {
                std.log.err("failed to clean up text glyph entity: {}", .{err});
            };
        }
    }
}

fn deinitEntry(allocator: std.mem.Allocator, entry: *TextEntry) void {
    entry.children.deinit(allocator);
    allocator.free(entry.placements);
}

test "font load resolves glyphs and validates rects" {
    const json =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[
        \\ {"ch":"A","x":0,"y":0,"w":4,"h":6,"advance":5},
        \\ {"ch":"B","x":4,"y":0,"w":4,"h":6,"advance":5,"offset":[1,0]},
        \\ {"ch":" ","x":0,"y":0,"w":0,"h":0,"advance":3},
        \\ {"ch":"?","x":0,"y":6,"w":2,"h":2,"advance":3}]}
    ;
    var owned = try load(std.testing.allocator, json, 8, 8);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), (owned.glyph('B').?).uv.x, 1e-5);
    try std.testing.expectEqual(@as(usize, 4), owned.glyphs.len);
    const bad =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[{"ch":"A","x":7,"y":0,"w":4,"h":6,"advance":5}]}
    ;
    try std.testing.expectError(error.InvalidFontGlyph, load(std.testing.allocator, bad, 8, 8));
    const multi_codepoint =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[{"ch":"ab","x":0,"y":0,"w":4,"h":6,"advance":5}]}
    ;
    try std.testing.expectError(error.InvalidFontGlyph, load(std.testing.allocator, multi_codepoint, 8, 8));
}

test "font fallback chain degrades without breaking" {
    const only_a =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[{"ch":"A","x":0,"y":0,"w":4,"h":6,"advance":5}]}
    ;
    var minimal = try load(std.testing.allocator, only_a, 8, 8);
    defer minimal.deinit(std.testing.allocator);
    switch (minimal.fallback('A', 16)) {
        .glyph => |item| try std.testing.expectEqual(@as(u21, 'A'), item.codepoint),
        .skip => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(f32, 8), minimal.fallback('Z', 16).skip);

    const with_replacement =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[
        \\ {"ch":"?","x":0,"y":0,"w":2,"h":2,"advance":3},
        \\ {"ch":"�","x":2,"y":0,"w":2,"h":2,"advance":4}]}
    ;
    var replacement = try load(std.testing.allocator, with_replacement, 8, 8);
    defer replacement.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u21, 0xfffd), replacement.fallback('Z', 16).glyph.codepoint);

    const question_and_space =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[
        \\ {"ch":"?","x":0,"y":0,"w":2,"h":2,"advance":3},
        \\ {"ch":" ","x":0,"y":0,"w":0,"h":0,"advance":4}]}
    ;
    var lower_priority = try load(std.testing.allocator, question_and_space, 8, 8);
    defer lower_priority.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u21, '?'), lower_priority.fallback('Z', 16).glyph.codepoint);

    const space_only =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[{"ch":" ","x":0,"y":0,"w":0,"h":0,"advance":4}]}
    ;
    var space_font = try load(std.testing.allocator, space_only, 8, 8);
    defer space_font.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 8), space_font.fallback('Z', 16).skip);
}

test "text layout places glyphs with advances and newlines" {
    const json =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[
        \\ {"ch":"A","x":0,"y":0,"w":4,"h":6,"advance":5},
        \\ {"ch":"B","x":4,"y":0,"w":4,"h":6,"advance":5},
        \\ {"ch":" ","x":0,"y":0,"w":0,"h":0,"advance":3},
        \\ {"ch":"?","x":0,"y":6,"w":2,"h":2,"advance":3}]}
    ;
    var font = try load(std.testing.allocator, json, 8, 8);
    defer font.deinit(std.testing.allocator);
    const line = try layout(std.testing.allocator, &font, "AB", 16, .left, 8, 8);
    defer std.testing.allocator.free(line);
    try std.testing.expectEqual(@as(usize, 2), line.len);
    try std.testing.expectApproxEqAbs(@as(f32, 10), line[1].pen_x, 1e-5);

    const multiline = try layout(std.testing.allocator, &font, "A\nB", 16, .center, 8, 8);
    defer std.testing.allocator.free(multiline);
    try std.testing.expectApproxEqAbs(@as(f32, -5), multiline[0].pen_x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -20), multiline[1].pen_y, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -5), multiline[1].pen_x, 1e-5);

    const uneven = try layout(std.testing.allocator, &font, "AB\nA", 16, .center, 8, 8);
    defer std.testing.allocator.free(uneven);
    try std.testing.expectApproxEqAbs(@as(f32, -10), uneven[0].pen_x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, -10), uneven[2].pen_x, 1e-5);
}

test "text layout decodes Vietnamese UTF-8 codepoints" {
    const json =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[
        \\ {"ch":"ộ","x":0,"y":0,"w":4,"h":6,"advance":6}]}
    ;
    var font = try load(std.testing.allocator, json, 8, 8);
    defer font.deinit(std.testing.allocator);
    const placements = try layout(std.testing.allocator, &font, "ộộ", 16, .left, 8, 8);
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(usize, 2), placements.len);
    try std.testing.expectApproxEqAbs(@as(f32, 12), placements[1].pen_x, 1e-5);
}

test "text layout replaces invalid UTF-8 and skips missing glyphs" {
    const with_fallback =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[
        \\ {"ch":"A","x":0,"y":0,"w":4,"h":6,"advance":5},
        \\ {"ch":"?","x":4,"y":0,"w":2,"h":2,"advance":3}]}
    ;
    var font = try load(std.testing.allocator, with_fallback, 8, 8);
    defer font.deinit(std.testing.allocator);
    const placements = try layout(std.testing.allocator, &font, "A\xffZ", 8, .left, 8, 8);
    defer std.testing.allocator.free(placements);
    try std.testing.expectEqual(@as(usize, 3), placements.len);
    try std.testing.expectApproxEqAbs(@as(f32, 8), placements[2].pen_x, 1e-5);

    const minimal_json =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[{"ch":"A","x":0,"y":0,"w":4,"h":6,"advance":5}]}
    ;
    var minimal = try load(std.testing.allocator, minimal_json, 8, 8);
    defer minimal.deinit(std.testing.allocator);
    const skipped = try layout(std.testing.allocator, &minimal, "AZA", 8, .left, 8, 8);
    defer std.testing.allocator.free(skipped);
    try std.testing.expectEqual(@as(usize, 2), skipped.len);
    try std.testing.expectApproxEqAbs(@as(f32, 0), skipped[0].pen_x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 9), skipped[1].pen_x, 1e-5);
}

test "text system spawns glyphs, follows the parent, and cleans orphans" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    const font_handle = try manager.loadFontFile(
        threaded.io(),
        "tests/fixtures/font_test.json",
        "tests/fixtures/font_test.ztex",
        1024 * 1024,
    );
    const texture = manager.getFont(font_handle).?.texture;
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var system = TextSystem.init(&manager);
    defer system.deinit();

    const parent = try world.create();
    try world.add(parent, Components.Transform{ .position = .{ .x = 10, .y = 20 } });
    var text = Components.Text{ .font = font_handle };
    try text.setText("AB");
    try world.add(parent, text);
    try system.update(&world, 0);
    try std.testing.expectEqual(@as(usize, 3), world.aliveCount());

    var glyphs = world.query(.{ Components.SpriteRenderer, Components.GlyphOf });
    const first = glyphs.next().?;
    const second = glyphs.next().?;
    try std.testing.expect(glyphs.next() == null);
    try std.testing.expectEqual(texture.index, first.SpriteRenderer.texture.index);
    try std.testing.expectApproxEqAbs(@as(f32, 0), first.SpriteRenderer.source_rect.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), second.SpriteRenderer.source_rect.x, 1e-5);

    (try world.get(parent, Components.Transform)).position.x = 30;
    try system.update(&world, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 30), (try world.get(first.entity, Components.Transform)).position.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 40), (try world.get(second.entity, Components.Transform)).position.x, 1e-5);

    try world.destroy(parent);
    try system.update(&world, 0);
    try std.testing.expectEqual(@as(usize, 0), world.aliveCount());
}

test "text system preserves glyphs for stale font and rejects oversized text" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var manager = Manager.init(std.testing.allocator);
    defer manager.deinit();
    const font_handle = try manager.loadFontFile(
        threaded.io(),
        "tests/fixtures/font_test.json",
        "tests/fixtures/font_test.ztex",
        1024 * 1024,
    );
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var system = TextSystem.init(&manager);
    defer system.deinit();

    const parent = try world.create();
    try world.add(parent, Components.Transform{});
    var text = Components.Text{ .font = font_handle };
    try text.setText("A");
    try world.add(parent, text);
    try system.update(&world, 0);
    var glyphs = world.query(.{ Components.SpriteRenderer, Components.GlyphOf });
    const glyph = glyphs.next().?;
    const original_uv = glyph.SpriteRenderer.source_rect;
    try manager.releaseFont(font_handle);
    try system.update(&world, 1);
    try std.testing.expectEqual(original_uv, (try world.get(glyph.entity, Components.SpriteRenderer)).source_rect);

    var bounded = Components.Text{ .font = font_handle };
    try bounded.setText("old");
    const before = bounded;
    const oversized = [_]u8{'x'} ** 257;
    try std.testing.expectError(error.TextTooLong, bounded.setText(&oversized));
    try std.testing.expectEqual(before, bounded);
}
