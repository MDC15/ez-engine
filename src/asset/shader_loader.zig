const std = @import("std");

pub const ShaderCode = struct {
    words: []u32,
    pub fn deinit(self: *ShaderCode, allocator: std.mem.Allocator) void {
        allocator.free(self.words);
    }
};

pub fn loadSpirV(allocator: std.mem.Allocator, bytes: []const u8) !ShaderCode {
    if (bytes.len < 20 or bytes.len % 4 != 0) return error.InvalidShader;
    const words = try allocator.alloc(u32, bytes.len / 4);
    errdefer allocator.free(words);
    for (words, 0..) |*word, index|
        word.* = std.mem.readInt(u32, bytes[index * 4 ..][0..4], .little);
    if (words[0] != 0x07230203) return error.InvalidShader;
    return .{ .words = words };
}

test "SPIR-V loader validates magic and copies aligned words" {
    var bytes: [20]u8 = @splat(0);
    std.mem.writeInt(u32, bytes[0..4], 0x07230203, .little);
    var shader = try loadSpirV(std.testing.allocator, &bytes);
    defer shader.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 0x07230203), shader.words[0]);
}
