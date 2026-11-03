const std = @import("std");

pub const Stage = struct {
    initialize: *const fn (*anyopaque) anyerror!void,
    cleanup: *const fn (*anyopaque) void,
};

pub fn run(context: *anyopaque, stages: []const Stage) anyerror!void {
    var initialized: usize = 0;
    errdefer while (initialized > 0) {
        initialized -= 1;
        stages[initialized].cleanup(context);
    };

    for (stages) |stage| {
        try stage.initialize(context);
        initialized += 1;
    }
}

const TestContext = struct {
    fail_at: usize,
    event_count: usize = 0,
    events: [8]u8 = undefined,

    fn record(self: *TestContext, event: u8) void {
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

fn initializeStage(context: *anyopaque, index: usize) anyerror!void {
    const state: *TestContext = @ptrCast(@alignCast(context));
    state.record(@intCast(index + 1));
    if (state.fail_at == index) return error.InjectedFailure;
}

fn cleanupStage(context: *anyopaque, index: usize) void {
    const state: *TestContext = @ptrCast(@alignCast(context));
    state.record(@intCast(index + 11));
}

fn initialize0(context: *anyopaque) anyerror!void {
    try initializeStage(context, 0);
}
fn initialize1(context: *anyopaque) anyerror!void {
    try initializeStage(context, 1);
}
fn initialize2(context: *anyopaque) anyerror!void {
    try initializeStage(context, 2);
}
fn initialize3(context: *anyopaque) anyerror!void {
    try initializeStage(context, 3);
}
fn cleanup0(context: *anyopaque) void {
    cleanupStage(context, 0);
}
fn cleanup1(context: *anyopaque) void {
    cleanupStage(context, 1);
}
fn cleanup2(context: *anyopaque) void {
    cleanupStage(context, 2);
}
fn cleanup3(context: *anyopaque) void {
    cleanupStage(context, 3);
}

test "initialization failure cleans completed stages in reverse order" {
    const stages = [_]Stage{
        .{ .initialize = initialize0, .cleanup = cleanup0 },
        .{ .initialize = initialize1, .cleanup = cleanup1 },
        .{ .initialize = initialize2, .cleanup = cleanup2 },
        .{ .initialize = initialize3, .cleanup = cleanup3 },
    };
    const expected = [_][8]u8{
        .{ 1, 0, 0, 0, 0, 0, 0, 0 },
        .{ 1, 2, 11, 0, 0, 0, 0, 0 },
        .{ 1, 2, 3, 12, 11, 0, 0, 0 },
        .{ 1, 2, 3, 4, 13, 12, 11, 0 },
    };
    const expected_lengths = [_]usize{ 1, 3, 5, 7 };

    for (0..stages.len) |fail_at| {
        var state = TestContext{ .fail_at = fail_at };
        try std.testing.expectError(error.InjectedFailure, run(&state, &stages));
        try std.testing.expectEqual(expected_lengths[fail_at], state.event_count);
        try std.testing.expectEqualSlices(u8, expected[fail_at][0..expected_lengths[fail_at]], state.events[0..state.event_count]);
    }
}

test "successful initialization leaves ownership with the caller" {
    const stages = [_]Stage{
        .{ .initialize = initialize0, .cleanup = cleanup0 },
        .{ .initialize = initialize1, .cleanup = cleanup1 },
        .{ .initialize = initialize2, .cleanup = cleanup2 },
        .{ .initialize = initialize3, .cleanup = cleanup3 },
    };
    var state = TestContext{ .fail_at = stages.len };

    try run(&state, &stages);

    try std.testing.expectEqual(@as(usize, stages.len), state.event_count);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4 }, state.events[0..state.event_count]);
}
