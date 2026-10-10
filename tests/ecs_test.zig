const std = @import("std");
const game = @import("game_lib");

test "archetype migration and stale entity handles" {
    const Position = struct { x: f32 };
    const Velocity = struct { x: f32 };
    var world = game.World.init(std.testing.allocator);
    defer world.deinit();

    const old_entity = try world.create();
    try world.add(old_entity, Position{ .x = 1 });
    try world.add(old_entity, Velocity{ .x = 2 });
    (try world.get(old_entity, Position)).x += (try world.get(old_entity, Velocity)).x;
    try std.testing.expectEqual(@as(f32, 3), (try world.get(old_entity, Position)).x);
    try world.destroy(old_entity);

    const new_entity = try world.create();
    try std.testing.expectEqual(old_entity.id, new_entity.id);
    try std.testing.expect(old_entity.generation != new_entity.generation);
    try std.testing.expectError(game.World.Error.InvalidEntity, world.get(old_entity, Position));
}
