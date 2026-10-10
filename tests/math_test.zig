const std = @import("std");
const game = @import("game_lib");

test "matrix and quaternion transform primitives" {
    const rotation = game.Quat.fromAxisAngle(.{ .z = 1 }, std.math.pi / 2.0);
    const transform = game.Mat4.fromTRS(.{ .x = 3 }, rotation, .one);
    const result = game.Mat4.transformPoint(transform, .{ .x = 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 3), result.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), result.y, 0.0001);
}
