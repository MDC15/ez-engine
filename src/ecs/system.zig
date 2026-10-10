const World = @import("world.zig").World;

pub const Id = u32;
pub const UpdateFn = *const fn (?*anyopaque, *World, f32) anyerror!void;

pub const System = struct {
    name: []const u8,
    context: ?*anyopaque,
    update: UpdateFn,
};
