# Bitmap Text Rendering Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render UTF-8 text (HUD, menus, dialogue) as ordinary sprites through the untouched extract → cull → batch path, from versioned bitmap-font JSON + texture.

**Architecture:** New `src/gfx/font.zig` parses/validates font JSON into glyph UVs (arena-owned, atlas pattern); the asset manager caches fonts path-keyed with texture-independent lifetimes; a manager-holding `TextSystem` reconciles per-entity glyph child entities and re-syncs their `Transform`s from the parent every frame. Grid/atlas animation untouched.

**Tech Stack:** Zig 0.16.0, `ez_engine` lib, `zig build test`.

**Spec:** `docs/superpowers/specs/2026-10-13-text-rendering-design.md` (including Builder-check resolutions — they override the body where they differ).

## Global Constraints

- Zig 0.16.0 only; `zig build`, `zig build test`, `zig fmt --check src tests tools template examples build.zig build.zig.zon` stay green on Linux x86_64.
- New tests live INLINE in `src/` files (run in the `library_tests` binary — standalone `tests/` files linking new modules risk the known toolchain segfault; `font.zig`/`text` code paths are std-only plus already-linked modules).
- Public API only via `src/root.zig`; CHANGELOG entry under Unreleased as additive.
- Components stay plain data (byte-copied, alignment <= 16, no destructors).
- No change to batching, culling, camera, backends, or `extract`; no `Game`/`App` changes.

## Review Focus

- Invalid UTF-8 bytes in content must render the fallback glyph and continue layout — expect the invalid byte to occupy exactly one fallback advance, never an error or a gap.
- A codepoint missing from the font (with no `?`/FFFD/space present) must skip the quad but still advance — expect child count and next-glyph x to prove it.
- Destroyed parent must leave zero orphan glyphs and the next update must not crash — expect `aliveCount` delta and a clean second update.
- Stale font handle must leave existing glyphs untouched without error — expect `source_rect` unchanged and no error from `update`.
- `setText` past 256 bytes must return `TextTooLong` with old content preserved — expect error plus unchanged `len`/bytes.

---

### Task 1: Font document (parse, validate, lookup, fallback)

**Files:**
- Create: `src/gfx/font.zig`
- Modify: `src/core/handle.zig` (add `AtlasHandle`-style `FontHandle`), `src/root.zig` (export `Font` + test-block import)
- Test: inline in `src/gfx/font.zig`

**Interfaces:**
- Consumes: `UVRect` (`render_components.zig`), `Vec2`; `std.unicode.Utf8View`/`Utf8Iterator.nextCodepoint` for later tasks (not this one).
- Produces (exact names later tasks use verbatim):
  - `pub const FontHandle = Handle(enum { font })` in `src/core/handle.zig`
  - `pub const Glyph = struct { codepoint: u21, uv: UVRect, offset: Vec2, advance: f32 }`
  - `pub const OwnedFont = struct { size_px: f32, line_height_px: f32, glyphs: []Glyph, arena, pub fn deinit(*OwnedFont, Allocator) void, pub fn glyph(self: *const OwnedFont, cp: u21) ?*const Glyph, pub fn fallback(self: *const OwnedFont, cp: u21, size: f32) Fallback }` where `Fallback = union(enum) { skip: f32, glyph: *const Glyph }` implementing the chain U+FFFD → `?` → space advance → skip-with-`size*0.5`
  - `pub fn load(allocator, json_bytes, texture_width, texture_height) !OwnedFont`
  - Errors: `UnsupportedFontVersion`, `InvalidFontGlyph`, `UnknownFontGlyph` (reserved for direct lookup use; layout prefers `fallback`)

- [ ] **Step 1: Write failing tests in `src/gfx/font.zig`**

```zig
test "font load resolves glyphs and validates rects" {
    const json =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[
        \\ {"ch":"A","x":0,"y":0,"w":4,"h":6,"advance":5},
        \\ {"ch":"B","x":4,"y":0,"w":4,"h":6,"advance":5,"offset":[1,0]},
        \\ {"ch":" ","x":0,"y":0,"w":0,"h":0,"advance":3},
        \\ {"ch":"?","x":0,"y":6,"w":2,"h":2,"advance":3}]}
    ;
    var owned = try load(std.testing.allocator, json, 8, 8);
    defer owned.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), (owned.glyph('B').?).uv.x, 1e-5);
    try std.testing.expectEqual(@as(usize, 4), owned.glyphs.len);
    const bad =
        \\{"version":1,"size_px":8,"line_height_px":10,"glyphs":[{"ch":"A","x":7,"y":0,"w":4,"h":6,"advance":5}]}
    ;
    try std.testing.expectError(error.InvalidFontGlyph, load(std.testing.allocator, bad, 8, 8));
}

test "fallback chain degrades without breaking" {
    // font with only 'A': fallback('A') → glyph; fallback('Z') → skip with advance size*0.5
    // font with '?' added: fallback('Z') → glyph '?'
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -8`
Expected: FAIL — `font.zig` has no member `load` / undeclared identifiers (wire `_ = @import("gfx/font.zig");` into the `src/root.zig` test block first so the tests execute, plus the `pub const Font` export).

