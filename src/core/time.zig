const std = @import("std");

pub const Clock = struct {
    previous_ns: i96,

    pub fn start(io: std.Io) Clock {
        return .{ .previous_ns = std.Io.Clock.awake.now(io).nanoseconds };
    }

    pub fn tick(self: *Clock, io: std.Io) f64 {
        const now = std.Io.Clock.awake.now(io).nanoseconds;
        const elapsed = @max(@as(i96, 0), now - self.previous_ns);
        self.previous_ns = now;
        return @as(f64, @floatFromInt(elapsed)) / std.time.ns_per_s;
    }
};

/// Fixed-step accumulator; callers control the policy for excess catch-up.
pub const FixedStepper = struct {
    step_seconds: f64,
    accumulator: f64 = 0,
    max_steps: u32 = 8,

    pub fn init(step_seconds: f64, max_steps: u32) !FixedStepper {
        if (!std.math.isFinite(step_seconds) or step_seconds <= 0 or max_steps == 0)
            return error.InvalidStep;
        return .{ .step_seconds = step_seconds, .max_steps = max_steps };
    }

    pub fn advance(self: *FixedStepper, frame_seconds: f64) u32 {
        self.accumulator += @max(0, frame_seconds);
        var count: u32 = 0;
        while (self.accumulator >= self.step_seconds and count < self.max_steps) : (count += 1) {
            self.accumulator -= self.step_seconds;
        }
        if (count == self.max_steps and self.accumulator >= self.step_seconds)
            self.accumulator = @mod(self.accumulator, self.step_seconds);
        return count;
    }

    pub fn interpolationAlpha(self: FixedStepper) f32 {
        return @floatCast(self.accumulator / self.step_seconds);
    }
};

test "fixed step accumulator caps catch-up and provides interpolation" {
    var stepper = try FixedStepper.init(0.1, 2);
    try std.testing.expectEqual(@as(u32, 1), stepper.advance(0.15));
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), stepper.interpolationAlpha(), 0.0001);
    try std.testing.expectEqual(@as(u32, 2), stepper.advance(1));
    try std.testing.expect(stepper.interpolationAlpha() < 1);
}
