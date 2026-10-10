const std = @import("std");
const World = @import("ecs/world.zig").World;
const Scheduler = @import("ecs/scheduler.zig").Scheduler;
const Input = @import("input_module").Input;
const Audio = @import("audio/audio.zig").Audio;
const RenderWorld = @import("gfx/render_world.zig").RenderWorld;
const Backend = @import("gfx/renderer.zig").Backend;
const Clock = @import("core/time.zig").Clock;
const Platform = @import("platform");
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
    audio: Audio,
    render_world: RenderWorld,
    camera_2d: Camera2D = .{},
    renderer: ?Backend = null,
    frame_index: u64 = 0,
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
        self.audio.deinit();
        self.assets.deinit();
        self.render_world.deinit();
        self.scheduler.deinit();
        self.world.deinit();
    }

    pub fn beginFrame(self: *Game) void {
        self.input.beginFrame();
    }

    pub fn frame(self: *Game, dt: f32) !void {
        if (!std.math.isFinite(dt) or dt < 0) return error.InvalidDeltaTime;
        try self.scheduler.run(&self.world, dt);
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
            dt,
            self.world.aliveCount(),
            extracted_render_items,
            &self.render_world,
        );
    }

    pub fn run(self: *Game, io: std.Io, window: Platform.Window) !void {
        var clock = Clock.start(io);
        self.running = true;
        self.framebuffer_extent = window.extent();
        while (self.running and !window.shouldClose()) {
            self.beginFrame();
            try window.pollEvents(onPlatformEvent, self);
            if (!self.running or window.shouldClose()) break;
            const dt: f32 = @floatCast(@min(clock.tick(io), 0.25));
            try self.frame(dt);
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
