# Next work

## Renderer

- Support packed atlas regions and animation clips beyond uniform sprite grids.
- Add a reference-image or pixel-output check for the WGPU sample.
- Mesh/material/3D support is a future design decision, not a leftover:
  the render path is intentionally sprites-only (see CHANGELOG).

## Runtime

- Add a real audio-device backend (mixer exists, no device or resampling yet).
- Document and test ECS component lifetime rules before supporting components
  that own resources.

## Library hardening

- Add `LICENSE` and `CONTRIBUTING.md`; tag `0.1.0`.
- Add CI running `zig build`, `zig build test` and `zig fmt --check`.
- Build a scene→runtime pipeline so `editor_scene.json` can spawn entities.

Items are intentionally limited to work that extends the current framework;
there is no production release checklist yet.