- [ ] **Step 3: Implement `src/gfx/font.zig`**

JSON shape `version/size_px/line_height_px/glyphs[{ch,x,y,w,h,advance,offset?}]`, strict parse (unknown fields error). `ch` must decode to exactly one codepoint (`std.unicode.utf8DecodeSequence` length check); numeric validation mirrors atlas (finite, x/y >= 0, inside dims, unique codepoints, advance > 0 finite); zero-size rect allowed IFF codepoint is U+0020 (space), else `InvalidFontGlyph`; `version != 1` → `UnsupportedFontVersion`; `size_px/line_height_px` > 0 finite else `InvalidFontGlyph`. UV top-left origin, same formula as atlas. Arena owns names/slices; no `parsed.deinit()` (arena takes ownership, atlas pattern).

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: all steps green.

- [ ] **Step 5: Commit**

```bash
git add src/gfx/font.zig src/core/handle.zig src/root.zig
git commit -m "feat: add bitmap font document with validation"
```

### Task 2: Asset-manager integration + fixtures

**Files:**
- Modify: `src/asset/manager.zig` (`FontEntry`, `font_paths`, `loadFontFile`/`getFont`/`releaseFont`)
- Create: `tests/fixtures/font_test.ztex`, `tests/fixtures/font_test.json` (NOT `assets/` — fixtures must not ship in scaffolded games)
- Test: inline in `src/asset/manager.zig` (Threaded-io pattern from the atlas manager test)

**Interfaces:**
- Consumes: Task 1 (`OwnedFont`, `FontHandle`); `Store`/`texture_paths` mirror (`src/asset/manager.zig`).
- Produces:
  - `pub const FontEntry = struct { texture: TextureHandle, font: OwnedFont }`
  - `pub fn loadFontFile(self: *Manager, io: std.Io, json_path: []const u8, texture_path: []const u8, max_bytes: usize) !FontHandle` (cached on `json_path`; texture via shared cache; release never releases the texture)
  - `pub fn getFont(self: *Manager, handle: FontHandle) ?*FontEntry`
  - `pub fn releaseFont(self: *Manager, handle: FontHandle) !void`

- [ ] **Step 1: Create fixtures + write failing inline test**

Create an 8x8 ZTEX fixture and `font_test.json` with glyphs `A` (0,0,4x6 adv 5), `B` (4,0,4x6 adv 5), ` ` (0,0,0x0 adv 3), `?` (0,6,2x2 adv 3), `size_px: 8`, `line_height_px: 10`.
```zig
test "manager caches fonts by json path and keeps texture independent" {
    // Threaded init + Manager.init (atlas-test pattern):
    // loadFontFile twice → same index; getFont != null;
    // releaseFont → getFont == null; texture from loadTextureFile still live.
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -6`
Expected: FAIL — `loadFontFile` undefined on `Manager`.

- [ ] **Step 3: Implement manager font store**

Mirror `atlases`/`atlas_paths` exactly (including `AssetCacheCorrupt` on dead-slot hit and path-key removal on release).

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: all steps green.

- [ ] **Step 5: Commit**

```bash
git add src/asset/manager.zig tests/fixtures/font_test.ztex tests/fixtures/font_test.json
git commit -m "feat: cache bitmap fonts in the asset manager"
```

### Task 3: Text component + layout + TextSystem + docs

**Files:**
- Modify: `src/gfx/render_components.zig` (add `Text`, `GlyphOf`), `src/gfx/font.zig` (add `layout`, `TextSystem`), `src/root.zig` (nothing new — `Font` module export already covers it), `docs/api.md`, `CHANGELOG.md`
- Test: inline in `src/gfx/font.zig`

