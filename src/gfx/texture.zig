pub const Texture = struct {
    width: u32,
    height: u32,
    format: Format = .rgba8_unorm,
    mip_levels: u8 = 1,

    pub const Format = enum { rgba8_unorm, bgra8_unorm, rgba16_float };

    pub fn byteSize(self: Texture) !usize {
        if (self.width == 0 or self.height == 0 or self.mip_levels == 0) return error.InvalidTexture;
        const bytes_per_pixel: usize = switch (self.format) {
            .rgba8_unorm, .bgra8_unorm => 4,
            .rgba16_float => 8,
        };
        return try @import("std").math.mul(usize, try @import("std").math.mul(usize, self.width, self.height), bytes_per_pixel);
    }
};
