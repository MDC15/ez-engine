const Vec3 = @import("vec3.zig").Vec3;

pub const Quat = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 1,

    pub const identity: Quat = .{};

    pub fn fromAxisAngle(axis: Vec3, radians: f32) Quat {
        const normalized_axis = axis.normalized();
        const half_angle = radians * 0.5;
        const sine = @sin(half_angle);
        return .{
            .x = normalized_axis.x * sine,
            .y = normalized_axis.y * sine,
            .z = normalized_axis.z * sine,
            .w = @cos(half_angle),
        };
    }

    pub fn multiply(a: Quat, b: Quat) Quat {
        return .{
            .x = a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
            .y = a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
            .z = a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w,
            .w = a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        };
    }

    pub fn normalized(self: Quat) Quat {
        const length_squared = self.x * self.x + self.y * self.y + self.z * self.z + self.w * self.w;
        if (length_squared == 0) return identity;
        const inverse_length = 1 / @sqrt(length_squared);
        return .{
            .x = self.x * inverse_length,
            .y = self.y * inverse_length,
            .z = self.z * inverse_length,
            .w = self.w * inverse_length,
        };
    }

    pub fn rotate(self: Quat, vector: Vec3) Vec3 {
        const q = self.normalized();
        const imaginary = Vec3{ .x = q.x, .y = q.y, .z = q.z };
        const twice_cross = Vec3.scale(Vec3.cross(imaginary, vector), 2);
        return Vec3.add(vector, Vec3.add(Vec3.scale(twice_cross, q.w), Vec3.cross(imaginary, twice_cross)));
    }
};

test "quaternion rotates a vector around z" {
    const std = @import("std");
    const rotated = Quat.rotate(Quat.fromAxisAngle(.{ .z = 1 }, std.math.pi / 2.0), .{ .x = 1 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), rotated.x, 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), rotated.y, 0.0001);
}
