# Public API (`ez_engine` `0.1.0`)

Source of truth: `src/root.zig`. Full signatures: `zig build docs`.
Internal import names (`ez_platform`, `ez_input`, `ez_zigimg`) are build
details; consumers only import `ez_engine`.

## Game loop

- `Game.init(allocator, audio_channels) !Game` — builds world, scheduler,
  assets, audio mixer and render world.
- `Game.frame(dt: f32) !void` — one update + one present; `dt` must be finite
  and `>= 0` (`error.InvalidDeltaTime`).
- `Game.update(dt: f32) !void` / `Game.present(frame_seconds: f32) !void` —
  the two halves of `frame`: run systems, then extract/cull/sort/render,
  capture debug stats and reclaim.
- `Game.tick(frame_seconds: f64) !void` — drives `GameLoop`: runs 0..N
  simulation steps then one present; frame time is clamped to
  `loop.max_frame_seconds`. A `stopped` loop skips both.
- `Game.run(io: std.Io, window: Platform.Window) !void` — clock loop feeding
  `tick`; feed input via `beginFrame()` + platform events.
- `Game.deinit()` — waits for renderer work, deinitializes registered systems,
  destroys the renderer, then frees game subsystems. System cleanup can still
  access the world and assets.
- `game.loop: GameLoop` — timing controller: `time_scale` (0 or negative
  freezes), `pause`/`unpause`/`stop`, `GameLoop.initFixed(step_seconds,
  max_steps)`; default is `variable` (one step per frame).
- `Game.destroyDeferred(entity) !void` and `Game.frameAllocator() Allocator` —
  end-of-frame destroy queue and temp allocator; backed by `game.reclaimer`.
- `Game.releaseTexture(handle) !void` — rejects a texture referenced by any
  live `SpriteRenderer`, waits for renderer work, then releases the asset.
  Returns `error.TextureInUse` while an entity still uses that handle.
- `Game.releaseAtlas(handle) !void` and `Game.releaseFont(handle) !void` —
  reject release while live `AtlasPlayer` or `Text` components reference those
  handles, then wait for renderer work before release.
- `game.renderer: ?Renderer.Backend`, `game.camera_2d: Camera2D`,
  `game.debug: Debug.Monitor`, `game.logger: Logging.Logger`,
  `game.input: Input`, `game.assets: Assets`, `game.world: World`.
- `game.post_process: PostProcess.Settings` — post-render color effects;
  `grayscale` and `vignette` are `0...1`, `exposure` is `0...8`. Defaults
  (`0`, `0`, `1`) leave the image unchanged.

## ECS

- `World`: `init/deinit`, `create() !Entity`, `destroy(entity)`,
  `add(entity, value: anytype)`, `remove(T)`, `get(T) !*T`, `has(T)`,
  `query(spec)`, `aliveCount()`. Components must be plain data: `add`
  byte-copies the value (mutating the source afterwards changes nothing),
  migration re-copies the bytes, re-`add` overwrites, and
  `remove`/`destroy` drops the bytes silently with no destructor call.
  Never store owning resources (allocated slices, file handles) in a
  component — a stored slice keeps pointing at the caller's memory.
- `World.destroyDeferred(entity) !void` queues a destroy for a safe boundary;
  `World.flushDeferred()` destroys the queue (already-dead entities are
  dropped, `OutOfMemory` keeps the entry for a retry);
  `World.pendingDestroyCount()`. `destroy` stays immediate.
- `Entity{ id, generation }` (generational: stale handles fail `isAlive`).
- `Scheduler`: `addSystem(name, ctx, UpdateFn) !SystemId`,
  `addSystemWithDeinit(name, ctx, UpdateFn, DeinitFn) !SystemId`,
  `dependsOn(before, after)`, `run(world, dt)` in topological order,
  `error.DependencyCycle` on loops. A registered context is borrowed, not
  allocated or freed by the scheduler; it must outlive the scheduler.
  `addSystemWithDeinit` calls the supplied cleanup callback exactly once
  from   `Scheduler.deinit()`, in reverse dependency order. `Game.deinit()` waits for
  renderer work, then deinitializes its scheduler before destroying the
  renderer, assets or world.
