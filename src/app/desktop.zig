//! Desktop application helper: window + graphics + game in one object.
//!
//! Desktop-only (needs `zglfw`/`zgpu`, Linux x86_64). Import as the `ez_app`
//! module from `build.zig`, never from the `ez_engine` root.

const std = @import("std");
const ez_engine = @import("ez_engine");
const zglfw = @import("zglfw");
const zgpu = @import("zgpu");
const GlfwWindow = @import("glfw_window").WindowAdapter;
const SpriteBackend = @import("wgpu_backend").SpriteBackend;
const init_stages = @import("init_stages.zig");

pub const App = struct {
    allocator: std.mem.Allocator,
    window: GlfwWindow,
    graphics: *zgpu.GraphicsContext,
    backend: SpriteBackend,
    game: ez_engine.Game,

    const InitContext = struct {
        app: *App,
        allocator: std.mem.Allocator,
        title: [:0]const u8,
        width: u32,
        height: u32,
        resizable: bool,
        fail_at: ?usize,
    };

    const init_sequence = [_]init_stages.Stage{
        .{ .initialize = initWindow, .cleanup = cleanupWindow },
        .{ .initialize = initGraphics, .cleanup = cleanupGraphics },
        .{ .initialize = initGame, .cleanup = cleanupGame },
        .{ .initialize = initBackend, .cleanup = cleanupBackend },
    };

    /// Initializes in place through `self`: the backend's renderer context
    /// and asset pointer must keep pointing at this `App`'s own fields for
    /// the whole run, so callers provide stable storage instead of taking a
    /// returned copy (returning `App` by value would dangle them).
    pub fn init(self: *App, allocator: std.mem.Allocator, title: [:0]const u8, width: u32, height: u32, resizable: bool) !void {
        try self.initInternal(allocator, title, width, height, resizable, null);
    }

    pub fn initWithFaultInjectionForTesting(
        self: *App,
        allocator: std.mem.Allocator,
        title: [:0]const u8,
        width: u32,
        height: u32,
        resizable: bool,
        fail_at: usize,
    ) !void {
        try self.initInternal(allocator, title, width, height, resizable, fail_at);
    }

    fn initInternal(
        self: *App,
        allocator: std.mem.Allocator,
        title: [:0]const u8,
        width: u32,
        height: u32,
        resizable: bool,
        fail_at: ?usize,
    ) !void {
        self.allocator = allocator;
        var context = InitContext{
            .app = self,
            .allocator = allocator,
            .title = title,
            .width = width,
            .height = height,
            .resizable = resizable,
            .fail_at = fail_at,
        };
        try init_stages.run(&context, &init_sequence);
        // Permanent guard: the renderer must resolve back to our own fields.
        std.debug.assert(self.game.renderer.?.context == @as(*anyopaque, @ptrCast(&self.backend)));
        std.debug.assert(self.backend.assets == &self.game.assets);
    }

    fn initWindow(raw: *anyopaque) anyerror!void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        try injectFailure(context, 0);
        context.app.window = try GlfwWindow.init(context.width, context.height, context.title, context.resizable);
    }

    fn cleanupWindow(raw: *anyopaque) void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        context.app.window.deinit();
    }

    fn initGraphics(raw: *anyopaque) anyerror!void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        try injectFailure(context, 1);
        context.app.graphics = try zgpu.GraphicsContext.create(context.allocator, .{
            .window = context.app.window.native(),
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        }, .{});
    }

    fn cleanupGraphics(raw: *anyopaque) void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        context.app.graphics.destroy(context.allocator);
    }

    fn initGame(raw: *anyopaque) anyerror!void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        try injectFailure(context, 2);
        context.app.game = try ez_engine.Game.init(context.allocator, 2);
    }

    fn cleanupGame(raw: *anyopaque) void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        context.app.game.deinit();
    }

    fn initBackend(raw: *anyopaque) anyerror!void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        try injectFailure(context, 3);
        context.app.backend = try SpriteBackend.init(context.allocator, context.app.graphics, &context.app.game.assets);
        context.app.game.renderer = context.app.backend.backend();
    }

    fn cleanupBackend(raw: *anyopaque) void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        context.app.backend.deinit();
    }

    fn injectFailure(context: *InitContext, stage: usize) error{InjectedInitFailure}!void {
        if (context.fail_at == stage) return error.InjectedInitFailure;
    }

    pub fn run(self: *App, io: std.Io) !void {
        try self.game.run(io, self.window.platformWindow());
    }

    pub fn deinit(self: *App) void {
        // Game.deinit destroys the backend through the renderer first.
        self.game.deinit();
        self.graphics.destroy(self.allocator);
        self.window.deinit();
    }
};
