const std = @import("std");
const game_lib = @import("ez_engine");
const App = @import("ez_app").App;

const PlayerController = struct {
    const Animation = game_lib.RenderComponents.SpriteAnimation;
    const idle_clip: Animation.Clip = .{ .first_frame = 0, .frame_count = 1, .frames_per_second = 1 };
    const walk_clip: Animation.Clip = .{ .first_frame = 1, .frame_count = 4, .frames_per_second = 8 };

    game: *game_lib.Game,
    input: *const game_lib.Input,
    player: game_lib.Entity,
    fn keyDown(input: *const game_lib.Input, code: u16) bool {
        const state = input.keyCode(code) catch return false;
        return state.down;
    }

    fn update(context: ?*anyopaque, world: *game_lib.World, dt: f32) anyerror!void {
        const self: *PlayerController = @ptrCast(@alignCast(context.?));
        if (keyDown(self.input, 256)) self.game.running = false; // Escape
        var direction = game_lib.Vec2.zero;
        if (keyDown(self.input, 65)) direction.x -= 1; // A
        if (keyDown(self.input, 68)) direction.x += 1; // D
        if (keyDown(self.input, 83)) direction.y -= 1; // S
        if (keyDown(self.input, 87)) direction.y += 1; // W
        if (direction.x != 0 and direction.y != 0) direction = game_lib.Vec2.scale(direction, 0.70710678);
        const transform = try world.get(self.player, game_lib.RenderComponents.Transform);
        transform.position.x += direction.x * 260 * dt;
        transform.position.y += direction.y * 260 * dt;

        const animation = try world.get(self.player, Animation);
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
        const toggle = self.game.input.keyCode(292) catch return; // F3
        if (toggle.pressed) {
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
    var app = try App.init(allocator, "ez-engine | textured 2D sprites", 1280, 720);
    defer app.deinit();
    var game = &app.game;
    const player_sheet = try game.assets.loadTextureFile(init.io, "assets/player_sheet.png", 16 * 1024 * 1024);
    const decoration_texture = try game.assets.loadTextureFile(init.io, "assets/sprite.png", 16 * 1024 * 1024);
    const sprite = try game.world.create();
    try game.world.add(sprite, game_lib.RenderComponents.Transform{ .position = .{ .x = 0, .y = 0 } });
    try game.world.add(sprite, game_lib.RenderComponents.SpriteRenderer{
        .texture = player_sheet,
        .size = .{ .x = 240, .y = 240 },
        .z_index = 0,
    });
    try game.world.add(sprite, game_lib.RenderComponents.SpriteAnimation{
        .sheet = .{ .columns = 5, .rows = 1 },
        .clip = PlayerController.idle_clip,
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
    var player_controller = PlayerController{ .game = game, .input = &game.input, .player = sprite };
    _ = try game.scheduler.addSystem("Player movement", &player_controller, PlayerController.update);
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
    try app.run(init.io);
}
