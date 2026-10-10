const ez_engine = @import("ez_engine");

// Marker gắn cho entity nhặt được (như Unity tag "Pickup").
pub const Collectible = struct {};

// Listener xóa vật phẩm khi player chạm vào (chỉ xử lý event begin).
pub const PickupListener = struct {
    pub fn onContact(context: ?*anyopaque, world: *ez_engine.World, event: ez_engine.Collision2D.Event) anyerror!void {
        const game: *ez_engine.Game = @ptrCast(@alignCast(context.?));
        if (event.kind != .begin) return;
        const item = if (world.has(event.a, Collectible))
            event.a
        else if (world.has(event.b, Collectible))
            event.b
        else
            return;
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
