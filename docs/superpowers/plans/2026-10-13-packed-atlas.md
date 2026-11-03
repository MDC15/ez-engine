# Packed Atlas + Named Clips Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Load offline-packed atlases (texture + JSON) and play named clips with per-frame timing and draw offsets, reusing the existing sprite render path.

**Architecture:** New `src/gfx/atlas.zig` parses/validates atlas JSON into UV rects (top-left origin, like `SpriteSheet.frameUv`); the asset manager caches atlases path-keyed like textures; a manager-holding ECS system advances a plain-data `AtlasPlayer` component and writes `SpriteRenderer.source_rect` + a new additive `draw_offset`. Grid animation is untouched.

**Tech Stack:** Zig 0.16.0, `ez_engine` lib, `zig build test`.

**Spec:** `docs/superpowers/specs/2026-10-13-packed-atlas-design.md` (plus Builder-check resolutions at its end — they override the body where they differ).

## Global Constraints

- Zig 0.16.0 only; `zig build`, `zig build test`, `zig fmt --check src tests tools template examples build.zig build.zig.zon` stay green on Linux x86_64.
- Public API only via `src/root.zig`; note the addition in `CHANGELOG.md` under `Unreleased/Added` as additive (not breaking).
- ECS components stay plain data (byte-copied, alignment <= 16, no destructors).
- No change to batching, culling, camera, or backend code; `extract` gains one additive offset line only.
- No runtime packing, no editor UI, no rotated/trimmed support (reject with named errors).

## Review Focus

- Atlas JSON with a rect extending past texture dims must fail `InvalidAtlasRegion` with nothing cached — expect `expectError` + `getAtlas(handle)==null`-style check, never a clamped UV.
- File with `"rotated": true` or `"trimmed": true` must fail with a named error telling the user to re-export — expect `expectError`, never a silently wrong render.
- `playAtlas` with an unknown clip name must return the error before touching the entity — expect `expectError` + `world.has(entity, AtlasPlayer)==false`.
- Atlas released while an `AtlasPlayer` is live must not crash the system — expect system run leaves `source_rect` untouched and returns no error.
- `Atlas.load` with `texture_width == 0` must return an error, never divide by zero.

---

### Task 1: Atlas document (parse, validate, lookup)

**Files:**
- Create: `src/gfx/atlas.zig`
- Modify: `src/root.zig` (export `Atlas` + add `_ = @import("gfx/atlas.zig");` to test block)
- Test: inline in `src/gfx/atlas.zig` (runs under existing `library_tests`; no `build.zig` change)

**Interfaces:**
- Consumes: `RenderComponents.UVRect` (`src/gfx/render_components.zig:15-22`), `Vec2` (`src/math/vec2.zig`).
- Produces (exact names later tasks use verbatim):
  - `pub const AtlasHandle = Handle(enum { atlas })` in `src/core/handle.zig` (added this task)
  - `pub const Frame = struct { name: []const u8, uv: UVRect, offset: Vec2 }`
  - `pub const ClipFrame = struct { frame: []const u8, duration_s: ?f32 }`
  - `pub const Clip = struct { name: []const u8, frames: []ClipFrame, fps: f32, looping: bool }`
  - `pub const OwnedAtlas = struct { frames: []Frame, clips: []Clip, pub fn deinit(*OwnedAtlas, Allocator) void }` (single internal arena owns all names/slices)
  - `pub fn load(allocator: Allocator, json_bytes: []const u8, texture_width: u32, texture_height: u32) !OwnedAtlas`
  - `pub fn frameUv(atlas: *const OwnedAtlas, name: []const u8) error{UnknownAtlasFrame}!UVRect`
  - `pub fn findClip(atlas: *const OwnedAtlas, name: []const u8) ?*const Clip`
  - Errors: `UnsupportedAtlasVersion`, `InvalidAtlasRegion`, `UnknownAtlasFrame`, `InvalidAtlasClip`

