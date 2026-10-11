//! Zig-native gameplay scripting: plain structs with `onStart`/`onUpdate`
//! become ECS systems through a comptime adapter. No VM, no hot reload.
//!
//! A `Script` is owned by the caller (usually on the stack next to the
//! behavior) and must outlive the scheduler it registers with: the system
//! context points back at it.

const std = @import("std");
const World = @import("../ecs/world.zig").World;
const Entity = @import("../ecs/entity.zig").Entity;
const Vec2 = @import("../math/vec2.zig").Vec2;
const Components = @import("../gfx/render_components.zig");
const Scheduler = @import("../ecs/scheduler.zig").Scheduler;
const Game = @import("../game.zig").Game;

pub const Script = struct {
    pub const Ctx = struct {
        world: *World,
        game: *Game,
        dt: f32,
        /// Temporary, frame-scoped allocator: freed at the end of the frame.
        frame_allocator: std.mem.Allocator,
    };

    game: *Game,
    ptr: *anyopaque,
    update_fn: *const fn (*anyopaque, *Ctx) anyerror!void,
    start_fn: ?*const fn (*anyopaque, *Ctx) anyerror!void,

    /// Wraps any struct with `onUpdate(*T, *Ctx) (!void|void)`.
    /// Missing `onUpdate` is a compile error at the call site.
    /// A defined `onStart` is silently ignored here — use `initWithStart`.
    pub fn init(game: *Game, behavior: anytype) Script {
        const T = @TypeOf(behavior.*);
        return .{
            .game = game,
            .ptr = behavior,
            .update_fn = wrapUpdate(T),
            .start_fn = null,
        };
    }

    /// Like `init`, but also wires `onStart(*T, *Ctx) (!void|void)`.
    /// `onStart` runs on the first executed frame, so register before the
    /// first `Game.frame` to get it. Two constructors exist because Zig
    /// cannot probe for an optional method across the behavior/lib
    /// reference cycle; explicit is better than magic here.
    pub fn initWithStart(game: *Game, behavior: anytype) Script {
        const T = @TypeOf(behavior.*);
        return .{
            .game = game,
            .ptr = behavior,
            .update_fn = wrapUpdate(T),
            .start_fn = wrapStart(T),
        };
    }

    pub fn register(self: *Script, scheduler: *Scheduler, name: []const u8) !void {
        _ = try scheduler.addSystem(name, self, systemFn);
    }

    /// Ready-made top-down movement: WASD + arrow keys drive the bound
    /// entity's `Transform` at `speed` world units per second. Returns the
    /// normalized direction so behaviors can reuse it (e.g. animation).
    /// Bind `entity` before the first frame; null reads `UnboundEntity`.
    pub const Mover2D = struct {
        entity: ?Entity = null,
        speed: f32 = 260,

        pub fn update(self: *Mover2D, ctx: *Ctx) !Vec2 {
            const entity = self.entity orelse return error.UnboundEntity;
            var direction = Vec2.zero;
            const input = &ctx.game.input;
            if (input.isDown(.a) or input.isDown(.left)) direction.x -= 1;
            if (input.isDown(.d) or input.isDown(.right)) direction.x += 1;
            if (input.isDown(.s) or input.isDown(.down)) direction.y -= 1;
            if (input.isDown(.w) or input.isDown(.up)) direction.y += 1;
            if (direction.x != 0 and direction.y != 0) direction = Vec2.scale(direction, 0.70710678);
            const transform = try ctx.world.get(entity, Components.Transform);
            transform.position.x += direction.x * self.speed * ctx.dt;
            transform.position.y += direction.y * self.speed * ctx.dt;
            return direction;
        }
    };

    fn systemFn(context: ?*anyopaque, world: *World, dt: f32) anyerror!void {
        const self: *Script = @ptrCast(@alignCast(context.?));
        var ctx = Ctx{
            .world = world,
            .game = self.game,
            .dt = dt,
            .frame_allocator = self.game.frameAllocator(),
        };
        if (self.game.update_count == 0) {
            if (self.start_fn) |start| try start(self.ptr, &ctx);
        }
        try self.update_fn(self.ptr, &ctx);
    }

    fn wrapUpdate(comptime T: type) *const fn (*anyopaque, *Ctx) anyerror!void {
        return struct {
            fn f(ptr: *anyopaque, ctx: *Ctx) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                const R = @typeInfo(@TypeOf(T.onUpdate)).@"fn".return_type orelse void;
                if (R == void) {
                    self.onUpdate(ctx);
                } else {
                    try self.onUpdate(ctx);
                }
            }
        }.f;
    }

    fn wrapStart(comptime T: type) *const fn (*anyopaque, *Ctx) anyerror!void {
        return struct {
            fn f(ptr: *anyopaque, ctx: *Ctx) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                const R = @typeInfo(@TypeOf(T.onStart)).@"fn".return_type orelse void;
                if (R == void) {
                    self.onStart(ctx);
                } else {
                    try self.onStart(ctx);
                }
            }
        }.f;
    }
};
