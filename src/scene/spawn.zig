const std = @import("std");
const World = @import("../ecs/world.zig").World;
const Entity = @import("../ecs/entity.zig").Entity;
const Scene = @import("scene.zig");
const RenderComponents = @import("../gfx/render_components.zig");
const Collision2D = @import("../physics/collision2d.zig");
const TextureHandle = @import("../core/handle.zig").TextureHandle;
const Vec2 = @import("../math/vec2.zig").Vec2;
const Vec4 = @import("../math/vec4.zig").Vec4;

pub const SpawnTextures = struct {
    player: TextureHandle,
    sprite: TextureHandle,
};

pub const AssetResolver = struct {
    context: ?*anyopaque = null,
    resolveFn: *const fn (?*anyopaque, []const u8) anyerror!TextureHandle,

    pub fn resolve(self: AssetResolver, path: []const u8) anyerror!TextureHandle {
        return self.resolveFn(self.context, path);
    }
};

const SpawnedObject = struct {
    object_id: u32,
    entity: Entity,
};

/// Tracks entities created for one scene so they can be located or despawned.
pub const Instance = struct {
    allocator: std.mem.Allocator,
    objects: std.ArrayListUnmanaged(SpawnedObject) = .empty,
    player: ?Entity = null,

    pub fn entityForObject(self: *const Instance, object_id: u32) ?Entity {
        for (self.objects.items) |object| {
            if (object.object_id == object_id) return object.entity;
        }
        return null;
    }

    pub fn despawnObject(self: *Instance, world: *World, object_id: u32) !bool {
        for (self.objects.items, 0..) |object, index| {
            if (object.object_id != object_id) continue;
            if (world.isAlive(object.entity)) {
                try world.reserveDestroyCapacity(1);
                try world.destroy(object.entity);
            }
            _ = self.objects.orderedRemove(index);
            if (self.player != null and self.player.?.id == object.entity.id and
                self.player.?.generation == object.entity.generation)
                self.player = null;
            return true;
        }
        return false;
    }

    pub fn despawn(self: *Instance, world: *World) !void {
        try world.reserveDestroyCapacity(self.objects.items.len);
        var index = self.objects.items.len;
        while (index > 0) {
            index -= 1;
            const entity = self.objects.items[index].entity;
            if (world.isAlive(entity)) try world.destroy(entity);
            _ = self.objects.orderedRemove(index);
        }
        self.objects.deinit(self.allocator);
        self.player = null;
    }
};

/// Spawns one object using a caller-provided texture. Game-specific components
/// remain the caller's responsibility.
pub fn spawnObject(world: *World, object: Scene.Object, textures: SpawnTextures) !?Entity {
    try Scene.validateObject(object);
    if (object.asset_path.len > 0) return error.AssetResolverRequired;
    const texture = if (object.kind == .sprite) textures.player else textures.sprite;
    return try spawnObjectWithTexture(world, object, texture);
}

fn spawnObjectWithTexture(world: *World, object: Scene.Object, texture: TextureHandle) !Entity {
    try world.reserveDestroyCapacity(1);
    const entity = try world.create();
    errdefer world.destroy(entity) catch |err| {
        std.log.err("failed to roll back partially spawned scene object: {s}", .{@errorName(err)});
    };

    try world.add(entity, RenderComponents.Transform{
        .position = .{ .x = object.position[0], .y = object.position[1] },
    });
    const size = if (object.kind == .sprite)
        Vec2{ .x = 240, .y = 240 }
    else
        Vec2{ .x = object.size[0], .y = object.size[1] };
    const tint: Vec4 = switch (object.kind) {
        .sprite => .one,
        .pickup => .{ .x = 1, .y = 0.7, .z = 0.2, .w = 1 },
        .obstacle => .{ .x = 0.45, .y = 0.5, .z = 0.6, .w = 1 },
    };
    const z_index: i32 = if (object.kind == .sprite) 0 else 1;
    try world.add(entity, RenderComponents.SpriteRenderer{
        .texture = texture,
        .size = size,
        .tint = tint,
        .z_index = z_index,
    });
    if (object.kind == .sprite) {
        try world.add(entity, RenderComponents.SpriteAnimation{
            .sheet = .{ .columns = 5, .rows = 1 },
        });
    }
    const collider = switch (object.kind) {
        .sprite => Collision2D.Collider2D{
            .size = .{ .x = object.size[0], .y = object.size[1] },
            .solid = true,
            .layer = 1,
        },
        .pickup => Collision2D.Collider2D{
            .size = .{ .x = object.size[0], .y = object.size[1] },
            .layer = 3,
            .collides_with = Collision2D.layerBit(1),
        },
        .obstacle => Collision2D.Collider2D{
            .size = .{ .x = object.size[0], .y = object.size[1] },
            .solid = true,
            .is_static = true,
            .layer = 2,
            .collides_with = Collision2D.layerBit(1) | Collision2D.layerBit(2),
        },
    };
    try world.add(entity, collider);
    return entity;
}

