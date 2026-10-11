//! Named action and axis mapping on top of the frame-based `Input` state.
//! Gameplay asks for actions ("jump", "move_left") instead of raw keys, so
//! key choices live in one binding table instead of scattered across systems.

const std = @import("std");
const input_mod = @import("input.zig");
const Input = input_mod.Input;
const Key = input_mod.Key;
const MouseButton = input_mod.MouseButton;

/// One physical source that can drive an action.
pub const Binding = union(enum) {
    key: Key,
    key_code: u16,
    mouse: MouseButton,

    fn isDown(self: Binding, input: *const Input) bool {
        return switch (self) {
            .key => |code| input.isDown(code),
            .key_code => |code| (input.keyCode(code) catch return false).down,
            .mouse => |button| input.mouseButton(button).down,
        };
    }

    fn justPressed(self: Binding, input: *const Input) bool {
        return switch (self) {
            .key => |code| input.justPressed(code),
            .key_code => |code| (input.keyCode(code) catch return false).pressed,
            .mouse => |button| input.mouseButton(button).pressed,
        };
    }

    fn justReleased(self: Binding, input: *const Input) bool {
        return switch (self) {
            .key => |code| input.justReleased(code),
            .key_code => |code| (input.keyCode(code) catch return false).released,
            .mouse => |button| input.mouseButton(button).released,
        };
    }
};

/// A table of named actions, each bound to one or more `Binding`s. Actions
/// let gameplay read intent ("jump") rather than specific keys, so rebinding
/// stays a data change.
pub const InputMap = struct {
    allocator: std.mem.Allocator,
    actions: std.ArrayListUnmanaged(Action) = .empty,

    const Action = struct {
        name: []u8,
        bindings: std.ArrayListUnmanaged(Binding) = .empty,
    };

    pub fn init(allocator: std.mem.Allocator) InputMap {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InputMap) void {
        for (self.actions.items) |*action| {
            self.allocator.free(action.name);
            action.bindings.deinit(self.allocator);
        }
        self.actions.deinit(self.allocator);
        self.* = undefined;
    }

    /// Binds `binding` to `action`, creating the action on first use. The name
    /// is copied, so a temporary buffer is fine.
    pub fn bind(self: *InputMap, action: []const u8, binding: Binding) !void {
        for (self.actions.items) |*existing| {
            if (std.mem.eql(u8, existing.name, action)) {
                try existing.bindings.append(self.allocator, binding);
                return;
            }
        }
        const name = try self.allocator.dupe(u8, action);
        errdefer self.allocator.free(name);
        var bindings: std.ArrayListUnmanaged(Binding) = .empty;
        errdefer bindings.deinit(self.allocator);
        try bindings.append(self.allocator, binding);
        try self.actions.append(self.allocator, .{ .name = name, .bindings = bindings });
    }

    /// True while any binding of `action` is held. Unknown actions are inert.
    pub fn isDown(self: *const InputMap, input: *const Input, action: []const u8) bool {
        const found = self.find(action) orelse return false;
        for (found.bindings.items) |binding| {
            if (binding.isDown(input)) return true;
        }
        return false;
    }

    /// True on the frame any binding of `action` went down.
    pub fn justPressed(self: *const InputMap, input: *const Input, action: []const u8) bool {
        const found = self.find(action) orelse return false;
        for (found.bindings.items) |binding| {
            if (binding.justPressed(input)) return true;
        }
        return false;
    }

    /// True on the frame any binding of `action` was released.
    pub fn justReleased(self: *const InputMap, input: *const Input, action: []const u8) bool {
        const found = self.find(action) orelse return false;
        for (found.bindings.items) |binding| {
            if (binding.justReleased(input)) return true;
        }
        return false;
    }

    /// `-1..1` from two actions: `+1` when only `positive` is down, `-1` when
    /// only `negative` is down, `0` when both or neither are down.
    pub fn axis(
        self: *const InputMap,
        input: *const Input,
        negative: []const u8,
        positive: []const u8,
    ) f32 {
        const neg: f32 = if (self.isDown(input, negative)) 1 else 0;
        const pos: f32 = if (self.isDown(input, positive)) 1 else 0;
        return pos - neg;
    }

    fn find(self: *const InputMap, action: []const u8) ?*const Action {
        for (self.actions.items) |*candidate| {
            if (std.mem.eql(u8, candidate.name, action)) return candidate;
        }
        return null;
    }
};

