//! A modular, data-oriented game library. Gameplay and ECS modules do not
//! depend on a graphics backend.

pub const version: []const u8 = "0.1.0-dev";

pub const World = @import("ecs/world.zig").World;
pub const Entity = @import("ecs/entity.zig").Entity;
pub const Scheduler = @import("ecs/scheduler.zig").Scheduler;
pub const Query = @import("ecs/query.zig");
pub const Vec3 = @import("math/vec3.zig").Vec3;
pub const Vec2 = @import("math/vec2.zig").Vec2;
pub const Vec4 = @import("math/vec4.zig").Vec4;
pub const Quat = @import("math/quat.zig").Quat;
pub const Mat4 = @import("math/mat4.zig").Mat4;
pub const Handles = @import("core/handle.zig");
pub const TextureHandle = Handles.TextureHandle;
pub const RenderWorld = @import("gfx/render_world.zig").RenderWorld;
pub const RenderComponents = @import("gfx/render_components.zig");
pub const SpriteAnimation = @import("gfx/sprite_animation.zig");
pub const Collision2D = @import("physics/collision2d.zig");
pub const Camera = @import("gfx/camera.zig").Camera;
pub const Camera2D = @import("gfx/camera.zig").Camera2D;
pub const CameraFollow2D = @import("gfx/camera_follow.zig");
pub const Renderer = @import("gfx/renderer.zig");
pub const Platform = @import("ez_platform");
pub const Input = @import("ez_input").Input;
pub const Audio = @import("audio/audio.zig").Audio;
pub const Assets = @import("asset/manager.zig").Manager;
pub const Game = @import("game.zig").Game;
pub const Time = @import("core/time.zig");
pub const Logging = @import("core/log.zig");
pub const Debug = @import("core/debug.zig");
pub const AllocatorTools = @import("core/allocator.zig");
pub const InputModule = @import("ez_input");
pub const Scene = @import("scene/scene.zig");
pub const Texture = @import("gfx/texture.zig").Texture;
pub const AssetLoading = struct {
    pub const Texture = @import("asset/texture_loader.zig");
};

test {
    _ = @import("ecs/world.zig");
    _ = @import("ecs/query.zig");
    _ = @import("ecs/scheduler.zig");
    _ = @import("ecs/system.zig");
    _ = @import("ecs/component.zig");
    _ = @import("ecs/archetype.zig");
    _ = @import("ecs/storage.zig");
    _ = @import("math/vec3.zig");
    _ = @import("math/vec2.zig");
    _ = @import("math/vec4.zig");
    _ = @import("math/quat.zig");
    _ = @import("math/mat4.zig");
    _ = @import("core/time.zig");
    _ = @import("core/log.zig");
    _ = @import("core/debug.zig");
    _ = @import("core/allocator.zig");
    _ = @import("core/handle.zig");
    _ = @import("ez_input");
    _ = @import("asset/manager.zig");
    _ = @import("asset/texture_loader.zig");
    _ = @import("audio/audio.zig");
    _ = @import("gfx/renderer.zig");
    _ = @import("gfx/camera.zig");
    _ = @import("gfx/camera_follow.zig");
    _ = @import("gfx/render_world.zig");
    _ = @import("gfx/sprite_animation.zig");
    _ = @import("physics/collision2d.zig");
    _ = @import("scene/scene.zig");
    _ = @import("ez_platform");
    _ = @import("gfx/texture.zig");
    _ = @import("game.zig");
}
