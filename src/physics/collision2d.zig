const std = @import("std");
const Entity = @import("../ecs/entity.zig").Entity;
const World = @import("../ecs/world.zig").World;
const Components = @import("../gfx/render_components.zig");
const Vec2 = @import("../math/vec2.zig").Vec2;
const Physics2D = @import("physics2d.zig");

/// Axis-aligned box centered at Transform.position plus the scaled offset.
/// Rotation is ignored. Solid colliders resolve overlap; triggers only report it.
pub const Collider2D = struct {
    size: Vec2,
    offset: Vec2 = .zero,
    enabled: bool = true,
    solid: bool = false,
    is_static: bool = false,
    /// Collision layer bit index (0..15). Like an id/tag for the collider.
    layer: u4 = 0,
    /// Which layers this collider reacts to. Default: every layer.
    collides_with: u16 = 0xffff,
};

/// Mask with exactly `index` set — the bit that stands for layer `index`.
pub fn layerBit(index: u4) u16 {
    return @as(u16, 1) << index;
}

pub const EventKind = enum { begin, stay, end };

pub const Event = struct {
    kind: EventKind,
    a: Entity,
    b: Entity,
};

pub const Listener = *const fn (context: ?*anyopaque, world: *World, event: Event) anyerror!void;

const Contact = struct {
    a: Entity,
    b: Entity,

    fn lessThan(_: void, lhs: Contact, rhs: Contact) bool {
        if (!entityEqual(lhs.a, rhs.a)) return entityLess(lhs.a, rhs.a);
        return entityLess(lhs.b, rhs.b);
    }

    fn eql(lhs: Contact, rhs: Contact) bool {
        return entityEqual(lhs.a, rhs.a) and entityEqual(lhs.b, rhs.b);
    }
};

const Body = struct {
    entity: Entity,
    center: Vec2,
    half_size: Vec2,
    transform: *Components.Transform,
    collider: *Collider2D,
    velocity: ?*Physics2D.Velocity,
    restitution: f32,
    movable: bool,
};

/// ECS overlap system. Contact buffers are reused between frames.
pub const System = struct {
    allocator: std.mem.Allocator,
    listener: ?Listener = null,
    listener_context: ?*anyopaque = null,
    bodies: std.ArrayListUnmanaged(Body) = .empty,
    active_contacts: std.ArrayListUnmanaged(Contact) = .empty,
    next_contacts: std.ArrayListUnmanaged(Contact) = .empty,

    pub fn init(allocator: std.mem.Allocator) System {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *System) void {
        self.next_contacts.deinit(self.allocator);
        self.active_contacts.deinit(self.allocator);
        self.bodies.deinit(self.allocator);
    }

    pub fn deinitSystem(context: ?*anyopaque) void {
        const self: *System = @ptrCast(@alignCast(context.?));
        self.deinit();
    }

    pub fn setListener(self: *System, context: ?*anyopaque, listener: Listener) void {
        self.listener_context = context;
        self.listener = listener;
    }

    pub fn updateSystem(context: ?*anyopaque, world: *World, _: f32) anyerror!void {
        const self: *System = @ptrCast(@alignCast(context.?));
        try self.update(world);
    }

    pub fn update(self: *System, world: *World) !void {
        self.bodies.clearRetainingCapacity();
        var query = world.query(.{ Components.Transform, Collider2D });
        while (query.next()) |item| {
            if (!item.Collider2D.enabled) continue;
            const body = try makeBody(world, item.entity, item.Transform, item.Collider2D);
            try self.bodies.append(self.allocator, body);
        }

        self.next_contacts.clearRetainingCapacity();
        for (self.bodies.items, 0..) |*lhs, lhs_index| {
            for (self.bodies.items[lhs_index + 1 ..]) |*rhs| {
                if (!interacts(lhs.collider, rhs.collider)) continue;
                if (!overlaps(lhs.*, rhs.*)) continue;
                if (lhs.collider.solid and rhs.collider.solid) resolve(lhs, rhs);
                const pair = orderedPair(lhs.entity, rhs.entity);
                try self.next_contacts.append(self.allocator, pair);
            }
        }
        std.mem.sort(Contact, self.next_contacts.items, {}, Contact.lessThan);

        var previous_index: usize = 0;
        var next_index: usize = 0;
        while (previous_index < self.active_contacts.items.len or next_index < self.next_contacts.items.len) {
            if (previous_index == self.active_contacts.items.len) {
                try self.emit(world, .begin, self.next_contacts.items[next_index]);
                next_index += 1;
                continue;
            }
            if (next_index == self.next_contacts.items.len) {
                try self.emit(world, .end, self.active_contacts.items[previous_index]);
                previous_index += 1;
                continue;
            }

            const previous = self.active_contacts.items[previous_index];
            const next = self.next_contacts.items[next_index];
            if (Contact.eql(previous, next)) {
                try self.emit(world, .stay, next);
                previous_index += 1;
                next_index += 1;
            } else if (Contact.lessThan({}, previous, next)) {
                try self.emit(world, .end, previous);
                previous_index += 1;
            } else {
                try self.emit(world, .begin, next);
                next_index += 1;
            }
        }

        std.mem.swap(std.ArrayListUnmanaged(Contact), &self.active_contacts, &self.next_contacts);
    }

    fn emit(self: *System, world: *World, kind: EventKind, contact: Contact) anyerror!void {
        if (self.listener) |listener| {
            try listener(self.listener_context, world, .{ .kind = kind, .a = contact.a, .b = contact.b });
        }
    }
};

