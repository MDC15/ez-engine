const std = @import("std");
const ez = @import("ez_engine");

test "public GameLoop drives fixed steps and reclaims deferred entities" {
    var game = try ez.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop = try ez.GameLoop.initFixed(0.1, 8);

    const entity = try game.world.create();
    try game.destroyDeferred(entity);

    try game.tick(0.25);
    try std.testing.expect(!game.world.isAlive(entity));
    try std.testing.expectEqual(@as(u64, 1), game.frame_index);
    _ = game.reclaimer.arenaBytes();
}

test "Reclaimer works without a Game" {
    var world = ez.World.init(std.testing.allocator);
    defer world.deinit();
    var reclaimer = ez.Reclaimer.init(std.testing.allocator);
    defer reclaimer.deinit();

    const entity = try world.create();
    try world.destroyDeferred(entity);
    try std.testing.expectEqual(@as(usize, 1), world.pendingDestroyCount());

    reclaimer.collect(&world);
    try std.testing.expect(!world.isAlive(entity));
    try std.testing.expectEqual(@as(usize, 0), world.pendingDestroyCount());

    const buffer = try reclaimer.frameAllocator().alloc(u8, 8);
    buffer[0] = 1;
}
