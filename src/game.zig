const std = @import("std");
const World = @import("ecs/world.zig").World;
const Entity = @import("ecs/entity.zig").Entity;
const Scheduler = @import("ecs/scheduler.zig").Scheduler;
const Input = @import("ez_input").Input;
const InputMap = @import("ez_input").InputMap;
const Audio = @import("audio/audio.zig").Audio;
const RenderWorld = @import("gfx/render_world.zig").RenderWorld;
const Backend = @import("gfx/renderer.zig").Backend;
const Clock = @import("core/time.zig").Clock;
const GameLoop = @import("core/game_loop.zig").GameLoop;
const Reclaimer = @import("core/reclaimer.zig").Reclaimer;
const Platform = @import("ez_platform");
const Camera2D = @import("gfx/camera.zig").Camera2D;
const AssetManager = @import("asset/manager.zig").Manager;
const DebugMonitor = @import("core/debug.zig").Monitor;
const Logger = @import("core/log.zig").Logger;

/// Owns common runtime subsystems while leaving window and platform ownership
/// to the application. Feed platform events into input between beginFrame and
/// frame; frame updates gameplay, extracts render data, then submits it.
pub const Game = struct {
    allocator: std.mem.Allocator,
    world: World,
    scheduler: Scheduler,
    assets: AssetManager,
    logger: Logger = .{},
    debug: DebugMonitor = .{},
    input: Input = .{},
    input_map: InputMap,
    audio: Audio,
    render_world: RenderWorld,
    camera_2d: Camera2D = .{},
    loop: GameLoop = .{},
    reclaimer: Reclaimer,
    renderer: ?Backend = null,
    frame_index: u64 = 0,
    update_count: u64 = 0,
    input_consumed: bool = true,
    running: bool = false,
    framebuffer_extent: Platform.Extent2D = .{ .width = 0, .height = 0 },
    rendered_extent: Platform.Extent2D = .{ .width = 0, .height = 0 },

    pub fn init(allocator: std.mem.Allocator, audio_channels: u8) !Game {
        return .{
            .allocator = allocator,
            .world = World.init(allocator),
            .scheduler = Scheduler.init(allocator),
            .assets = AssetManager.init(allocator),
            .audio = try Audio.init(allocator, audio_channels),
            .render_world = RenderWorld.init(allocator),
            .input_map = InputMap.init(allocator),
            .reclaimer = Reclaimer.init(allocator),
        };
    }

    pub fn deinit(self: *Game) void {
        if (self.renderer) |renderer| {
            renderer.waitIdle() catch |err| {
                self.logger.formatCategory(
                    self.allocator,
                    .err,
                    "renderer",
                    "waitIdle failed during Game.deinit: {}",
                    .{err},
                ) catch {};
            };
            renderer.deinit();
            self.renderer = null;
        }
        self.input_map.deinit();
        self.audio.deinit();
        self.assets.deinit();
        self.render_world.deinit();
        self.scheduler.deinit();
        self.world.deinit();
        self.reclaimer.deinit();
    }

    pub fn beginFrame(self: *Game) void {
        // Edges and mouse deltas are cleared by the simulation step that
        // consumes them (see `tick`/`frame`). If the previous rendered frame
        // ran zero steps, keep them so a press on a starved frame survives
        // until a step actually observes it.
        if (self.input_consumed) self.input.beginFrame();
    }

    pub fn update(self: *Game, dt: f32) !void {
        if (!std.math.isFinite(dt) or dt < 0) return error.InvalidDeltaTime;
        try self.scheduler.run(&self.world, dt);
        self.update_count += 1;
    }

    pub fn present(self: *Game, frame_seconds: f32) !void {
        try self.render_world.extract(&self.world);
        const extracted_render_items = self.render_world.items.items.len;
        if (self.framebuffer_extent.width > 0 and self.framebuffer_extent.height > 0) {
            const aspect = @as(f32, @floatFromInt(self.framebuffer_extent.width)) /
                @as(f32, @floatFromInt(self.framebuffer_extent.height));
            self.camera_2d.viewport_size.y = self.camera_2d.viewport_size.x / aspect;
        }
        try self.render_world.cullSprites2D(self.camera_2d);
        self.render_world.sortForBatching();
        if (self.renderer) |renderer| {
            if (self.framebuffer_extent.width > 0 and self.framebuffer_extent.height > 0 and
                (self.framebuffer_extent.width != self.rendered_extent.width or
                    self.framebuffer_extent.height != self.rendered_extent.height))
            {
                try renderer.resize(.{
                    .width = self.framebuffer_extent.width,
                    .height = self.framebuffer_extent.height,
                });
                self.rendered_extent = self.framebuffer_extent;
            }
            try renderer.render(&self.render_world);
        }
        self.frame_index += 1;
        self.debug.captureFrame(
            self.frame_index,
            frame_seconds,
            self.world.aliveCount(),
            extracted_render_items,
            &self.render_world,
        );
        self.reclaimer.collect(&self.world);
    }

    pub fn frame(self: *Game, dt: f32) !void {
        try self.update(dt);
        self.input.clearEdges();
        self.input_consumed = true;
        try self.present(dt);
    }

    pub fn tick(self: *Game, frame_seconds: f64) !void {
        if (self.loop.isStopped()) return;
        const steps = self.loop.stepCount(frame_seconds);
        var index: u32 = 0;
        while (index < steps) : (index += 1) {
            const step_dt: f32 = @floatCast(self.loop.stepSeconds(frame_seconds));
            try self.update(step_dt);
            if (index == 0) self.input.clearEdges();
        }
        self.input_consumed = steps > 0;
        try self.present(@floatCast(self.loop.clampFrameSeconds(frame_seconds)));
    }

    pub fn destroyDeferred(self: *Game, entity: Entity) !void {
        try self.world.destroyDeferred(entity);
    }

    pub fn frameAllocator(self: *Game) std.mem.Allocator {
        return self.reclaimer.frameAllocator();
    }

    pub fn run(self: *Game, io: std.Io, window: Platform.Window) !void {
        var clock = Clock.start(io);
        self.running = true;
        self.framebuffer_extent = window.extent();
        while (self.running and !self.loop.isStopped() and !window.shouldClose()) {
            self.beginFrame();
            try window.pollEvents(onPlatformEvent, self);
            if (!self.running or window.shouldClose()) break;
            try self.tick(clock.tick(io));
        }
    }

    fn onPlatformEvent(context: ?*anyopaque, event: Platform.Event) void {
        const self: *Game = @ptrCast(@alignCast(context.?));
        Platform.feedInput(&self.input, event);
        switch (event) {
            .resized => |extent| self.framebuffer_extent = extent,
            .close_requested => self.running = false,
            else => {},
        }
    }
};

