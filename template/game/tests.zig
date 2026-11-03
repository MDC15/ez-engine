const std = @import("std");
const Player = @import("src/scripts/player.zig").Player;

test "player animation clips match sprite sheet layout" {
    try std.testing.expectEqual(@as(u16, 1), Player.idle_clip.frame_count);
    try std.testing.expectEqual(@as(u16, 4), Player.walk_clip.frame_count);
}
