# Architecture

## Frame flow

```text
Game.frame
  → run ECS systems
  → extract Transform + MeshRenderer / SpriteRenderer
  → cull meshes with Camera and sprites with Camera2D
  → sort render items and form adjacent batches
  → call Renderer.Backend.render(RenderWorld)
```

Gameplay components contain resource handles, not GPU objects. `RenderWorld` is
temporary CPU-side render data. The headless backend counts submissions; the
WGPU example currently draws sprites only.

## Ownership

- `Game` owns the world, scheduler, asset manager, audio mixer and render world.
- `Assets` owns decoded texture pixels and file-cache bytes. Load texture files
  with the caller's `std.Io` and a maximum file size.
- A rendering backend resolves handles and owns its GPU resources. `Game.deinit`
  waits for renderer work, destroys the backend, then releases assets.
- ECS components are copied during archetype migration. Keep components plain
  data; do not put owning pointers or values that require destructors in them.

The WGPU sample uses `zglfw` and `zgpu` through `src/platform/glfw_window.zig`.
The adapter owns GLFW initialization and the native window, then translates
keyboard, mouse, scroll, close and framebuffer resize callbacks into
`Platform.Event`. Pass `adapter.platformWindow()` to `Game.run(io, window)` to
use the engine's frame loop. The sample's WASD movement is an ECS system, so
window and input handling stay separate from gameplay.

## Logging and runtime debug stats

`Game.logger` writes leveled messages with a category in the consistent format
`[LEVEL] [category] message`. Multiline messages repeat the prefix on each
line. `min_level` filters messages, `writeCategory` writes a string without
allocating, and `formatCategory` formats a message using a caller-provided
allocator. A custom sink can route output to a file, editor console or other
development tool.

Set `game.debug.enabled = true` to capture a `game.debug.stats` snapshot after
each successful frame. It includes frame time, smoothed FPS, live entities,
render items before and after culling, culled items and render batches. Stats
collection is disabled by default. The WGPU sample toggles collection with F3
and reports frame number, FPS, frame time, entity count, visible/total sprites,
culled sprites and batches through the logger once per second.

## Sprite behavior

`SpriteRenderer` provides a texture handle, world-space size, tint, UV source
rectangle and integer `z_index`. `Transform` provides position, rotation and
scale. The 2D camera maps its centered world-space viewport to normalized
device coordinates. The game derives viewport height from viewport width and
framebuffer aspect ratio.

Sprites with lower `z_index` draw first. Equal-layer sprites keep extraction
order; only adjacent sprites with the same texture and layer share a draw call.
The sample uses nearest filtering and alpha blending.

`SpriteSheet` maps a row-major grid to normalized UV rectangles; frame zero is
the top-left cell. Attach `SpriteAnimation` alongside `SpriteRenderer` and add
`SpriteAnimation.updateSystem` to the scheduler. Call `play(clip)` to switch
clips; the animation restarts only when the selected clip changes. Clips support
looping or one-shot playback and a configurable frame rate. The WGPU sample
selects a single-frame idle clip when the player stops and a four-frame walk
clip while WASD is held. Run the movement system before the animation system so
the selected clip advances in the same frame.

## 2D overlap detection

Attach `Collision2D.Collider2D` and `Transform` to an entity, then add an
initialized `Collision2D.System` to the scheduler. It checks axis-aligned boxes
using `size`, `offset` and absolute transform scale; rotation is ignored. The
system reuses its buffers and emits `begin`, `stay` and `end` events through an
optional listener. A `solid` collider resolves overlap along the shallower axis;
when one collider is `is_static`, only the other is moved. Two dynamic solid
colliders split the correction. A non-solid collider acts as a trigger. Collider
bounds are captured before event dispatch, so a listener can destroy an entity
safely. Register this system after movement so the correction applies in the
same frame. This is a simple discrete response and does not include forces,
friction or continuous collision detection. The sample uses a static wall and
logs contact `begin`/`end` with entity IDs. It destroys its trigger collectible
on the first `begin` event and logs the pickup separately.

## 2D camera follow

Create `CameraFollow2D.System` with a pointer to `Game.camera_2d` and the target
entity, then register `updateSystem` after movement and collision systems. Set
`follow_speed` to `0` for direct tracking or a positive value for a smooth
response; `offset` adjusts the camera target in world units. The WGPU sample
uses smooth follow so the player stays near the center while moving.

## Texture formats

`Assets.loadTextureFile` detects PNG by its signature and ZTEX by its magic.
PNG input is decoded on the CPU to tightly packed RGBA8 pixels. The caller's
maximum file size also caps expanded RGBA storage using dimensions from IHDR,
before invoking the decoder.

## ZTEX texture format

The built-in decoder accepts exactly one tightly packed image:

| Offset | Size | Meaning |
| --- | ---: | --- |
| 0 | 4 bytes | ASCII `ZTEX` |
| 4 | u32 LE | Version, currently `1` |
| 8 | u32 LE | Width in pixels |
| 12 | u32 LE | Height in pixels |
| 16 | 1 byte | `0` = RGBA8, `1` = BGRA8 |
| 17 | 3 bytes | Reserved |
| 20 | `width × height × 4` bytes | Pixel data, rows in order |

Dimensions must be nonzero and the file length must match the header exactly.
The file-size limit is checked when reading the asset. ZTEX is an engine format;
JPEG and other image formats are not decoded.

## Current renderer limits

- WGPU sprite rendering is in the example backend, not a built-in cross-platform
  renderer module.
- Mesh and material items can be extracted and batched but are not drawn by the
  WGPU sample.
- The WGPU backend checks texture handles each frame and releases GPU textures
  whose assets were unloaded. Release therefore takes effect at the next render.
- The sample submits directly to the WebGPU queue; the pinned `zgpu` submit
  helper is not used.
