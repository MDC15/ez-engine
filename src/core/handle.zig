//! Backend-neutral resource handles suitable for gameplay components.

pub fn Handle(comptime Tag: type) type {
    _ = Tag;
    return struct {
        index: u32,
        generation: u32 = 0,

        pub fn invalid() @This() {
            return .{ .index = invalid_index };
        }

        pub fn isValid(self: @This()) bool {
            return self.index != invalid_index;
        }
    };
}

pub const invalid_index = std.math.maxInt(u32);

pub const TextureHandle = Handle(enum { texture });
pub const AtlasHandle = Handle(enum { atlas });
pub const FontHandle = Handle(enum { font });

const std = @import("std");
