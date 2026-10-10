const std = @import("std");

/// Allocator roles make ownership explicit at subsystem boundaries.
pub const Allocators = struct {
    permanent: std.mem.Allocator,
    frame: std.mem.Allocator,
    scratch: std.mem.Allocator,
};

/// Owns a frame arena whose storage is reclaimed together at endFrame.
pub const FrameArena = struct {
    arena: std.heap.ArenaAllocator,

    pub fn init(parent: std.mem.Allocator) FrameArena {
        return .{ .arena = std.heap.ArenaAllocator.init(parent) };
    }

    pub fn allocator(self: *FrameArena) std.mem.Allocator {
        return self.arena.allocator();
    }

    pub fn endFrame(self: *FrameArena) void {
        _ = self.arena.reset(.retain_capacity);
    }

    pub fn deinit(self: *FrameArena) void {
        self.arena.deinit();
    }
};
