const std = @import("std");
const game_lib = @import("ez_engine");
const GlApp = @import("gl_app").GlApp;

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var app: GlApp = undefined;
    try app.init(allocator, "ez-engine | textured 2D sprites (OpenGL)", 1280, 720, false);
    defer app.deinit();
    var game = &app.game;
    const player_sheet = try game.assets.loadTextureFile(init.io, "assets/player_sheet.png", 16 * 1024 * 1024);
    const sprite = try game.world.create();
    try game.world.add(sprite, game_lib.RenderComponents.Transform{ .position = .{ .x = 0, .y = 0 } });
    try game.world.add(sprite, game_lib.RenderComponents.SpriteRenderer{
        .texture = player_sheet,
        .size = .{ .x = 240, .y = 240 },
        .z_index = 0,
    });
    try app.run(init.io);
}
