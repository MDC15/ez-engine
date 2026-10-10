pub const Id = u32;

pub const Info = struct {
    name: []const u8,
    size: usize,
    alignment: usize,
    stride: usize,
};

pub fn info(comptime T: type) Info {
    comptime {
        if (@alignOf(T) > 16) @compileError("ECS components must have alignment <= 16");
    }
    return .{
        .name = @typeName(T),
        .size = @sizeOf(T),
        .alignment = @max(1, @alignOf(T)),
        .stride = @import("std").mem.alignForward(usize, @max(@sizeOf(T), 1), @max(1, @alignOf(T))),
    };
}