- `Query`: `Read(T)`, `Optional(T)`, `Exclude(T)` combinators;
  `Query(Include, Excluded, World).next()`.

`UpdateFn = *fn (?*anyopaque, *World, f32) anyerror!void`.
`DeinitFn = *fn (?*anyopaque) void`.

## Sprites and camera

- `RenderComponents.Transform{ position: Vec3, rotation: Quat, scale: Vec3 }`.
- `RenderComponents.SpriteRenderer{ texture, size: Vec2, tint: Vec4,
  source_rect: UVRect, z_index: i32 }`.
- `RenderComponents.SpriteSheet{ columns, rows }` +
  `frameUv(i) !UVRect`; `SpriteAnimation{ sheet, clip, ... }` with
  `play(clip)`, `update(sprite, dt)`, and scheduler-ready
  `SpriteAnimation.updateSystem`.
- Packed atlas (`Atlas`): `load(allocator, json, tex_w, tex_h) !OwnedAtlas`
  (`version: 1`, named pixel frames + named clips, per-frame `duration_s`
  and `offset`); `frameUv(name)`, `findClip(name)`; `Manager.loadAtlasFile`
  / `getAtlas` / `releaseAtlas` (path-cached, texture-independent).
  `RenderComponents.AtlasPlayer{ atlas, clip_index, ... }` +
  `Atlas.playAtlas(manager, world, entity, atlas, clip)` and scheduler-ready
  `Atlas.AtlasSystem` (holds `*Manager`); use `Game.releaseAtlas` while the
  game world may contain `AtlasPlayer`s. `SpriteRenderer.draw_offset`
  shifts the quad in world units and is added at `extract` time.
- `RenderWorld`: `extract(world)`, `cullSprites2D(Camera2D)`,
  `sortForBatching()`, `batches()` → `Batch{texture, z_index, first, count}`.
- `Camera2D{ center, viewport_size, zoom }` + `worldToNdc`;
  `CameraFollow2D.System.init(&camera_2d, target)` with
  `follow_speed` (`0` = snap) and `offset`.
- Bitmap fonts (`Font`): `Assets.loadFontFile(io, json_path, texture_path,
  max_bytes) !FontHandle` caches the JSON and shared texture; `getFont` and
  `releaseFont` manage the font independently of its texture; use
  `Game.releaseFont` while the world may contain `Text` components. Font JSON
  uses version 1:

  ```json
  {
    "version": 1,
    "size_px": 8,
    "line_height_px": 10,
    "glyphs": [
      { "ch": "A", "x": 0, "y": 0, "w": 4, "h": 6, "advance": 5 },
      { "ch": " ", "x": 0, "y": 0, "w": 0, "h": 0, "advance": 3 }
    ]
  }
  ```

  `ch` is exactly one Unicode codepoint; `x`, `y`, `w`, `h`, `advance`, and
  optional `offset: [x, y]` are pixel values. Regions must fit the texture;
  advances and font metrics must be positive and finite. A zero-size region is
  allowed only for U+0020. Missing or malformed text characters use U+FFFD,
  then `?`, then a space advance, or a half-em skip.
