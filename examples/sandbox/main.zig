const std = @import("std");
const game_lib = @import("ez_engine");

/// Headless example showing the same asset and ECS sprite path without a
/// window or GPU requirement.
pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var game = try game_lib.Game.init(allocator, 2);
    defer game.deinit();

    const texture = try game.assets.loadTextureFile(init.io, "assets/sprite.ztex", 16 * 1024 * 1024);
    const entity = try game.world.create();
    try game.world.add(entity, game_lib.RenderComponents.Transform{ .position = .{ .x = 12, .y = 8 } });
    try game.world.add(entity, game_lib.RenderComponents.SpriteRenderer{
        .texture = texture,
        .size = .{ .x = 64, .y = 64 },
    });

    var stats: game_lib.Renderer.HeadlessStats = .{};
    var headless = game_lib.Renderer.Headless{ .stats = &stats };
    game.renderer = headless.backend();
    try game.frame(1.0 / 60.0);
    try game.logger.formatCategory(
        allocator,
        .info,
        "render",
        "Headless frame submitted {d} sprite(s)",
        .{stats.submitted_items},
    );
}