test "game frame updates systems and extracts sprite items" {
    const Components = @import("gfx/render_components.zig");

    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    const entity = try game.world.create();
    try game.world.add(entity, Components.Transform{ .position = .{ .x = 0, .y = 0 } });
    try game.world.add(entity, Components.SpriteRenderer{
        .texture = .{ .index = 2 },
    });
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(usize, 1), game.render_world.items.items.len);
    try std.testing.expectEqual(@as(f32, 0), game.render_world.items.items[0].position.x);
}

test "game frame extracts 2d sprite components" {
    const Components = @import("gfx/render_components.zig");

    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    const entity = try game.world.create();
    try game.world.add(entity, Components.Transform{ .position = .{ .x = 24, .y = -12 } });
    try game.world.add(entity, Components.SpriteRenderer{
        .texture = .{ .index = 4, .generation = 2 },
        .size = .{ .x = 32, .y = 48 },
        .z_index = 7,
    });
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(usize, 1), game.render_world.items.items.len);
    const item = game.render_world.items.items[0];
    try std.testing.expectEqual(@as(u32, 4), item.texture.index);
    try std.testing.expectEqual(@as(f32, 32), item.sprite_size.x);
    try std.testing.expectEqual(@as(i32, 7), item.z_index);
}

test "game exposes a bindable input map" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    try game.input_map.bind("jump", .{ .key = .space });
    game.input.setKey(.space, true);
    try std.testing.expect(game.input_map.justPressed(&game.input, "jump"));
}

