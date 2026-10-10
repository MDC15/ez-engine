const std = @import("std");
const ez_engine = @import("ez_engine");
const App = @import("ez_app").App;

const Player = struct {
    const Animation = ez_engine.RenderComponents.SpriteAnimation;
    const idle_clip: Animation.Clip = .{ .first_frame = 0, .frame_count = 1, .frames_per_second = 1 };
    const walk_clip: Animation.Clip = .{ .first_frame = 1, .frame_count = 4, .frames_per_second = 8 };

    mover: ez_engine.Script.Mover2D = .{},

    pub fn onUpdate(self: *Player, ctx: *ez_engine.Script.Ctx) !void {
        if (ctx.game.input.key(.escape).down) ctx.game.running = false;
        const direction = try self.mover.update(ctx);
        const animation = try ctx.world.get(self.mover.entity.?, Animation);
        animation.play(if (direction.x == 0 and direction.y == 0) idle_clip else walk_clip);
    }
};

const Collectible = struct {};

const PickupListener = struct {
    fn onContact(context: ?*anyopaque, world: *ez_engine.World, event: ez_engine.Collision2D.Event) anyerror!void {
        const game: *ez_engine.Game = @ptrCast(@alignCast(context.?));
        if (event.kind != .begin) return;
        const item = if (world.has(event.a, Collectible)) event.a else if (world.has(event.b, Collectible)) event.b else return;
        try game.logger.formatCategory(
            game.allocator,
            .info,
            "gameplay",
            "Picked up item entity={d}:{d}",
            .{ item.id, item.generation },
        );
        try world.destroy(item);
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var app = try App.init(allocator, "MyFirstGame", 1280, 720);
    defer app.deinit();
    const game = &app.game;

    const player_sheet = try game.assets.loadTextureFile(init.io, "Assets/player_sheet.png", 16 * 1024 * 1024);
    const decoration_texture = try game.assets.loadTextureFile(init.io, "Assets/sprite.png", 16 * 1024 * 1024);

    const player = try game.world.create();
    try game.world.add(player, ez_engine.RenderComponents.Transform{});
    try game.world.add(player, ez_engine.RenderComponents.SpriteRenderer{
        .texture = player_sheet,
        .size = .{ .x = 240, .y = 240 },
    });
    try game.world.add(player, ez_engine.RenderComponents.SpriteAnimation{
        .sheet = .{ .columns = 5, .rows = 1 },
        .clip = Player.idle_clip,
    });
    try game.world.add(player, ez_engine.Collision2D.Collider2D{
        .size = .{ .x = 48, .y = 48 },
        .solid = true,
    });

    const pickup = try game.world.create();
    try game.world.add(pickup, ez_engine.RenderComponents.Transform{ .position = .{ .x = 300, .y = 0 } });
    try game.world.add(pickup, ez_engine.RenderComponents.SpriteRenderer{
        .texture = decoration_texture,
        .size = .{ .x = 48, .y = 48 },
        .tint = .{ .x = 1, .y = 0.7, .z = 0.2, .w = 1 },
        .z_index = 1,
    });
    try game.world.add(pickup, ez_engine.Collision2D.Collider2D{ .size = .{ .x = 40, .y = 40 } });
    try game.world.add(pickup, Collectible{});

    const wall = try game.world.create();
    try game.world.add(wall, ez_engine.RenderComponents.Transform{ .position = .{ .x = 0, .y = 150 } });
    try game.world.add(wall, ez_engine.RenderComponents.SpriteRenderer{
        .texture = decoration_texture,
        .size = .{ .x = 100, .y = 60 },
        .tint = .{ .x = 0.45, .y = 0.5, .z = 0.6, .w = 1 },
        .z_index = 1,
    });
    try game.world.add(wall, ez_engine.Collision2D.Collider2D{
        .size = .{ .x = 100, .y = 60 },
        .solid = true,
        .is_static = true,
    });

    var player_behavior = Player{};
    player_behavior.mover.entity = player;
    var player_script = ez_engine.Script.init(game, &player_behavior);
    try player_script.register(&game.scheduler, "Player movement");
    _ = try game.scheduler.addSystem("Sprite animation", null, ez_engine.SpriteAnimation.updateSystem);
    var collisions = ez_engine.Collision2D.System.init(allocator);
    defer collisions.deinit();
    collisions.setListener(game, PickupListener.onContact);
    _ = try game.scheduler.addSystem("2D collision", &collisions, ez_engine.Collision2D.System.updateSystem);
    var camera_follow = ez_engine.CameraFollow2D.System.init(&game.camera_2d, player);
    camera_follow.follow_speed = 7;
    _ = try game.scheduler.addSystem("Camera follow", &camera_follow, ez_engine.CameraFollow2D.System.updateSystem);

    game.logger.writeCategory(.info, "sample", "Move with WASD or arrow keys, grab the orange pickup");
    try app.run(init.io);
}
