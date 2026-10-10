pub const Vec4 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    z: f32 = 0,
    w: f32 = 0,
    pub const zero: Vec4 = .{};
    pub const one: Vec4 = .{ .x = 1, .y = 1, .z = 1, .w = 1 };

    pub fn get(self: Vec4, index: usize) f32 {
        return switch (index) {
            0 => self.x,
            1 => self.y,
            2 => self.z,
            3 => self.w,
            else => unreachable,
        };
    }

    pub fn set(self: *Vec4, index: usize, value: f32) void {
        switch (index) {
            0 => self.x = value,
            1 => self.y = value,
            2 => self.z = value,
            3 => self.w = value,
            else => unreachable,
        }
    }
};
