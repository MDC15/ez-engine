const std = @import("std");
const game_lib = @import("ez_engine");
const App = @import("gl_app").GlApp;

const Player = struct {
    const Animation = game_lib.RenderComponents.SpriteAnimation;
    const idle_clip: Animation.Clip = .{ .first_frame = 0, .frame_count = 1, .frames_per_second = 1 };
    const walk_clip: Animation.Clip = .{ .first_frame = 1, .frame_count = 4, .frames_per_second = 8 };

    mover: game_lib.Script.Mover2D = .{},

    pub fn onUpdate(self: *Player, game: *game_lib.Game, dt: f32) !void {
        if (game.input.isDown(.escape)) game.running = false;
        const direction = try self.mover.update(game, dt);
        const animation = try game.world.get(self.mover.entity.?, Animation);
        animation.play(if (direction.x == 0 and direction.y == 0) idle_clip else walk_clip);
    }
};

const Collectible = struct {};

const PickupListener = struct {
    fn onContact(context: ?*anyopaque, world: *game_lib.World, event: game_lib.Collision2D.Event) anyerror!void {
        const game: *game_lib.Game = @ptrCast(@alignCast(context.?));
        if (event.kind != .stay) {
            try game.logger.formatCategory(
                game.allocator,
                .info,
                "collision",
                "{s} entity={d}:{d} with entity={d}:{d}",
                .{
                    @tagName(event.kind),
                    event.a.id,
                    event.a.generation,
                    event.b.id,
                    event.b.generation,
                },
            );
        }
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

const DebugReporter = struct {
    game: *game_lib.Game,
    elapsed_seconds: f32 = 0,

    fn update(context: ?*anyopaque, _: *game_lib.World, dt: f32) anyerror!void {
        const self: *DebugReporter = @ptrCast(@alignCast(context.?));
        if (self.game.input.justPressed(.f3)) {
            self.game.debug.enabled = !self.game.debug.enabled;
            self.elapsed_seconds = 0;
            self.game.logger.writeCategory(
                .info,
                "debug",
                if (self.game.debug.enabled) "Runtime stats enabled" else "Runtime stats disabled",
            );
        }
        if (!self.game.debug.enabled) return;

        self.elapsed_seconds += dt;
        if (self.elapsed_seconds < 1) return;
        self.elapsed_seconds = @mod(self.elapsed_seconds, 1);

        const stats = self.game.debug.stats;
        self.game.logger.formatCategory(
            self.game.allocator,
            .info,
            "debug",
            "frame={d} fps={d:.1} dt={d:.2}ms entities={d} sprites={d}/{d} culled={d} batches={d}",
            .{
                stats.frame_index,
                stats.fps,
                stats.frame_time_ms,
                stats.entity_count,
                stats.visible_render_items,
                stats.extracted_render_items,
                stats.culled_render_items,
                stats.render_batches,
            },
        ) catch {};
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;
    var app: App = undefined;
    try app.init(allocator, "ez-engine | textured 2D sprites", 960, 540, false);
    defer app.deinit();
    var game = &app.game;
    // Small window, sharp image: render offscreen at 1080p, downscale on present.
    app.backend.render_extent = .{ .width = 1920, .height = 1080 };
    const player_sheet = try game.assets.loadTextureFile(init.io, "assets/Sprites/player_sheet.png", 16 * 1024 * 1024);
    const decoration_texture = try game.assets.loadTextureFile(init.io, "assets/Sprites/sprite.png", 16 * 1024 * 1024);
    const sprite = try game.world.create();
    try game.world.add(sprite, game_lib.RenderComponents.Transform{ .position = .{ .x = 0, .y = 0 } });
    try game.world.add(sprite, game_lib.RenderComponents.SpriteRenderer{
        .texture = player_sheet,
        .size = .{ .x = 240, .y = 240 },
        .z_index = 0,
    });
    try game.world.add(sprite, game_lib.RenderComponents.SpriteAnimation{
        .sheet = .{ .columns = 5, .rows = 1 },
        .clip = Player.idle_clip,
    });
    try game.world.add(sprite, game_lib.Collision2D.Collider2D{
        .size = .{ .x = 48, .y = 48 },
        .solid = true,
    });
    const second = try game.world.create();
    try game.world.add(second, game_lib.RenderComponents.Transform{ .position = .{ .x = 220, .y = 60 } });
    try game.world.add(second, game_lib.RenderComponents.SpriteRenderer{
        .texture = decoration_texture,
        .size = .{ .x = 150, .y = 150 },
        .tint = .{ .x = 0.55, .y = 0.8, .z = 1, .w = 0.85 },
        .z_index = 1,
    });
    const pickup = try game.world.create();
    try game.world.add(pickup, game_lib.RenderComponents.Transform{ .position = .{ .x = 300, .y = 0 } });
    try game.world.add(pickup, game_lib.RenderComponents.SpriteRenderer{
        .texture = decoration_texture,
        .size = .{ .x = 48, .y = 48 },
        .tint = .{ .x = 1, .y = 0.7, .z = 0.2, .w = 1 },
        .z_index = 1,
    });
    try game.world.add(pickup, game_lib.Collision2D.Collider2D{ .size = .{ .x = 40, .y = 40 } });
    try game.world.add(pickup, Collectible{});
    const wall = try game.world.create();
    try game.world.add(wall, game_lib.RenderComponents.Transform{ .position = .{ .x = 0, .y = 150 } });
    try game.world.add(wall, game_lib.RenderComponents.SpriteRenderer{
        .texture = decoration_texture,
        .size = .{ .x = 100, .y = 60 },
        .tint = .{ .x = 0.45, .y = 0.5, .z = 0.6, .w = 1 },
        .z_index = 1,
    });
    try game.world.add(wall, game_lib.Collision2D.Collider2D{
        .size = .{ .x = 100, .y = 60 },
        .solid = true,
        .is_static = true,
    });
    var player = Player{};
    player.mover.entity = sprite;
    var player_script = game_lib.Script.init(game, &player);
    try player_script.register(&game.scheduler, "Player movement");
    _ = try game.scheduler.addSystem("Sprite animation", null, game_lib.SpriteAnimation.updateSystem);
    var collisions = game_lib.Collision2D.System.init(allocator);
    defer collisions.deinit();
    collisions.setListener(game, PickupListener.onContact);
    _ = try game.scheduler.addSystem("2D collision", &collisions, game_lib.Collision2D.System.updateSystem);
    var camera_follow = game_lib.CameraFollow2D.System.init(&game.camera_2d, sprite);
    camera_follow.follow_speed = 7;
    _ = try game.scheduler.addSystem("Camera follow", &camera_follow, game_lib.CameraFollow2D.System.updateSystem);
    var debug_reporter = DebugReporter{ .game = game };
    _ = try game.scheduler.addSystem("Debug stats", &debug_reporter, DebugReporter.update);
    game.logger.writeCategory(.info, "sample", "Press F3 to toggle runtime statistics");
    // GL vsync (swapInterval) is ignored on some drivers/WSL, so cap in
    // software: sleep the remainder of each 1/60s frame in Game.run.
    game.setTargetFps(60);
    try app.run(init.io);
}
