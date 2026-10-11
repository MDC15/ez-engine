const std = @import("std");
const ez_engine = @import("ez_engine");

test "input map binds actions through the public API" {
    var input: ez_engine.Input = .{};
    var map = ez_engine.InputMap.init(std.testing.allocator);
    defer map.deinit();

    try map.bind("jump", ez_engine.InputBinding{ .key = .space });
    try map.bind("jump", ez_engine.InputBinding{ .key = .w });
    try map.bind("left", ez_engine.InputBinding{ .key = .a });
    try map.bind("right", ez_engine.InputBinding{ .key = .d });

    input.setKey(.w, true);
    try std.testing.expect(map.justPressed(&input, "jump"));

    input.beginFrame();
    try std.testing.expect(map.isDown(&input, "jump"));

    input.setKey(.a, true);
    try std.testing.expectEqual(@as(f32, -1), map.axis(&input, "left", "right"));
}

test "game owns an input map that is freed on deinit" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    try game.input_map.bind("dash", ez_engine.InputBinding{ .key = .left_shift });
    game.input.setKey(.left_shift, true);
    try std.testing.expect(game.input_map.isDown(&game.input, "dash"));
}
