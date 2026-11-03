const std = @import("std");
const ez_engine = @import("ez_engine");
const App = @import("ez_app").App;
const Player = @import("scripts/player.zig").Player;
const Pickup = @import("scripts/pickup.zig");

// Scene path must match the startup_scene configured in project.json.
const STARTUP_SCENE = "Scenes/editor_scene.json"; // khớp project.json:startup_scene
const WINDOW_TITLE = "@TITLE@";

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.page_allocator;

    // 1. Initialize the application window and game runtime.
    var app: App = undefined;
    try app.init(allocator, WINDOW_TITLE, 1280, 720, false);
    defer app.deinit();
    const game = &app.game;

    // 2. Đọc scene file thành dữ liệu thô.
    var scene = ez_engine.Scene.Document.init(allocator);
    defer scene.deinit();
    try scene.load(init.io, STARTUP_SCENE);

    // 3. Resolve stable scene asset paths, then spawn a tracked scene instance.
    var asset_resolver = SceneAssetResolver{ .game = game, .io = init.io };
    var scene_instance = try ez_engine.SceneSpawn.spawnDocumentResolved(
        &game.world,
        allocator,
        &scene,
        .{ .context = &asset_resolver, .resolveFn = SceneAssetResolver.resolve },
    );
    defer scene_instance.despawn(&game.world) catch |err| {
        std.log.err("failed to despawn startup scene: {s}", .{@errorName(err)});
    };

    const player = scene_instance.player;
    for (scene.objects.items) |object| {
        const spawned = scene_instance.entityForObject(object.id) orelse return error.SceneInstanceMismatch;
        if (object.kind == .sprite and player != null and spawned.id == player.?.id) {
            (try game.world.get(player.?, ez_engine.RenderComponents.SpriteAnimation)).clip = Player.idle_clip;
        }
    }
    if (player == null) return error.MissingPlayer;

    const prefab_json = try std.Io.Dir.cwd().readFileAlloc(init.io, "Prefabs/pickup.json", allocator, .limited(1024 * 1024));
    defer allocator.free(prefab_json);
    var pickup_prefab = try ez_engine.Scene.Prefab.parse(allocator, prefab_json);
    defer pickup_prefab.deinit();
    var pickup_instance = try ez_engine.SceneSpawn.spawnPrefabResolved(
        &game.world,
        allocator,
        &pickup_prefab,
        .{ .context = &asset_resolver, .resolveFn = SceneAssetResolver.resolve },
    );
    defer pickup_instance.despawn(&game.world) catch |err| {
        std.log.err("failed to despawn pickup prefab: {s}", .{@errorName(err)});
    };
    const pickup = pickup_instance.entityForObject(pickup_prefab.object.id) orelse return error.PrefabInstanceMismatch;
    try game.world.add(pickup, Pickup.Collectible{});

    // 4. Register gameplay behaviors and runtime systems.
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

const SceneAssetResolver = struct {
    game: *ez_engine.Game,
    io: std.Io,

    fn resolve(context: ?*anyopaque, path: []const u8) anyerror!ez_engine.TextureHandle {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        return self.game.assets.loadTextureFile(self.io, path, 16 * 1024 * 1024);
    }
};

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