fn makeBody(world: *World, entity: Entity, transform: *Components.Transform, collider: *Collider2D) error{InvalidCollider}!Body {
    const values = [_]f32{
        transform.position.x, transform.position.y, transform.scale.x, transform.scale.y,
        collider.offset.x,    collider.offset.y,    collider.size.x,   collider.size.y,
    };
    for (values) |value| if (!std.math.isFinite(value)) return error.InvalidCollider;
    if (collider.size.x < 0 or collider.size.y < 0) return error.InvalidCollider;

    const scale_x = @abs(transform.scale.x);
    const scale_y = @abs(transform.scale.y);
    const center = Vec2{
        .x = transform.position.x + collider.offset.x * transform.scale.x,
        .y = transform.position.y + collider.offset.y * transform.scale.y,
    };
    const half_size = Vec2{
        .x = collider.size.x * scale_x * 0.5,
        .y = collider.size.y * scale_y * 0.5,
    };
    if (!std.math.isFinite(center.x) or !std.math.isFinite(center.y) or
        !std.math.isFinite(half_size.x) or !std.math.isFinite(half_size.y))
        return error.InvalidCollider;

    const velocity: ?*Physics2D.Velocity = world.get(entity, Physics2D.Velocity) catch null;
    const rigid: ?*Physics2D.RigidBody2D = world.get(entity, Physics2D.RigidBody2D) catch null;
    const movable = if (rigid) |body|
        body.body_type == .dynamic
    else
        collider.solid and !collider.is_static;

    return .{
        .entity = entity,
        .center = center,
        .half_size = half_size,
        .transform = transform,
        .collider = collider,
        .velocity = velocity,
        .restitution = if (rigid) |body| body.restitution else 0,
        .movable = movable,
    };
}

fn overlaps(lhs: Body, rhs: Body) bool {
    return @abs(lhs.center.x - rhs.center.x) <= lhs.half_size.x + rhs.half_size.x and
        @abs(lhs.center.y - rhs.center.y) <= lhs.half_size.y + rhs.half_size.y;
}

/// Two colliders interact only when both sides accept the other's layer.
fn interacts(a: *const Collider2D, b: *const Collider2D) bool {
    return (a.collides_with & layerBit(b.layer)) != 0 and
        (b.collides_with & layerBit(a.layer)) != 0;
}

