const std = @import("std");

/// Keyboard keys named after the GLFW key codes the platform layer emits.
/// Values match GLFW, so a backend can hand a raw key code straight through
/// via `setKeyCode`.
pub const Key = enum(u16) {
    unknown = 0,

    space = 32,
    apostrophe = 39,
    comma = 44,
    minus = 45,
    period = 46,
    slash = 47,
    digit_0 = 48,
    digit_1 = 49,
    digit_2 = 50,
    digit_3 = 51,
    digit_4 = 52,
    digit_5 = 53,
    digit_6 = 54,
    digit_7 = 55,
    digit_8 = 56,
    digit_9 = 57,
    semicolon = 59,
    equal = 61,

    a = 65,
    b = 66,
    c = 67,
    d = 68,
    e = 69,
    f = 70,
    g = 71,
    h = 72,
    i = 73,
    j = 74,
    k = 75,
    l = 76,
    m = 77,
    n = 78,
    o = 79,
    p = 80,
    q = 81,
    r = 82,
    s = 83,
    t = 84,
    u = 85,
    v = 86,
    w = 87,
    x = 88,
    y = 89,
    z = 90,

    left_bracket = 91,
    backslash = 92,
    right_bracket = 93,
    grave_accent = 96,
    world_1 = 161,
    world_2 = 162,

    escape = 256,
    enter = 257,
    tab = 258,
    backspace = 259,
    insert = 260,
    delete = 261,
    right = 262,
    left = 263,
    down = 264,
    up = 265,
    page_up = 266,
    page_down = 267,
    home = 268,
    end = 269,
    caps_lock = 280,
    scroll_lock = 281,
    num_lock = 282,
    print_screen = 283,
    pause = 284,

    f1 = 290,
    f2 = 291,
    f3 = 292,
    f4 = 293,
    f5 = 294,
    f6 = 295,
    f7 = 296,
    f8 = 297,
    f9 = 298,
    f10 = 299,
    f11 = 300,
    f12 = 301,

    kp_0 = 320,
    kp_1 = 321,
    kp_2 = 322,
    kp_3 = 323,
    kp_4 = 324,
    kp_5 = 325,
    kp_6 = 326,
    kp_7 = 327,
    kp_8 = 328,
    kp_9 = 329,
    kp_decimal = 330,
    kp_divide = 331,
    kp_multiply = 332,
    kp_subtract = 333,
    kp_add = 334,
    kp_enter = 335,
    kp_equal = 336,

    left_shift = 340,
    left_control = 341,
    left_alt = 342,
    left_super = 343,
    right_shift = 344,
    right_control = 345,
    right_alt = 346,
    right_super = 347,
    menu = 348,
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

    /// Clears pressed/released edges while keeping held state. Call after the
    /// first simulation step of a frame so edge-triggered actions fire once
    /// even when a frame runs several fixed steps.
    pub fn clearEdges(self: *Input) void {
        for (&self.keys) |*button| {
            button.pressed = false;
            button.released = false;
        }
        for (&self.mouse_buttons) |*button| {
            button.pressed = false;
            button.released = false;
        }
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

    /// True while the key is held down.
    pub fn isDown(self: *const Input, key_code: Key) bool {
        return self.keys[@intFromEnum(key_code)].down;
    }

    /// True only on the frame the key went down.
    pub fn justPressed(self: *const Input, key_code: Key) bool {
        return self.keys[@intFromEnum(key_code)].pressed;
    }

    /// True only on the frame the key was released.
    pub fn justReleased(self: *const Input, key_code: Key) bool {
        return self.keys[@intFromEnum(key_code)].released;
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

/// Named action/axis mapping over `Input`; see `input_map.zig`.
pub const InputMap = @import("input_map.zig").InputMap;
pub const Binding = @import("input_map.zig").Binding;

test {
    _ = @import("input_map.zig");
}

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

test "input exposes ergonomic key queries" {
    var input: Input = .{};
    input.setKey(.f3, true);
    try std.testing.expect(input.isDown(.f3));
    try std.testing.expect(input.justPressed(.f3));
    try std.testing.expect(!input.justReleased(.f3));
    input.beginFrame();
    try std.testing.expect(input.isDown(.f3));
    try std.testing.expect(!input.justPressed(.f3));
    input.setKey(.f3, false);
    try std.testing.expect(input.justReleased(.f3));
    try std.testing.expect(!input.isDown(.f3));
    input.beginFrame();
    try std.testing.expect(!input.justReleased(.f3));
}

test "key enum covers standard named keys" {
    try std.testing.expectEqual(@as(u16, 65), @intFromEnum(Key.a));
    try std.testing.expectEqual(@as(u16, 90), @intFromEnum(Key.z));
    try std.testing.expectEqual(@as(u16, 48), @intFromEnum(Key.digit_0));
    try std.testing.expectEqual(@as(u16, 290), @intFromEnum(Key.f1));
    try std.testing.expectEqual(@as(u16, 340), @intFromEnum(Key.left_shift));
    try std.testing.expectEqual(@as(u16, 348), @intFromEnum(Key.menu));
    try std.testing.expectEqual(@as(u16, 335), @intFromEnum(Key.kp_enter));
}

test "clearEdges drops edges but keeps held state" {
    var input: Input = .{};
    input.setKey(.space, true);
    input.setMouseButton(.left, true);
    input.clearEdges();
    try std.testing.expect(input.isDown(.space));
    try std.testing.expect(!input.justPressed(.space));
    try std.testing.expect(input.mouseButton(.left).down);
    try std.testing.expect(!input.mouseButton(.left).pressed);
}
