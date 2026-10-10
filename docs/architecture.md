# Architecture

## Frame flow

```text
Game.frame(dt)
  → Scheduler.run: gameplay systems (movement, animation, collision, camera)
  → RenderWorld.extract: Transform + SpriteRenderer → RenderItems
  → RenderWorld.cullSprites2D: orthographic cull against Camera2D
  → RenderWorld.sortForBatching: painter order (z_index, then extraction order)
  → Renderer.Backend.render: backend draws batches, resolves texture handles
```

`RenderWorld` is temporary CPU-side data: positions, sizes, tints, UVs and
texture handles. It owns no GPU objects. `Game.frame` also adapts
`camera_2d.viewport_size` to the framebuffer aspect ratio before culling.

## Module layout

```text
src/root.zig          public facade: ez_engine (see docs/api.md)
src/game.zig          Game: owns world, scheduler, assets, audio, render_world
src/ecs/              World, Entity, Scheduler, Query, System, archetype storage
src/math/             Vec2/3/4, Quat, Mat4
src/core/             generational handles, leveled logger, debug stats,
                      clock/fixed-step time, frame arena
src/gfx/              sprites, Camera2D + follow, render world/batching,
                      Backend vtable, Headless backend, texture descriptor,
                      platform event interface
src/gfx/wgpu/         SpriteBackend (separate module, Linux x86_64 only)
src/asset/            Manager (path-cached handles), texture_loader (PNG/ZTEX)
src/audio/            WAV decode + software mixer (no device backend yet)
src/input/            OS-independent Key/MouseButton/Input with 1-frame edges
src/physics/          Collision2D: discrete AABB overlap + events (no dynamics)
src/platform/         GLFW window adapter → Platform.Window/Event
src/scene/            Scene document: JSON save/load (ez_engine.Scene)
```

Core gameplay modules (`ecs`, `math`, `core`, `scene`) never touch a graphics
backend. `src/gfx/wgpu/` is deliberately NOT exported from `root.zig` so the
core library builds on every target without `zgpu`.

## Ownership

- `Game` owns the world, scheduler, asset manager, audio mixer and render
  world. `Game.init(allocator, audio_channels)` builds them; `Game.deinit`
  waits for renderer work, destroys the backend, then releases assets.
- `Assets` owns decoded texture pixels and file-cache bytes. Load files with
  the caller's `std.Io` plus a maximum byte size; textures are cached by path
  and returned as generational handles (`TextureHandle{index, generation}`).
  Releasing a texture only frees the CPU copy; the backend evicts its GPU
  copy on the next render.
- A rendering backend resolves handles and owns its GPU resources
  (pipelines, buffers, textures, bind groups).
- ECS components are copied during archetype migration. Keep components plain
  data; do not put owning pointers or values that require destructors in them.

## Backends

All backends implement `Renderer.Backend` (`resize`, `render`, `waitIdle`,
`deinit`) and are driven by `Game.frame` / `Game.run`.

- **Headless** (`Renderer.Headless`, in the core lib): counts
  `submitted_frames` / `submitted_items`, does no GPU work. Used by the
  sandbox example and backend-interface tests.
- **WGPU sprite backend** (`src/gfx/wgpu/backend.zig`, module
  `wgpu_backend`): nearest-filtered, alpha-blended quads. Created with
  `SpriteBackend.init(allocator, graphics, assets)` which builds the WGSL
  pipeline, sampler and a 4096-vertex buffer that grows by powers of two;
  release with `deinit()`. Hand `backend.backend()` to `game.renderer`.
  Textures upload on first use keyed by `(generation << 32) | index`.
  The sample submits directly to the WebGPU queue.

The WGPU sample (`examples/wgpu_clear`, ~200 lines) is gameplay only: player
controller, sprite animation, collision listener, camera follow and debug
reporter systems. Window and input come from `src/platform/glfw_window.zig`,
which owns GLFW init and translates callbacks into `Platform.Event`; pass
`adapter.platformWindow()` to `Game.run(io, window)`.

## Logging and runtime debug stats

`Game.logger` writes `[LEVEL][category] message`; multiline messages repeat
the prefix per line. `min_level` filters, `writeCategory` avoids allocation,
`formatCategory` formats with a caller allocator. Point the sink at a file or
tool console as needed.