- `RenderComponents.Text{ font, content, len, size, tint, z_index, alignment }`
  stores up to 256 UTF-8 bytes; `setText(bytes)` returns `error.TextTooLong`
  without changing existing content when over capacity. `Font.TextSystem.init(&assets)`
  creates ordinary sprite entities for glyphs; register
  `Font.TextSystem.updateSystem` with its context after gameplay updates.
  Supports left/center/right alignment against the widest line and
  newline-separated lines. Glyph entities carry
  `RenderComponents.GlyphOf{ parent }`; exclude that marker from gameplay
  queries. Register the system with its cleanup callback so glyph children
  are removed while the world is alive:

  ```zig
  const font = try game.assets.loadFontFile(
      io,
      "Assets/Fonts/ui.json",
      "Assets/Fonts/ui.ztex",
      4 * 1024 * 1024,
  );
  const label = try game.world.create();
  try game.world.add(label, RenderComponents.Transform{
      .position = .{ .x = -300, .y = 250 },
  });
  var text = RenderComponents.Text{ .font = font, .size = 24 };
  try text.setText("Xin chào");
  try game.world.add(label, text);

  var text_system = Font.TextSystem.init(&game.assets);
  try game.scheduler.addSystemWithDeinit(
      "Text",
      &text_system,
      Font.TextSystem.updateSystem,
      Font.TextSystem.deinitSystem,
  );
  ```

  `text_system` storage is borrowed by the scheduler and must remain alive
  until `game.deinit()`; scheduler cleanup calls `TextSystem.deinitSystem`.

## Collision

- `Collision2D.Collider2D{ size: Vec2, offset: Vec2, enabled, solid,
  is_static, layer: u4, collides_with: u16 }` — `layer` tags the collider
  (like an id); `collides_with` is the mask of layers it reacts to (default:
  every layer). Two colliders interact only when **both** masks accept the
  other's layer.
- `Collision2D.layerBit(index: u4) u16` builds a single-layer mask.
- `Collision2D.System.init(allocator)`, `setListener(ctx, fn)`,
  `Collision2D.System.updateSystem`; `Event{ kind: begin|stay|end, a, b }`.
  Solid bodies are separated; a body with `Physics2D.Velocity` also has its
  normal velocity cancelled (and reflected by `RigidBody2D.restitution`).
  Kinematic and static bodies are never pushed.

## Physics

- `Physics2D.Velocity{ linear: Vec2 }`.
- `Physics2D.BodyType = enum { static, kinematic, dynamic }`.
- `Physics2D.RigidBody2D{ body_type = .dynamic, gravity_scale = 1,
  linear_damping = 0, restitution = 0 }`.
- `Physics2D.System{ gravity: Vec2 = {0, -981} }`,
  `Physics2D.System.updateSystem`; run it **before** `Collision2D` (e.g.
  `scheduler.dependsOn(physics_id, collision_id)`). Dynamic bodies integrate
  gravity + damping into `Transform`; kinematic bodies move by velocity
  without gravity; static bodies are skipped. An entity with `Velocity` and
  no `RigidBody2D` moves at a constant velocity (no gravity).

## Assets and audio

- `Assets.loadTextureFile(io, path, max_bytes) !TextureHandle` (PNG/ZTEX,
  path-cached); `getTexture(handle)`, `releaseTexture(handle)`. A texture
  referenced by a live atlas or font cannot be released and returns
  `error.TextureInUse`; release dependent atlases/fonts first. For textures
  referenced by ECS sprites, use `Game.releaseTexture`; direct manager release
  does not inspect the game world. Cache keys are the exact path bytes supplied
  by the caller; aliases such as `assets/hero.png` and `./assets/hero.png` are
  distinct entries. Use a consistent path spelling. Releasing an atlas or font
  does not release its texture.
- `AssetLoading.Texture`: raw `load(bytes)` / `loadAny(bytes, max)`.
- `Texture{ width, height, format: rgba8|bgra8, ... }`.
- `Audio.init(allocator, channels)` / `initConfigured(..., rate)` (default
  48000 Hz, no resampling); `play(clip, volume) !voice`,
  `stop(voice)`, `mix(out: []f32)`; `decodeWav(allocator, bytes)`.
  `Audio.resample(allocator, clip, target_rate) !OwnedClip` (offline linear
  interpolation — the documented fix for `error.SampleRateMismatch`);
  `Audio.releaseClip(allocator, &owned_clip)` frees decoded/resampled samples
  only after voices using that clip are stopped or complete (`ClipInUse`
  otherwise). `play` borrows the clip; keep its storage stable until then.
  `Audio.Device` vtable (`write(frames)`, `deinit`) with headless
  `Audio.NullDevice` for tests. `AudioClip` is the root-exported clip type.
