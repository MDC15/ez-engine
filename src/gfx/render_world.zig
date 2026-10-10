const std = @import("std");
const Handles = @import("../core/handle.zig");
const Vec2 = @import("../math/vec2.zig").Vec2;
const Vec3 = @import("../math/vec3.zig").Vec3;
const Vec4 = @import("../math/vec4.zig").Vec4;
const Quat = @import("../math/quat.zig").Quat;
const Camera = @import("camera.zig").Camera;
const Camera2D = @import("camera.zig").Camera2D;
const Components = @import("render_components.zig");

pub const ItemKind = enum { mesh, sprite };

/// CPU-side render extraction target. It contains no GPU objects and owns no
/// resource handles; the backend resolves handles through the Game asset manager.
pub const RenderItem = struct {
    kind: ItemKind = .mesh,
    mesh: Handles.MeshHandle = .{ .index = 0, .generation = 0 },
    material: Handles.MaterialHandle = .{ .index = 0, .generation = 0 },
    texture: Handles.TextureHandle = .{ .index = 0, .generation = 0 },
    position: Vec3 = .zero,
    rotation: Quat = .identity,
    scale: Vec3 = .one,
    sprite_size: Vec2 = .one,
    tint: Vec4 = .one,
    source_rect: Components.UVRect = .full,
    z_index: i32 = 0,
    order: usize = 0,
    bounds_radius: f32 = 1,
};

pub const Batch = struct {
    kind: ItemKind,
    mesh: Handles.MeshHandle,
    material: Handles.MaterialHandle,
    texture: Handles.TextureHandle,
    z_index: i32,
    first: usize,
    count: usize,
};

pub const BatchIterator = struct {
    items: []const RenderItem,
    cursor: usize = 0,

    pub fn next(self: *BatchIterator) ?Batch {
        if (self.cursor >= self.items.len) return null;
        const first = self.cursor;
        const item = self.items[first];
        self.cursor += 1;
        while (self.cursor < self.items.len and sameBatch(item, self.items[self.cursor])) : (self.cursor += 1) {}
        return .{
            .kind = item.kind,
            .mesh = item.mesh,
            .material = item.material,
            .texture = item.texture,
            .z_index = item.z_index,
            .first = first,
            .count = self.cursor - first,
        };
    }
};

pub const RenderWorld = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(RenderItem) = .empty,
    camera_2d: Camera2D = .{},

    pub fn init(allocator: std.mem.Allocator) RenderWorld {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RenderWorld) void {
        self.items.deinit(self.allocator);
    }

    pub fn clear(self: *RenderWorld) void {
        self.items.clearRetainingCapacity();
    }

    pub fn add(self: *RenderWorld, item: RenderItem) !void {
        var ordered = item;
        ordered.order = self.items.items.len;
        try self.items.append(self.allocator, ordered);
    }

    pub fn extract(self: *RenderWorld, world: anytype) !void {
        self.clear();
        var meshes = world.query(.{ Components.Transform, Components.MeshRenderer });
        while (meshes.next()) |item| {
            try self.add(.{
                .kind = .mesh,
                .mesh = item.MeshRenderer.mesh,
                .material = item.MeshRenderer.material,
                .position = item.Transform.position,
                .rotation = item.Transform.rotation,
                .scale = item.Transform.scale,
            });
        }
        var sprites = world.query(.{ Components.Transform, Components.SpriteRenderer });
        while (sprites.next()) |item| {
            try self.add(.{
                .kind = .sprite,
                .texture = item.SpriteRenderer.texture,
                .position = item.Transform.position,
                .rotation = item.Transform.rotation,
                .scale = item.Transform.scale,
                .sprite_size = item.SpriteRenderer.size,
                .tint = item.SpriteRenderer.tint,
                .source_rect = item.SpriteRenderer.source_rect,
                .z_index = item.SpriteRenderer.z_index,
            });
        }
    }

    /// Perspective frustum culling applies only to meshes; sprites are culled
    /// against the orthographic camera in `cullSprites2D`.
    pub fn cull(self: *RenderWorld, camera: Camera) !void {
        try camera.validate();
        const forward = camera.forward.normalized();
        const right = Vec3.cross(forward, camera.up).normalized();
        const up = Vec3.cross(right, forward).normalized();
        const tan_half_fov = @tan(camera.vertical_fov_radians * 0.5);
        var visible: usize = 0;
        for (self.items.items) |item| {
            if (item.kind == .sprite) {
                self.items.items[visible] = item;
                visible += 1;
                continue;
            }
            const offset = Vec3.sub(item.position, camera.position);
            const depth = Vec3.dot(offset, forward);
            const radius = @max(item.bounds_radius, 0);
            if (depth + radius < camera.near_plane or depth - radius > camera.far_plane) continue;
            const visible_depth = @max(depth, camera.near_plane);
            const half_height = visible_depth * tan_half_fov;
            const half_width = half_height * camera.aspect_ratio;
            if (@abs(Vec3.dot(offset, right)) > half_width + radius) continue;
            if (@abs(Vec3.dot(offset, up)) > half_height + radius) continue;
            self.items.items[visible] = item;
            visible += 1;
        }
        self.items.items.len = visible;
    }

    pub fn cullSprites2D(self: *RenderWorld, camera: Camera2D) !void {
        try camera.validate();
        self.camera_2d = camera;
        const half_view = Vec2.scale(camera.viewport_size, 0.5 / camera.zoom);
        var visible: usize = 0;
        for (self.items.items) |item| {
            if (item.kind != .sprite) {
                self.items.items[visible] = item;
                visible += 1;
                continue;
            }
            const radius_x = @abs(item.sprite_size.x * item.scale.x) * 0.70710678;
            const radius_y = @abs(item.sprite_size.y * item.scale.y) * 0.70710678;
            const x = item.position.x - camera.center.x;
            const y = item.position.y - camera.center.y;
            if (@abs(x) > half_view.x + radius_x or @abs(y) > half_view.y + radius_y) continue;
            self.items.items[visible] = item;
            visible += 1;
        }
        self.items.items.len = visible;
    }

    /// Sorts by render kind, then sprite painter's order and texture; mesh
    /// instances are grouped by material and mesh.
    pub fn sortForBatching(self: *RenderWorld) void {
        std.mem.sort(RenderItem, self.items.items, {}, lessThan);
    }

    pub fn batches(self: *const RenderWorld) BatchIterator {
        return .{ .items = self.items.items };
    }
};

