const std = @import("std");
const ez_engine = @import("ez_engine");
const App = @import("ez_app").App;
const Player = @import("scripts/player.zig").Player;
const Pickup = @import("scripts/pickup.zig");

// Bản đồ khái niệm Unity → template này:
//   Scene (file)   → Scenes/editor_scene.json (sửa vị trí/kích thước ở đó)
//   GameObject     → Entity (mỗi object trong scene nở thành 1 entity)
//   Component      → Transform, SpriteRenderer, Collider2D, ... (gắn bằng world.add)
//   MonoBehaviour  → struct có onStart/onUpdate trong src/scripts/, đăng ký bằng Script.register
//   Build Settings → project.json (startup_scene phải khớp STARTUP_SCENE)
const STARTUP_SCENE = "Scenes/editor_scene.json"; // khớp project.json:startup_scene
const WINDOW_TITLE = "@TITLE@";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    // 1. Cửa sổ + game (như Unity mở viewport).
    var app: App = undefined;
    try app.init(allocator, WINDOW_TITLE, 1280, 720);
    defer app.deinit();
    const game = &app.game;

    // 2. Đọc scene file thành dữ liệu thô.
    var scene = ez_engine.Scene.Document.init(allocator);
    defer scene.deinit();
    try scene.load(init.io, STARTUP_SCENE);

    // 3. Nở mỗi object thành entity + components (như Unity instantiate prefab).
    const player_sheet = try game.assets.loadTextureFile(init.io, "Assets/player_sheet.png", 16 * 1024 * 1024);
    const sprite = try game.assets.loadTextureFile(init.io, "Assets/sprite.png", 16 * 1024 * 1024);
    var player: ?ez_engine.Entity = null;
    for (scene.objects.items) |object| {
        switch (object.kind) {
            .sprite => player = try spawnPlayer(game, player_sheet, object),
            .pickup => try spawnPickup(game, sprite, object),
            .obstacle => try spawnWall(game, sprite, object),
        }
    }
    if (player == null) return error.MissingPlayer;

    // 4. Gắn scripts + systems (như Unity thêm Component vào GameObject).
    var behaviour = Player{};
    behaviour.mover.entity = player.?;
    var script = ez_engine.Script.init(game, &behaviour);
    try script.register(&game.scheduler, "Player movement");
    _ = try game.scheduler.addSystem("Sprite animation", null, ez_engine.SpriteAnimation.updateSystem);
    var collisions = ez_engine.Collision2D.System.init(allocator);
    defer collisions.deinit();
    collisions.setListener(game, Pickup.PickupListener.onContact);
    var physics = ez_engine.Physics2D.System{ .gravity = .zero }; // sample top-down: không có trọng lực
    const physics_id = try game.scheduler.addSystem("2D physics", &physics, ez_engine.Physics2D.System.updateSystem);
    const collision_id = try game.scheduler.addSystem("2D collision", &collisions, ez_engine.Collision2D.System.updateSystem);
    try game.scheduler.dependsOn(physics_id, collision_id);
    var camera_follow = ez_engine.CameraFollow2D.System.init(&game.camera_2d, player.?);
    camera_follow.follow_speed = 7;
    _ = try game.scheduler.addSystem("Camera follow", &camera_follow, ez_engine.CameraFollow2D.System.updateSystem);

    // Debug bật sẵn: log fps + số entity mỗi 60 bước mô phỏng.
    game.debug.enabled = true;
    game.logger.min_level = .debug;
    var stats = StatsLogger{ .game = game };
    _ = try game.scheduler.addSystem("Debug stats", &stats, StatsLogger.update);

    // 5. Chạy.
    game.logger.writeCategory(.info, "sample", "Move with WASD or arrow keys, grab the orange pickup");
    try app.run(init.io);
}

/// System nhỏ log fps + số entity mỗi 60 bước mô phỏng (debug bật sẵn trong main).
const StatsLogger = struct {
    game: *ez_engine.Game,
    tick: u32 = 0,

    fn update(context: ?*anyopaque, _: *ez_engine.World, _: f32) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.tick +%= 1;
        if (self.tick % 60 != 0) return;
        const stats = self.game.debug.stats;
        try self.game.logger.formatCategory(
            self.game.allocator,
            .debug,
            "stats",
            "fps={d:.0} entities={d}",
            .{ stats.fps, stats.entity_count },
        );
    }
};

// Prefab "player": hình lấy từ sprite sheet (hằng số theo art),
// còn vị trí + collider lấy từ scene (sửa JSON là đổi gameplay).
fn spawnPlayer(game: *ez_engine.Game, texture: ez_engine.TextureHandle, object: ez_engine.Scene.Object) !ez_engine.Entity {
    const entity = try game.world.create();
    try game.world.add(entity, ez_engine.RenderComponents.Transform{
        .position = .{ .x = object.position[0], .y = object.position[1] },
    });
    try game.world.add(entity, ez_engine.RenderComponents.SpriteRenderer{
        .texture = texture,
        .size = .{ .x = 240, .y = 240 },
    });
    try game.world.add(entity, ez_engine.RenderComponents.SpriteAnimation{
        .sheet = .{ .columns = 5, .rows = 1 },
        .clip = Player.idle_clip,
    });
    try game.world.add(entity, ez_engine.Collision2D.Collider2D{
        .size = .{ .x = object.size[0], .y = object.size[1] },
        .solid = true,
        .layer = 1,
    });
    return entity;
}

// Prefab "pickup": vị trí + collider từ scene, màu cam để dễ thấy.
fn spawnPickup(game: *ez_engine.Game, texture: ez_engine.TextureHandle, object: ez_engine.Scene.Object) !void {
    const entity = try game.world.create();
    try game.world.add(entity, ez_engine.RenderComponents.Transform{
        .position = .{ .x = object.position[0], .y = object.position[1] },
    });
    try game.world.add(entity, ez_engine.RenderComponents.SpriteRenderer{
        .texture = texture,
        .size = .{ .x = object.size[0], .y = object.size[1] },
        .tint = .{ .x = 1, .y = 0.7, .z = 0.2, .w = 1 },
        .z_index = 1,
    });
    try game.world.add(entity, ez_engine.Collision2D.Collider2D{
        .size = .{ .x = object.size[0], .y = object.size[1] },
        .layer = 3,
        .collides_with = ez_engine.Collision2D.layerBit(1),
    });
    try game.world.add(entity, Pickup.Collectible{});
}

// Prefab "wall": khối tĩnh chặn player, kích thước hoàn toàn từ scene.
fn spawnWall(game: *ez_engine.Game, texture: ez_engine.TextureHandle, object: ez_engine.Scene.Object) !void {
    const entity = try game.world.create();
    try game.world.add(entity, ez_engine.RenderComponents.Transform{
        .position = .{ .x = object.position[0], .y = object.position[1] },
    });
    try game.world.add(entity, ez_engine.RenderComponents.SpriteRenderer{
        .texture = texture,
        .size = .{ .x = object.size[0], .y = object.size[1] },
        .tint = .{ .x = 0.45, .y = 0.5, .z = 0.6, .w = 1 },
        .z_index = 1,
    });
    try game.world.add(entity, ez_engine.Collision2D.Collider2D{
        .size = .{ .x = object.size[0], .y = object.size[1] },
        .solid = true,
        .is_static = true,
        .layer = 2,
        .collides_with = ez_engine.Collision2D.layerBit(1) | ez_engine.Collision2D.layerBit(2),
    });
}
