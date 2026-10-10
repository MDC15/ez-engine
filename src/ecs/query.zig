const std = @import("std");
const Entity = @import("entity.zig").Entity;

const AccessMode = enum { mutable, read, optional, exclude };

pub fn Read(comptime T: type) type {
    return struct {
        pub const Component = T;
        pub const access_mode = AccessMode.read;
    };
}

pub fn Optional(comptime T: type) type {
    return struct {
        pub const Component = T;
        pub const access_mode = AccessMode.optional;
    };
}

pub fn Exclude(comptime T: type) type {
    return struct {
        pub const Component = T;
        pub const access_mode = AccessMode.exclude;
    };
}

pub fn ItemType(comptime Include: anytype) type {
    return itemType(Include);
}

pub fn Query(comptime Include: anytype, comptime Excluded: anytype, comptime WorldType: type) type {
    const Item = itemType(Include);

    return struct {
        world: *WorldType,
        archetype_index: usize = 0,
        row: usize = 0,

        pub fn next(self: *@This()) ?Item {
            while (self.archetype_index < self.world.archetypes.items.len) {
                const archetype = &self.world.archetypes.items[self.archetype_index];
                if (!self.matches(archetype.component_ids.items)) {
                    self.archetype_index += 1;
                    self.row = 0;
                    continue;
                }
                if (self.row >= archetype.entities.items.len) {
                    self.archetype_index += 1;
                    self.row = 0;
                    continue;
                }

                const current_row = self.row;
                self.row += 1;
                return makeItem(self.world, self.archetype_index, current_row, Include);
            }
            return null;
        }

        fn matches(self: *@This(), ids: []const u32) bool {
            inline for (Include) |entry| {
                const T = componentType(entry);
                if (comptime modeOf(entry) != .optional) {
                    if (!self.world.archetypeHasType(ids, T)) return false;
                }
            }
            inline for (Excluded) |entry| {
                const T = componentType(entry);
                if (self.world.archetypeHasType(ids, T)) return false;
            }
            return true;
        }
    };
}

fn itemType(comptime Include: anytype) type {
    var field_names: [Include.len + 1][]const u8 = undefined;
    var field_types: [Include.len + 1]type = undefined;
    var field_attrs: [Include.len + 1]std.builtin.Type.StructField.Attributes = undefined;
    inline for (Include, 0..) |entry, index| {
        const T = componentType(entry);
        const mode = comptime modeOf(entry);
        field_names[index] = componentFieldName(T);
        field_types[index] = switch (mode) {
            .read => *const T,
            .optional => ?*T,
            .mutable, .exclude => *T,
        };
        field_attrs[index] = .{
            .@"align" = @alignOf(field_types[index]),
        };
    }
    field_names[Include.len] = "entity";
    field_types[Include.len] = Entity;
    field_attrs[Include.len] = .{ .@"align" = @alignOf(Entity) };
    return @Struct(.auto, null, &field_names, &field_types, &field_attrs);
}

fn makeItem(world: anytype, archetype_index: usize, row: usize, comptime Include: anytype) itemType(Include) {
    var result: itemType(Include) = undefined;
    inline for (Include) |entry| {
        const T = componentType(entry);
        const field_name = comptime componentFieldName(T);
        const mode = comptime modeOf(entry);
        if (mode == .optional) {
            @field(result, field_name) = world.getAt(T, archetype_index, row);
        } else {
            @field(result, field_name) = world.getAt(T, archetype_index, row).?;
        }
    }
    result.entity = world.archetypes.items[archetype_index].entities.items[row];
    return result;
}

fn componentType(comptime Entry: type) type {
    if (@hasDecl(Entry, "Component")) return Entry.Component;
    return Entry;
}

fn modeOf(comptime Entry: type) AccessMode {
    if (@hasDecl(Entry, "access_mode")) return Entry.access_mode;
    return .mutable;
}

fn componentFieldName(comptime T: type) [:0]const u8 {
    const type_name = @typeName(T);
    const start = comptime if (std.mem.lastIndexOfScalar(u8, type_name, '.')) |index| index + 1 else 0;
    return std.fmt.comptimePrint("{s}", .{type_name[start..]});
}

test "query access modes are available" {
    _ = Read;
    _ = Optional;
    _ = Exclude;
}
