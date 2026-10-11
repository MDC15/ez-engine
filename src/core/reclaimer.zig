const std = @import("std");
const FrameArena = @import("allocator.zig").FrameArena;
const World = @import("../ecs/world.zig").World;

/// End-of-frame reclamation: flushes `World`'s deferred destroys and resets
/// the per-frame arena. Call `collect` once per rendered frame, after systems
/// have finished iterating.
pub const Reclaimer = struct {
    arena: FrameArena,

    pub fn init(allocator: std.mem.Allocator) Reclaimer {
        return .{ .arena = FrameArena.init(allocator) };
    }

    pub fn deinit(self: *Reclaimer) void {
        self.arena.deinit();
    }

    /// Allocator for temporary, frame-scoped data. Freed at the next `collect`.
    pub fn frameAllocator(self: *Reclaimer) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Bytes currently held by the frame arena (retained across resets).
    pub fn arenaBytes(self: *const Reclaimer) usize {
        return self.arena.arena.queryCapacity();
    }

    pub fn collect(self: *Reclaimer, world: *World) void {
        world.flushDeferred();
        self.arena.endFrame();
    }
};

test "collect flushes deferred destroys and resets the frame arena" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var reclaimer = Reclaimer.init(std.testing.allocator);
    defer reclaimer.deinit();

    const entity = try world.create();
    try world.destroyDeferred(entity);

    const scratch = try reclaimer.frameAllocator().alloc(u8, 1024);
    scratch[0] = 7;
    try std.testing.expect(reclaimer.arenaBytes() > 0);

    reclaimer.collect(&world);
    try std.testing.expect(!world.isAlive(entity));
    try std.testing.expectEqual(@as(usize, 0), world.pendingDestroyCount());

    // Arena is reusable after the reset.
    const again = try reclaimer.frameAllocator().alloc(u8, 32);
    again[0] = 1;
}
