# Public API (`ez_engine` `0.1.0-dev`)

Source of truth: `src/root.zig`. Full signatures: `zig build docs`.
Internal import names (`ez_platform`, `ez_input`, `ez_zigimg`) are build
details; consumers only import `ez_engine`.

## Game loop

- `Game.init(allocator, audio_channels) !Game` — builds world, scheduler,
  assets, audio mixer and render world.
- `Game.frame(dt: f32) !void` — `dt` must be finite and `>= 0`
  (`error.InvalidDeltaTime`); runs systems, extracts/culls/sorts sprites,
  renders, captures debug stats.
- `Game.run(io: std.Io, window: Platform.Window) !void` — clock loop with
  `dt` clamped to 0.25s; feed input via `beginFrame()` + platform events.
- `Game.deinit()` — `waitIdle`, destroys backend, then frees subsystems.
- `game.renderer: ?Renderer.Backend`, `game.camera_2d: Camera2D`,
  `game.debug: Debug.Monitor`, `game.logger: Logging.Logger`,
  `game.input: Input`, `game.assets: Assets`, `game.world: World`.

## ECS

- `World`: `init/deinit`, `create() !Entity`, `destroy(entity)`,
  `add(entity, value: anytype)`, `remove(T)`, `get(T) !*T`, `has(T)`,
  `query(spec)`, `aliveCount()`. Components must be plain data (copied on
  archetype migration — no owning pointers).
- `Entity{ id, generation }` (generational: stale handles fail `isAlive`).
- `Scheduler`: `addSystem(name, ctx, UpdateFn) !SystemId`,
  `dependsOn(before, after)`, `run(world, dt)` in topological order,
  `error.DependencyCycle` on loops.
- `Query`: `Read(T)`, `Optional(T)`, `Exclude(T)` combinators;
  `Query(Include, Excluded, World).next()`.

`UpdateFn = *fn (?*anyopaque, *World, f32) anyerror!void`.

## Sprites and camera

- `RenderComponents.Transform{ position: Vec3, rotation: Quat, scale: Vec3 }`.
- `RenderComponents.SpriteRenderer{ texture, size: Vec2, tint: Vec4,
  source_rect: UVRect, z_index: i32 }`.
- `RenderComponents.SpriteSheet{ columns, rows }` +
  `frameUv(i) !UVRect`; `SpriteAnimation{ sheet, clip, ... }` with
  `play(clip)`, `update(sprite, dt)`, and scheduler-ready
  `SpriteAnimation.updateSystem`.
- `RenderWorld`: `extract(world)`, `cullSprites2D(Camera2D)`,
  `sortForBatching()`, `batches()` → `Batch{texture, z_index, first, count}`.
- `Camera2D{ center, viewport_size, zoom }` + `worldToNdc`;
  `CameraFollow2D.System.init(&camera_2d, target)` with
  `follow_speed` (`0` = snap) and `offset`.

## Collision

- `Collision2D.Collider2D{ size: Vec2, offset: Vec2, enabled, solid,
  is_static }`.
- `Collision2D.System.init(allocator)`, `setListener(ctx, fn)`,
  `Collision2D.System.updateSystem`; `Event{ kind: begin|stay|end, a, b }`.

## Assets and audio

- `Assets.loadTextureFile(io, path, max_bytes) !TextureHandle` (PNG/ZTEX,
  path-cached); `getTexture(handle)`, `releaseTexture(handle)`.
- `AssetLoading.Texture`: raw `load(bytes)` / `loadAny(bytes, max)`.
- `Texture{ width, height, format: rgba8|bgra8, ... }`.
- `Audio.init(allocator, channels)` / `initConfigured(..., rate)` (default
  48000 Hz, no resampling); `play(clip, volume) !voice`,
  `stop(voice)`, `mix(out: []f32)`; `decodeWav(allocator, bytes)`.

## Input, platform, scene

- `Input`: `key/keyCode`, `mouseButton`, `moveMouse`, `addScroll`;
  per-frame edges via `beginFrame()` (`pressed`/`released` live one frame).
  `Key` / `MouseButton` enums exported at root.
- `Platform.Window` vtable (`pollEvents`, `framebuffer_extent`,
  `requestClose`, `shouldClose`) and `Platform.Event`; GLFW adapter at
  `src/platform/glfw_window.zig` (`WindowAdapter.init(w, h, title)`).
- `Scene.Document`: `init/deinit`, `add(kind) !id`, `remove(id) bool`,
  `get(id) ?*Object`, `save(io, path)`, `load(io, path)`
  (`error.UnsupportedSceneVersion` unless `version == 1`).
- `Script`: `init(game, &behavior)` / `initWithStart(game, &behavior)` for
  structs with `pub onUpdate(*T, *Ctx) (!void|void)` (plus optional `pub
  onStart` via `initWithStart`, runs on the first executed frame — plain
  `init` silently ignores `onStart`);
  `register(&scheduler, name)`. `Script.Ctx{ world, game, dt }`.
- `Script.Mover2D{ entity: ?Entity = null, speed: f32 = 260 }`:
  `update(&ctx) !Vec2` drives `Transform` with WASD + arrows, returns the
  normalized direction; null entity → `error.UnboundEntity`.
- `Renderer.Backend` vtable + `Renderer.Headless` test backend
  (`submitted_frames`, `submitted_items`).
- `Scene`, `Logging`, `Debug`, `Time` (Clock/FixedStepper),
  `AllocatorTools` (FrameArena), `Handles`/`TextureHandle`, math
  (`Vec2/3/4`, `Quat`, `Mat4`).

## Desktop-only module

- `wgpu_backend` (`src/gfx/wgpu/backend.zig`, Linux x86_64):
  `SpriteBackend.init(allocator, graphics, assets) !SpriteBackend`,
  `backend() Renderer.Backend`, `deinit()`. Import as its own module, not
  from `ez_engine` root.
- `ez_app` (`src/app/desktop.zig`, Linux x86_64): `App.init(&app, allocator,
  title, width, height) !void` builds window + graphics + game + backend in
  place (out-pointer: the backend must keep pointing at the `App`'s own
  fields, so `App` is never returned by value);
  `run(io)` enters `Game.run`; `deinit()` tears down in reverse order
  (game first, so the backend is destroyed through the renderer).

## Stability

Version is `0.1.0-dev`: anything may change before `0.1.0`. Breaking
changes are recorded in `CHANGELOG.md`.
