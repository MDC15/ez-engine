# Changelog

## Unreleased

### Added

- Zig-native scripting: `ez_engine.Script` (`onUpdate`, optional `onStart`
  via `initWithStart`, one-line `register`) plus built-in `Mover2D`.
- Desktop `App` helper (`ez_app` module): window + graphics + game + backend
  in `App.init`, `run`, `deinit`. The WGPU sample is gameplay-only.
- `ez new <name>` command (`./ez` script) wrapping `zig build new` with a
  standard project template (starter uses App + Script); the Python project
  tool is gone.
- Input ergonomics: `Key` now names the full GLFW key set (letters, digits,
  function keys, navigation, modifiers, keypad, punctuation) and `Input`
  gains `isDown` / `justPressed` / `justReleased`. New `InputMap` (root
  export) binds named actions and axes to keys, mouse buttons or raw codes;
  `Game.input_map` is a ready, empty map freed on `deinit`.
- Managed game loop: `GameLoop` (variable/fixed timestep via `FixedStepper`,
  `time_scale`, pause/`unpause`/stop, frame-time clamp) and `Game.tick`; `Game`
  gains split `update`/`present` (with `frame(dt)` unchanged).
- Automatic end-of-frame reclamation: `World.destroyDeferred`/`flushDeferred`,
  `Reclaimer` + per-frame `FrameArena` (`Game.frameAllocator`,
  `Script.Ctx.frame_allocator`), and `Input.clearEdges` so edge-triggered
  actions fire once per rendered frame under fixed timestep.
- Collision layers: `Collider2D.layer` / `collides_with` plus
  `Collision2D.layerBit(index)` say which entities hit which (both sides must
  agree); defaults keep the old "everything collides" behavior.
- `Physics2D`: `Velocity`, `RigidBody2D` (dynamic/kinematic/static,
  `gravity_scale`, `linear_damping`, `restitution`) and an integrator
  `System`; `Collision2D` now applies restitution and treats kinematic
  bodies as immovable.
- Ctx-free behaviors: `onUpdate(self, game, dt)` / `onStart(self, game)`
  alongside the existing `*Script.Ctx` form; the scaffold template wires
  physics + collision + camera, turns debug on, and uses the new form.

### Removed

- Deleted the desktop editor (`examples/editor/`, `docs/editor.md`,
  `zig build editor(editor-run)` steps, `zgui` dependency, `open` subcommand
  in `tools/ez_project.py`). Scene editing is done by hand in
  `Scenes/editor_scene.json` (`ez_engine.Scene` format).

- Removed the headless `sandbox` example and the `zig build example` step;
  the headless backend is still covered by `tests/backend_iface_test.zig`.

- Deleted the unused raw Vulkan wrapper (`src/gfx/vulkan/`, ~1900 lines).
  Samples render through `zgpu`, never through this module.
- Removed undrawn mesh/material code (`src/gfx/mesh.zig`,
  `src/gfx/material.zig`, `src/asset/mesh_loader.zig`,
  `src/asset/shader_loader.zig`, `MeshRenderer` component). The render path
  is now sprites-only. Also retired `BackendKind.vulkan`, `VulkanSurface`,
  the 3D `Camera` export and `Mesh/Material/Shader` handle aliases.
- Removed public aliases `AssetStore`, `AudioModule`, `InputModule`; use
  `Assets`, `Audio`, `Input` plus new `Key`/`MouseButton` exports.

### Changed

- Project template is organized Unity-style: `src/main.zig` only
  bootstraps (window → load `Scenes/editor_scene.json` → spawn entities
  → attach scripts → run), behaviors live one-per-file under
  `src/scripts/` (`player.zig`, `pickup.zig`), and object
  positions/sizes come from the scene JSON instead of hardcoded values.
- Source break: `Script.Mover2D.update` now takes `(game: *Game, dt: f32)`
  instead of a `*Script.Ctx`. The `Script.Ctx` behavior form still works;
  migrate `self.mover.update(ctx)` → `self.mover.update(game, dt)`.
- Renamed the package and module from `game_lib` to `ez_engine`
  (version `0.1.0-dev`, `src/root.zig: version`). Migration:
  `@import("game_lib")` → `@import("ez_engine")`.
- Internal imports are now namespaced (`ez_platform`, `ez_input`,
  `ez_zigimg`) to avoid collisions in consumers.
- Moved the WGPU sprite backend from `examples/wgpu_clear/main.zig` to
  `src/gfx/wgpu/backend.zig` (separate `wgpu_backend` module, Linux x86_64
  only; not exported from `ez_engine` root). The backend now owns pipeline
  creation via `SpriteBackend.init(allocator, graphics, assets)` /
  `deinit()`; the example is gameplay-only (~200 lines).
- Promoted the editor scene document from `examples/editor/scene.zig` to
  `src/scene/scene.zig`, exported as `ez_engine.Scene`. Scene JSON
  (`version: 1`) is unchanged and still loads.
- `Game` no longer carries the unused 3D `camera` field (kept `camera_2d`).
- Non-Linux/x86_64 builds now log a warning instead of silently skipping
  the desktop samples.
- `Input`'s inline tests now run under `zig build test`: the `ez_input`
  module gets its own test step, so its tests (and `InputMap`'s) are
  collected instead of silently skipped at the module boundary.
- `Mover2D` reads keys through the new `Input.isDown` helper (behavior
  unchanged).

### Added

- `zig build docs` emits API documentation.
- `tests/render_world_sprite_test.zig`: locks sprite extract/cull/batch order.
- `tests/backend_iface_test.zig`: locks one headless submit per frame.
