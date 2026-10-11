const std = @import("std");
const Entity = @import("entity.zig").Entity;
const Query = @import("query.zig").Query;
const ComponentInfo = @import("component.zig").Info;
const Archetype = @import("archetype.zig").Archetype;
const Column = @import("storage.zig").Column;

const Record = struct {
    generation: u32 = 1,
    alive: bool = false,
    archetype_index: usize = 0,
    row: usize = 0,
};

/// Archetype ECS with columnar component storage. Components must be plain
/// data values with alignment no greater than 16 bytes; they are byte-copied
/// during archetype migration and do not have per-instance destructors.
pub const World = struct {
    allocator: std.mem.Allocator,
    records: std.ArrayListUnmanaged(Record) = .empty,
    free_ids: std.ArrayListUnmanaged(u32) = .empty,
    components: std.ArrayListUnmanaged(ComponentInfo) = .empty,
    archetypes: std.ArrayListUnmanaged(Archetype) = .empty,
    pending_destroys: std.ArrayListUnmanaged(Entity) = .empty,

    pub const Error = error{
        InvalidEntity,
        ComponentMissing,
        ComponentNotRegistered,
    };

    pub fn init(allocator: std.mem.Allocator) World {
        return .{ .allocator = allocator };
    }

    /// Number of currently live entities.
    pub fn aliveCount(self: *const World) usize {
        return self.records.items.len - self.free_ids.items.len;
    }

    pub fn deinit(self: *World) void {
        for (self.archetypes.items) |*archetype| archetype.deinit(self.allocator);
        self.archetypes.deinit(self.allocator);
        self.components.deinit(self.allocator);
        self.records.deinit(self.allocator);
        self.free_ids.deinit(self.allocator);
        self.pending_destroys.deinit(self.allocator);
    }

    pub fn create(self: *World) !Entity {
        const empty_archetype = try self.ensureArchetype(&.{});
        try self.archetypes.items[empty_archetype].entities.ensureUnusedCapacity(self.allocator, 1);
        var id: u32 = undefined;
        if (self.free_ids.pop()) |free_id| {
            id = free_id;
        } else {
            if (self.records.items.len > std.math.maxInt(u32)) return error.OutOfMemory;
            id = @intCast(self.records.items.len);
            try self.records.append(self.allocator, .{});
        }

        const entity_slot = &self.records.items[id];
        const entity = Entity{ .id = id, .generation = entity_slot.generation };
        const archetype = &self.archetypes.items[empty_archetype];
        archetype.entities.appendAssumeCapacity(entity);
        entity_slot.alive = true;
        entity_slot.archetype_index = empty_archetype;
        entity_slot.row = archetype.entities.items.len - 1;
        return entity;
    }

    pub fn destroy(self: *World, entity: Entity) !void {
        const entity_slot = try self.entityRecord(entity);
        try self.free_ids.ensureUnusedCapacity(self.allocator, 1);
        const archetype_index = entity_slot.archetype_index;
        const row = entity_slot.row;
        const moved = self.archetypes.items[archetype_index].removeRow(row);
        if (moved) |moved_entity| {
            self.records.items[moved_entity.id].row = row;
        }
        entity_slot.alive = false;
        entity_slot.generation +%= 1;
        if (entity_slot.generation == 0) entity_slot.generation = 1;
        self.free_ids.appendAssumeCapacity(entity.id);
    }

    /// Queue an entity for destruction at a safe boundary (end of frame).
    /// Destroying while a query is iterating is unsafe; use `flushDeferred`.
    pub fn destroyDeferred(self: *World, entity: Entity) !void {
        try self.pending_destroys.append(self.allocator, entity);
    }

    /// Destroys every queued entity. Already-dead entities are dropped; an
    /// entity whose destroy fails with OutOfMemory stays queued for a retry.
    pub fn flushDeferred(self: *World) void {
        var index: usize = 0;
        while (index < self.pending_destroys.items.len) {
            const entity = self.pending_destroys.items[index];
            if (self.destroy(entity)) {
                _ = self.pending_destroys.swapRemove(index);
            } else |err| switch (err) {
                error.InvalidEntity => _ = self.pending_destroys.swapRemove(index),
                else => index += 1,
            }
        }
    }

    pub fn pendingDestroyCount(self: *const World) usize {
        return self.pending_destroys.items.len;
    }

    pub fn isAlive(self: *const World, entity: Entity) bool {
        if (entity.id >= self.records.items.len) return false;
        const entity_slot = self.records.items[entity.id];
        return entity_slot.alive and entity_slot.generation == entity.generation;
    }

    pub fn add(self: *World, entity: Entity, value: anytype) !void {
        const T = @TypeOf(value);
        const entity_slot = try self.entityRecord(entity);
        const component_id = try self.registerComponent(T);
        const source_index = entity_slot.archetype_index;
        const source = &self.archetypes.items[source_index];
        if (source.findColumn(component_id)) |column_index| {
            const column = &source.columns.items[column_index];
            @memcpy(column.rowPtr(entity_slot.row)[0..@sizeOf(T)], std.mem.asBytes(&value));
            return;
        }

        var ids: std.ArrayListUnmanaged(u32) = .empty;
        defer ids.deinit(self.allocator);
        try ids.appendSlice(self.allocator, source.component_ids.items);
        try ids.append(self.allocator, component_id);
        std.mem.sort(u32, ids.items, {}, std.sort.asc(u32));
        try self.migrate(entity, ids.items, component_id, std.mem.asBytes(&value));
    }

    pub fn remove(self: *World, entity: Entity, comptime T: type) !void {
        const entity_slot = try self.entityRecord(entity);
        const component_id = self.componentId(T) orelse return Error.ComponentNotRegistered;
        const source = &self.archetypes.items[entity_slot.archetype_index];
        if (source.findColumn(component_id) == null) return Error.ComponentMissing;

        var ids: std.ArrayListUnmanaged(u32) = .empty;
        defer ids.deinit(self.allocator);
        for (source.component_ids.items) |id| {
            if (id != component_id) try ids.append(self.allocator, id);
        }
        try self.migrate(entity, ids.items, null, &.{});
    }

    pub fn get(self: *World, entity: Entity, comptime T: type) !*T {
        const entity_slot = try self.entityRecord(entity);
        const component_id = self.componentId(T) orelse return Error.ComponentNotRegistered;
        const archetype = &self.archetypes.items[entity_slot.archetype_index];
        const column_index = archetype.findColumn(component_id) orelse return Error.ComponentMissing;
        return @ptrCast(@alignCast(archetype.columns.items[column_index].rowPtr(entity_slot.row)));
    }

    pub fn has(self: *const World, entity: Entity, comptime T: type) bool {
        if (!self.isAlive(entity)) return false;
        const component_id = self.componentId(T) orelse return false;
        const entity_slot = self.records.items[entity.id];
        return self.archetypes.items[entity_slot.archetype_index].findColumn(component_id) != null;
    }

    pub fn query(self: *World, comptime spec: anytype) QuerySpec(@TypeOf(spec), spec) {
        const Parts = QuerySpecParts(@TypeOf(spec), spec);
        return .{ .query = Query(Parts.include, Parts.exclude, World){ .world = self } };
    }

    pub fn QuerySpec(comptime Spec: type, comptime spec: anytype) type {
        return QuerySpecImpl(Spec, spec);
    }

    fn QuerySpecParts(comptime Spec: type, comptime spec: anytype) type {
        if (@hasField(Spec, "include")) return struct {
            const include = spec.include;
            const exclude = if (@hasField(Spec, "exclude")) spec.exclude else .{};
        };
        return struct {
            const include = spec;
            const exclude = .{};
        };
    }

    fn QuerySpecImpl(comptime Spec: type, comptime spec: anytype) type {
        const Parts = QuerySpecParts(Spec, spec);
        return struct {
            query: Query(Parts.include, Parts.exclude, World),

            pub fn next(self: *@This()) ?@import("query.zig").ItemType(Parts.include) {
                return self.query.next();
            }
        };
    }

    fn migrate(self: *World, entity: Entity, dest_ids: []const u32, extra_id: ?u32, extra: []const u8) !void {
        const entity_slot = try self.entityRecord(entity);
        const source_index = entity_slot.archetype_index;
        const source_row = entity_slot.row;
        const dest_index = try self.ensureArchetype(dest_ids);
        const source = &self.archetypes.items[source_index];
        const dest = &self.archetypes.items[dest_index];
        try dest.reserveRow(self.allocator);
        const dest_row = dest.entities.items.len;

        for (dest.columns.items) |*column| {
            const target = column.rowPtr(dest_row)[0..column.stride];
            if (extra_id != null and column.component_id == extra_id.?) {
                @memcpy(target[0..extra.len], extra);
            } else {
                const source_column_index = source.findColumn(column.component_id).?;
                const source_column = &source.columns.items[source_column_index];
                @memcpy(target[0..source_column.stride], source_column.constRowPtr(source_row)[0..source_column.stride]);
            }
        }
        try dest.entities.append(self.allocator, entity);
        const moved = self.archetypes.items[source_index].removeRow(source_row);
        if (moved) |moved_entity| self.records.items[moved_entity.id].row = source_row;
        const updated = &self.records.items[entity.id];
        updated.archetype_index = dest_index;
        updated.row = dest_row;
    }

    fn ensureArchetype(self: *World, ids: []const u32) !usize {
        for (self.archetypes.items, 0..) |archetype, index| {
            if (std.mem.eql(u32, archetype.component_ids.items, ids)) return index;
        }

        var archetype: Archetype = .{};
        errdefer archetype.deinit(self.allocator);
        try archetype.component_ids.appendSlice(self.allocator, ids);
        for (ids) |component_id| {
            const info = self.components.items[component_id];
            try archetype.columns.append(self.allocator, .{
                .component_id = component_id,
                .stride = info.stride,
            });
        }
        try self.archetypes.append(self.allocator, archetype);
        return self.archetypes.items.len - 1;
    }

    fn registerComponent(self: *World, comptime T: type) !u32 {
        const descriptor = @import("component.zig").info(T);
        const name = descriptor.name;
        for (self.components.items, 0..) |info, index| {
            if (std.mem.eql(u8, info.name, name)) return @intCast(index);
        }
        const id: u32 = @intCast(self.components.items.len);
        try self.components.append(self.allocator, descriptor);
        return id;
    }

    fn componentId(self: *const World, comptime T: type) ?u32 {
        const name = @typeName(T);
        for (self.components.items, 0..) |info, index| {
            if (std.mem.eql(u8, info.name, name)) return @intCast(index);
        }
        return null;
    }

    fn entityRecord(self: *World, entity: Entity) Error!*Record {
        if (!self.isAlive(entity)) return Error.InvalidEntity;
        return &self.records.items[entity.id];
    }

    pub fn archetypeHasType(self: *World, ids: []const u32, comptime T: type) bool {
        const id = self.componentId(T) orelse return false;
        for (ids) |candidate| {
            if (candidate == id) return true;
        }
        return false;
    }

    pub fn getAt(self: *World, comptime T: type, archetype_index: usize, row: usize) ?*T {
        const id = self.componentId(T) orelse return null;
        const archetype = &self.archetypes.items[archetype_index];
        const column_index = archetype.findColumn(id) orelse return null;
        return @ptrCast(@alignCast(archetype.columns.items[column_index].rowPtr(row)));
    }
};

