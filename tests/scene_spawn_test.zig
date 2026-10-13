const std = @import("std");
const ez = @import("ez_engine");

test "spawnDocument maps sprite/pickup/obstacle kinds and returns player" {
    var world = ez.World.init(std.testing.allocator);
    defer world.deinit();
    var doc = ez.Scene.Document.init(std.testing.allocator);
    defer doc.deinit();

    const sprite_id = try doc.add(.sprite);
    doc.get(sprite_id).?.position = .{ 10, 20 };
    doc.get(sprite_id).?.size = .{ 64, 64 };
    const pickup_id = try doc.add(.pickup);
    doc.get(pickup_id).?.position = .{ 100, 0 };
    doc.get(pickup_id).?.size = .{ 32, 32 };
    const wall_id = try doc.add(.obstacle);
    doc.get(wall_id).?.position = .{ -50, 5 };
    doc.get(wall_id).?.size = .{ 128, 32 };

    const textures = ez.SceneSpawn.SpawnTextures{
        .player = .{ .index = 1 },
        .sprite = .{ .index = 2 },
    };
    const player = try ez.SceneSpawn.spawnDocument(&world, doc, textures);
    try std.testing.expect(player != null);
    try std.testing.expectEqual(@as(usize, 3), world.aliveCount());

    const transform = try world.get(player.?, ez.RenderComponents.Transform);
    try std.testing.expectEqual(@as(f32, 10), transform.position.x);
    try std.testing.expectEqual(@as(f32, 20), transform.position.y);
}

test "spawnObject rejects non-finite position and zero size without spawning" {
    var world = ez.World.init(std.testing.allocator);
    defer world.deinit();
    const textures = ez.SceneSpawn.SpawnTextures{
        .player = .{ .index = 1 },
        .sprite = .{ .index = 2 },
    };
    const bad_pos = ez.Scene.Object{ .id = 1, .kind = .sprite, .position = .{ std.math.nan(f32), 0 }, .size = .{ 64, 64 } };
    try std.testing.expectError(error.InvalidSceneObject, ez.SceneSpawn.spawnObject(&world, bad_pos, textures));
    const bad_size = ez.Scene.Object{ .id = 2, .kind = .pickup, .position = .{ 0, 0 }, .size = .{ 0, 64 } };
    try std.testing.expectError(error.InvalidSceneObject, ez.SceneSpawn.spawnObject(&world, bad_size, textures));
    try std.testing.expectEqual(@as(usize, 0), world.aliveCount());
}
