const std = @import("std");
const game_lib = @import("game_lib");

test "sprite extract, cull and batch order locked" {
    var world = game_lib.World.init(std.testing.allocator);
    defer world.deinit();

    const tex_a = game_lib.TextureHandle{ .index = 1, .generation = 1 };
    const tex_b = game_lib.TextureHandle{ .index = 2, .generation = 1 };

    const e1 = try world.create();
    try world.add(e1, game_lib.RenderComponents.Transform{ .position = .{ .x = 0, .y = 0 } });
    try world.add(e1, game_lib.RenderComponents.SpriteRenderer{ .texture = tex_a, .z_index = 0 });

    const e2 = try world.create();
    try world.add(e2, game_lib.RenderComponents.Transform{ .position = .{ .x = 10000, .y = 0 } });
    try world.add(e2, game_lib.RenderComponents.SpriteRenderer{ .texture = tex_a, .z_index = 0 });

    const e3 = try world.create();
    try world.add(e3, game_lib.RenderComponents.Transform{ .position = .{ .x = 0, .y = 0 } });
    try world.add(e3, game_lib.RenderComponents.SpriteRenderer{ .texture = tex_b, .z_index = 1 });

    var rw = game_lib.RenderWorld.init(std.testing.allocator);
    defer rw.deinit();
    try rw.extract(&world);
    try std.testing.expectEqual(@as(usize, 3), rw.items.items.len);
    try rw.cullSprites2D(.{});
    try std.testing.expectEqual(@as(usize, 2), rw.items.items.len);
    rw.sortForBatching();
    var it = rw.batches();
    const b1 = it.next().?;
    const b2 = it.next().?;
    try std.testing.expectEqual(@as(i32, 0), b1.z_index);
    try std.testing.expectEqual(@as(i32, 1), b2.z_index);
    try std.testing.expect(it.next() == null);
}
