const std = @import("std");
const FixedStepper = @import("time.zig").FixedStepper;

pub const State = enum { running, paused, stopped };
pub const Timing = union(enum) { variable, fixed: FixedStepper };

/// Timing and run-state controller for a game. Pure data plus logic: it does
/// not touch the world or a window, so it is testable without either. `Game`
/// owns one and asks it how many simulation steps a rendered frame should run.
pub const GameLoop = struct {
    state: State = .running,
    timing: Timing = .variable,
    time_scale: f64 = 1,
    max_frame_seconds: f64 = 0.25,

    pub fn init() GameLoop {
        return .{};
    }

    /// Fixed timestep: `step_seconds` per simulation step, at most
    /// `max_steps` catch-up steps per frame.
    pub fn initFixed(step_seconds: f64, max_steps: u32) !GameLoop {
        return .{ .timing = .{ .fixed = try FixedStepper.init(step_seconds, max_steps) } };
    }

    pub fn pause(self: *GameLoop) void {
        self.state = .paused;
    }

    pub fn unpause(self: *GameLoop) void {
        self.state = .running;
    }

    pub fn stop(self: *GameLoop) void {
        self.state = .stopped;
    }

    pub fn isStopped(self: GameLoop) bool {
        return self.state == .stopped;
    }

    /// Non-finite frame times clamp to `max_frame_seconds`; finite ones to
    /// `[0, max_frame_seconds]`.
    pub fn clampFrameSeconds(self: GameLoop, frame_seconds: f64) f64 {
        if (!std.math.isFinite(frame_seconds)) return self.max_frame_seconds;
        return std.math.clamp(frame_seconds, 0, self.max_frame_seconds);
    }

    fn scaled(self: GameLoop, frame_seconds: f64) f64 {
        return self.clampFrameSeconds(frame_seconds) * @max(0, self.time_scale);
    }

    /// Number of simulation steps to run this frame. Zero while paused or
    /// stopped, one for variable timing, or the fixed accumulator's output.
    pub fn stepCount(self: *GameLoop, frame_seconds: f64) u32 {
        if (self.state != .running) return 0;
        return switch (self.timing) {
            .variable => 1,
            .fixed => |*stepper| stepper.advance(self.scaled(frame_seconds)),
        };
    }

    /// Delta seconds to pass each simulation step.
    pub fn stepSeconds(self: GameLoop, frame_seconds: f64) f64 {
        return switch (self.timing) {
            .variable => self.scaled(frame_seconds),
            .fixed => |stepper| stepper.step_seconds,
        };
    }

    /// Fractional progress toward the next fixed step; `0` for variable timing.
    pub fn interpolationAlpha(self: GameLoop) f32 {
        return switch (self.timing) {
            .variable => 0,
            .fixed => |stepper| stepper.interpolationAlpha(),
        };
    }
};

test "variable timing runs one step scaled by time_scale" {
    var loop = GameLoop.init();
    loop.max_frame_seconds = 1;
    try std.testing.expectEqual(@as(u32, 1), loop.stepCount(0.1));
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), loop.stepSeconds(0.1), 1e-9);
    loop.time_scale = 2;
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), loop.stepSeconds(0.1), 1e-9);
}

test "fixed timing steps at fixed dt and caps catch-up" {
    var loop = try GameLoop.initFixed(0.1, 2);
    try std.testing.expectEqual(@as(u32, 1), loop.stepCount(0.15));
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), loop.stepSeconds(0.15), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), loop.interpolationAlpha(), 1e-4);
    try std.testing.expectEqual(@as(u32, 2), loop.stepCount(1));
}

test "pause and stop gate stepping" {
    var loop = GameLoop.init();
    loop.pause();
    try std.testing.expectEqual(@as(u32, 0), loop.stepCount(0.1));
    loop.unpause();
    try std.testing.expectEqual(@as(u32, 1), loop.stepCount(0.1));
    loop.stop();
    try std.testing.expect(loop.isStopped());
    try std.testing.expectEqual(@as(u32, 0), loop.stepCount(0.1));
}

test "time_scale zero or negative freezes" {
    var loop = GameLoop.init();
    loop.max_frame_seconds = 1;
    loop.time_scale = 0;
    try std.testing.expectApproxEqAbs(@as(f64, 0), loop.stepSeconds(0.1), 1e-9);
    loop.time_scale = -3;
    try std.testing.expectApproxEqAbs(@as(f64, 0), loop.stepSeconds(0.1), 1e-9);
}

test "frame time is clamped to max_frame_seconds" {
    var loop = GameLoop.init();
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), loop.stepSeconds(10), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), loop.stepSeconds(-1), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), loop.stepSeconds(std.math.inf(f64)), 1e-9);
}

test "initFixed rejects invalid step" {
    try std.testing.expectError(error.InvalidStep, GameLoop.initFixed(0, 8));
    try std.testing.expectError(error.InvalidStep, GameLoop.initFixed(1.0 / 60.0, 0));
}