/// Resolves all referenced assets before creating entities. A missing or
/// invalid asset therefore leaves the world unchanged.
pub fn spawnDocumentResolved(
    world: *World,
    allocator: std.mem.Allocator,
    document: *const Scene.Document,
    resolver: AssetResolver,
) !Instance {
    try document.validate();
    var textures = try allocator.alloc(TextureHandle, document.objects.items.len);
    defer allocator.free(textures);
    for (document.objects.items, 0..) |object, index| {
        if (object.asset_path.len == 0) return error.MissingAssetReference;
        textures[index] = resolver.resolve(object.asset_path) catch |err| switch (err) {
            error.FileNotFound, error.InvalidHandle => return error.AssetNotFound,
            else => return err,
        };
    }
    return spawnAll(world, allocator, document, textures);
}

pub fn spawnPrefabResolved(
    world: *World,
    allocator: std.mem.Allocator,
    prefab: *const Scene.Prefab,
    resolver: AssetResolver,
) !Instance {
    try Scene.validateObject(prefab.object);
    if (prefab.object.asset_path.len == 0) return error.MissingAssetReference;
    const texture = resolver.resolve(prefab.object.asset_path) catch |err| switch (err) {
        error.FileNotFound, error.InvalidHandle => return error.AssetNotFound,
        else => return err,
    };
    try world.reserveDestroyCapacity(1);
    var instance = Instance{ .allocator = allocator };
    errdefer rollback(&instance, world);
    try instance.objects.ensureTotalCapacity(allocator, 1);
    const entity = try spawnObjectWithTexture(world, prefab.object, texture);
    instance.objects.appendAssumeCapacity(.{ .object_id = prefab.object.id, .entity = entity });
    if (prefab.object.kind == .sprite) instance.player = entity;
    return instance;
}

/// Spawns every object using legacy per-kind texture fallbacks. Prefer
/// `spawnDocumentResolved` for documents with stable asset paths.
pub fn spawnDocument(world: *World, document: Scene.Document, textures: SpawnTextures) !?Entity {
    try document.validate();
    for (document.objects.items) |object| {
        if (object.asset_path.len > 0) return error.AssetResolverRequired;
    }
    var instance = try spawnLegacyInstance(world, &document, textures);
    defer instance.objects.deinit(instance.allocator);
    return instance.player;
}

fn spawnLegacyInstance(world: *World, document: *const Scene.Document, textures: SpawnTextures) !Instance {
    try world.reserveDestroyCapacity(document.objects.items.len);
    var instance = Instance{ .allocator = world.allocator };
    errdefer rollback(&instance, world);
    try instance.objects.ensureTotalCapacity(world.allocator, document.objects.items.len);
    for (document.objects.items) |object| {
        const texture = if (object.kind == .sprite) textures.player else textures.sprite;
        const entity = try spawnObjectWithTexture(world, object, texture);
        instance.objects.appendAssumeCapacity(.{ .object_id = object.id, .entity = entity });
        if (object.kind == .sprite and instance.player == null) instance.player = entity;
    }
    return instance;
}

fn spawnAll(
    world: *World,
    allocator: std.mem.Allocator,
    document: *const Scene.Document,
    textures: []const TextureHandle,
) !Instance {
    try world.reserveDestroyCapacity(document.objects.items.len);
    var instance = Instance{ .allocator = allocator };
    errdefer rollback(&instance, world);
    try instance.objects.ensureTotalCapacity(allocator, document.objects.items.len);
    for (document.objects.items, textures) |object, texture| {
        const entity = try spawnObjectWithTexture(world, object, texture);
        instance.objects.appendAssumeCapacity(.{ .object_id = object.id, .entity = entity });
        if (object.kind == .sprite and instance.player == null) instance.player = entity;
    }
    return instance;
}

