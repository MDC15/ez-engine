//! OpenGL desktop application helper: window + GL sprite backend + game.
//!
//! Desktop-only (needs `zglfw` and a GL 3.3 core context, Linux x86_64).
//! Import as the `gl_app` module from `build.zig`, never from the `ez_engine`
//! root.

const std = @import("std");
const ez_engine = @import("ez_engine");
const zglfw = @import("zglfw");
const GlfwWindow = @import("glfw_window").WindowAdapter;
const SpriteBackend = @import("gl_backend").SpriteBackend;
const init_stages = @import("init_stages.zig");

pub const GlApp = struct {
    allocator: std.mem.Allocator,
    window: GlfwWindow,
    backend: SpriteBackend,
    game: ez_engine.Game,

    const InitContext = struct {
        app: *GlApp,
        allocator: std.mem.Allocator,
        title: [:0]const u8,
        width: u32,
        height: u32,
        resizable: bool,
        fail_at: ?usize,
    };

    const init_sequence = [_]init_stages.Stage{
        .{ .initialize = initWindow, .cleanup = cleanupWindow },
        .{ .initialize = initGame, .cleanup = cleanupGame },
        .{ .initialize = initBackend, .cleanup = cleanupBackend },
    };

    /// Initializes in place through `self`: the backend's renderer context
    /// and asset pointer must keep pointing at this `GlApp`'s own fields for
    /// the whole run, so callers provide stable storage instead of taking a
    /// returned copy (returning `GlApp` by value would dangle them).
    pub fn init(self: *GlApp, allocator: std.mem.Allocator, title: [:0]const u8, width: u32, height: u32, resizable: bool) !void {
        try self.initInternal(allocator, title, width, height, resizable, null);
    }

    pub fn initWithFaultInjectionForTesting(
        self: *GlApp,
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
        self: *GlApp,
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
        context.app.window = try GlfwWindow.initOpenGL(context.width, context.height, context.title, context.resizable);
        zglfw.swapInterval(1);
    }

    fn cleanupWindow(raw: *anyopaque) void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        context.app.window.deinit();
    }

    fn initGame(raw: *anyopaque) anyerror!void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        try injectFailure(context, 1);
        context.app.game = try ez_engine.Game.init(context.allocator, 2);
    }

    fn cleanupGame(raw: *anyopaque) void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        context.app.game.deinit();
    }

    fn initBackend(raw: *anyopaque) anyerror!void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        try injectFailure(context, 2);
        context.app.backend = try SpriteBackend.init(context.allocator, context.app.window.native(), &context.app.game.assets);
        context.app.game.renderer = context.app.backend.backend();
    }

    fn cleanupBackend(raw: *anyopaque) void {
        const context: *InitContext = @ptrCast(@alignCast(raw));
        context.app.backend.deinit();
    }

    fn injectFailure(context: *InitContext, stage: usize) error{InjectedInitFailure}!void {
        if (context.fail_at == stage) return error.InjectedInitFailure;
    }

    pub fn run(self: *GlApp, io: std.Io) !void {
        try self.game.run(io, self.window.platformWindow());
    }

    pub fn deinit(self: *GlApp) void {
        // Destroy the game first: it destroys the backend through the renderer.
        self.game.deinit();
        self.window.deinit();
    }
};
