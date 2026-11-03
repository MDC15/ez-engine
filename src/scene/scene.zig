const std = @import("std");

pub const ObjectKind = enum { sprite, obstacle, pickup };

pub const Object = struct {
    id: u32,
    kind: ObjectKind = .sprite,
    position: [2]f32 = .{ 0, 0 },
    size: [2]f32 = .{ 64, 64 },
    asset_path: []const u8 = "",
};

const CurrentVersion: u32 = 2;

const SerializedScene = struct {
    version: u32 = 1,
    objects: []Object,
};

const SerializedPrefab = struct {
    version: u32 = 1,
    object: Object,
};

pub const Document = struct {
    allocator: std.mem.Allocator,
    strings: std.heap.ArenaAllocator,
    objects: std.ArrayListUnmanaged(Object) = .empty,
    next_id: u32 = 1,

    pub fn init(allocator: std.mem.Allocator) Document {
        return .{ .allocator = allocator, .strings = std.heap.ArenaAllocator.init(allocator) };
    }

    pub fn deinit(self: *Document) void {
        const allocator = self.allocator;
        self.objects.deinit(self.allocator);
        self.strings.deinit();
        self.* = Document.init(allocator);
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

    /// Asset references are project-relative paths, never runtime handles.
    pub fn setAssetPath(self: *Document, id: u32, path: []const u8) !void {
        const object = self.get(id) orelse return error.ObjectNotFound;
        if (path.len > 0 and !validAssetPath(path)) return error.InvalidAssetPath;
        const owned_path = if (path.len > 0) try self.strings.allocator().dupe(u8, path) else "";
        object.asset_path = owned_path;
    }

    pub fn validate(self: *const Document) !void {
        for (self.objects.items, 0..) |object, index| {
            try validateObject(object);
            for (self.objects.items[0..index]) |previous| {
                if (previous.id == object.id) return error.DuplicateObjectId;
            }
        }
    }

    pub fn parse(allocator: std.mem.Allocator, json: []const u8) !Document {
        const parsed = try std.json.parseFromSlice(SerializedScene, allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value.version != 1 and parsed.value.version != CurrentVersion)
            return error.UnsupportedSceneVersion;

        var document = Document.init(allocator);
        errdefer document.deinit();
        try document.objects.ensureTotalCapacity(allocator, parsed.value.objects.len);
        var highest_id: u32 = 0;
        for (parsed.value.objects) |source| {
            try validateObject(source);
            for (document.objects.items) |previous| {
                if (previous.id == source.id) return error.DuplicateObjectId;
            }
            const path = if (source.asset_path.len == 0) "" else try document.strings.allocator().dupe(u8, source.asset_path);
            document.objects.appendAssumeCapacity(.{
                .id = source.id,
                .kind = source.kind,
                .position = source.position,
                .size = source.size,
                .asset_path = path,
            });
            highest_id = @max(highest_id, source.id);
        }
        if (highest_id == std.math.maxInt(u32)) return error.EntityIdExhausted;
        document.next_id = highest_id + 1;
        return document;
    }

    pub fn stringify(self: *const Document, allocator: std.mem.Allocator) ![]u8 {
        try self.validate();
        return std.json.Stringify.valueAlloc(allocator, SerializedScene{
            .version = CurrentVersion,
            .objects = self.objects.items,
        }, .{ .whitespace = .indent_2 });
    }

    pub fn save(self: *const Document, io: std.Io, path: []const u8) !void {
        const json = try self.stringify(self.allocator);
        defer self.allocator.free(json);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = json });
    }

    pub fn load(self: *Document, io: std.Io, path: []const u8) !void {
        const json = try std.Io.Dir.cwd().readFileAlloc(io, path, self.allocator, .limited(1024 * 1024));
        defer self.allocator.free(json);
        const replacement = try Document.parse(self.allocator, json);
        self.deinit();
        self.* = replacement;
    }
};

/// Reusable single-object scene definition. Runtime entity handles and
/// game-specific components are deliberately not serialized.
pub const Prefab = struct {
    allocator: std.mem.Allocator,
    strings: std.heap.ArenaAllocator,
    object: Object,

    pub fn init(allocator: std.mem.Allocator, kind: ObjectKind) Prefab {
        return .{
            .allocator = allocator,
            .strings = std.heap.ArenaAllocator.init(allocator),
            .object = .{ .id = 1, .kind = kind },
        };
    }

    pub fn deinit(self: *Prefab) void {
        const allocator = self.allocator;
        self.strings.deinit();
        self.* = Prefab.init(allocator, self.object.kind);
    }

    pub fn setAssetPath(self: *Prefab, path: []const u8) !void {
        if (path.len > 0 and !validAssetPath(path)) return error.InvalidAssetPath;
        const owned_path = if (path.len > 0) try self.strings.allocator().dupe(u8, path) else "";
        self.object.asset_path = owned_path;
    }

    pub fn parse(allocator: std.mem.Allocator, json: []const u8) !Prefab {
        const parsed = try std.json.parseFromSlice(SerializedPrefab, allocator, json, .{});
        defer parsed.deinit();
        if (parsed.value.version != 1 and parsed.value.version != CurrentVersion)
            return error.UnsupportedPrefabVersion;
        try validateObject(parsed.value.object);
        var prefab = Prefab.init(allocator, parsed.value.object.kind);
        errdefer prefab.deinit();
        const owned_path = if (parsed.value.object.asset_path.len > 0)
            try prefab.strings.allocator().dupe(u8, parsed.value.object.asset_path)
        else
            "";
        prefab.object = parsed.value.object;
        prefab.object.asset_path = owned_path;
        return prefab;
    }

    pub fn stringify(self: *const Prefab, allocator: std.mem.Allocator) ![]u8 {
        try validateObject(self.object);
        return std.json.Stringify.valueAlloc(allocator, SerializedPrefab{
            .version = CurrentVersion,
            .object = self.object,
        }, .{ .whitespace = .indent_2 });
    }
};

