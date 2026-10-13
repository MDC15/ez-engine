const std = @import("std");
const ez = @import("ez_engine");

test "component bytes are copied on add, caller keeps no alias" {
    var world = ez.World.init(std.testing.allocator);
    defer world.deinit();
    const Tag = struct { x: f32 };
    const entity = try world.create();
    var source = Tag{ .x = 2 };
    try world.add(entity, source);
    source.x = 99;
    try std.testing.expectEqual(@as(f32, 2), (try world.get(entity, Tag)).x);
}

test "slice component is shallow-copied and destroy frees nothing" {
    var world = ez.World.init(std.testing.allocator);
    defer world.deinit();
    const Ref = struct { ptr: []const u8 };
    const backing = "static-backing";
    const entity = try world.create();
    try world.add(entity, Ref{ .ptr = backing });
    // Force an archetype migration via a second component; bytes must survive.
    const Extra = struct { y: u32 };
    try world.add(entity, Extra{ .y = 7 });
    const stored = try world.get(entity, Ref);
    try std.testing.expectEqual(backing.len, stored.ptr.len);
    try std.testing.expectEqualStrings(backing, stored.ptr);
    // Destroy runs no destructor and frees nothing owned; backing stays valid.
    try world.destroy(entity);
    try std.testing.expectEqualStrings(backing, backing);
}

test "remove then destroy drops component without destructor" {
    var world = ez.World.init(std.testing.allocator);
    defer world.deinit();
    const Tag = struct { x: f32 };
    const entity = try world.create();
    try world.add(entity, Tag{ .x = 1 });
    try world.remove(entity, Tag);
    try std.testing.expect(!world.has(entity, Tag));
    try world.destroy(entity);
    try std.testing.expect(!world.isAlive(entity));
}
