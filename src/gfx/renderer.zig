const std = @import("std");
const RenderWorld = @import("render_world.zig").RenderWorld;

pub const Extent2D = struct { width: u32, height: u32 };
pub const BackendKind = enum { headless };

/// Offscreen resolution for the scene pass. A fixed override lets a small
/// window render sharp (e.g. 1920x1080) and downscale on present; `null`
/// follows the window/framebuffer size (current default behavior).

pub const Backend = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        resize: *const fn (*anyopaque, Extent2D) anyerror!void,
        render: *const fn (*anyopaque, *const RenderWorld) anyerror!void,
        waitIdle: *const fn (*anyopaque) anyerror!void,
        deinit: *const fn (*anyopaque) void,
    };

    pub fn resize(self: Backend, extent: Extent2D) !void {
        try self.vtable.resize(self.context, extent);
    }

    pub fn render(self: Backend, world: *const RenderWorld) !void {
        try self.vtable.render(self.context, world);
    }

    pub fn waitIdle(self: Backend) !void {
        try self.vtable.waitIdle(self.context);
    }

    pub fn deinit(self: Backend) void {
        self.vtable.deinit(self.context);
    }
};

pub fn resolveRenderExtent(window: Extent2D, override: ?Extent2D) Extent2D {
    return override orelse window;
}

/// Useful for headless/server tests. It validates render submission while
/// doing no GPU work; it is not a rendering backend.
pub const HeadlessStats = struct {
    submitted_frames: u64 = 0,
    submitted_items: u64 = 0,
};

pub const Headless = struct {
    stats: *HeadlessStats,
    extent: Extent2D = .{ .width = 1, .height = 1 },

    pub fn backend(self: *Headless) Backend {
        return .{ .context = self, .vtable = &vtable };
    }

    const vtable = Backend.VTable{
        .resize = resizeImpl,
        .render = renderImpl,
        .waitIdle = waitIdleImpl,
        .deinit = deinitImpl,
    };

    fn resizeImpl(context: *anyopaque, extent: Extent2D) anyerror!void {
        if (extent.width == 0 or extent.height == 0) return error.InvalidExtent;
        const self: *Headless = @ptrCast(@alignCast(context));
        self.extent = extent;
    }

    fn renderImpl(context: *anyopaque, world: *const RenderWorld) anyerror!void {
        const self: *Headless = @ptrCast(@alignCast(context));
        self.stats.submitted_frames += 1;
        self.stats.submitted_items += world.items.items.len;
    }

    fn waitIdleImpl(_: *anyopaque) anyerror!void {}
    fn deinitImpl(_: *anyopaque) void {}
};

test "headless backend accepts render world and tracks submissions" {
    var stats: HeadlessStats = .{};
    var headless = Headless{ .stats = &stats };
    const backend_instance = headless.backend();
    var world = @import("render_world.zig").RenderWorld.init(std.testing.allocator);
    defer world.deinit();
    try backend_instance.render(&world);
    try std.testing.expectEqual(@as(u64, 1), stats.submitted_frames);
}

test "render extent override decouples offscreen resolution from window" {
    const window: Extent2D = .{ .width = 960, .height = 540 };
    const followed = resolveRenderExtent(window, null);
    try std.testing.expectEqual(window.width, followed.width);
    try std.testing.expectEqual(window.height, followed.height);
    const full_hd: Extent2D = .{ .width = 1920, .height = 1080 };
    const overridden = resolveRenderExtent(window, full_hd);
    try std.testing.expectEqual(@as(u32, 1920), overridden.width);
    try std.testing.expectEqual(@as(u32, 1080), overridden.height);
}