- [ ] **Step 1: Write failing tests in `src/gfx/atlas.zig`**

```zig
test "atlas load resolves named frames to UV and rejects out-of-bounds rect" {
    const json =
        \\{"version":1,"frames":[{"name":"a","x":0,"y":0,"w":2,"h":2},{"name":"b","x":2,"y":0,"w":2,"h":2}],
        \\ "clips":[{"name":"ab","fps":8,"looping":true,"frames":[{"frame":"a"},{"frame":"b","duration_s":0.5}]}]}
    ;
    var owned = try Atlas.load(std.testing.allocator, json, 4, 2);
    defer owned.deinit(std.testing.allocator);
    const uv = try owned.frameUv("b");
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), uv.x, 1e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), uv.width, 1e-5);
    try std.testing.expectError(error.UnknownAtlasFrame, owned.frameUv("nope"));
    const bad_json =
        \\{"version":1,"frames":[{"name":"o","x":3,"y":0,"w":2,"h":2}],"clips":[]}
    ;
    try std.testing.expectError(error.InvalidAtlasRegion, Atlas.load(std.testing.allocator, bad_json, 4, 2));
}

test "atlas rejects rotated frames and zero texture size" {
    const rotated =
        \\{"version":1,"frames":[{"name":"r","x":0,"y":0,"w":2,"h":2,"rotated":true}],"clips":[]}
    ;
    try std.testing.expectError(error.InvalidAtlasRegion, Atlas.load(std.testing.allocator, rotated, 4, 2));
    const json =
        \\{"version":1,"frames":[{"name":"a","x":0,"y":0,"w":2,"h":2}],"clips":[]}
    ;
    try std.testing.expectError(error.InvalidAtlasRegion, Atlas.load(std.testing.allocator, json, 0, 2));
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -8`
Expected: FAIL — `atlas.zig` has no member / file not found (module does not exist yet).

- [ ] **Step 3: Implement `src/gfx/atlas.zig`**

JSON parse structs mirror the on-disk shape (`version`, `frames[{name,x,y,w,h,offset?,rotated?,trimmed?}]`, `clips[{name,fps,looping,frames[{frame,duration_s?}]}]`), strict (unknown fields error) except the two packer flags which are parsed then explicitly rejected. UV: `u = x/tex_w, v = y/tex_h` (top-left origin, same convention as `SpriteSheet.frameUv`). Validation order: version → dims nonzero → rects (finite, x/y >= 0, w/h > 0, inside dims, unique names) → clips (nonempty, fps > 0 finite, known frame refs, durations > 0 finite when present). `offset` defaults to `.{0,0}`. Add `AtlasHandle` to `src/core/handle.zig`, export `Atlas` (+`AtlasHandle`) in `src/root.zig`, register the module in its test block.

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: `33/33 steps succeeded` (test count grows by 2).

- [ ] **Step 5: Commit**

```bash
git add src/gfx/atlas.zig src/core/handle.zig src/root.zig
git commit -m "feat: add packed atlas document with validation"
```

### Task 2: Asset-manager integration + fixtures

**Files:**
- Modify: `src/asset/manager.zig` (atlas store + paths + load/release)
- Modify: `src/root.zig` (export `AtlasHandle` if not already visible via `Handles`)
- Modify: `build.zig` (add `"atlas_manager_test.zig"` to the inline test list)
- Create: `tests/atlas_manager_test.zig`
- Create: `assets/atlas_test.ztex`, `assets/atlas_test.json` (fixtures)

