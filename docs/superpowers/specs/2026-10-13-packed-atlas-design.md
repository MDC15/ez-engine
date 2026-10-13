# Packed Atlas + Named Animation Clips — Design

## Intent and why

`ez_engine` sprites today only understand uniform grids (`SpriteSheet{ columns, rows }`,
frame by index). Real 2D art is packed: frames of different sizes laid out tightly by an
offline tool (Aseprite, TexturePacker), with named clips (`idle`, `walk`, `attack`) and
per-frame timing. Without atlas support, users must hand-cut uniform grids or hardcode
`source_rect` per entity — wasting texture memory and blocking artists.

This design adds offline-packed atlases and name-driven animation while keeping the
existing render path (extract → cull → batch by texture) untouched: an atlas is still
one texture, so batching behavior does not change.

## Goals

- Load a packed atlas (one texture + one JSON sidecar) through the existing asset
  manager (`loadTextureFile`-style path caching).
- Address any frame by **name** and get its UV rect; animation clips are ordered lists
  of named frames with per-frame durations and a loop flag.
- `SpriteAnimation` can play a named clip; the uniform-grid API keeps working unchanged
  (old components, samples, and template keep compiling and behaving identically).
- JSON validation mirrors `Scene` (`version` field, finite numbers, positive sizes):
  malformed files fail with named errors and spawn/load nothing partial.

## Non-goals

- No runtime packing algorithm. Atlases are packed offline; the engine only reads them.
- No editor UI and no new scene-object kinds for atlases in this project.
- No 3D, no mesh/material, no JPEG (separate P2 items).
- No change to batching, culling, camera, or backend code.

## Anti-goals

- A second, parallel animation system. Named clips must reuse `SpriteAnimation.update`
  and `SpriteRenderer.source_rect`, not fork them.
- An atlas format that only our own (nonexistent) packer can produce: the JSON must be
  hand-writable and documented field-by-field, so Aseprite/TexturePacker output can be
  converted with a trivial script (converter script itself is out of scope).

## Constraints

- Zig 0.16.0; `zig build`, `zig build test`, `zig fmt --check` stay green on Linux x86_64.
- Public API only via `src/root.zig`; breaking changes noted in `CHANGELOG.md`.
- ECS components stay plain data (byte-copied, no destructors).
- Audio/resampling, physics, and WGPU golden-image work are separate projects.

## Decided (how)

- **Format**: `Atlas` JSON document, `version: 1`, with `frames: [{ name, x, y, w, h }]`
  in pixels plus `clips: [{ name, frames: [frame_name...], fps, looping }]`.
  Pixel rects convert to normalized UV against the texture size at load time.
  Rationale: pixel ints are what packers emit; normalization is a pure function of
  texture dimensions, easy to test without GPU.
- **Types**: new `src/gfx/atlas.zig` with `Atlas` (owns names + UV rects + clips),
  `AtlasRegion{ uv: UVRect }` lookup by name (`error.UnknownAtlasFrame` otherwise).
  Stored in the asset manager behind a generational handle, path-cached exactly like
  textures (`texture_paths` pattern in `src/asset/manager.zig`).
- **Animation**: `SpriteAnimation` gains an atlas-clip mode alongside the existing
  grid `sheet`/`clip` fields; `update()` writes `sprite.source_rect` from the atlas
  frame when in that mode. Grid behavior byte-for-byte unchanged (existing tests must
  pass unmodified). Per-frame durations: each clip frame may carry its own duration
  in seconds; `fps` is the fallback when absent. (My call.)
- **Validation**: reject non-finite/negative rects, zero-size frames, duplicate frame
  names, clips referencing unknown frames, `fps <= 0`, empty clips, `version != 1`.
  Same error style as `Scene.load` (`UnsupportedAtlasVersion`, `InvalidAtlasRegion`,
  `UnknownAtlasFrame`, `InvalidAtlasClip`).
- **Docs**: `docs/api.md` Atlas section, `CHANGELOG.md` Unreleased/Added entry,
  format documented field-by-field so third-party packer output is convertible by hand.

## Left to the builder

- Exact struct field names and function signatures (propose in the plan).
- Whether `Atlas` owns its name strings via one arena allocation or per-string dupes.
- Test file layout (`tests/atlas_test.zig` vs inline tests) and sample art, if any.
- Whether the template/sample adopts atlas for the player sheet or stays grid-only.

## Builder-check resolutions (my calls)

- **Trimmed/rotated frames are out of scope (partner decision).** Target art is
  AI-generated (uniform frames, no packer metadata), so v1 accepts only plain
  rectangles. Files containing `rotated`/`trimmed` markers fail with named errors
  telling the user to re-export without them. Per-frame `offset: [2]f32`
  (default zero) compensates AI frame drift.
- **Atlas data reaches `update` via a manager-holding system, not via components.**
  `playAtlas(manager, atlas_handle, clip_name)` resolves the name eagerly and
  stores only plain data (atlas handle + clip/frame indices + elapsed); a system
  struct holding `*Manager` (scheduler context) advances atlas clips each frame.
  Grid `SpriteAnimation.update(sprite, dt)` is untouched; both paths share one
  frame-writing helper. Rationale: components stay destructor-free plain data and
  the system loop never fails on name lookup (errors surface at `play` time).
- **Load API**: `loadAtlasFile(io, json_path, texture_path, max_bytes) !AtlasHandle`,
  path-cached on `json_path`; the texture goes through the existing
  `loadTextureFile` cache (shared, independent lifetimes — releasing the atlas
  does not release the texture).
- **Per-frame durations**: `frames: [{ frame: string, duration_s?: f32 }]`; `fps`
  is the fallback when `duration_s` is absent. Non-finite/negative durations are
  `InvalidAtlasClip`.
- **Struct growth is non-breaking**: atlas-mode fields are additive with defaults,
  so existing `SpriteAnimation{...}` literals keep compiling; noted as additive
  (not breaking) in `CHANGELOG.md`.