- `Audio.PulseDevice.init(audio, app, stream, server) !PulseDevice` (Linux;
  runtime-loaded `libpulse-simple`, no dev package or link needed; `server`
  null selects the desktop default). Pump once per rendered frame with
  frames matching consumed simulation time:
  `tick(dt)` then `device.write(@intFromFloat(48000 * dt))`.
  Errors: `AudioLibraryMissing` (no lib), `NoAudioServer` (no daemon),
  `PulseWriteFailed` (mid-stream). Recipe on any error: log once, stop
  pumping, the game continues silent. Destroy the device before
  `Game.audio`; borrowed `*Audio`/names must outlive it.

## Input, platform, scene

- `Input`: `key/keyCode`, `isDown/justPressed/justReleased(key)`, `mouseButton`,
  `moveMouse`, `addScroll`; per-frame edges via `beginFrame()`
  (`pressed`/`released` live one frame). `clearEdges()` drops the edges but
  keeps held state (used after the first fixed step). Platform focus loss
  releases held keys/buttons and resets the cursor-delta origin. Invalid raw
  platform key codes are logged and ignored. `Key` names the GLFW key set;
  `Key` / `MouseButton` enums exported at root.
- `InputMap` (root export): `init(allocator)`, `bind(action, InputBinding)`,
  `isDown/justPressed/justReleased(input, action)`, `axis(input, negative,
  positive)`. `InputBinding` is `.key`, `.key_code` or `.mouse`. `Game.input_map`
  is a ready, empty map; `Game.deinit` frees it.
- `Platform.Window` vtable (`pollEvents`, `framebuffer_extent`,
  `requestClose`, `shouldClose`) and `Platform.Event` (including focus
  changes); GLFW adapter at `src/platform/glfw_window.zig`
  (`WindowAdapter.init(w, h, title)`).
- `Scene.Document`: `init/deinit`, `add(kind) !id`, `remove(id) bool`,
  `get(id) ?*Object`, `save(io, path)`, `load(io, path)`
  (`error.UnsupportedSceneVersion` unless `version == 1`).
- `SceneSpawn`: `SpawnTextures{ player, sprite }`,
  `spawnObject(world, object, textures) !?Entity`,
  `spawnDocument(world, doc, textures) !?Entity` (first `.sprite` or null).
  Base components only (Transform + SpriteRenderer + Collider2D, default
  5x1 animation on player); game markers (Collectible, scripts) stay in
  the caller. Invalid size/position → `error.InvalidSceneObject`, nothing spawned.
- `Script`: `init(game, &behavior)` / `initWithStart(game, &behavior)` for
  structs with `pub onUpdate(*T, *Ctx)` or the ctx-free
  `pub onUpdate(*T, *Game, f32)` (either may return `void` or `!void`; plus
  optional `pub onStart(*T, *Ctx)` / `pub onStart(*T, *Game)` via
  `initWithStart`, runs on the first executed frame — plain `init` silently
  ignores `onStart`); `register(&scheduler, name)`.
  `Script.Ctx{ world, game, dt, frame_allocator }` (`frame_allocator` is
  freed at the end of the frame).
- `Script.Mover2D{ entity: ?Entity = null, speed: f32 = 260 }`:
  `update(game: *Game, dt: f32) !Vec2` drives `Transform` with WASD + arrows,
  returns the normalized direction; null entity → `error.UnboundEntity`.
- `Renderer.Backend` vtable + `Renderer.Headless` test backend
  (`submitted_frames`, `submitted_items`).
- `Scene`, `Logging`, `Debug`, `Time` (Clock/FixedStepper), `GameLoop`,
  `Reclaimer`, `AllocatorTools` (FrameArena), `Handles`/`TextureHandle`, math
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

Version is `0.1.0`. Breaking changes after this release are recorded in
`CHANGELOG.md` under `Unreleased`.
