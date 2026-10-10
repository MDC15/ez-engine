const std = @import("std");
const game = @import("game_lib");

test "typed include exclude and optional queries" {
    const Position = struct { x: f32 };
    const Velocity = struct { x: f32 };
    const Static = struct {};
    var world = game.World.init(std.testing.allocator);
    defer world.deinit();

    const moving = try world.create();
    try world.add(moving, Position{ .x = 1 });
    try world.add(moving, Velocity{ .x = 2 });
    const fixed = try world.create();
    try world.add(fixed, Position{ .x = 5 });
    try world.add(fixed, Velocity{ .x = 0 });
    try world.add(fixed, Static{});

    var query = world.query(.{
        .include = .{ Position, Velocity, game.Query.Optional(Static) },
        .exclude = .{game.Query.Exclude(Static)},
    });
    const item = query.next().?;
    try std.testing.expectEqual(@as(f32, 1), item.Position.x);
    try std.testing.expect(item.Static == null);
    try std.testing.expect(query.next() == null);
}
