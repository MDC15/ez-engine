const std = @import("std");
const ez_engine = @import("ez_engine");

const Counter = struct {
    starts: u32 = 0,
    updates: u32 = 0,
    saw_game: bool = false,

    pub fn onStart(self: *Counter, ctx: *ez_engine.Script.Ctx) !void {
        _ = ctx;
        self.starts += 1;
    }

    pub fn onUpdate(self: *Counter, ctx: *ez_engine.Script.Ctx) !void {
        self.updates += 1;
        self.saw_game = (ctx.game.frame_index >= 0);
        _ = ctx.world.aliveCount();
    }
};

test "script calls onStart once and onUpdate every frame" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    var behavior = Counter{};
    var script = ez_engine.Script.initWithStart(&game, &behavior);
    try script.register(&game.scheduler, "Counter");
    try game.frame(1.0 / 60.0);
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), behavior.starts);
    try std.testing.expectEqual(@as(u32, 2), behavior.updates);
    try std.testing.expect(behavior.saw_game);
}

const Boom = struct {
    pub fn onUpdate(_: *Boom, _: *ez_engine.Script.Ctx) !void {
        return error.Boom;
    }
};

const Late = struct {
    starts: u32 = 0,
    pub fn onStart(self: *Late, _: *ez_engine.Script.Ctx) !void {
        self.starts += 1;
    }
    pub fn onUpdate(_: *Late, _: *ez_engine.Script.Ctx) !void {}
};

test "script error aborts frame and late onStart never runs" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    var boom = Boom{};
    var boom_script = ez_engine.Script.init(&game, &boom);
    try boom_script.register(&game.scheduler, "Boom");
    try std.testing.expectError(error.Boom, game.frame(1.0 / 60.0));
}

test "onStart never runs for systems registered after the first frame" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    try game.frame(1.0 / 60.0);
    var late = Late{};
    var late_script = ez_engine.Script.initWithStart(&game, &late);
    try late_script.register(&game.scheduler, "Late");
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 0), late.starts);
}

test "onStart runs on the first update even when the loop starts paused" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop.pause();

    var counter = Counter{};
    var script = ez_engine.Script.initWithStart(&game, &counter);
    try script.register(&game.scheduler, "PausedCounter");

    try game.tick(0.25);
    try std.testing.expectEqual(@as(u32, 0), counter.starts);
    try std.testing.expectEqual(@as(u32, 0), counter.updates);

    game.loop.unpause();
    try game.tick(0.25);
    try std.testing.expectEqual(@as(u32, 1), counter.starts);
    try std.testing.expectEqual(@as(u32, 1), counter.updates);
}

test "script context exposes a reusable frame allocator" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();

    const Allocator = struct {
        bytes: usize = 0,
        pub fn onUpdate(self: *@This(), ctx: *ez_engine.Script.Ctx) !void {
            const buffer = try ctx.frame_allocator.alloc(u8, 64);
            self.bytes += buffer.len;
        }
    };
    var behavior = Allocator{};
    var script = ez_engine.Script.init(&game, &behavior);
    try script.register(&game.scheduler, "Allocator");

    try game.frame(1.0 / 60.0);
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(usize, 128), behavior.bytes);
}

const Modern = struct {
    starts: u32 = 0,
    updates: u32 = 0,
    saw_world: bool = false,

    pub fn onStart(self: *Modern, game: *ez_engine.Game) !void {
        _ = game;
        self.starts += 1;
    }

    pub fn onUpdate(self: *Modern, game: *ez_engine.Game, dt: f32) !void {
        _ = dt;
        self.updates += 1;
        self.saw_world = game.world.aliveCount() >= 0;
    }
};

test "ctx-free behavior receives game and dt" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    var behavior = Modern{};
    var script = ez_engine.Script.initWithStart(&game, &behavior);
    try script.register(&game.scheduler, "Modern");
    try game.frame(1.0 / 60.0);
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), behavior.starts);
    try std.testing.expectEqual(@as(u32, 2), behavior.updates);
    try std.testing.expect(behavior.saw_world);
}

const ModernVoid = struct {
    updates: u32 = 0,
    pub fn onUpdate(self: *ModernVoid, game: *ez_engine.Game, dt: f32) void {
        _ = game;
        _ = dt;
        self.updates += 1;
    }
};

test "ctx-free behavior may return void" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    var behavior = ModernVoid{};
    var script = ez_engine.Script.init(&game, &behavior);
    try script.register(&game.scheduler, "ModernVoid");
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), behavior.updates);
}

const LegacyVoid = struct {
    updates: u32 = 0,
    pub fn onUpdate(self: *LegacyVoid, _: *ez_engine.Script.Ctx) void {
        self.updates += 1;
    }
};

test "ctx behavior may return void" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    var behavior = LegacyVoid{};
    var script = ez_engine.Script.init(&game, &behavior);
    try script.register(&game.scheduler, "LegacyVoid");
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), behavior.updates);
}

const ModernStartVoid = struct {
    starts: u32 = 0,
    pub fn onStart(self: *ModernStartVoid, _: *ez_engine.Game) void {
        self.starts += 1;
    }
    pub fn onUpdate(_: *ModernStartVoid, _: *ez_engine.Game, _: f32) void {}
};

test "ctx-free onStart may return void" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    var behavior = ModernStartVoid{};
    var script = ez_engine.Script.initWithStart(&game, &behavior);
    try script.register(&game.scheduler, "ModernStartVoid");
    try game.frame(1.0 / 60.0);
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), behavior.starts);
}