test "game shutdown waits for and deinitializes its renderer" {
    const BackendState = struct {
        wait_count: u32 = 0,
        deinit_count: u32 = 0,

        fn resize(_: *anyopaque, _: @import("gfx/renderer.zig").Extent2D) anyerror!void {}
        fn render(_: *anyopaque, _: *const RenderWorld) anyerror!void {}
        fn waitIdle(context: *anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.wait_count += 1;
        }
        fn deinit(context: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context));
            self.deinit_count += 1;
        }
    };

    var game = try Game.init(std.testing.allocator, 2);
    var state: BackendState = .{};
    game.renderer = .{
        .context = &state,
        .vtable = &.{
            .resize = BackendState.resize,
            .render = BackendState.render,
            .waitIdle = BackendState.waitIdle,
            .deinit = BackendState.deinit,
        },
    };
    game.deinit();
    try std.testing.expectEqual(@as(u32, 1), state.wait_count);
    try std.testing.expectEqual(@as(u32, 1), state.deinit_count);
}

test "game tick runs fixed steps and presents once" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop = try GameLoop.initFixed(0.1, 8);

    var updates: u32 = 0;
    const Counter = struct {
        fn run(context: ?*anyopaque, _: *World, _: f32) anyerror!void {
            const count: *u32 = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    _ = try game.scheduler.addSystem("Count", &updates, Counter.run);

    try game.tick(0.25);
    try std.testing.expectEqual(@as(u32, 2), updates);
    try std.testing.expectEqual(@as(u64, 1), game.frame_index);
}

test "paused loop presents without stepping" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop.pause();

    var updates: u32 = 0;
    const Counter = struct {
        fn run(context: ?*anyopaque, _: *World, _: f32) anyerror!void {
            const count: *u32 = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    _ = try game.scheduler.addSystem("Count", &updates, Counter.run);

    try game.tick(0.25);
    try std.testing.expectEqual(@as(u32, 0), updates);
    try std.testing.expectEqual(@as(u64, 1), game.frame_index);
}

test "stopped loop does not present or step" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop.stop();
    try std.testing.expect(game.loop.isStopped());
    try game.tick(0.25);
    try std.testing.expectEqual(@as(u64, 0), game.frame_index);
}

test "fixed loop consumes an input edge once per frame" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop = try GameLoop.initFixed(0.1, 8);
    game.input.setKey(.space, true);

    var presses: u32 = 0;
    const Probe = struct {
        game: *Game,
        presses: *u32,
        fn run(context: ?*anyopaque, _: *World, _: f32) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.game.input.justPressed(.space)) self.presses.* += 1;
        }
    };
    var probe = Probe{ .game = &game, .presses = &presses };
    _ = try game.scheduler.addSystem("Probe", &probe, Probe.run);

    try game.tick(0.25);
    try std.testing.expectEqual(@as(u32, 1), presses);
}

test "input edge survives a rendered frame that runs zero fixed steps" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop = try GameLoop.initFixed(0.1, 8);

    var presses: u32 = 0;
    const Probe = struct {
        game: *Game,
        presses: *u32,
        fn run(context: ?*anyopaque, _: *World, _: f32) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.game.input.justPressed(.space)) self.presses.* += 1;
        }
    };
    var probe = Probe{ .game = &game, .presses = &presses };
    _ = try game.scheduler.addSystem("Probe", &probe, Probe.run);

    // Rendered frame 1: a press arrives, but the accumulator yields no step.
    game.beginFrame();
    game.input.setKey(.space, true);
    try game.tick(0.05);
    try std.testing.expectEqual(@as(u32, 0), presses);

    // Rendered frame 2: the key is still held (no fresh event) and a step runs.
    game.beginFrame();
    try game.tick(0.05);

    try std.testing.expectEqual(@as(u32, 1), presses);
}

test "deferred entity is destroyed after a frame" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    const entity = try game.world.create();
    try game.destroyDeferred(entity);
    try std.testing.expect(game.world.isAlive(entity));
    try game.frame(1.0 / 60.0);
    try std.testing.expect(!game.world.isAlive(entity));
}

test "frame allocator is reusable across frames" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    const first = try game.frameAllocator().alloc(u8, 256);
    first[0] = 1;
    try game.frame(1.0 / 60.0);
    const second = try game.frameAllocator().alloc(u8, 256);
    second[0] = 2;
    try std.testing.expect(game.reclaimer.arenaBytes() > 0);
}
