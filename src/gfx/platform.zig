const std = @import("std");
const Input = @import("input_module").Input;

pub const Extent2D = struct { width: u32, height: u32 };

pub const Event = union(enum) {
    key: struct { code: @import("input_module").Key, down: bool },
    key_code: struct { code: u16, down: bool },
    mouse_button: struct { button: @import("input_module").MouseButton, down: bool },
    mouse_move: struct { x: f32, y: f32 },
    scroll: struct { x: f32, y: f32 },
    resized: Extent2D,
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

pub const VulkanSurface = struct {
    context: *anyopaque,
    required_instance_extensions: []const [*:0]const u8,
    vtable: *const VTable,

    pub const VTable = struct {
        create: *const fn (*anyopaque, ?*anyopaque, *u64) anyerror!void,
        destroy: *const fn (*anyopaque, ?*anyopaque, u64) void,
        supports_present: *const fn (*anyopaque, ?*anyopaque, ?*anyopaque, u32, u64) anyerror!bool,
    };

    pub fn create(self: VulkanSurface, instance: ?*anyopaque) !u64 {
        var surface: u64 = 0;
        try self.vtable.create(self.context, instance, &surface);
        if (surface == 0) return error.SurfaceCreationFailed;
        return surface;
    }

    pub fn destroy(self: VulkanSurface, instance: ?*anyopaque, surface: u64) void {
        self.vtable.destroy(self.context, instance, surface);
    }

    pub fn supportsPresent(self: VulkanSurface, instance: ?*anyopaque, physical_device: ?*anyopaque, family: u32, surface: u64) !bool {
        return self.vtable.supports_present(self.context, instance, physical_device, family, surface);
    }
};

pub fn feedInput(input: *Input, event: Event) void {
    switch (event) {
        .key => |key| input.setKey(key.code, key.down),
        .key_code => |key| input.setKeyCode(key.code, key.down) catch {},
        .mouse_button => |button| input.setMouseButton(button.button, button.down),
        .mouse_move => |position| input.moveMouse(position.x, position.y),
        .scroll => |scroll| input.addScroll(scroll.x, scroll.y),
        .resized, .close_requested => {},
    }
}

test "platform event translation updates input state" {
    var input: Input = .{};
    feedInput(&input, .{ .key = .{ .code = .a, .down = true } });
    try std.testing.expect(input.key(.a).pressed);
}