**Interfaces:**
- Consumes: Tasks 1–2 (`OwnedFont.fallback/glyph`, `Manager.getFont/loadFontFile`, `FontHandle`); `World.create/destroy/add/get/query/destroyDeferred/flushDeferred/isAlive`, `Transform`, `SpriteRenderer`, `Quat.rotate(Vec3)` for TRS composition.
- Produces:
  - `RenderComponents.Text = struct { font: FontHandle, content: [256]u8 = zeros, len: usize = 0, size: f32 = 16, tint: Vec4 = .one, z_index: i32 = 0, align: Align = .left, pub fn setText(*Text, []const u8) error{TextTooLong}!void }` (`Align = enum { left, center, right }`; error before mutating on overflow)
  - `RenderComponents.GlyphOf = struct { parent: Entity }` (marker; games exclude it from gameplay queries)
  - `pub fn layout(allocator, font: *const OwnedFont, text: []const u8, size: f32, align: Align) ![ ]PlacedGlyph` with `PlacedGlyph = struct { uv: UVRect, quad_w: f32, quad_h: f32, pen_x: f32, pen_y: f32 }` in WORLD units relative to parent origin (scale = size/size_px; pen advances `advance*scale`; newline → `pen_y -= line_height*scale`; center/right shift against longest-line advance; UTF-8 via `Utf8View.initUnchecked` + null codepoint → fallback; per-glyph quad from rect×scale, `draw_offset`-style drift folded into pen via `(offset_px/tex_dims)*quad` — needs tex dims: pass `tex_w: f32, tex_h: f32` params from the manager entry)
  - `pub const TextSystem = struct { manager: *Manager, entries: std.AutoHashMapUnmanaged(u64, Entry), pub fn init/deinit, pub fn update(self, world, dt) !void, pub fn updateSystem(ctx, world, dt) anyerror!void }` with `Entry = struct { children: std.ArrayListUnmanaged(Entity), hash: u64 }` keyed by `(@as(u64, id) << 32) | generation` (respawn-all on content/font/size/z change; per-frame TRS re-sync of every glyph `Transform` = parent pos + `rotation*(pen*parent_scale)`, glyph rotation = parent rotation, glyph size from layout; orphans destroyed via `destroyDeferred` + end-of-update `flushDeferred`; stale font → untouched, no error; invalid size (non-finite/<=0) → untouched, no error; `dt` unused except signature)

- [ ] **Step 1: Write failing tests in `src/gfx/font.zig`**

```zig
test "text layout places glyphs with advances and newlines" {
    // load font_test.json equivalent inline (Task 1 shape, glyphs A/B/space/?):
    // layout("AB", size 16, left) → 2 placements; second pen_x ≈ 10 (advance 5 × scale 2);
    // layout("A\nB") → second pen_y ≈ -20 (line 10 × scale 2); center align shifts by -longest/2.
}
test "system spawns glyphs, follows the parent, and cleans orphans" {
    // Manager + World + font fixture; entity with Transform{(10, 20)} + Text("AB");
    // update → 2 children with SpriteRenderer (font texture, uv of A then B);
    // move parent to (30, 20) → update → children shifted +20 x;
    // world.destroy(parent) → update → children gone (aliveCount back), no error.
}
test "unknown and invalid bytes fall back without breaking layout" {
    // content "A\xFFZ" (fixture HAS '?' so Z→'?' glyph; 0xFF → fallback advance; assert 3 children and third pen_x == first + 2 advances).
    // setText over 256 bytes → TextTooLong with len unchanged.
    // minimal inline font with only 'A' (Task-1 JSON shape, no '?'/space): layout("AZ") → 1 placement (A) and total advance == A.advance + size*0.5, proving the skip path.
}
test "stale font handle leaves glyphs untouched" {
    // play text, releaseFont, update(dt>0) → source_rect unchanged, no error.
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -6`
Expected: FAIL — `Text` / `layout` / `TextSystem` undefined.

- [ ] **Step 3a: Implement `Text`/`GlyphOf` + `layout` in `render_components.zig` / `src/gfx/font.zig`**

Component structs verbatim from Interfaces (`FontHandle` import is handle-only, no cycle). `layout` per Interfaces; UTF-8 via `Utf8View.initUnchecked` + null codepoint → `fallback`. Run: layout-only test must pass; system tests still fail (undefined `TextSystem`).

- [ ] **Step 3b: Implement `TextSystem` in `src/gfx/font.zig`**

Per Interfaces (change hash `std.hash.Wyhash` over content bytes + font index/generation + size/z bits; `destroyDeferred` + end-of-update `flushDeferred`). Run full suite green per Step 4.

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: all steps green, all pre-existing tests unmodified and passing.

- [ ] **Step 5: Document + commit**

`docs/api.md` Font/Text bullets + recipe; `CHANGELOG.md` Unreleased/Added entry.
```bash
git add src/gfx/render_components.zig src/gfx/font.zig tests/fixtures/font_test.* docs/api.md CHANGELOG.md
git commit -m "feat: render UTF-8 text as sprites via TextSystem"
```
