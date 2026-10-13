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
    try app.init(allocator, WINDOW_TITLE, 1280, 720, false);
    defer app.deinit();
    const game = &app.game;

    // 2. Đọc scene file thành dữ liệu thô.
    var scene = ez_engine.Scene.Document.init(allocator);
    defer scene.deinit();
    try scene.load(init.io, STARTUP_SCENE);

    // 3. Nở mỗi object thành entity + components (như Unity instantiate prefab).
    // Base components do SceneSpawn lo; marker game-specific gắn thêm tại đây.
    const player_sheet = try game.assets.loadTextureFile(init.io, "Assets/Sprites/player_sheet.png", 16 * 1024 * 1024);
    const sprite = try game.assets.loadTextureFile(init.io, "Assets/Sprites/sprite.png", 16 * 1024 * 1024);
    const textures = ez_engine.SceneSpawn.SpawnTextures{ .player = player_sheet, .sprite = sprite };
    var player: ?ez_engine.Entity = null;
    for (scene.objects.items) |object| {
        const spawned = try ez_engine.SceneSpawn.spawnObject(&game.world, object, textures);
        if (object.kind == .sprite and player == null) {
            player = spawned;
            (try game.world.get(player.?, ez_engine.RenderComponents.SpriteAnimation)).clip = Player.idle_clip;
        } else if (object.kind == .pickup) {
            try game.world.add(spawned.?, Pickup.Collectible{});
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