fn resolve(lhs: *Body, rhs: *Body) void {
    if (!lhs.movable and !rhs.movable) return;

    const dx = lhs.center.x - rhs.center.x;
    const dy = lhs.center.y - rhs.center.y;
    const penetration_x = lhs.half_size.x + rhs.half_size.x - @abs(dx);
    const penetration_y = lhs.half_size.y + rhs.half_size.y - @abs(dy);
    const direction = if (penetration_x < penetration_y)
        Vec2{ .x = if (dx < 0) -1 else 1, .y = 0 }
    else
        Vec2{ .x = 0, .y = if (dy < 0) -1 else 1 };
    const penetration = if (direction.x != 0) penetration_x else penetration_y;
    if (penetration <= 0) return;

    if (lhs.movable and !rhs.movable) {
        moveBody(lhs, Vec2.scale(direction, penetration));
    } else if (!lhs.movable and rhs.movable) {
        moveBody(rhs, Vec2.scale(direction, -penetration));
    } else {
        const half_penetration = penetration * 0.5;
        moveBody(lhs, Vec2.scale(direction, half_penetration));
        moveBody(rhs, Vec2.scale(direction, -half_penetration));
    }

    if (lhs.movable) bounce(lhs, direction);
    if (rhs.movable) bounce(rhs, Vec2.scale(direction, -1));
}

/// Remove the velocity component going into the contact and reflect it by the
/// body's restitution. `normal` points away from the other body.
fn bounce(body: *Body, normal: Vec2) void {
    const velocity = body.velocity orelse return;
    const normal_speed = Vec2.dot(velocity.linear, normal);
    if (normal_speed >= 0) return;
    const factor = 1 + body.restitution;
    velocity.linear.x -= normal.x * normal_speed * factor;
    velocity.linear.y -= normal.y * normal_speed * factor;
}

fn moveBody(body: *Body, delta: Vec2) void {
    body.transform.position.x += delta.x;
    body.transform.position.y += delta.y;
    body.center.x += delta.x;
    body.center.y += delta.y;
}

fn orderedPair(a: Entity, b: Entity) Contact {
    return if (entityLess(b, a)) .{ .a = b, .b = a } else .{ .a = a, .b = b };
}

fn entityLess(a: Entity, b: Entity) bool {
    return a.id < b.id or (a.id == b.id and a.generation < b.generation);
}

fn entityEqual(a: Entity, b: Entity) bool {
    return a.id == b.id and a.generation == b.generation;
}

test "AABB system reports begin stay and end contacts" {
    const Recorder = struct {
        events: [4]Event = undefined,
        count: usize = 0,

        fn listen(context: ?*anyopaque, _: *World, event: Event) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.events[self.count] = event;
            self.count += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const a = try world.create();
    const b = try world.create();
    try world.add(a, Components.Transform{});
    try world.add(b, Components.Transform{ .position = .{ .x = 8 } });
    try world.add(a, Collider2D{ .size = .{ .x = 10, .y = 10 } });
    try world.add(b, Collider2D{ .size = .{ .x = 10, .y = 10 } });

    var recorder: Recorder = .{};
    var system = System.init(std.testing.allocator);
    defer system.deinit();
    system.setListener(&recorder, Recorder.listen);

    try system.update(&world);
    try system.update(&world);
    (try world.get(b, Components.Transform)).position.x = 30;
    try system.update(&world);

    try std.testing.expectEqual(@as(usize, 3), recorder.count);
    try std.testing.expectEqual(EventKind.begin, recorder.events[0].kind);
    try std.testing.expectEqual(EventKind.stay, recorder.events[1].kind);
    try std.testing.expectEqual(EventKind.end, recorder.events[2].kind);
    try std.testing.expectEqual(a.id, recorder.events[0].a.id);
    try std.testing.expectEqual(b.id, recorder.events[0].b.id);
}

test "disabled colliders do not produce contacts" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const a = try world.create();
    const b = try world.create();
    try world.add(a, Components.Transform{});
    try world.add(b, Components.Transform{});
    try world.add(a, Collider2D{ .size = .{ .x = 10, .y = 10 } });
    try world.add(b, Collider2D{ .size = .{ .x = 10, .y = 10 }, .enabled = false });
    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(usize, 0), system.active_contacts.items.len);
}

