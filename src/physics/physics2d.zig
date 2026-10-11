const std = @import("std");
const World = @import("../ecs/world.zig").World;
const Components = @import("../gfx/render_components.zig");
const Vec2 = @import("../math/vec2.zig").Vec2;
const Query = @import("../ecs/query.zig");

/// Linear velocity in world units per second.
pub const Velocity = struct {
    linear: Vec2 = .zero,
};

/// How a body responds to the physics step and to collisions.
pub const BodyType = enum { static, kinematic, dynamic };

/// Motion parameters for a `Velocity` body. Add this to enable gravity,
/// damping and bounce; omit it for constant-velocity motion.
pub const RigidBody2D = struct {
    body_type: BodyType = .dynamic,
    gravity_scale: f32 = 1,
    linear_damping: f32 = 0,
    restitution: f32 = 0,
};

/// Integrates `Velocity` into `Transform` each step. Run it before the
/// `Collision2D` system so contacts see the moved positions.
pub const System = struct {
    gravity: Vec2 = .{ .x = 0, .y = -981 },

    pub fn init() System {
        return .{};
    }

    pub fn updateSystem(context: ?*anyopaque, world: *World, dt: f32) anyerror!void {
        const self: *System = @ptrCast(@alignCast(context.?));
        try self.update(world, dt);
    }

    pub fn update(self: *System, world: *World, dt: f32) !void {
        if (!std.math.isFinite(dt) or dt < 0) return error.InvalidDeltaTime;
        var query = world.query(.{ Components.Transform, Velocity, Query.Optional(RigidBody2D) });
        while (query.next()) |item| {
            const body_type: BodyType = if (item.RigidBody2D) |body| body.body_type else .dynamic;
            if (body_type == .static) continue;
            const gravity_scale: f32 = if (item.RigidBody2D) |body| body.gravity_scale else 0;
            const damping: f32 = if (item.RigidBody2D) |body| body.linear_damping else 0;

            const velocity = &item.Velocity.linear;
            if (body_type == .dynamic) {
                velocity.x += self.gravity.x * gravity_scale * dt;
                velocity.y += self.gravity.y * gravity_scale * dt;
                if (damping > 0) {
                    const factor = @max(@as(f32, 0), 1 - damping * dt);
                    velocity.x *= factor;
                    velocity.y *= factor;
                }
            }
            item.Transform.position.x += velocity.x * dt;
            item.Transform.position.y += velocity.y * dt;
        }
    }
};

test "gravity accelerates a dynamic body and integrates position" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try world.add(e, Components.Transform{});
    try world.add(e, Velocity{});
    try world.add(e, RigidBody2D{ .gravity_scale = 1 });
    var system = System{ .gravity = .{ .x = 0, .y = -10 } };
    try system.update(&world, 0.5);
    try std.testing.expectEqual(@as(f32, -5), (try world.get(e, Velocity)).linear.y);
    try std.testing.expectEqual(@as(f32, -2.5), (try world.get(e, Components.Transform)).position.y);
}

test "linear damping slows a body" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try world.add(e, Components.Transform{});
    try world.add(e, Velocity{ .linear = .{ .x = 10, .y = 0 } });
    try world.add(e, RigidBody2D{ .gravity_scale = 0, .linear_damping = 1 });
    var system = System{ .gravity = .zero };
    try system.update(&world, 0.5);
    try std.testing.expectEqual(@as(f32, 5), (try world.get(e, Velocity)).linear.x);
    try std.testing.expectEqual(@as(f32, 2.5), (try world.get(e, Components.Transform)).position.x);
}

test "velocity without a rigid body has no gravity" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try world.add(e, Components.Transform{});
    try world.add(e, Velocity{ .linear = .{ .x = 4, .y = 0 } });
    var system = System{ .gravity = .{ .x = 0, .y = -10 } };
    try system.update(&world, 0.5);
    try std.testing.expectEqual(@as(f32, 4), (try world.get(e, Velocity)).linear.x);
    try std.testing.expectEqual(@as(f32, 0), (try world.get(e, Velocity)).linear.y);
    try std.testing.expectEqual(@as(f32, 2), (try world.get(e, Components.Transform)).position.x);
}

test "kinematic moves by velocity and static does not move" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const k = try world.create();
    const s = try world.create();
    try world.add(k, Components.Transform{});
    try world.add(k, Velocity{ .linear = .{ .x = 2, .y = 0 } });
    try world.add(k, RigidBody2D{ .body_type = .kinematic });
    try world.add(s, Components.Transform{ .position = .{ .x = 7 } });
    try world.add(s, Velocity{ .linear = .{ .x = 2, .y = 0 } });
    try world.add(s, RigidBody2D{ .body_type = .static });
    var system = System{ .gravity = .{ .x = 0, .y = -10 } };
    try system.update(&world, 0.5);
    try std.testing.expectEqual(@as(f32, 1), (try world.get(k, Components.Transform)).position.x);
    try std.testing.expectEqual(@as(f32, 2), (try world.get(k, Velocity)).linear.x);
    try std.testing.expectEqual(@as(f32, 7), (try world.get(s, Components.Transform)).position.x);
}

test "non-finite or negative dt is rejected" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var system = System{};
    try std.testing.expectError(error.InvalidDeltaTime, system.update(&world, -1));
    try std.testing.expectError(error.InvalidDeltaTime, system.update(&world, std.math.nan(f32)));
}
