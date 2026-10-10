const std = @import("std");
const Vec3 = @import("../math/vec3.zig").Vec3;
const Vec2 = @import("../math/vec2.zig").Vec2;

pub const Camera = struct {
    position: Vec3 = .zero,
    forward: Vec3 = .{ .z = -1 },
    up: Vec3 = .{ .y = 1 },
    vertical_fov_radians: f32 = 1.04719755,
    aspect_ratio: f32 = 16.0 / 9.0,
    near_plane: f32 = 0.1,
    far_plane: f32 = 1000,

    pub fn validate(self: Camera) !void {
        if (!(self.vertical_fov_radians > 0 and self.vertical_fov_radians < 3.14159265) or
            !(self.aspect_ratio > 0) or !(self.near_plane > 0) or !(self.far_plane > self.near_plane))
            return error.InvalidCamera;
        if (Vec3.lengthSquared(self.forward) == 0 or Vec3.lengthSquared(self.up) == 0)
            return error.InvalidCamera;
    }
};

/// Centered orthographic camera for pixel and world-space 2D rendering.
/// `viewport_size` is measured in world units at zoom 1.
pub const Camera2D = struct {
    center: Vec2 = .zero,
    viewport_size: Vec2 = .{ .x = 1280, .y = 720 },
    zoom: f32 = 1,

    pub fn validate(self: Camera2D) !void {
        if (!std.math.isFinite(self.center.x) or !std.math.isFinite(self.center.y) or
            !std.math.isFinite(self.viewport_size.x) or !std.math.isFinite(self.viewport_size.y) or
            !std.math.isFinite(self.zoom) or self.viewport_size.x <= 0 or
            self.viewport_size.y <= 0 or self.zoom <= 0)
            return error.InvalidCamera;
    }

    pub fn worldToNdc(self: Camera2D, point: Vec2) Vec2 {
        const half_width = self.viewport_size.x / (2 * self.zoom);
        const half_height = self.viewport_size.y / (2 * self.zoom);
        return .{
            .x = (point.x - self.center.x) / half_width,
            .y = (point.y - self.center.y) / half_height,
        };
    }
};
