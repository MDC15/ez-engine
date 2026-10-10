const std = @import("std");
const Entity = @import("../ecs/entity.zig").Entity;
const World = @import("../ecs/world.zig").World;
const Components = @import("render_components.zig");
const Camera2D = @import("camera.zig").Camera2D;
const Vec2 = @import("../math/vec2.zig").Vec2;

/// Moves a 2D camera toward one entity. A zero follow_speed locks directly
/// to the target; positive values smooth motion using an exponential response.
pub const System = struct {
    camera: *Camera2D,
    target: Entity,
    offset: Vec2 = .zero,
    follow_speed: f32 = 0,

    pub fn init(camera: *Camera2D, target: Entity) System {
        return .{ .camera = camera, .target = target };
    }

    pub fn updateSystem(context: ?*anyopaque, world: *World, dt: f32) anyerror!void {
        const self: *System = @ptrCast(@alignCast(context.?));
        try self.update(world, dt);
    }

    pub fn update(self: *System, world: *World, dt: f32) !void {
        if (!std.math.isFinite(dt) or dt < 0 or
            !std.math.isFinite(self.follow_speed) or self.follow_speed < 0 or
            !std.math.isFinite(self.offset.x) or !std.math.isFinite(self.offset.y))
            return error.InvalidCameraFollow;

        const transform = try world.get(self.target, Components.Transform);
        const target_position = Vec2.add(
            .{ .x = transform.position.x, .y = transform.position.y },
            self.offset,
        );
        if (self.follow_speed == 0) {
            self.camera.center = target_position;
            return;
        }

        const response = 1 - @exp(-self.follow_speed * dt);
        self.camera.center.x += (target_position.x - self.camera.center.x) * response;
        self.camera.center.y += (target_position.y - self.camera.center.y) * response;
    }
};

test "camera follow locks to target and applies offset" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const target = try world.create();
    try world.add(target, Components.Transform{ .position = .{ .x = 40, .y = -20 } });

    var camera: Camera2D = .{};
    var system = System.init(&camera, target);
    system.offset = .{ .x = 3, .y = 5 };
    try system.update(&world, 1.0 / 60.0);
    try std.testing.expectEqual(@as(f32, 43), camera.center.x);
    try std.testing.expectEqual(@as(f32, -15), camera.center.y);
}

test "camera follow smoothing moves toward target without overshooting" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const target = try world.create();
    try world.add(target, Components.Transform{ .position = .{ .x = 100 } });

    var camera: Camera2D = .{};
    var system = System.init(&camera, target);
    system.follow_speed = 4;
    try system.update(&world, 0.1);
    try std.testing.expect(camera.center.x > 0 and camera.center.x < 100);
    const first_position = camera.center.x;
    try system.update(&world, 0.1);
    try std.testing.expect(camera.center.x > first_position and camera.center.x < 100);
}
