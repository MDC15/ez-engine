const std = @import("std");
const World = @import("world.zig").World;
const System = @import("system.zig").System;

pub const SystemId = @import("system.zig").Id;
pub const UpdateFn = @import("system.zig").UpdateFn;
pub const DeinitFn = @import("system.zig").DeinitFn;

const Dependency = struct {
    before: SystemId,
    after: SystemId,
};

/// Deterministic system graph. The cached topological order is rebuilt only
/// when systems/dependencies change, not during normal frame updates.
pub const Scheduler = struct {
    allocator: std.mem.Allocator,
    systems: std.ArrayListUnmanaged(System) = .empty,
    dependencies: std.ArrayListUnmanaged(Dependency) = .empty,
    order: std.ArrayListUnmanaged(SystemId) = .empty,

    pub const Error = error{
        InvalidSystem,
        DependencyCycle,
        DuplicateDependency,
    };

    pub fn init(allocator: std.mem.Allocator) Scheduler {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Scheduler) void {
        var index = self.order.items.len;
        while (index > 0) {
            index -= 1;
            const system = self.systems.items[self.order.items[index]];
            if (system.deinit) |deinit_fn| deinit_fn(system.context);
        }
        self.order.deinit(self.allocator);
        self.dependencies.deinit(self.allocator);
        self.systems.deinit(self.allocator);
    }

    pub fn addSystem(self: *Scheduler, name: []const u8, context: ?*anyopaque, update: UpdateFn) !SystemId {
        return self.addSystemInternal(name, context, update, null);
    }

    /// Registers a system with a cleanup callback. The scheduler calls the
    /// callback once during deinit, in reverse dependency order; the caller
    /// still owns the context storage and must keep it alive until then.
    pub fn addSystemWithDeinit(
        self: *Scheduler,
        name: []const u8,
        context: ?*anyopaque,
        update: UpdateFn,
        deinit_fn: DeinitFn,
    ) !SystemId {
        return self.addSystemInternal(name, context, update, deinit_fn);
    }

    fn addSystemInternal(
        self: *Scheduler,
        name: []const u8,
        context: ?*anyopaque,
        update: UpdateFn,
        deinit_fn: ?DeinitFn,
    ) !SystemId {
        if (self.systems.items.len > std.math.maxInt(SystemId)) return error.OutOfMemory;
        const id: SystemId = @intCast(self.systems.items.len);
        try self.systems.append(self.allocator, .{
            .name = name,
            .context = context,
            .update = update,
            .deinit = deinit_fn,
        });
        self.rebuildOrder() catch |err| {
            self.systems.items.len -= 1;
            return err;
        };
        return id;
    }

    /// Requires `before` to finish before `after` is eligible to run.
    pub fn dependsOn(self: *Scheduler, before: SystemId, after: SystemId) !void {
        if (before >= self.systems.items.len or after >= self.systems.items.len or before == after)
            return Error.InvalidSystem;
        for (self.dependencies.items) |dependency| {
            if (dependency.before == before and dependency.after == after)
                return Error.DuplicateDependency;
        }
        try self.dependencies.append(self.allocator, .{ .before = before, .after = after });
        self.rebuildOrder() catch |err| {
            self.dependencies.items.len -= 1;
            return err;
        };
    }

    pub fn run(self: *Scheduler, world: *World, dt: f32) !void {
        for (self.order.items) |system_id| {
            const system = self.systems.items[system_id];
            try system.update(system.context, world, dt);
        }
    }

    pub fn systemName(self: *const Scheduler, id: SystemId) Error![]const u8 {
        if (id >= self.systems.items.len) return Error.InvalidSystem;
        return self.systems.items[id].name;
    }

    fn rebuildOrder(self: *Scheduler) !void {
        const count = self.systems.items.len;
        var indegree = try self.allocator.alloc(usize, count);
        defer self.allocator.free(indegree);
        @memset(indegree, 0);
        for (self.dependencies.items) |dependency| indegree[dependency.after] += 1;

        var new_order: std.ArrayListUnmanaged(SystemId) = .empty;
        errdefer new_order.deinit(self.allocator);
        try new_order.ensureTotalCapacity(self.allocator, count);
        var selected = try self.allocator.alloc(bool, count);
        defer self.allocator.free(selected);
        @memset(selected, false);

        while (new_order.items.len < count) {
            var candidate: ?usize = null;
            for (0..count) |index| {
                if (!selected[index] and indegree[index] == 0) {
                    candidate = index;
                    break;
                }
            }
            const index = candidate orelse return Error.DependencyCycle;
            selected[index] = true;
            new_order.appendAssumeCapacity(@intCast(index));
            for (self.dependencies.items) |dependency| {
                if (dependency.before == index) indegree[dependency.after] -= 1;
            }
        }

        self.order.deinit(self.allocator);
        self.order = new_order;
    }
};

test "scheduler observes explicit dependency order" {
    const State = struct {
        values: [3]u8 = .{ 0, 0, 0 },
        next: usize = 0,
        fn update(context: ?*anyopaque, _: *World, _: f32) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.values[self.next] = @intCast(self.next + 1);
            self.next += 1;
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var state: State = .{};
    var scheduler = Scheduler.init(std.testing.allocator);
    defer scheduler.deinit();
    const first = try scheduler.addSystem("Input", &state, State.update);
    const second = try scheduler.addSystem("Gameplay", &state, State.update);
    const third = try scheduler.addSystem("Render extraction", &state, State.update);
    try scheduler.dependsOn(first, second);
    try scheduler.dependsOn(second, third);
    try scheduler.run(&world, 1.0 / 60.0);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, &state.values);
    try std.testing.expectError(Scheduler.Error.DependencyCycle, scheduler.dependsOn(third, first));
}

test "scheduler deinitializes systems in reverse dependency order" {
    const State = struct {
        id: u8,
        order: *[2]u8,
        count: *usize,

        fn update(_: ?*anyopaque, _: *World, _: f32) anyerror!void {}

        fn deinit(context: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.order[self.count.*] = self.id;
            self.count.* += 1;
        }
    };

    var order: [2]u8 = .{ 0, 0 };
    var count: usize = 0;
    var first = State{ .id = 1, .order = &order, .count = &count };
    var second = State{ .id = 2, .order = &order, .count = &count };
    var scheduler = Scheduler.init(std.testing.allocator);
    var deinitialized = false;
    defer if (!deinitialized) scheduler.deinit();
    const first_id = try scheduler.addSystemWithDeinit("first", &first, State.update, State.deinit);
    const second_id = try scheduler.addSystemWithDeinit("second", &second, State.update, State.deinit);
    try scheduler.dependsOn(first_id, second_id);

    scheduler.deinit();
    deinitialized = true;

    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualSlices(u8, &.{ 2, 1 }, &order);
}
