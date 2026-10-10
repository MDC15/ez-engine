const std = @import("std");

pub const Vec3 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,

    pub const zero: Vec3 = .{};
    pub const one: Vec3 = .{ .x = 1, .y = 1, .z = 1 };

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn scale(v: Vec3, factor: f32) Vec3 {
        return .{ .x = v.x * factor, .y = v.y * factor, .z = v.z * factor };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn lengthSquared(v: Vec3) f32 {
        return dot(v, v);
    }

    pub fn length(v: Vec3) f32 {
        return @sqrt(lengthSquared(v));
    }

    pub fn normalized(v: Vec3) Vec3 {
        const magnitude = length(v);
        if (magnitude == 0) return zero;
        return scale(v, 1.0 / magnitude);
    }
};

test "vector arithmetic" {
    const a = Vec3{ .x = 1, .y = 2, .z = 3 };
    const b = Vec3{ .x = 3, .y = 2, .z = 1 };
    try std.testing.expectEqual(Vec3{ .x = 4, .y = 4, .z = 4 }, Vec3.add(a, b));
    try std.testing.expectEqual(@as(f32, 10), Vec3.dot(a, b));
}
