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

pub const App = struct {
    allocator: std.mem.Allocator,
    window: GlfwWindow,
    graphics: *zgpu.GraphicsContext,
    backend: SpriteBackend,
    game: ez_engine.Game,

    pub fn init(allocator: std.mem.Allocator, title: [:0]const u8, width: u32, height: u32) !App {
        var window = try GlfwWindow.init(width, height, title);
        errdefer window.deinit();
        const graphics = try zgpu.GraphicsContext.create(allocator, .{
            .window = window.native(),
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        }, .{});
        errdefer graphics.destroy(allocator);
        var game = try ez_engine.Game.init(allocator, 2);
        errdefer game.deinit();
        var backend = try SpriteBackend.init(allocator, graphics, &game.assets);
        errdefer backend.deinit();
        game.renderer = backend.backend();
        return .{
            .allocator = allocator,
            .window = window,
            .graphics = graphics,
            .backend = backend,
            .game = game,
        };
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
