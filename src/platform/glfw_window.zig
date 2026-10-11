const zglfw = @import("zglfw");
const game_lib = @import("ez_engine");
const Platform = game_lib.Platform;

/// GLFW window adapter for the engine's platform event and run-loop interface.
pub const WindowAdapter = struct {
    native_window: *zglfw.Window,
    callback: ?Platform.EventFn = null,
    callback_context: ?*anyopaque = null,

    const vtable = Platform.Window.VTable{
        .poll_events = pollEventsImpl,
        .framebuffer_extent = framebufferExtentImpl,
        .request_close = requestCloseImpl,
        .should_close = shouldCloseImpl,
    };

    pub fn init(width: u32, height: u32, title: [:0]const u8, resizable: bool) !WindowAdapter {
        try zglfw.init();
        errdefer zglfw.terminate();

        zglfw.windowHint(.client_api, .no_api);
        zglfw.windowHint(.resizable, resizable);
        const native_window = try zglfw.Window.create(@intCast(width), @intCast(height), title, null, null);
        errdefer native_window.destroy();

        _ = native_window.setKeyCallback(onKey);
        _ = native_window.setMouseButtonCallback(onMouseButton);
        _ = native_window.setCursorPosCallback(onCursorPosition);
        _ = native_window.setScrollCallback(onScroll);
        _ = native_window.setFramebufferSizeCallback(onFramebufferResize);

        return .{ .native_window = native_window };
    }

    pub fn deinit(self: *WindowAdapter) void {
        self.native_window.destroy();
        zglfw.terminate();
    }

    pub fn native(self: *WindowAdapter) *zglfw.Window {
        return self.native_window;
    }

    pub fn platformWindow(self: *WindowAdapter) Platform.Window {
        return .{ .context = self, .vtable = &vtable };
    }

    fn fromNative(window: *zglfw.Window) ?*WindowAdapter {
        // GLFW may dispatch the initial Wayland framebuffer resize during
        // graphics-context setup, before pollEventsImpl installs the pointer.
        return window.getUserPointer(WindowAdapter);
    }

    fn emit(self: *WindowAdapter, event: Platform.Event) void {
        if (self.callback) |callback| callback(self.callback_context, event);
    }

    fn pollEventsImpl(
        context: *anyopaque,
        callback: Platform.EventFn,
        callback_context: ?*anyopaque,
    ) anyerror!void {
        const self: *WindowAdapter = @ptrCast(@alignCast(context));
        self.callback = callback;
        self.callback_context = callback_context;
        self.native_window.setUserPointer(self);
        zglfw.pollEvents();
        if (self.native_window.shouldClose()) self.emit(.close_requested);
        self.callback = null;
        self.callback_context = null;
    }

    fn framebufferExtentImpl(context: *anyopaque) Platform.Extent2D {
        const self: *WindowAdapter = @ptrCast(@alignCast(context));
        const size = self.native_window.getFramebufferSize();
        return .{
            .width = @intCast(@max(size[0], 0)),
            .height = @intCast(@max(size[1], 0)),
        };
    }

    fn requestCloseImpl(context: *anyopaque) void {
        const self: *WindowAdapter = @ptrCast(@alignCast(context));
        self.native_window.setShouldClose(true);
    }

    fn shouldCloseImpl(context: *anyopaque) bool {
        const self: *WindowAdapter = @ptrCast(@alignCast(context));
        return self.native_window.shouldClose();
    }

    fn onKey(window: *zglfw.Window, key: zglfw.Key, _: c_int, action: zglfw.Action, _: zglfw.Mods) callconv(.c) void {
        if (key == .unknown or action == .repeat) return;
        const adapter = fromNative(window) orelse return;
        adapter.emit(.{ .key_code = .{
            .code = @intCast(@intFromEnum(key)),
            .down = action == .press,
        } });
    }

    fn onMouseButton(window: *zglfw.Window, button: zglfw.MouseButton, action: zglfw.Action, _: zglfw.Mods) callconv(.c) void {
        const engine_button: ?game_lib.MouseButton = switch (button) {
            .left => .left,
            .right => .right,
            .middle => .middle,
            .four => .extra_1,
            .five => .extra_2,
            else => null,
        };
        if (engine_button) |mapped| {
            const adapter = fromNative(window) orelse return;
            adapter.emit(.{ .mouse_button = .{
                .button = mapped,
                .down = action == .press,
            } });
        }
    }

    fn onCursorPosition(window: *zglfw.Window, x: f64, y: f64) callconv(.c) void {
        const adapter = fromNative(window) orelse return;
        adapter.emit(.{ .mouse_move = .{ .x = @floatCast(x), .y = @floatCast(y) } });
    }

    fn onScroll(window: *zglfw.Window, x: f64, y: f64) callconv(.c) void {
        const adapter = fromNative(window) orelse return;
        adapter.emit(.{ .scroll = .{ .x = @floatCast(x), .y = @floatCast(y) } });
    }

    fn onFramebufferResize(window: *zglfw.Window, width: c_int, height: c_int) callconv(.c) void {
        const adapter = fromNative(window) orelse return;
        adapter.emit(.{ .resized = .{
            .width = @intCast(@max(width, 0)),
            .height = @intCast(@max(height, 0)),
        } });
    }
};
