const std = @import("std");
const Input = @import("ez_input").Input;

pub const Extent2D = struct { width: u32, height: u32 };
pub const MousePosition = struct { x: f32, y: f32 };

pub const Event = union(enum) {
    key: struct { code: @import("ez_input").Key, down: bool },
    key_code: struct { code: u16, down: bool },
    mouse_button: struct { button: @import("ez_input").MouseButton, down: bool },
    mouse_move: struct { x: f32, y: f32 },
    scroll: struct { x: f32, y: f32 },
    resized: Extent2D,
    focus_changed: bool,
    close_requested,
};

pub const EventFn = *const fn (?*anyopaque, Event) void;

/// Window systems stay outside game-lib. Applications can adapt SDL, GLFW,
/// native WSLg/X11/Wayland, or a custom host to this small contract.
pub const Window = struct {
    context: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        poll_events: *const fn (*anyopaque, EventFn, ?*anyopaque) anyerror!void,
        framebuffer_extent: *const fn (*anyopaque) Extent2D,
        request_close: *const fn (*anyopaque) void,
        should_close: *const fn (*anyopaque) bool,
    };

    pub fn pollEvents(self: Window, callback: EventFn, callback_context: ?*anyopaque) !void {
        try self.vtable.poll_events(self.context, callback, callback_context);
    }

    pub fn extent(self: Window) Extent2D {
        return self.vtable.framebuffer_extent(self.context);
    }

    pub fn requestClose(self: Window) void {
        self.vtable.request_close(self.context);
    }

    pub fn shouldClose(self: Window) bool {
        return self.vtable.should_close(self.context);
    }
};

/// Converts GLFW-style logical window cursor coordinates to top-left-origin
/// framebuffer pixels. The values may be fractional on scaled displays.
pub fn cursorToFramebuffer(
    x: f64,
    y: f64,
    window_extent: Extent2D,
    framebuffer_extent: Extent2D,
) error{ InvalidWindowExtent, InvalidCursorPosition }!MousePosition {
    if (window_extent.width == 0 or window_extent.height == 0) return error.InvalidWindowExtent;
    if (!std.math.isFinite(x) or !std.math.isFinite(y)) return error.InvalidCursorPosition;
    const scale_x = @as(f64, @floatFromInt(framebuffer_extent.width)) / @as(f64, @floatFromInt(window_extent.width));
    const scale_y = @as(f64, @floatFromInt(framebuffer_extent.height)) / @as(f64, @floatFromInt(window_extent.height));
    const pixel_x = x * scale_x;
    const pixel_y = y * scale_y;
    if (!std.math.isFinite(pixel_x) or !std.math.isFinite(pixel_y) or
        @abs(pixel_x) > std.math.floatMax(f32) or @abs(pixel_y) > std.math.floatMax(f32))
        return error.InvalidCursorPosition;
    return .{ .x = @floatCast(pixel_x), .y = @floatCast(pixel_y) };
}

pub fn feedInput(input: *Input, event: Event) void {
    switch (event) {
        .key => |key| input.setKey(key.code, key.down),
        .key_code => |key| input.setKeyCode(key.code, key.down) catch |err| {
            std.log.err("platform emitted invalid key code {d}: {s}", .{ key.code, @errorName(err) });
        },
        .mouse_button => |button| input.setMouseButton(button.button, button.down),
        .mouse_move => |position| input.moveMouse(position.x, position.y),
        .scroll => |scroll| input.addScroll(scroll.x, scroll.y),
        .focus_changed => |focused| if (!focused) input.resetAfterFocusLoss(),
        .resized, .close_requested => {},
    }
}

test "platform event translation updates input state" {
    var input: Input = .{};
    feedInput(&input, .{ .key = .{ .code = .a, .down = true } });
    try std.testing.expect(input.key(.a).pressed);
}

test "focus loss platform event clears held input safely" {
    var input: Input = .{};
    feedInput(&input, .{ .mouse_button = .{ .button = .right, .down = true } });
    feedInput(&input, .{ .focus_changed = false });
    try std.testing.expect(input.mouseButton(.right).released);
    try std.testing.expect(!input.mouseButton(.right).down);
}

test "cursor coordinates scale from logical window to framebuffer pixels" {
    const position = try cursorToFramebuffer(
        100,
        40,
        .{ .width = 800, .height = 600 },
        .{ .width = 1600, .height = 1200 },
    );
    try std.testing.expectEqual(@as(f32, 200), position.x);
    try std.testing.expectEqual(@as(f32, 80), position.y);

    const non_uniform = try cursorToFramebuffer(
        200,
        150,
        .{ .width = 800, .height = 600 },
        .{ .width = 1200, .height = 900 },
    );
    try std.testing.expectEqual(@as(f32, 300), non_uniform.x);
    try std.testing.expectEqual(@as(f32, 225), non_uniform.y);
    try std.testing.expectError(
        error.InvalidWindowExtent,
        cursorToFramebuffer(0, 0, .{ .width = 0, .height = 1 }, .{ .width = 1, .height = 1 }),
    );
    try std.testing.expectError(
        error.InvalidCursorPosition,
        cursorToFramebuffer(std.math.nan(f64), 0, .{ .width = 1, .height = 1 }, .{ .width = 1, .height = 1 }),
    );
}
