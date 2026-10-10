//! Zig-native gameplay scripting: plain structs with `onStart`/`onUpdate`
//! become ECS systems through a comptime adapter. No VM, no hot reload.
//!
//! A `Script` is owned by the caller (usually on the stack next to the
//! behavior) and must outlive the scheduler it registers with: the system
//! context points back at it.

const std = @import("std");
const World = @import("../ecs/world.zig").World;
const Scheduler = @import("../ecs/scheduler.zig").Scheduler;
const Game = @import("../game.zig").Game;

pub const Script = struct {
    pub const Ctx = struct {
        world: *World,
        game: *Game,
        dt: f32,
    };

    game: *Game,
    ptr: *anyopaque,
    update_fn: *const fn (*anyopaque, *Ctx) anyerror!void,
    start_fn: ?*const fn (*anyopaque, *Ctx) anyerror!void,

    /// Wraps any struct with `onUpdate(*T, *Ctx) (!void|void)`.
    /// Missing `onUpdate` is a compile error at the call site.
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

    fn systemFn(context: ?*anyopaque, world: *World, dt: f32) anyerror!void {
        const self: *Script = @ptrCast(@alignCast(context.?));
        var ctx = Ctx{ .world = world, .game = self.game, .dt = dt };
        if (self.game.frame_index == 0) {
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
