# Text Rendering (Bitmap Font) — Design

## Intent and why

Games need text: HUD scores, menu labels, dialogues. `ez_engine` renders
nothing but textured quads today, so any text must become sprites. A
TrueType rasterizer (stb_truetype port, new dependency, hinting complexity)
is overkill for a 2D sprite engine; AI/tool-generated bitmap fonts plus a
tiny layout engine cover menus, HUD, and dialogue — the actual need.

## Goals

- Load a bitmap font (one texture + one JSON sidecar, same duo pattern as
  atlas/scene) through the asset manager with path caching.
- ASCII printable + Vietnamese UTF-8: layout decodes UTF-8 codepoints;
  invalid sequences render the replacement glyph (never crash, never skip
  silently leaving layout broken — missing glyph also falls back to `?`).
- `Text` component + system turns a string into positioned glyph quads that
  flow through the EXISTING extract → cull → batch path untouched.
- Alignment left/center/right, newline support, integer-or-float scale,
  per-text tint. Line height from font metrics.

## Non-goals

- No TTF/OTF parsing or runtime rasterization, no SDF/MSDF (would need
  shader changes in both backends), no shaping (Arabic/Indic), no
  word-wrap (caller inserts `\n`; wrapping policy is game-specific),
  no text input/IME caret.
- No GUI widgets in this project (buttons/panels come next, on top of text).

## Anti-goals

- A second render path for glyphs. Glyphs must be ordinary sprites
  (batching by texture keeps working, including shared font atlas).
- Heap-owning components. Text content lives in a bounded inline buffer
  (plain data, ECS-safe); longer strings are the caller's to split.

## Constraints

- Zig 0.16.0; `zig build`, `zig build test`, `zig fmt --check` stay green.
- Public API only via `src/root.zig`; CHANGELOG entry under Unreleased.
- Components stay plain data (byte-copied, no destructors).
- Tests run headless: layout math tested without GPU; no font files needed
  beyond small committed fixtures (hand-written JSON + tiny ZTEX).

## Decided (how)

- **Format**: `Font` JSON `version: 1`: `{ size_px, line_height_px,
  glyphs: [{ ch: "A", x, y, w, h, advance, offset: [ox, oy] }] }`.
  `ch` is a single UTF-8 character string (1–4 bytes); `advance`/`offset`
  in pixels. Validation mirrors atlas/scene style (version, finite,
  inside texture, unique codepoints, positive advance). Rejected: empty
  `ch`, multi-codepoint strings, out-of-bounds rects.
- **Types**: `src/gfx/font.zig` with `FontHandle` (new `Handle(enum{font})`
  in `core/handle.zig`), `OwnedFont` (arena-owned, like `OwnedAtlas`),
  `load(allocator, json, tex_w, tex_h)`, `glyph(codepoint u21) ?*Glyph`.
  Manager gains `loadFontFile/getFont/releaseFont` + `font_paths`,
  mirroring textures/atlases texture-independently.
- **Text component**: `RenderComponents.Text{ font: FontHandle,
  content: [256]u8 = zeroes, len: usize = 0, size: f32 = 16,
  tint: Vec4 = .one, align: Align = .left }` with
  `setText(*Text, []const u8) !void` (`error.TextTooLong` past 256 bytes;
  byte length, not glyph count). Newline `\n` starts a new line.
- **Glyph entities**: `TextSystem{ manager }` (scheduler context, like
  `AtlasSystem`) keeps per-entity glyph children: on content/font/size
  change it reconciles N child entities each carrying `Transform` (pen
  position + frame offset) + `SpriteRenderer` (font texture, per-glyph
  `source_rect`, tint, same `z_index` as parent... plus small epsilon per
  glyph? No — same z, order by creation `order` field keeps sequence
  within one batch since texture+z equal). Children are hidden
  implementation detail: tagged with a `GlyphOf{ parent: Entity }` marker
  component so games can ignore them in queries (documented).
- **Layout math (pure, headless-tested)**: `layoutLine`-style function
  mapping (font, bytes, size, align, max_width?) → pen positions; UTF-8
  decode via `std.unicode.Utf8View`; scale = size/size_px; pen advances by
  `advance * scale`; newline resets pen; align shifts whole lines.
- **Docs**: `docs/api.md` Font/Text bullets + recipe (load font, attach
  Text, register system), CHANGELOG entry, fixture format documented
  field-by-field so BMFont-style tools can target it by hand.

## Left to the builder

- Fixture font contents (which glyphs the test font must contain).
- `GlyphOf` marker exact shape (propose in plan).

## Builder-check resolutions (my calls)

- **Q1 — glyphs re-sync from the parent every frame (full TRS).** No
  one-time layout: `TextSystem` recomputes each glyph `Transform` per
  update from parent position + rotation/scale-composed pen offsets, so
  moving the parent moves the text. Cost: O(glyphs) math per frame, no
  allocations (respawn only on content/font/size change).
- **Q2 — mirror atlas exactly.** `loadFontFile(io, json_path, texture_path,
  max_bytes)`, `FontEntry{ texture, font }`, cached on `json_path`,
  `releaseFont` never releases the texture.
- **Q3 — `Text` carries `z_index`; glyphs inherit it.** Same z + same font
  texture batch together; within-text order is deterministic because
  respawn-all creates glyphs in content order and `RenderItem.order`
  follows creation sequence. A `Text` entity needs no `SpriteRenderer`.
- **Q4 — layout frame.** Pen origin = parent position (first-line baseline);
  lines advance `-line_height * scale` in y (world up = +y); center/right
  align against the longest line; `size` scales as `size/size_px`;
  per-glyph quad size = rect size × scale; world offset =
  `(offset_px / tex_dims) × quad size` (same formula as atlas drift).
  Space (U+0020) MAY have a zero-size rect with `advance > 0` — explicit
  exception to the positive-size rule.
- **Q5 — system-owned child table, safe cleanup.** `TextSystem` owns a
  hash map (precedent: `Collision2D.System` buffers) of
  `Entity → { children, content hash, font, size }`; respawn-all on change;
  parent dead (`!isAlive`) or entity reused → destroy children via
  `destroyDeferred` + `flushDeferred` at end of update; stale font handle
  leaves existing glyphs untouched (mirror `AtlasSystem`).
- **Q6 — no required glyphs; fallback chain.** Missing/invalid → U+FFFD if
  present, else `?` if present, else space advance, else skip with advance
  `size * 0.5`. AI-made fonts stay loadable; layout never breaks.
