const std = @import("std");

pub const MeshData = struct {
    vertices: []Vertex,
    indices: []u32,

    pub fn deinit(self: *MeshData, allocator: std.mem.Allocator) void {
        allocator.free(self.indices);
        allocator.free(self.vertices);
    }
};

pub const Vertex = extern struct {
    position: [3]f32,
    normal: [3]f32,
    uv: [2]f32,
};

/// Loads a compact engine-owned mesh format: magic "ZMSH", version u32,
/// vertex_count u32, index_count u32, then packed Vertex and u32 arrays.
pub fn load(allocator: std.mem.Allocator, bytes: []const u8) !MeshData {
    if (bytes.len < 16 or !std.mem.eql(u8, bytes[0..4], "ZMSH")) return error.InvalidMesh;
    const version = readU32(bytes, 4);
    const vertex_count = readU32(bytes, 8);
    const index_count = readU32(bytes, 12);
    if (version != 1) return error.UnsupportedVersion;

    const vertex_bytes = try std.math.mul(usize, vertex_count, @sizeOf(Vertex));
    const index_bytes = try std.math.mul(usize, index_count, @sizeOf(u32));
    const expected_len = try std.math.add(usize, 16, try std.math.add(usize, vertex_bytes, index_bytes));
    if (bytes.len != expected_len) return error.InvalidMesh;

    const vertices = try allocator.alloc(Vertex, vertex_count);
    errdefer allocator.free(vertices);
    const indices = try allocator.alloc(u32, index_count);
    errdefer allocator.free(indices);
    @memcpy(std.mem.sliceAsBytes(vertices), bytes[16 .. 16 + vertex_bytes]);
    @memcpy(std.mem.sliceAsBytes(indices), bytes[16 + vertex_bytes ..]);
    for (indices) |index| if (index >= vertex_count) return error.InvalidIndex;
    return .{ .vertices = vertices, .indices = indices };
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
