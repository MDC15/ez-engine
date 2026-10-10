const std = @import("std");
const World = @import("../ecs/world.zig").World;
const Components = @import("render_components.zig");

/// ECS system that advances every entity with both sprite and animation data.
pub fn updateSystem(_: ?*anyopaque, world: *World, dt: f32) anyerror!void {
    if (!std.math.isFinite(dt) or dt < 0) return error.InvalidDeltaTime;
    var animated_sprites = world.query(.{ Components.SpriteAnimation, Components.SpriteRenderer });
    while (animated_sprites.next()) |item| {
        try item.SpriteAnimation.update(item.SpriteRenderer, dt);
    }
}
