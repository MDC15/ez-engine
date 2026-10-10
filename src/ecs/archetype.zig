const std = @import("std");
const Entity = @import("entity.zig").Entity;
const Column = @import("storage.zig").Column;

pub const Archetype = struct {
    component_ids: std.ArrayListUnmanaged(u32) = .empty,
    columns: std.ArrayListUnmanaged(Column) = .empty,
    entities: std.ArrayListUnmanaged(Entity) = .empty,

    pub fn deinit(self: *Archetype, allocator: std.mem.Allocator) void {
        for (self.columns.items) |column| {
            if (column.capacity > 0) allocator.free(column.data);
        }
        self.columns.deinit(allocator);
        self.component_ids.deinit(allocator);
        self.entities.deinit(allocator);
    }

    pub fn findColumn(self: *const Archetype, component_id: u32) ?usize {
        for (self.component_ids.items, 0..) |id, index| {
            if (id == component_id) return index;
        }
        return null;
    }

    pub fn reserveRow(self: *Archetype, allocator: std.mem.Allocator) !void {
        const required = self.entities.items.len + 1;
        try self.entities.ensureTotalCapacity(allocator, required);
        for (self.columns.items) |*column| try column.reserve(allocator, required);
    }

    pub fn removeRow(self: *Archetype, row: usize) ?Entity {
        const last = self.entities.items.len - 1;
        const moved = if (row != last) self.entities.items[last] else null;
        if (row != last) {
            self.entities.items[row] = self.entities.items[last];
            for (self.columns.items) |*column| {
                @memcpy(column.rowPtr(row)[0..column.stride], column.constRowPtr(last)[0..column.stride]);
            }
        }
        self.entities.items.len = last;
        return moved;
    }
};
