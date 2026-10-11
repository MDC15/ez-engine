const std = @import("std");
const ez_engine = @import("ez_engine");

test "mover2d moves bound entity and rejects unbound" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    const entity = try game.world.create();
    try game.world.add(entity, ez_engine.RenderComponents.Transform{});
    var mover = ez_engine.Script.Mover2D{ .entity = entity };
    var ctx = ez_engine.Script.Ctx{
        .world = &game.world,
        .game = &game,
        .dt = 1.0 / 60.0,
        .frame_allocator = game.frameAllocator(),
    };
    game.input.setKey(.d, true);
    const dir = try mover.update(&ctx);
    try std.testing.expectEqual(@as(f32, 1), dir.x);
    try std.testing.expectEqual(@as(f32, 0), dir.y);
    const transform = try game.world.get(entity, ez_engine.RenderComponents.Transform);
    try std.testing.expectEqual(@as(f32, 260.0 / 60.0), transform.position.x);

    var unbound = ez_engine.Script.Mover2D{};
    try std.testing.expectError(error.UnboundEntity, unbound.update(&ctx));
}
