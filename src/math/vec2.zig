pub const Vec2 = extern struct {
    x: f32 = 0,
    y: f32 = 0,
    pub const zero: Vec2 = .{};
    pub const one: Vec2 = .{ .x = 1, .y = 1 };

    pub fn add(a: Vec2, b: Vec2) Vec2 {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn scale(v: Vec2, scalar: f32) Vec2 {
        return .{ .x = v.x * scalar, .y = v.y * scalar };
    }
    pub fn dot(a: Vec2, b: Vec2) f32 {
        return a.x * b.x + a.y * b.y;
    }
};
