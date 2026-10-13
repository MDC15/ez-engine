const std = @import("std");
const World = @import("../ecs/world.zig").World;
const Entity = @import("../ecs/entity.zig").Entity;
const Scene = @import("scene.zig");
const RenderComponents = @import("../gfx/render_components.zig");
const Collision2D = @import("../physics/collision2d.zig");
const TextureHandle = @import("../core/handle.zig").TextureHandle;

/// Textures used when spawning a scene. Game art stays in the caller;
/// the pipeline only maps kinds to entities + base components.
pub const SpawnTextures = struct {
    player: TextureHandle,
    sprite: TextureHandle,
};

fn validate(object: Scene.Object) !void {
    if (!std.math.isFinite(object.position[0]) or !std.math.isFinite(object.position[1]) or
        !std.math.isFinite(object.size[0]) or !std.math.isFinite(object.size[1]) or
        object.size[0] <= 0 or object.size[1] <= 0)
        return error.InvalidSceneObject;
}

/// Spawns one scene object. Returns the entity, or null (never for the
/// current kinds — reserved for future non-entity objects).
/// Game-specific markers (e.g. Collectible, Script state) stay in the
/// caller; this only attaches Transform + SpriteRenderer + Collider2D
/// (+ default SpriteAnimation for .sprite).
pub fn spawnObject(world: *World, object: Scene.Object, textures: SpawnTextures) !?Entity {
    try validate(object);
    switch (object.kind) {
        .sprite => {
            const entity = try world.create();
            errdefer world.destroy(entity) catch {};
            try world.add(entity, RenderComponents.Transform{
                .position = .{ .x = object.position[0], .y = object.position[1] },
            });
            try world.add(entity, RenderComponents.SpriteRenderer{
                .texture = textures.player,
                .size = .{ .x = 240, .y = 240 },
            });
            try world.add(entity, RenderComponents.SpriteAnimation{
                .sheet = .{ .columns = 5, .rows = 1 },
            });
            try world.add(entity, Collision2D.Collider2D{
                .size = .{ .x = object.size[0], .y = object.size[1] },
                .solid = true,
                .layer = 1,
            });
            return entity;
        },
        .pickup => {
            const entity = try world.create();
            errdefer world.destroy(entity) catch {};
            try world.add(entity, RenderComponents.Transform{
                .position = .{ .x = object.position[0], .y = object.position[1] },
            });
            try world.add(entity, RenderComponents.SpriteRenderer{
                .texture = textures.sprite,
                .size = .{ .x = object.size[0], .y = object.size[1] },
                .tint = .{ .x = 1, .y = 0.7, .z = 0.2, .w = 1 },
                .z_index = 1,
            });
            try world.add(entity, Collision2D.Collider2D{
                .size = .{ .x = object.size[0], .y = object.size[1] },
                .layer = 3,
                .collides_with = Collision2D.layerBit(1),
            });
            return entity;
        },
        .obstacle => {
            const entity = try world.create();
            errdefer world.destroy(entity) catch {};
            try world.add(entity, RenderComponents.Transform{
                .position = .{ .x = object.position[0], .y = object.position[1] },
            });
            try world.add(entity, RenderComponents.SpriteRenderer{
                .texture = textures.sprite,
                .size = .{ .x = object.size[0], .y = object.size[1] },
                .tint = .{ .x = 0.45, .y = 0.5, .z = 0.6, .w = 1 },
                .z_index = 1,
            });
            try world.add(entity, Collision2D.Collider2D{
                .size = .{ .x = object.size[0], .y = object.size[1] },
                .solid = true,
                .is_static = true,
                .layer = 2,
                .collides_with = Collision2D.layerBit(1) | Collision2D.layerBit(2),
            });
            return entity;
        },
    }
}

/// Spawns every object in a loaded document. Returns the first .sprite
/// entity (the player) or null when the document has none.
/// Atomic: all objects are validated before any entity is created, so an
/// invalid object leaves the world untouched.
pub fn spawnDocument(world: *World, doc: Scene.Document, textures: SpawnTextures) !?Entity {
    for (doc.objects.items) |object| try validate(object);
    var player: ?Entity = null;
    for (doc.objects.items) |object| {
        const spawned = try spawnObject(world, object, textures);
        if (object.kind == .sprite and player == null) player = spawned;
    }
    return player;
}
