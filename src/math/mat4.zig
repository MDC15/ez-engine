const Vec3 = @import("vec3.zig").Vec3;
const Vec4 = @import("vec4.zig").Vec4;
const Quat = @import("quat.zig").Quat;

/// Column-major matrix, matching common graphics API conventions.
pub const Mat4 = extern struct {
    columns: [4]Vec4,

    pub const identity: Mat4 = .{ .columns = .{
        .{ .x = 1 }, .{ .y = 1 }, .{ .z = 1 }, .{ .w = 1 },
    } };

    pub fn translation(position: Vec3) Mat4 {
        var result = identity;
        result.columns[3] = .{ .x = position.x, .y = position.y, .z = position.z, .w = 1 };
        return result;
    }

    pub fn scale(value: Vec3) Mat4 {
        return .{ .columns = .{
            .{ .x = value.x }, .{ .y = value.y }, .{ .z = value.z }, .{ .w = 1 },
        } };
    }

    pub fn fromTRS(position: Vec3, rotation: Quat, scale_value: Vec3) Mat4 {
        const q = rotation.normalized();
        const xx = q.x * q.x;
        const yy = q.y * q.y;
        const zz = q.z * q.z;
        const xy = q.x * q.y;
        const xz = q.x * q.z;
        const yz = q.y * q.z;
        const wx = q.w * q.x;
        const wy = q.w * q.y;
        const wz = q.w * q.z;
        return .{ .columns = .{
            .{ .x = (1 - 2 * (yy + zz)) * scale_value.x, .y = (2 * (xy + wz)) * scale_value.x, .z = (2 * (xz - wy)) * scale_value.x },
            .{ .x = (2 * (xy - wz)) * scale_value.y, .y = (1 - 2 * (xx + zz)) * scale_value.y, .z = (2 * (yz + wx)) * scale_value.y },
            .{ .x = (2 * (xz + wy)) * scale_value.z, .y = (2 * (yz - wx)) * scale_value.z, .z = (1 - 2 * (xx + yy)) * scale_value.z },
            .{ .x = position.x, .y = position.y, .z = position.z, .w = 1 },
        } };
    }

    pub fn multiply(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = undefined;
        for (0..4) |column| {
            for (0..4) |row| {
                out.columns[column].set(row, a.columns[0].get(row) * b.columns[column].x +
                    a.columns[1].get(row) * b.columns[column].y +
                    a.columns[2].get(row) * b.columns[column].z +
                    a.columns[3].get(row) * b.columns[column].w);
            }
        }
        return out;
    }

    pub fn transformPoint(matrix: Mat4, point: Vec3) Vec3 {
        const x = matrix.columns[0].x * point.x + matrix.columns[1].x * point.y + matrix.columns[2].x * point.z + matrix.columns[3].x;
        const y = matrix.columns[0].y * point.x + matrix.columns[1].y * point.y + matrix.columns[2].y * point.z + matrix.columns[3].y;
        const z = matrix.columns[0].z * point.x + matrix.columns[1].z * point.y + matrix.columns[2].z * point.z + matrix.columns[3].z;
        const w = matrix.columns[0].w * point.x + matrix.columns[1].w * point.y + matrix.columns[2].w * point.z + matrix.columns[3].w;
        if (w == 0 or w == 1) return .{ .x = x, .y = y, .z = z };
        return .{ .x = x / w, .y = y / w, .z = z / w };
    }
};

test "matrix transforms points" {
    const std = @import("std");
    const moved = Mat4.transformPoint(Mat4.translation(.{ .x = 2, .y = 3, .z = 4 }), .{ .x = 1, .y = 1, .z = 1 });
    try std.testing.expectEqual(Vec3{ .x = 3, .y = 4, .z = 5 }, moved);
}
