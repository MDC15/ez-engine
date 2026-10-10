const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;
const Vec2 = @import("../math/vec2.zig").Vec2;

pub const Vertex = extern struct {
    position: Vec3,
    normal: Vec3 = .{ .y = 1 },
    uv: Vec2 = .zero,
};

pub const Mesh = struct {
    vertices: []const Vertex,
    indices: []const u32,

    pub fn validate(self: Mesh) !void {
        if (self.vertices.len == 0 or self.indices.len == 0) return error.EmptyMesh;
        for (self.indices) |index| if (index >= self.vertices.len) return error.InvalidIndex;
    }
};

test "mesh validates indices" {
    const mesh = Mesh{ .vertices = &.{.{ .position = .zero }}, .indices = &.{0} };
    try mesh.validate();
    try std.testing.expectError(error.InvalidIndex, (Mesh{ .vertices = mesh.vertices, .indices = &.{1} }).validate());
}