Set `game.debug.enabled = true` to capture `game.debug.stats` after each
frame: frame time, smoothed FPS, live entities, extracted/visible/culled
render items and batch count. Disabled by default; the sample toggles it
with F3 and logs a one-line summary once per second.

## Sprite behavior

`SpriteRenderer` carries a texture handle, world-space `size`, `tint`, UV
`source_rect` and integer `z_index`. `Transform` carries position, rotation
(`Quat`) and scale. `Camera2D.worldToNdc` maps the centered world viewport to
normalized device coordinates.

Lower `z_index` draws first; equal layers keep extraction order. Only
adjacent items sharing texture and layer form one draw call. Rotation is
applied on the CPU per corner before NDC mapping.

`SpriteSheet` maps a uniform row-major grid to UV rects (frame 0 = top-left).
Attach `SpriteAnimation` next to `SpriteRenderer` and register
`SpriteAnimation.updateSystem`. `play(clip)` restarts only when the clip
changes; clips loop or play once at a set FPS. Register movement before the
animation system so the clip advances in the same frame.

## 2D overlap detection

Attach `Collision2D.Collider2D{size, offset, solid, is_static}` plus
`Transform`, then register an initialized `Collision2D.System`. Boxes are
axis-aligned from `size`, `offset` and absolute scale; rotation is ignored.
The system reuses its buffers and emits `begin`/`stay`/`end` through an
optional listener set with `setListener`. `solid` colliders separate along
the shallower axis (static moves nothing; two dynamic bodies split the
correction); non-solid colliders are triggers. Bounds are captured before
dispatch, so listeners may destroy entities. Register after movement.
No forces, friction or continuous collision detection.

## 2D camera follow

Build `CameraFollow2D.System` with `&game.camera_2d` and the target entity,
register `updateSystem` after movement/collision. `follow_speed = 0` snaps;
positive values smooth exponentially. `offset` shifts the target in world
units.

## Texture formats

`Assets.loadTextureFile` sniffs PNG by signature and ZTEX by magic. PNG
decodes on CPU to tightly packed RGBA8; the caller's byte limit also caps
expanded RGBA storage from IHDR dimensions before decoding.

ZTEX (engine format, version 1) is exactly:

| Offset | Size | Meaning |
| --- | ---: | --- |
| 0 | 4 bytes | ASCII `ZTEX` |
| 4 | u32 LE | Version (`1`) |
| 8 | u32 LE | Width in pixels |
| 12 | u32 LE | Height in pixels |
| 16 | 1 byte | `0` = RGBA8, `1` = BGRA8 |
| 17 | 3 bytes | Reserved |
| 20 | `width × height × 4` bytes | Pixel data, rows in order |

Dimensions must be nonzero and the length must match exactly. JPEG and other
formats are not decoded.

## Scripting

Gameplay behaviors are plain structs. `Script.init(&game, &behavior)` adapts
any struct with `pub onUpdate(*T, *Ctx)` into an ECS system registered with
one `script.register(&scheduler, name)` call — no manual `@ptrCast` or
`world.get` boilerplate at the call site. `Ctx` exposes `world`, `game` and
`dt`. `Script.initWithStart` additionally wires `pub onStart`, which runs on
the first executed frame (register before the first frame to get it). Errors
from behaviors propagate through `Game.frame` like handwritten systems.
`Script.Mover2D` is a ready-made WASD/arrows mover returning its direction
for reuse (e.g. animation selection). Handwritten `UpdateFn` systems keep
working unchanged; use them for cross-entity logic (collision listeners,
camera, debug) and behaviors for per-entity logic.

## Scene format

`Scene.Document` (`src/scene/scene.zig`) holds
`Object{id, kind: sprite|obstacle|pickup, position: [2]f32, size: [2]f32}`.
`save(io, path)` writes `{version: 1, objects: [...]}` JSON; `load(io, path)`
validates (`version == 1`, finite numbers, positive sizes) and rebuilds IDs
with `next_id = max_id + 1`. The project starter ships an `editor_scene.json`
example; there is no scene→runtime pipeline yet — games spawn entities in
code.

## Current limits

- Sprites only. Mesh/material/3D support was removed; re-adding it is a
  future design decision, not a leftover.
- Uniform-grid sprite sheets only; no packed atlas or complex clips.
- Discrete AABB overlap only; no physics simulation.
- Software audio mixer only; no audio-device backend, no resampling.
- No reference-image test for the WGPU sample.
- No CI, no license file, version is `0.1.0-dev`.
