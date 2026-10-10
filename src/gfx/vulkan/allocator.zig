const std = @import("std");

pub const MemoryType = extern struct {
    property_flags: u32,
    heap_index: u32,
};

pub const MemoryProperties = struct {
    memory_type_count: u32,
    memory_types: []const MemoryType,
};

/// Finds a memory type satisfying Vulkan's requirement bitmask and all
/// requested property flags (for example DEVICE_LOCAL or HOST_VISIBLE).
pub fn findMemoryType(properties: MemoryProperties, type_bits: u32, required_flags: u32) !u32 {
    const count = @min(properties.memory_type_count, properties.memory_types.len);
    for (properties.memory_types[0..count], 0..) |memory_type, index| {
        const bit: u32 = @as(u32, 1) << @intCast(index);
        if (type_bits & bit != 0 and memory_type.property_flags & required_flags == required_flags)
            return @intCast(index);
    }
    return error.NoCompatibleMemoryType;
}

test "memory selection respects type bits and required properties" {
    const types = [_]MemoryType{
        .{ .property_flags = 1, .heap_index = 0 },
        .{ .property_flags = 3, .heap_index = 0 },
    };
    try std.testing.expectEqual(@as(u32, 1), try findMemoryType(.{
        .memory_type_count = 2,
        .memory_types = &types,
    }, 0b11, 3));
    try std.testing.expectError(error.NoCompatibleMemoryType, findMemoryType(.{
        .memory_type_count = 2,
        .memory_types = &types,
    }, 0b01, 2));
}
