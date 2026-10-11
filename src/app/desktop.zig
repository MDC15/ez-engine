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

    /// Initializes in place through `self`: the backend's renderer context
    /// and asset pointer must keep pointing at this `App`'s own fields for
    /// the whole run, so callers provide stable storage instead of taking a
    /// returned copy (returning `App` by value would dangle them).
    pub fn init(self: *App, allocator: std.mem.Allocator, title: [:0]const u8, width: u32, height: u32, resizable: bool) !void {
        self.allocator = allocator;
        self.window = try GlfwWindow.init(width, height, title, resizable);
        errdefer self.window.deinit();
        self.graphics = try zgpu.GraphicsContext.create(allocator, .{
            .window = self.window.native(),
            .fn_getTime = @ptrCast(&zglfw.getTime),
            .fn_getFramebufferSize = @ptrCast(&zglfw.Window.getFramebufferSize),
            .fn_getWin32Window = @ptrCast(&zglfw.getWin32Window),
            .fn_getX11Display = @ptrCast(&zglfw.getX11Display),
            .fn_getX11Window = @ptrCast(&zglfw.getX11Window),
            .fn_getWaylandDisplay = @ptrCast(&zglfw.getWaylandDisplay),
            .fn_getWaylandSurface = @ptrCast(&zglfw.getWaylandWindow),
            .fn_getCocoaWindow = @ptrCast(&zglfw.getCocoaWindow),
        }, .{});
        errdefer self.graphics.destroy(allocator);
        self.game = try ez_engine.Game.init(allocator, 2);
        errdefer self.game.deinit();
        self.backend = try SpriteBackend.init(allocator, self.graphics, &self.game.assets);
        errdefer self.backend.deinit();
        self.game.renderer = self.backend.backend();
        // Permanent guard: the renderer must resolve back to our own fields.
        std.debug.assert(self.game.renderer.?.context == @as(*anyopaque, @ptrCast(&self.backend)));
        std.debug.assert(self.backend.assets == &self.game.assets);
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