fn expectAxis(actual: f32, expected: f32) !void {
    try std.testing.expectApproxEqAbs(expected, actual, 0.0001);
}

test "action is down while any bound key is held" {
    var input: Input = .{};
    var map = InputMap.init(std.testing.allocator);
    defer map.deinit();
    try map.bind("jump", .{ .key = .space });
    try map.bind("jump", .{ .key = .w });
    try std.testing.expect(!map.isDown(&input, "jump"));
    input.setKey(.w, true);
    try std.testing.expect(map.isDown(&input, "jump"));
    input.setKey(.space, true);
    try std.testing.expect(map.isDown(&input, "jump"));
    input.setKey(.w, false);
    try std.testing.expect(map.isDown(&input, "jump"));
    input.setKey(.space, false);
    try std.testing.expect(!map.isDown(&input, "jump"));
}

test "justPressed and justReleased only fire on the edge frame" {
    var input: Input = .{};
    var map = InputMap.init(std.testing.allocator);
    defer map.deinit();
    try map.bind("fire", .{ .key = .space });

    input.setKey(.space, true);
    try std.testing.expect(map.justPressed(&input, "fire"));
    try std.testing.expect(!map.justReleased(&input, "fire"));
    input.beginFrame();
    try std.testing.expect(!map.justPressed(&input, "fire"));
    input.setKey(.space, false);
    try std.testing.expect(map.justReleased(&input, "fire"));
    input.beginFrame();
    try std.testing.expect(!map.justReleased(&input, "fire"));
}

test "mouse buttons can be bound to actions" {
    var input: Input = .{};
    var map = InputMap.init(std.testing.allocator);
    defer map.deinit();
    try map.bind("shoot", .{ .mouse = .left });
    try std.testing.expect(!map.isDown(&input, "shoot"));
    input.setMouseButton(.left, true);
    try std.testing.expect(map.isDown(&input, "shoot"));
}

test "axis returns positive minus negative" {
    var input: Input = .{};
    var map = InputMap.init(std.testing.allocator);
    defer map.deinit();
    try map.bind("left", .{ .key = .a });
    try map.bind("right", .{ .key = .d });
    try expectAxis(map.axis(&input, "left", "right"), 0);
    input.setKey(.a, true);
    try expectAxis(map.axis(&input, "left", "right"), -1);
    input.setKey(.d, true);
    try expectAxis(map.axis(&input, "left", "right"), 0);
    input.setKey(.a, false);
    try expectAxis(map.axis(&input, "left", "right"), 1);
}

test "unknown actions are inert" {
    var input: Input = .{};
    var map = InputMap.init(std.testing.allocator);
    defer map.deinit();
    try std.testing.expect(!map.isDown(&input, "missing"));
    try std.testing.expect(!map.justPressed(&input, "missing"));
    try expectAxis(map.axis(&input, "none", "missing"), 0);
}

test "action names survive the caller's buffer going away" {
    var input: Input = .{};
    var map = InputMap.init(std.testing.allocator);
    defer map.deinit();
    var name_buf: [8]u8 = undefined;
    @memcpy(name_buf[0..4], "jump");
    try map.bind(name_buf[0..4], .{ .key = .space });
    @memset(name_buf[0..4], 'x');
    input.setKey(.space, true);
    try std.testing.expect(map.isDown(&input, "jump"));
}
