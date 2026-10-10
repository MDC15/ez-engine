const std = @import("std");
const ez_engine = @import("ez_engine");

test "headless backend receives one submit per frame" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    const entity = try game.world.create();
    try game.world.add(entity, ez_engine.RenderComponents.Transform{});
    try game.world.add(entity, ez_engine.RenderComponents.SpriteRenderer{
        .texture = .{ .index = 1, .generation = 1 },
    });
    var stats: ez_engine.Renderer.HeadlessStats = .{};
    var headless = ez_engine.Renderer.Headless{ .stats = &stats };
    game.renderer = headless.backend();
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(u64, 1), stats.submitted_frames);
    try std.testing.expectEqual(@as(u64, 1), stats.submitted_items);
}
