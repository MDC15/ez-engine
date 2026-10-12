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

pub const GlApp = struct {
    allocator: std.mem.Allocator,
    window: GlfwWindow,
    backend: SpriteBackend,
    game: ez_engine.Game,

    /// Initializes in place through `self`: the backend's renderer context
    /// and asset pointer must keep pointing at this `GlApp`'s own fields for
    /// the whole run, so callers provide stable storage instead of taking a
    /// returned copy (returning `GlApp` by value would dangle them).
    pub fn init(self: *GlApp, allocator: std.mem.Allocator, title: [:0]const u8, width: u32, height: u32, resizable: bool) !void {
        self.allocator = allocator;
        self.window = try GlfwWindow.initOpenGL(width, height, title, resizable);
        errdefer self.window.deinit();
        zglfw.swapInterval(1);
        self.game = try ez_engine.Game.init(allocator, 2);
        errdefer self.game.deinit();
        self.backend = try SpriteBackend.init(allocator, self.window.native(), &self.game.assets);
        errdefer self.backend.deinit();
        self.game.renderer = self.backend.backend();
        // Permanent guard: the renderer must resolve back to our own fields.
        std.debug.assert(self.game.renderer.?.context == @as(*anyopaque, @ptrCast(&self.backend)));
        std.debug.assert(self.backend.assets == &self.game.assets);
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
