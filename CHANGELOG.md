# Changelog

## Unreleased

### Removed

- Deleted the unused raw Vulkan wrapper (`src/gfx/vulkan/`, ~1900 lines).
  Samples render through `zgpu`, never through this module.
- Removed undrawn mesh/material code (`src/gfx/mesh.zig`,
  `src/gfx/material.zig`, `src/asset/mesh_loader.zig`,
  `src/asset/shader_loader.zig`, `MeshRenderer` component). The render path
  is now sprites-only.
- Removed unused public aliases `AssetStore`, `AudioModule`
  (`MeshHandle`, `MaterialHandle`, `ShaderHandle` retired with the code above).

### Changed

- Renamed the package and module from `game_lib` to `ez_engine`
  (version `0.1.0-dev`, `src/root.zig: version`). Migration:
  `@import("game_lib")` → `@import("ez_engine")`.
- Internal imports are now namespaced (`ez_platform`, `ez_input`,
  `ez_zigimg`) to avoid collisions in consumers.
- Moved the WGPU sprite backend from `examples/wgpu_clear/main.zig` to
  `src/gfx/wgpu/backend.zig` (separate `wgpu_backend` module, Linux x86_64
  only; not exported from `ez_engine` root).
- Promoted the editor scene document from `examples/editor/scene.zig` to
  `src/scene/scene.zig`, exported as `ez_engine.Scene`. Scene JSON
  (`version: 1`) is unchanged and still loads.
- `Game` no longer carries the unused 3D `camera` field (kept `camera_2d`).
- Non-Linux/x86_64 builds now log a warning instead of silently skipping
  the desktop samples.

### Added

- `zig build docs` emits API documentation.
- `tests/render_world_sprite_test.zig`: locks sprite extract/cull/batch order.
- `tests/backend_iface_test.zig`: locks one headless submit per frame.