pub fn validateObject(object: Object) !void {
    if (object.id == 0 or
        !std.math.isFinite(object.position[0]) or !std.math.isFinite(object.position[1]) or
        !std.math.isFinite(object.size[0]) or !std.math.isFinite(object.size[1]) or
        object.size[0] <= 0 or object.size[1] <= 0)
        return error.InvalidSceneObject;
    if (object.asset_path.len > 0 and !validAssetPath(object.asset_path)) return error.InvalidAssetPath;
}

fn validAssetPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or path[0] == '\\' or
        std.mem.indexOfScalar(u8, path, '\\') != null or
        std.mem.indexOfScalar(u8, path, ':') != null or
        std.mem.indexOfScalar(u8, path, 0) != null)
        return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

test "scene document JSON round-trip preserves objects and stable asset references" {
    var document = Document.init(std.testing.allocator);
    defer document.deinit();
    const first_id = try document.add(.sprite);
    const second_id = try document.add(.obstacle);
    document.get(first_id).?.position = .{ 42, -9 };
    document.get(second_id).?.size = .{ 100, 32 };
    try document.setAssetPath(first_id, "Assets/Sprites/player.png");

    const json = try document.stringify(std.testing.allocator);
    defer std.testing.allocator.free(json);
    var loaded = try Document.parse(std.testing.allocator, json);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 2), loaded.objects.items.len);
    try std.testing.expectEqual(@as(f32, 42), loaded.objects.items[0].position[0]);
    try std.testing.expectEqual(ObjectKind.obstacle, loaded.objects.items[1].kind);
    try std.testing.expectEqualStrings("Assets/Sprites/player.png", loaded.objects.items[0].asset_path);
    try std.testing.expectEqual(@as(u32, 3), try loaded.add(.pickup));
}

test "scene version one migrates and version two persists" {
    const legacy =
        \\{"version":1,"objects":[{"id":7,"kind":"sprite","position":[2,3],"size":[4,5]}]}
    ;
    var migrated = try Document.parse(std.testing.allocator, legacy);
    defer migrated.deinit();
    try std.testing.expectEqualStrings("", migrated.objects.items[0].asset_path);
    const current = try migrated.stringify(std.testing.allocator);
    defer std.testing.allocator.free(current);
    try std.testing.expect(std.mem.indexOf(u8, current, "\"version\": 2") != null);
    try std.testing.expectError(error.UnsupportedSceneVersion, Document.parse(std.testing.allocator, "{\"version\":3,\"objects\":[]}"));
}

test "scene validation rejects duplicate ids and unsafe asset paths" {
    var document = Document.init(std.testing.allocator);
    defer document.deinit();
    _ = try document.add(.sprite);
    _ = try document.add(.pickup);
    document.objects.items[1].id = document.objects.items[0].id;
    try std.testing.expectError(error.DuplicateObjectId, document.validate());

    document.objects.items[1].id = 2;
    try std.testing.expectError(error.InvalidAssetPath, document.setAssetPath(2, "../outside.png"));
    try std.testing.expectError(error.InvalidAssetPath, document.setAssetPath(2, "C:/outside.png"));
}

test "scene parse owns asset paths and validates object data" {
    const json =
        \\{"version":2,"objects":[{"id":1,"kind":"pickup","position":[0,0],"size":[0,2],"asset_path":"Assets/item.png"}]}
    ;
    try std.testing.expectError(error.InvalidSceneObject, Document.parse(std.testing.allocator, json));
}

test "prefab version one migrates and stable asset path round-trips" {
    const legacy =
        \\{"version":1,"object":{"id":7,"kind":"pickup","position":[1,2],"size":[3,4]}}
    ;
    var prefab = try Prefab.parse(std.testing.allocator, legacy);
    defer prefab.deinit();
    try prefab.setAssetPath("Assets/Sprites/pickup.png");

    const current = try prefab.stringify(std.testing.allocator);
    defer std.testing.allocator.free(current);
    try std.testing.expect(std.mem.indexOf(u8, current, "\"version\": 2") != null);
    var parsed = try Prefab.parse(std.testing.allocator, current);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("Assets/Sprites/pickup.png", parsed.object.asset_path);
    try std.testing.expectError(error.UnsupportedPrefabVersion, Prefab.parse(
        std.testing.allocator,
        "{\"version\":8,\"object\":{\"id\":1,\"kind\":\"pickup\",\"position\":[0,0],\"size\":[1,1]}}",
    ));
}