fn rollback(instance: *Instance, world: *World) void {
    for (instance.objects.items) |object| {
        if (!world.isAlive(object.entity)) continue;
        world.destroy(object.entity) catch |err| {
            std.log.err("failed to roll back scene spawn: {s}", .{@errorName(err)});
        };
    }
    instance.objects.deinit(instance.allocator);
}

test "resolved scene instance owns entity mapping and despawns cleanly" {
    const ResolverState = struct {
        calls: usize = 0,
        fn resolve(context: ?*anyopaque, path: []const u8) anyerror!TextureHandle {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            if (!std.mem.startsWith(u8, path, "Assets/")) return error.AssetNotFound;
            return .{ .index = @intCast(self.calls), .generation = 1 };
        }
    };

    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var document = Scene.Document.init(std.testing.allocator);
    defer document.deinit();
    const player_id = try document.add(.sprite);
    try document.setAssetPath(player_id, "Assets/Sprites/player.png");
    const pickup_id = try document.add(.pickup);
    try document.setAssetPath(pickup_id, "Assets/Sprites/item.png");
    var resolver_state: ResolverState = .{};

    var instance = try spawnDocumentResolved(&world, std.testing.allocator, &document, .{
        .context = &resolver_state,
        .resolveFn = ResolverState.resolve,
    });
    try std.testing.expectEqual(@as(usize, 2), world.aliveCount());
    try std.testing.expectEqual(@as(usize, 2), resolver_state.calls);
    try std.testing.expectEqual(instance.player.?.id, instance.entityForObject(player_id).?.id);
    try std.testing.expect(try instance.despawnObject(&world, pickup_id));
    try std.testing.expectEqual(@as(usize, 1), world.aliveCount());
    try instance.despawn(&world);
    try std.testing.expectEqual(@as(usize, 0), world.aliveCount());
}

test "resolved scene reports missing assets before spawning" {
    const Resolver = struct {
        fn resolve(_: ?*anyopaque, _: []const u8) anyerror!TextureHandle {
            return error.FileNotFound;
        }
    };
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var document = Scene.Document.init(std.testing.allocator);
    defer document.deinit();
    const id = try document.add(.pickup);
    try document.setAssetPath(id, "Assets/Sprites/missing.png");
    try std.testing.expectError(error.AssetNotFound, spawnDocumentResolved(&world, std.testing.allocator, &document, .{
        .resolveFn = Resolver.resolve,
    }));
    try std.testing.expectEqual(@as(usize, 0), world.aliveCount());
}

test "resolved scene rejects missing references and remains atomic on invalid documents" {
    const Resolver = struct {
        fn resolve(_: ?*anyopaque, _: []const u8) anyerror!TextureHandle {
            return .{ .index = 1, .generation = 1 };
        }
    };
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var document = Scene.Document.init(std.testing.allocator);
    defer document.deinit();
    _ = try document.add(.sprite);
    try std.testing.expectError(error.MissingAssetReference, spawnDocumentResolved(&world, std.testing.allocator, &document, .{
        .resolveFn = Resolver.resolve,
    }));
    try std.testing.expectEqual(@as(usize, 0), world.aliveCount());
}

test "resolved prefab spawns and despawns a tracked reusable object" {
    const Resolver = struct {
        fn resolve(_: ?*anyopaque, path: []const u8) anyerror!TextureHandle {
            if (!std.mem.eql(u8, path, "Assets/Sprites/pickup.png")) return error.FileNotFound;
            return .{ .index = 7, .generation = 2 };
        }
    };
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var prefab = Scene.Prefab.init(std.testing.allocator, .pickup);
    defer prefab.deinit();
    try prefab.setAssetPath("Assets/Sprites/pickup.png");

    var instance = try spawnPrefabResolved(&world, std.testing.allocator, &prefab, .{
        .resolveFn = Resolver.resolve,
    });
    try std.testing.expectEqual(@as(usize, 1), world.aliveCount());
    try std.testing.expect(instance.entityForObject(prefab.object.id) != null);
    try instance.despawn(&world);
    try std.testing.expectEqual(@as(usize, 0), world.aliveCount());
}