**Interfaces:**
- Consumes: Task 1 `Atlas.load`, `OwnedAtlas`; `Manager.loadTextureFile/loadFile` (`src/asset/manager.zig:111-168`); existing `Store`/`releaseTextureData` pattern.
- Produces:
  - `pub fn loadAtlasFile(self: *Manager, io: std.Io, json_path: []const u8, texture_path: []const u8, max_bytes: usize) !AtlasHandle` (path-cached on `json_path`; texture via existing `loadTextureFile` cache; releasing the atlas never releases the texture)
  - `pub fn getAtlas(self: *Manager, handle: AtlasHandle) ?*AtlasEntry`
  - `pub fn releaseAtlas(self: *Manager, handle: AtlasHandle) !void`
  - `pub const AtlasEntry = struct { texture: TextureHandle, atlas: OwnedAtlas }` (the stored slot value; Task 3 reads `entry.texture` for dims and `entry.atlas` for clips)

- [ ] **Step 1: Create fixtures + write failing test**

Create a 4x2 RGBA ZTEX fixture with the left half red and right half green;
use the format specified in `docs/architecture.md`.
`assets/atlas_test.json` (Task 1 shape; frames `a` at x=0 and `b` at x=2, clip `ab`):
```zig
test "manager caches atlas by json path and keeps texture independent" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var manager = ez.Assets.init(std.testing.allocator);
    defer manager.deinit();
    const h1 = try manager.loadAtlasFile(io, "assets/atlas_test.json", "assets/atlas_test.ztex", 1024 * 1024);
    const h2 = try manager.loadAtlasFile(io, "assets/atlas_test.json", "assets/atlas_test.ztex", 1024 * 1024);
    try std.testing.expectEqual(h1.index, h2.index);
    try std.testing.expect(manager.getAtlas(h1) != null);
    try manager.releaseAtlas(h1);
    try std.testing.expect(manager.getAtlas(h1) == null);
    const tex = try manager.loadTextureFile(io, "assets/atlas_test.ztex", 1024 * 1024);
    try std.testing.expect(manager.getTexture(tex) != null);
}
```
(`std.Io.Threaded.init(allocator, .{})` gives tests a real `Io`; no existing test constructs one, so if the `deinit` name/signature differs the compiler says so — adjust to what it says.)

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -8`
Expected: FAIL — `loadAtlasFile` undefined (manager has no such member).

- [ ] **Step 3: Implement manager atlas store**

Mirror `textures`/`texture_paths` with `atlases: Store(OwnedAtlas, AtlasHandle, releaseAtlasData)` + `atlas_paths`. `loadAtlasFile`: return cached handle on `json_path` hit (else `error.AssetCacheCorrupt` if slot dead, same as textures); otherwise load texture file first (dims for UV), read JSON via `loadFile`, `Atlas.load`, insert, cache path. `releaseAtlas` mirrors `releaseTexture` but never touches the texture store.

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: all steps green.

- [ ] **Step 5: Commit**

```bash
git add src/asset/manager.zig src/root.zig build.zig tests/atlas_manager_test.zig assets/atlas_test.ztex assets/atlas_test.json
git commit -m "feat: cache packed atlases in the asset manager"
```

### Task 3: Named-clip playback (AtlasPlayer + system + draw offset)

**Files:**
- Modify: `src/gfx/render_components.zig` (add `AtlasPlayer`, add `draw_offset` to `SpriteRenderer`)
- Modify: `src/gfx/render_world.zig:76-91` (`extract`: `position = Transform.position + draw_offset`)
- Modify: `src/gfx/atlas.zig` (add `playAtlas`, `AtlasSystem`)
- Modify: `src/root.zig` (export new names)
- Modify: `build.zig` (add `"atlas_playback_test.zig"`)
- Create: `tests/atlas_playback_test.zig`
- Docs: `docs/api.md` (Atlas bullets), `CHANGELOG.md` (Unreleased/Added)

**Interfaces:**
- Consumes: Tasks 1–2 (`AtlasHandle`, `findClip`, `Manager.getAtlas/loadAtlasFile`); `World.add/get/query`, `Scheduler.addSystem` (existing patterns).
- Produces:
  - `RenderComponents.AtlasPlayer = struct { atlas: AtlasHandle, clip_index: u32, frame_index: u16 = 0, elapsed_seconds: f32 = 0, playing: bool = true }`
  - `SpriteRenderer.draw_offset: Vec2 = .zero`
  - `pub fn playAtlas(manager: *Manager, world: *World, entity: Entity, atlas: AtlasHandle, clip_name: []const u8) !void` (resolves the clip eagerly; returns `UnknownAtlasFrame`-family error before modifying the entity when the name is unknown or the atlas handle is stale)
  - `pub const AtlasSystem = struct { manager: *Manager, pub fn init(manager: *Manager) AtlasSystem, pub fn update(self: *AtlasSystem, world: *World, dt: f32) !void, pub fn updateSystem(ctx: ?*anyopaque, world: *World, dt: f32) anyerror!void }` (scheduler-ready wrapper around `update`, same pattern as `Collision2D.System`; advances frames with `duration_s ?? 1/fps`; looping wraps, non-looping stops on last frame with `playing=false`, mirroring grid semantics; stale atlas handle leaves the sprite untouched without error; writes `source_rect` + `draw_offset` where `draw_offset = (frame.offset_px / tex_dims) * sprite.size`)

- [ ] **Step 1: Write failing test `tests/atlas_playback_test.zig`**

```zig
test "atlas clip advances named frames and applies draw offset" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var game = try ez.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    const h = try game.assets.loadAtlasFile(io, "assets/atlas_test.json", "assets/atlas_test.ztex", 1024 * 1024);
    const tex = try game.assets.loadTextureFile(io, "assets/atlas_test.ztex", 1024 * 1024);
    const e = try game.world.create();
    try game.world.add(e, ez.RenderComponents.Transform{});
    try game.world.add(e, ez.RenderComponents.SpriteRenderer{ .texture = tex, .size = .{ .x = 64, .y = 64 } });
    try ez.Atlas.playAtlas(&game.assets, &game.world, e, h, "ab");
    var system = ez.Atlas.AtlasSystem.init(&game.assets);
    try system.update(&game.world, 1.0 / 8.0);
    const sprite = try game.world.get(e, ez.RenderComponents.SpriteRenderer);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sprite.source_rect.x, 1e-5);
}
test "playAtlas with unknown clip leaves the entity untouched" {
    // (same Game/assets setup; works with stale handle too)
    // try std.testing.expectError(error.UnknownAtlasFrame, ez.Atlas.playAtlas(&game.assets, &game.world, e, h, "nope"));
    // try std.testing.expect(!game.world.has(e, ez.RenderComponents.AtlasPlayer));
}
test "system with released atlas leaves the sprite untouched" {
    // play clip "ab", snapshot source_rect, releaseAtlas(h), run system with dt>0:
    // expect no error and source_rect unchanged.
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -8`
Expected: FAIL — `AtlasPlayer` / `playAtlas` undefined.

- [ ] **Step 3: Implement component, system, and extract offset**

Additive only: `AtlasPlayer` struct + `draw_offset` field (defaults keep every existing literal compiling); one line in `extract` adding the offset to position; `playAtlas` + `AtlasSystem` in `src/gfx/atlas.zig` (imports `Manager`, `World`, `Entity`, components — same-module compilation as the rest of `ez_engine`, not the standalone scene-test pattern). Atlas texture dims for the offset formula come from `manager.getTexture(atlas.texture).?` — the handle is stored alongside the atlas in the manager slot (define `AtlasEntry = struct { texture: TextureHandle, atlas: OwnedAtlas }` as the stored value type). Wire exports + test file.

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: all steps green, including all pre-existing grid-animation tests unmodified.

- [ ] **Step 5: Document + commit**

Add `docs/api.md` Atlas bullets + `CHANGELOG.md` entry.
```bash
git add src/gfx/render_components.zig src/gfx/render_world.zig src/gfx/atlas.zig src/root.zig build.zig tests/atlas_playback_test.zig docs/api.md CHANGELOG.md
git commit -m "feat: play named atlas clips with per-frame offsets"
```
