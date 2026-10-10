const std = @import("std");

/// One SoA component column. Rows are byte-packed with the component stride
/// and the first row is 16-byte aligned for common SIMD-friendly components.
pub const Column = struct {
    component_id: u32,
    stride: usize,
    data: []align(16) u8 = &.{},
    capacity: usize = 0,

    pub fn reserve(self: *Column, allocator: std.mem.Allocator, rows: usize) !void {
        if (rows <= self.capacity) return;
        var new_capacity = @max(self.capacity, 8);
        while (new_capacity < rows) new_capacity = try std.math.mul(usize, new_capacity, 2);
        const byte_count = try std.math.mul(usize, new_capacity, self.stride);
        const data = try allocator.alignedAlloc(u8, .fromByteUnits(16), byte_count);
        if (self.capacity != 0) {
            @memcpy(data[0 .. self.capacity * self.stride], self.data[0 .. self.capacity * self.stride]);
            allocator.free(self.data);
        }
        self.data = data;
        self.capacity = new_capacity;
    }

    pub fn rowPtr(self: *Column, row: usize) [*]u8 {
        return @ptrCast(self.data.ptr + row * self.stride);
    }

    pub fn constRowPtr(self: *const Column, row: usize) [*]const u8 {
        return @ptrCast(self.data.ptr + row * self.stride);
    }
};
