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

pub fn validateRigidBody(body: RigidBody2D) error{InvalidRigidBody}!void {
    if (!std.math.isFinite(body.gravity_scale) or
        !std.math.isFinite(body.linear_damping) or body.linear_damping < 0 or
        !std.math.isFinite(body.restitution) or body.restitution < 0 or body.restitution > 1)
        return error.InvalidRigidBody;
}

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
        if (!std.math.isFinite(self.gravity.x) or !std.math.isFinite(self.gravity.y))
            return error.InvalidGravity;
        var query = world.query(.{ Components.Transform, Velocity, Query.Optional(RigidBody2D) });
        while (query.next()) |item| {
            const body = item.RigidBody2D;
            if (body) |value| try validateRigidBody(value.*);
            const body_type: BodyType = if (body) |value| value.body_type else .dynamic;
            const velocity = &item.Velocity.linear;
            if (!std.math.isFinite(velocity.x) or !std.math.isFinite(velocity.y) or
                !std.math.isFinite(item.Transform.position.x) or !std.math.isFinite(item.Transform.position.y))
                return error.InvalidBody;
            if (body_type == .static) continue;
            const gravity_scale: f32 = if (body) |value| value.gravity_scale else 0;
            const damping: f32 = if (body) |value| value.linear_damping else 0;

            var next_velocity = velocity.*;
            var next_position = item.Transform.position;
            if (body_type == .dynamic) {
                next_velocity.x += self.gravity.x * gravity_scale * dt;
                next_velocity.y += self.gravity.y * gravity_scale * dt;
                if (damping > 0) {
                    const factor = @max(@as(f32, 0), 1 - damping * dt);
                    next_velocity.x *= factor;
                    next_velocity.y *= factor;
                }
            }
            next_position.x += next_velocity.x * dt;
            next_position.y += next_velocity.y * dt;
            if (!std.math.isFinite(next_velocity.x) or !std.math.isFinite(next_velocity.y) or
                !std.math.isFinite(next_position.x) or !std.math.isFinite(next_position.y))
                return error.InvalidBody;
            velocity.* = next_velocity;
            item.Transform.position = next_position;
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

test "non-finite gravity, velocity, and invalid rigid-body settings are rejected" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.create();
    try world.add(entity, Components.Transform{});
    try world.add(entity, Velocity{});
    try world.add(entity, RigidBody2D{ .linear_damping = -1 });
    var system = System{ .gravity = .zero };
    try std.testing.expectError(error.InvalidRigidBody, system.update(&world, 0.1));

    try world.remove(entity, RigidBody2D);
    try world.add(entity, RigidBody2D{ .restitution = 1.01 });
    try std.testing.expectError(error.InvalidRigidBody, system.update(&world, 0.1));

    try world.remove(entity, RigidBody2D);
    (try world.get(entity, Velocity)).linear.x = std.math.inf(f32);
    try std.testing.expectError(error.InvalidBody, system.update(&world, 0.1));

    (try world.get(entity, Velocity)).linear.x = 0;
    system.gravity.y = std.math.nan(f32);
    try std.testing.expectError(error.InvalidGravity, system.update(&world, 0.1));
}

test "integration rejects overflow without storing non-finite state" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const entity = try world.create();
    try world.add(entity, Components.Transform{});
    try world.add(entity, Velocity{ .linear = .{ .x = std.math.floatMax(f32), .y = 0 } });
    var system = System{ .gravity = .zero };

    try std.testing.expectError(error.InvalidBody, system.update(&world, 2));
    try std.testing.expectEqual(std.math.floatMax(f32), (try world.get(entity, Velocity)).linear.x);
    try std.testing.expectEqual(@as(f32, 0), (try world.get(entity, Components.Transform)).position.x);
}
