const std = @import("std");

pub const Key = enum(u16) {
    unknown = 0,
    space = 32,
    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    a = 65,
    d = 68,
    s = 83,
    w = 87,
};

pub const MouseButton = enum(u8) { left, right, middle, extra_1, extra_2 };

pub const ButtonState = struct {
    down: bool = false,
    pressed: bool = false,
    released: bool = false,

    fn update(self: *ButtonState, is_down: bool) void {
        if (is_down == self.down) return;
        self.down = is_down;
        if (is_down) self.pressed = true else self.released = true;
    }

    fn beginFrame(self: *ButtonState) void {
        self.pressed = false;
        self.released = false;
    }
};

/// Frame-based input state. A platform/window layer feeds events; this module
/// deliberately has no SDL, GLFW, or operating-system dependency.
pub const Input = struct {
    keys: [512]ButtonState = @splat(.{}),
    mouse_buttons: [5]ButtonState = @splat(.{}),
    mouse_x: f32 = 0,
    mouse_y: f32 = 0,
    mouse_delta_x: f32 = 0,
    mouse_delta_y: f32 = 0,
    scroll_x: f32 = 0,
    scroll_y: f32 = 0,

    pub fn beginFrame(self: *Input) void {
        for (&self.keys) |*button| button.beginFrame();
        for (&self.mouse_buttons) |*button| button.beginFrame();
        self.mouse_delta_x = 0;
        self.mouse_delta_y = 0;
        self.scroll_x = 0;
        self.scroll_y = 0;
    }

    pub fn setKey(self: *Input, code: Key, down: bool) void {
        self.keys[@intFromEnum(code)].update(down);
    }

    pub fn setKeyCode(self: *Input, code: u16, down: bool) error{InvalidKeyCode}!void {
        if (code >= self.keys.len) return error.InvalidKeyCode;
        self.keys[code].update(down);
    }

    pub fn key(self: *const Input, key_code: Key) ButtonState {
        return self.keys[@intFromEnum(key_code)];
    }

    pub fn keyCode(self: *const Input, code: u16) error{InvalidKeyCode}!ButtonState {
        if (code >= self.keys.len) return error.InvalidKeyCode;
        return self.keys[code];
    }

    pub fn setMouseButton(self: *Input, button: MouseButton, down: bool) void {
        self.mouse_buttons[@intFromEnum(button)].update(down);
    }

    pub fn mouseButton(self: *const Input, button: MouseButton) ButtonState {
        return self.mouse_buttons[@intFromEnum(button)];
    }

    pub fn moveMouse(self: *Input, x: f32, y: f32) void {
        self.mouse_delta_x += x - self.mouse_x;
        self.mouse_delta_y += y - self.mouse_y;
        self.mouse_x = x;
        self.mouse_y = y;
    }

    pub fn addScroll(self: *Input, x: f32, y: f32) void {
        self.scroll_x += x;
        self.scroll_y += y;
    }
};

test "input preserves pressed/released edges for one frame" {
    var input: Input = .{};
    input.setKey(.space, true);
    try std.testing.expect(input.key(.space).pressed);
    input.beginFrame();
    try std.testing.expect(input.key(.space).down);
    try std.testing.expect(!input.key(.space).pressed);
    input.setKey(.space, false);
    try std.testing.expect(input.key(.space).released);
}