fn lessThan(_: void, a: RenderItem, b: RenderItem) bool {
    if (a.kind != b.kind) return @intFromEnum(a.kind) < @intFromEnum(b.kind);
    if (a.kind == .sprite) {
        if (a.z_index != b.z_index) return a.z_index < b.z_index;
        return a.order < b.order;
    }
    if (a.material.index != b.material.index) return a.material.index < b.material.index;
    if (a.material.generation != b.material.generation) return a.material.generation < b.material.generation;
    if (a.mesh.index != b.mesh.index) return a.mesh.index < b.mesh.index;
    return a.mesh.generation < b.mesh.generation;
}

fn sameBatch(a: RenderItem, b: RenderItem) bool {
    if (a.kind != b.kind) return false;
    if (a.kind == .sprite) return a.z_index == b.z_index and a.texture.index == b.texture.index and
        a.texture.generation == b.texture.generation;
    return a.mesh.index == b.mesh.index and a.mesh.generation == b.mesh.generation and
        a.material.index == b.material.index and a.material.generation == b.material.generation;
}

test "render world culls, sorts and batches without producing GPU objects" {
    var render_world = RenderWorld.init(std.testing.allocator);
    defer render_world.deinit();
    try render_world.add(.{ .mesh = .{ .index = 2 }, .material = .{ .index = 4 }, .position = .{ .z = -4 } });
    try render_world.add(.{ .mesh = .{ .index = 1 }, .material = .{ .index = 3 }, .position = .{ .z = -3 } });
    try render_world.add(.{ .mesh = .{ .index = 2 }, .material = .{ .index = 4 }, .position = .{ .x = 100, .z = -3 } });
    try render_world.cull(.{ .aspect_ratio = 1 });
    try std.testing.expectEqual(@as(usize, 2), render_world.items.items.len);
    render_world.sortForBatching();
    var batches = render_world.batches();
    try std.testing.expectEqual(@as(usize, 1), batches.next().?.count);
    try std.testing.expectEqual(@as(usize, 1), batches.next().?.count);
    try std.testing.expect(batches.next() == null);
}

test "2d sprites cull and batch by painter layer and texture" {
    var render_world = RenderWorld.init(std.testing.allocator);
    defer render_world.deinit();
    try render_world.add(.{ .kind = .sprite, .texture = .{ .index = 1, .generation = 1 }, .position = .{ .x = 0 } });
    try render_world.add(.{ .kind = .sprite, .texture = .{ .index = 1, .generation = 1 }, .position = .{ .x = 1000 } });
    try render_world.add(.{ .kind = .sprite, .texture = .{ .index = 2, .generation = 1 }, .z_index = 1 });
    try render_world.cullSprites2D(.{});
    try std.testing.expectEqual(@as(usize, 2), render_world.items.items.len);
    render_world.sortForBatching();
    var batches = render_world.batches();
    try std.testing.expectEqual(@as(i32, 0), batches.next().?.z_index);
    try std.testing.expectEqual(@as(i32, 1), batches.next().?.z_index);
    try std.testing.expect(batches.next() == null);
}