test "solid dynamic collider is moved out of a static collider" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const player = try world.create();
    const wall = try world.create();
    try world.add(player, Components.Transform{ .position = .{ .x = 25 } });
    try world.add(wall, Components.Transform{ .position = .{ .x = 30 } });
    try world.add(player, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try world.add(wall, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true, .is_static = true });

    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(f32, 20), (try world.get(player, Components.Transform)).position.x);
    try system.update(&world);
    try std.testing.expectEqual(@as(f32, 20), (try world.get(player, Components.Transform)).position.x);
}

test "non-matching layers produce no contact" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const a = try world.create();
    const b = try world.create();
    try world.add(a, Components.Transform{});
    try world.add(b, Components.Transform{});
    try world.add(a, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 1, .collides_with = layerBit(1) });
    try world.add(b, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 2, .collides_with = layerBit(2) });
    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(usize, 0), system.active_contacts.items.len);
}

test "one-sided mask mismatch produces no contact" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const a = try world.create();
    const b = try world.create();
    try world.add(a, Components.Transform{});
    try world.add(b, Components.Transform{});
    try world.add(a, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 1, .collides_with = layerBit(1) | layerBit(2) });
    try world.add(b, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 2, .collides_with = layerBit(2) });
    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(usize, 0), system.active_contacts.items.len);
}

test "matching layers still report a contact" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const a = try world.create();
    const b = try world.create();
    try world.add(a, Components.Transform{});
    try world.add(b, Components.Transform{});
    try world.add(a, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 1, .collides_with = layerBit(2) });
    try world.add(b, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 2, .collides_with = layerBit(1) });
    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(usize, 1), system.active_contacts.items.len);
}

test "dynamic body falling onto a static floor separates and stops" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const player = try world.create();
    const floor = try world.create();
    try world.add(player, Components.Transform{ .position = .{ .y = 6 } });
    try world.add(player, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try world.add(player, Physics2D.Velocity{ .linear = .{ .y = -20 } });
    try world.add(player, Physics2D.RigidBody2D{});
    try world.add(floor, Components.Transform{});
    try world.add(floor, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true, .is_static = true });

    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(f32, 10), (try world.get(player, Components.Transform)).position.y);
    try std.testing.expectEqual(@as(f32, 0), (try world.get(player, Physics2D.Velocity)).linear.y);
}

test "restitution one reflects the normal velocity" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const player = try world.create();
    const floor = try world.create();
    try world.add(player, Components.Transform{ .position = .{ .y = 6 } });
    try world.add(player, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try world.add(player, Physics2D.Velocity{ .linear = .{ .y = -20 } });
    try world.add(player, Physics2D.RigidBody2D{ .restitution = 1 });
    try world.add(floor, Components.Transform{});
    try world.add(floor, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true, .is_static = true });

    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(f32, 20), (try world.get(player, Physics2D.Velocity)).linear.y);
}

test "kinematic body is not pushed by an overlapping dynamic body" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const moving = try world.create();
    const platform = try world.create();
    try world.add(moving, Components.Transform{ .position = .{ .x = 6 } });
    try world.add(moving, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try world.add(moving, Physics2D.Velocity{});
    try world.add(moving, Physics2D.RigidBody2D{});
    try world.add(platform, Components.Transform{});
    try world.add(platform, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try world.add(platform, Physics2D.RigidBody2D{ .body_type = .kinematic });

    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(f32, 0), (try world.get(platform, Components.Transform)).position.x);
    try std.testing.expectEqual(@as(f32, 10), (try world.get(moving, Components.Transform)).position.x);
}
