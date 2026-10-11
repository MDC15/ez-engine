const ez_engine = @import("ez_engine");

// MonoBehaviour "Player": đi bằng WASD/arrows, đổi animation idle/walk.
// Gắn vào entity bằng Script.register trong main.zig.
pub const Player = struct {
    const Animation = ez_engine.RenderComponents.SpriteAnimation;

    pub const idle_clip: Animation.Clip = .{ .first_frame = 0, .frame_count = 1, .frames_per_second = 1 };
    pub const walk_clip: Animation.Clip = .{ .first_frame = 1, .frame_count = 4, .frames_per_second = 8 };

    mover: ez_engine.Script.Mover2D = .{},

    pub fn onUpdate(self: *Player, game: *ez_engine.Game, dt: f32) !void {
        if (game.input.isDown(.escape)) game.running = false;
        const direction = try self.mover.update(game, dt);
        const animation = try game.world.get(self.mover.entity.?, Animation);
        animation.play(if (direction.x == 0 and direction.y == 0) idle_clip else walk_clip);
    }
};