test "archetype migration, removal, entity reuse, and typed query" {
    const Transform = struct { x: f32 };
    const Velocity = struct { x: f32 };
    const Static = struct {};

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const entity = try world.create();
    try world.add(entity, Transform{ .x = 2 });
    try world.add(entity, Velocity{ .x = 3 });
    const static_entity = try world.create();
    try world.add(static_entity, Transform{ .x = 10 });
    try world.add(static_entity, Velocity{ .x = 1 });
    try world.add(static_entity, Static{});
    try std.testing.expectEqual(@as(f32, 2), (try world.get(entity, Transform)).x);
    (try world.get(entity, Transform)).x += (try world.get(entity, Velocity)).x;
    try std.testing.expectEqual(@as(f32, 5), (try world.get(entity, Transform)).x);

    var query = world.query(.{ .include = .{ Transform, Velocity }, .exclude = .{Static} });
    var count: usize = 0;
    while (query.next()) |item| {
        item.Transform.x += item.Velocity.x;
        count += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(f32, 8), (try world.get(entity, Transform)).x);

    var read_optional = world.query(.{ @import("query.zig").Read(Transform), @import("query.zig").Optional(Static) });
    const read_item = read_optional.next().?;
    try std.testing.expectEqual(@as(f32, 8), read_item.Transform.x);
    try std.testing.expect(read_item.Static == null);
    const static_read_item = read_optional.next().?;
    try std.testing.expectEqual(@as(f32, 10), static_read_item.Transform.x);
    try std.testing.expect(static_read_item.Static != null);
    try std.testing.expect(read_optional.next() == null);

    try world.remove(entity, Velocity);
    try std.testing.expect(!world.has(entity, Velocity));
    try world.destroy(entity);
    try std.testing.expect(!world.isAlive(entity));
    const reused = try world.create();
    try std.testing.expectEqual(entity.id, reused.id);
    try std.testing.expect(entity.generation != reused.generation);
    try std.testing.expectError(World.Error.InvalidEntity, world.get(entity, Transform));
}

test "destroyDeferred queues until flush and ignores already dead" {
    const Tag = struct { x: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const a = try world.create();
    const b = try world.create();
    try world.add(a, Tag{ .x = 1 });
    try world.destroyDeferred(a);
    try world.destroyDeferred(b);
    try world.destroyDeferred(a);

    try std.testing.expect(world.isAlive(a));
    try std.testing.expectEqual(@as(usize, 3), world.pendingDestroyCount());

    world.flushDeferred();
    try std.testing.expect(!world.isAlive(a));
    try std.testing.expect(!world.isAlive(b));
    try std.testing.expectEqual(@as(usize, 0), world.pendingDestroyCount());
}
