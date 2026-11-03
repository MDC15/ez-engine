const std = @import("std");
const ez = @import("ez_engine");

test "gravity settles a dynamic box onto a static floor" {
    var game = try ez.Game.init(std.testing.allocator, 2);
    defer game.deinit();

    const body = try game.world.create();
    try game.world.add(body, ez.RenderComponents.Transform{ .position = .{ .y = 8 } });
    try game.world.add(body, ez.Collision2D.Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try game.world.add(body, ez.Physics2D.Velocity{});
    try game.world.add(body, ez.Physics2D.RigidBody2D{});

    const floor = try game.world.create();
    try game.world.add(floor, ez.RenderComponents.Transform{});
    try game.world.add(floor, ez.Collision2D.Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true, .is_static = true });

    var physics = ez.Physics2D.System{ .gravity = .{ .x = 0, .y = -100 } };
    const physics_id = try game.scheduler.addSystem("physics", &physics, ez.Physics2D.System.updateSystem);
    var collision = ez.Collision2D.System.init(std.testing.allocator);
    defer collision.deinit();
    const collision_id = try game.scheduler.addSystem("collision", &collision, ez.Collision2D.System.updateSystem);
    try game.scheduler.dependsOn(physics_id, collision_id);

    try game.frame(0.1);

    try std.testing.expectEqual(@as(f32, 10), (try game.world.get(body, ez.RenderComponents.Transform)).position.y);
    try std.testing.expectEqual(@as(f32, 0), (try game.world.get(body, ez.Physics2D.Velocity)).linear.y);
}

test "colliders on disjoint layers ignore each other" {
    var game = try ez.Game.init(std.testing.allocator, 2);
    defer game.deinit();

    const body = try game.world.create();
    try game.world.add(body, ez.RenderComponents.Transform{ .position = .{ .y = 8 } });
    try game.world.add(body, ez.Collision2D.Collider2D{
        .size = .{ .x = 10, .y = 10 },
        .solid = true,
        .layer = 1,
        .collides_with = ez.Collision2D.layerBit(1),
    });
    try game.world.add(body, ez.Physics2D.Velocity{});
    try game.world.add(body, ez.Physics2D.RigidBody2D{});

    const floor = try game.world.create();
    try game.world.add(floor, ez.RenderComponents.Transform{});
    try game.world.add(floor, ez.Collision2D.Collider2D{
        .size = .{ .x = 10, .y = 10 },
        .solid = true,
        .is_static = true,
        .layer = 2,
        .collides_with = ez.Collision2D.layerBit(2),
    });

    var physics = ez.Physics2D.System{ .gravity = .{ .x = 0, .y = -100 } };
    const physics_id = try game.scheduler.addSystem("physics", &physics, ez.Physics2D.System.updateSystem);
    var collision = ez.Collision2D.System.init(std.testing.allocator);
    defer collision.deinit();
    const collision_id = try game.scheduler.addSystem("collision", &collision, ez.Collision2D.System.updateSystem);
    try game.scheduler.dependsOn(physics_id, collision_id);

    try game.frame(0.1);

    // No contact: the body keeps falling through the floor.
    try std.testing.expectEqual(@as(f32, 7), (try game.world.get(body, ez.RenderComponents.Transform)).position.y);
}

test "physics-before-collision ordering and discrete high-velocity tunneling" {
    var game = try ez.Game.init(std.testing.allocator, 2);
    defer game.deinit();

    const body = try game.world.create();
    try game.world.add(body, ez.RenderComponents.Transform{ .position = .{ .y = 10 } });
    try game.world.add(body, ez.Collision2D.Collider2D{
        .size = .{ .x = 1, .y = 1 },
        .solid = true,
    });
    try game.world.add(body, ez.Physics2D.Velocity{ .linear = .{ .y = -100 } });
    try game.world.add(body, ez.Physics2D.RigidBody2D{ .gravity_scale = 0 });

    const falling_body = try game.world.create();
    try game.world.add(falling_body, ez.RenderComponents.Transform{
        .position = .{ .x = 30, .y = 6 },
    });
    try game.world.add(falling_body, ez.Collision2D.Collider2D{
        .size = .{ .x = 1, .y = 1 },
        .solid = true,
    });
    try game.world.add(falling_body, ez.Physics2D.Velocity{ .linear = .{ .y = -10 } });
    try game.world.add(falling_body, ez.Physics2D.RigidBody2D{ .gravity_scale = 0 });

    const wall = try game.world.create();
    try game.world.add(wall, ez.RenderComponents.Transform{ .position = .{ .x = 30 } });
    try game.world.add(wall, ez.Collision2D.Collider2D{
        .size = .{ .x = 10, .y = 10 },
        .solid = true,
        .is_static = true,
    });

    var collision = ez.Collision2D.System.init(std.testing.allocator);
    defer collision.deinit();
    const collision_id = try game.scheduler.addSystem("collision", &collision, ez.Collision2D.System.updateSystem);
    var physics = ez.Physics2D.System{ .gravity = .zero };
    const physics_id = try game.scheduler.addSystem("physics", &physics, ez.Physics2D.System.updateSystem);
    try game.scheduler.dependsOn(physics_id, collision_id);

    try game.frame(0.2);

    try std.testing.expectEqual(@as(f32, -10), (try game.world.get(body, ez.RenderComponents.Transform)).position.y);
    try std.testing.expectEqual(@as(f32, 5.5), (try game.world.get(falling_body, ez.RenderComponents.Transform)).position.y);
    try std.testing.expectEqual(@as(f32, 0), (try game.world.get(falling_body, ez.Physics2D.Velocity)).linear.y);
    try std.testing.expectEqual(@as(usize, 1), collision.active_contacts.items.len);
}
