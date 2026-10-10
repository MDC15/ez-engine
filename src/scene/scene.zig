const std = @import("std");

pub const ObjectKind = enum { sprite, obstacle, pickup };

pub const Object = struct {
    id: u32,
    kind: ObjectKind = .sprite,
    position: [2]f32 = .{ 0, 0 },
    size: [2]f32 = .{ 64, 64 },
};

const SerializedScene = struct {
    version: u32 = 1,
    objects: []Object,
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayListUnmanaged(Object) = .empty,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Document) void {
        self.objects.deinit(self.allocator);
    }

    pub fn add(self: *Document, kind: ObjectKind) !u32 {
        if (self.next_id == 0) return error.EntityIdExhausted;
        const id = self.next_id;
        self.next_id +%= 1;
        try self.objects.append(self.allocator, .{ .id = id, .kind = kind });
        return id;
    }

    pub fn remove(self: *Document, id: u32) bool {
        for (self.objects.items, 0..) |object, index| {
            if (object.id != id) continue;
            _ = self.objects.orderedRemove(index);
            return true;
        }
        return false;
    }

    pub fn get(self: *Document, id: u32) ?*Object {
        for (self.objects.items) |*object| {
            if (object.id == id) return object;
        }
        return null;
    }

    pub fn save(self: *const Document, io: std.Io, path: []const u8) !void {
        const json = try std.json.Stringify.valueAlloc(self.allocator, SerializedScene{
            .objects = @constCast(self.objects.items),
        }, .{ .whitespace = .indent_2 });
        defer self.allocator.free(json);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
    }

    pub fn load(self: *Document, io: std.Io, path: []const u8) !void {
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(json);
        const parsed = try std.json.parseFromSlice(SerializedScene, self.allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value.version != 1) return error.UnsupportedSceneVersion;

        var replacement: std.ArrayListUnmanaged(Object) = .empty;
        errdefer replacement.deinit(self.allocator);
        try replacement.appendSlice(self.allocator, parsed.value.objects);
        var highest_id: u32 = 0;
        for (replacement.items) |object| {
            highest_id = @max(highest_id, object.id);
            if (!std.math.isFinite(object.position[0]) or !std.math.isFinite(object.position[1]) or
                !std.math.isFinite(object.size[0]) or !std.math.isFinite(object.size[1]) or
                object.size[0] <= 0 or object.size[1] <= 0)
                return error.InvalidSceneObject;
        }
        if (highest_id == std.math.maxInt(u32)) return error.EntityIdExhausted;

        self.objects.deinit(self.allocator);
        self.objects = replacement;
        self.next_id = highest_id + 1;
    }
};

test "scene document JSON round-trip preserves objects" {
    var document = Document.init(std.testing.allocator);
    defer document.deinit();
    const first_id = try document.add(.sprite);
    const second_id = try document.add(.obstacle);
    document.get(first_id).?.position = .{ 42, -9 };
    document.get(second_id).?.size = .{ 100, 32 };

    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, SerializedScene{
        .objects = document.objects.items,
    }, .{});
    defer std.testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(SerializedScene, std.testing.allocator, json, .{});
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 2), parsed.value.objects.len);
    try std.testing.expectEqual(@as(f32, 42), parsed.value.objects[0].position[0]);
    try std.testing.expectEqual(ObjectKind.obstacle, parsed.value.objects[1].kind);
}
