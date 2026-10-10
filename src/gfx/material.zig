const Vec4 = @import("../math/vec4.zig").Vec4;
const Handles = @import("../core/handle.zig");

pub const Material = struct {
    base_color: Vec4 = .one,
    base_color_texture: ?Handles.TextureHandle = null,
    metallic: f32 = 0,
    roughness: f32 = 1,
    shader: ?Handles.ShaderHandle = null,

    pub fn validate(self: Material) !void {
        if (!std.math.isFinite(self.metallic) or !std.math.isFinite(self.roughness) or
            self.metallic < 0 or self.metallic > 1 or self.roughness < 0 or self.roughness > 1)
            return error.InvalidMaterial;
    }

    const std = @import("std");
};
