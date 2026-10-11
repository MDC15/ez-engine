# OpenGL Sprite Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a desktop OpenGL 3.3 core sprite backend to `ez_engine` that renders the 2D sprite sample on the real GPU (Mesa d3d12 / NVIDIA RTX 3060 in WSL), alongside the existing WGPU backend.

**Architecture:** A standalone `gl_backend` module (`src/gfx/gl/backend.zig`) implements the existing `Renderer.Backend` vtable exactly like `src/gfx/wgpu/backend.zig` does, drawing GL-compatible vertices with the identical quad/UV/tint generation and batch iteration. A new `gl_app` module (`src/app/gl_desktop.zig`) mirrors `ez_app` but requests an OpenGL context from the shared `WindowAdapter`. A new `examples/gl` sample runs it.

**Tech Stack:** Zig 0.16.0, GLFW (`zglfw`), system OpenGL 3.3 core via `@cImport` of `GL/glcorearb.h` + `libGL`, Mesa d3d12 on WSL2.

**Spec:** `docs/superpowers/specs/2026-10-10-opengl-backend-design.md`

## Global Constraints

- Zig `0.16.0`; desktop features gated exactly like the wgpu sample: `target.result.os.tag == .linux and target.result.cpu.arch == .x86_64` (already the `desktop_supported` gate in `build.zig`).
- Executables use `use_llvm = true` (required for `@cImport`), mirroring the wgpu executable.
- GL **3.3 core** only — no compute, instancing, MSAA, FBOs, or GLES. One sampler (nearest), one pipeline.
- GL functions load via `@cImport` of the system `GL/glcorearb.h`; the executable links `libGL` (and `libX11`, mirroring the wgpu sample). No new dependency (no GLAD/GLEW/`zgl`).
- No runtime backend switching: choosing WGPU vs GL is which app module/sample you build. No renderer-selection code.
- Window stays fixed-size: all call sites pass `resizable = false`.
- The D3D12 adapter is selected by **environment variables only** (`GALLIUM_DRIVER=d3d12`, `MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA`) — never hardcoded. A startup diagnostic (D9) must log `GL_RENDERER` and warn if it is `llvmpipe`.
- Engine library stays backend-agnostic: nothing GL-related is exported from `src/root.zig`; `gl_backend` / `gl_app` are desktop modules like `wgpu_backend` / `ez_app`.
- Pinned values (copy verbatim): clear color `(0.035, 0.055, 0.09, 1.0)`; blend `glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)`; texture cache key `(generation << 32) | index`; eviction per wgpu backend; texture upload raw `GL_RGBA8`/`glTexImage2D` (no sRGB decode); vertex capacity starts `4096`, grows by power of two; swap happens at the end of `renderImpl`.
- On this machine, run builds with the local cache env set first: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local"`.

## Review Focus

Inputs or failure modes the spec implies, most likely to bite first:

1. **Missing d3d12 env vars** — the sample silently falls back to `llvmpipe` CPU with no visible failure. Expected: the D9 startup log prints a prominent warning naming both env vars. → Task 2 run step (no-env run must show the warning).
2. **Vertical orientation** — GL's texture row convention vs WGPU's top-left UV origin; a flipped sprite is an explicit release-blocker bug. Expected: player renders not upside down. → Task 2 run step (visual check, then Task 3 gameplay run re-checks).
3. **`bgra8` texture source** — the format switch must map both `rgba8 → GL_RGBA` and `bgra8 → GL_BGRA`, or byte-swapped textures break. → Task 2 code step (both arms present) + compile gate.
4. **Texture handle released mid-run** — eviction must run before draw (retire GL textures whose asset handle is gone) and a batch referencing a gone handle must not crash. Expected: rending continues; no error surfacing from `ensureTexture`. → Task 2 code step (1:1 port of the wgpu `evictReleasedTextures`).
5. **Zero extent** — `renderImpl` must skip when extent is 0 (window not yet visible) with no GL calls. Expected: no crash, no clear/draw. → Task 2 code step (guard ported from wgpu).

---

### Task 1: `WindowAdapter.initOpenGL`

**Files:**
- Modify: `src/platform/glfw_window.zig`

**Interfaces:**
- Consumes: `zglfw` (window hints `client_api`, `context_version_*`, `opengl_profile`, `opengl_forward_compat`; `makeContextCurrent`).
- Produces: `pub fn initOpenGL(width: u32, height: u32, title: [:0]const u8, resizable: bool) !WindowAdapter` — same return/`deinit`/callbacks as `init`, but the window is created with `client_api = .opengl`, core 3.3, forward compatible, and the context made current (`zglfw.makeContextCurrent`) before returning. Existing `init` keeps `.no_api` and must not change behavior.

- [ ] **Step 1: Add `initOpenGL` to `src/platform/glfw_window.zig`**

Keep `init(width, height, title, resizable)` byte-for-byte behavior (`client_api = .no_api`). Add `initOpenGL` that sets the OpenGL hints (`.context_version_major = 3`, `.context_version_minor = 3`, `.opengl_profile = .core`, `.opengl_forward_compat = true`), creates the window, installs the same five input callbacks (`setKeyCallback`, `setMouseButtonCallback`, `setCursorPosCallback`, `setScrollCallback`, `setFramebufferSizeCallback`), then calls `zglfw.makeContextCurrent(native_window)`. Factor the callback wiring into a private helper if it avoids duplication; do not change callback behavior.

- [ ] **Step 2: Verify it compiles through the existing desktop chain**

Run: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" && zig build wgpu`
Expected: builds clean; no behavior change warnings.

- [ ] **Step 3: Verify the test suite still passes**

Run: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" && zig build test`
Expected: all PASS.

- [ ] **Step 4: Commit**

```bash
git add src/platform/glfw_window.zig
git commit -m "feat: add OpenGL init path to GLFW window adapter"
```

### Task 2: GL render chain — backend, `GlApp`, minimal sample, build wiring

**Files:**
- Create: `src/gfx/gl/backend.zig`
- Create: `src/app/gl_desktop.zig`
- Create: `examples/gl/main.zig` (minimal: window + one sprite; replaced wholesale in Task 3)
- Modify: `build.zig`

**Interfaces:**
- Consumes: `ez_engine` (`Renderer.Backend`, `Assets`, `Handles.TextureHandle`, `RenderWorld`, `Game`); `zglfw` (`swapBuffers`, `getTime`, window type); `glfw_window.WindowAdapter` (from Task 1); `use_llvm` executables.
- Produces:
  - `src/gfx/gl/backend.zig`: `pub const SpriteVertex = extern struct { position: [2]f32, uv: [2]f32, tint: [4]f32 };` and `pub const SpriteBackend = struct { allocator: std.mem.Allocator, window: *zglfw.Window, assets: *ez_engine.Assets, program: c.GLuint, vao: c.GLuint, vbo: c.GLuint, vertex_capacity: usize = 4096, vertices: std.ArrayListUnmanaged(SpriteVertex) = .empty, gl_textures: std.AutoHashMapUnmanaged(u64, c.GLuint) = .empty, retired_gl_textures: std.ArrayListUnmanaged(u64) = .empty, extent: ez_engine.Renderer.Extent2D = .{ .width = 0, .height = 0 } }` with `init(allocator, window: *zglfw.Window, assets: *ez_engine.Assets) !SpriteBackend`, `deinit(self: *SpriteBackend) void`, `backend(self: *SpriteBackend) ez_engine.Renderer.Backend`.
  - `src/app/gl_desktop.zig`: `pub const GlApp = struct { allocator: std.mem.Allocator, window: GlfwWindow, backend: SpriteBackend, game: ez_engine.Game }` with `init(self: *GlApp, allocator: std.mem.Allocator, title: [:0]const u8, width: u32, height: u32, resizable: bool) !void`, `run(self: *GlApp, io: std.Io) !void`, `deinit(self: *GlApp) void`.
  - `build.zig`: modules `gl_backend` (root `src/gfx/gl/backend.zig`, imports `ez_engine`, `zglfw`), `gl_app` (root `src/app/gl_desktop.zig`, imports `ez_engine`, `zglfw`, `glfw_window`, `gl_backend`), `gl_module` (root `examples/gl/main.zig`, imports `ez_engine`, `gl_app`); executable `gl` (`use_llvm = true`, `linkLibrary(zglfw.artifact("glfw"))`, `linkSystemLibrary("GL")`, `linkSystemLibrary("X11")`, inside the existing `desktop_supported` block); steps `gl` and `gl-run`.

- [ ] **Step 1: Write `src/gfx/gl/backend.zig`**

Port `src/gfx/wgpu/backend.zig` 1:1, replacing the zgpu objects with GL equivalents and keeping the CPU-side logic (texture cache key, eviction, `appendSpriteVertices`, batch iteration, capacity growth) unchanged. Pinned details:

- Loader: `const gl = @cImport({ @cInclude("GL/glcorearb.h"); });` — do not `@cInclude("GL/gl.h")`.
- Shaders (GLSL 330 core, as string literals):
  - vertex: `#version 330 core` + `layout(location = 0) in vec2 position; layout(location = 1) in vec2 uv; layout(location = 2) in vec4 tint; out vec2 vUv; out vec4 vTint; void main() { vUv = uv; vTint = tint; gl_Position = vec4(position, 0.0, 1.0); }`
  - fragment: `#version 330 core` + `in vec2 vUv; in vec4 vTint; uniform sampler2D sprite_texture; out vec4 fragColor; void main() { fragColor = texture(sprite_texture, vUv) * vTint; }`
  - Compile/link with error logging on failure; helper `fn compileShader(type, source) !c.GLuint` and `fn linkProgram(vertex, fragment) !c.GLuint`.
- `init`: create program, VAO + VBO (attributes at locations 0/1/2, stride `@sizeOf(SpriteVertex)`, offsets 0/8/16), then run the D9 diagnostic: `std.debug.print` lines printing `gl vendor`/`gl renderer`/`gl version` from `glGetString(GL_VENDOR)` / `(GL_RENDERER)` / `(GL_VERSION)`; if the renderer string starts with `llvmpipe`, print a warning naming `GALLIUM_DRIVER=d3d12` and `MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA`.
- `ensureTexture(handle)`: key `(@as(u64, handle.generation) << 32) | handle.index`; `self.assets.getTexture(handle) orelse return error.InvalidTextureHandle`; reject zero width/height with `error.InvalidTexture`; `glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, format, GL_UNSIGNED_BYTE, pixels.ptr)` where `format` switches `source.format`: `.rgba8 => gl.GL_RGBA`, `.bgra8 => gl.GL_BGRA` (both arms mandatory); `glTexParameteri` min/mag filter `GL_NEAREST`, wrap `GL_CLAMP_TO_EDGE`; upload rows in natural order (first image row first) — orientation is corrected by the uv math exactly as in the wgpu backend; store the `c.GLuint`.
- `evictReleasedTextures`: copy the wgpu version verbatim (iterate keys, retire those whose handle is gone, `glDeleteTextures` the removed ones).
- `appendSpriteVertices` / `ensureVertexCapacity`: copy from the wgpu backend; `ensureVertexCapacity` grows the VBO via `glBufferData` with `GL_DYNAMIC_DRAW` sized `capacity * @sizeOf(SpriteVertex)`.
- `renderImpl`: evict → skip if `self.extent.width == 0 or self.extent.height == 0 and no accumulated vertices` (at minimum the zero-extent guard from wgpu: `if (self.extent.width == 0 or self.extent.height == 0) return;`) → append vertices → ensure capacity → upload (`glBufferSubData`) → `glViewport(0, 0, w, h)`; `glClearColor(0.035, 0.055, 0.09, 1.0)`, `glClear(GL_COLOR_BUFFER_BIT)`; `glEnable(GL_BLEND)`, `glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)`; bind program/VAO; `glActiveTexture(GL_TEXTURE0)` + sampler uniform = 0 once; walk `world.batches()` binding `glBindTexture(GL_TEXTURE_2D, ...)` and `glDrawArrays(GL_TRIANGLES, first * 6, count * 6)`; finally **`zglfw.swapBuffers(self.window)`**.
- `waitIdleImpl`: `glFinish()`.
- `deinitImpl`: iterate textures `glDeleteTextures`, delete VBO/VAO/program, free the lists.

- [ ] **Step 2: Write `src/app/gl_desktop.zig`**

Mirror `src/app/desktop.zig` exactly (init-in-place comment, `errdefer`s, the two permanent `std.debug.assert` guards) replacing:
- `GlfwWindow.init` → `GlfwWindow.initOpenGL`, then `zglfw.swapInterval(1)`.
- `zgpu.GraphicsContext` creation and `graphics.destroy` — dropped entirely (no zgpu dependency).
- `SpriteBackend.init(allocator, self.graphics, &self.game.assets)` → `SpriteBackend.init(allocator, self.window.native(), &self.game.assets)`.
- Same `run` (game.run with `self.window.platformWindow()`) and same `deinit` order (game first, then window).

- [ ] **Step 3: Write a minimal `examples/gl/main.zig`**

Mirror of `examples/wgpu/main.zig`'s `main(init: std.process.Init) !void` shape, `page_allocator`, `app.init(allocator, "ez-engine | textured 2D sprites (OpenGL)", 1280, 720, false)`, but with only the essential scene — no Player/scripting/collision/camera-follow yet: load `assets/player_sheet.png`, create one sprite (position 0,0, size 240×240, `z_index = 0`), then `app.run(init.io)`. Uses `@import("gl_app").GlApp`.

- [ ] **Step 4: Wire `build.zig`**

Inside the existing `desktop_supported` block, after the ez_app wiring: create the three modules (`gl_backend`, `gl_app`, `gl_module`) with the imports listed in Interfaces, the `gl` executable (`use_llvm = true`, `linkLibrary(zglfw.artifact("glfw"))`, `linkSystemLibrary("GL", .{})`, `linkSystemLibrary("X11", .{})`), and `build_gl` / `run_gl` steps named exactly `gl` ("Build the OpenGL sprite sample") and `gl-run` ("Run the OpenGL sprite sample").

- [ ] **Step 5: Build the GL sample**

Run: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" && zig build gl`
Expected: compiles clean. If `@cImport` of `glcorearb.h` errors, see the fallback in the spec (D3): replace with a small comptime loader over `zglfw.getProcAddress` for the entry points used, keeping it inside `backend.zig`.

- [ ] **Step 6: Run with d3d12 env — hardware renderer + orientation**

Run: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" && GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA timeout 25 zig build gl-run`
Expected: window opens; startup log shows `gl renderer: D3D12 (NVIDIA GeForce RTX 3060 Laptop GPU)`; **no** llvmpipe warning; the sprite is **not** upside down (review focus 2). Timeout killing the window (`exit 124` or X connection broken) is fine.

- [ ] **Step 7: Run without env — llvmpipe warning (review focus 1)**

Run: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" && timeout 20 zig build gl-run`
Expected: log still prints renderer, and the D9 warning naming `GALLIUM_DRIVER` / `MESA_D3D12_DEFAULT_ADAPTER_NAME` appears. (Then re-run Step 6 to restore the good state.)

- [ ] **Step 8: Test suite stays green**

Run: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" && zig build test`
Expected: all PASS.

- [ ] **Step 9: Commit**

```bash
git add src/gfx/gl/backend.zig src/app/gl_desktop.zig examples/gl/main.zig build.zig
git commit -m "feat: add OpenGL sprite backend and desktop app"
```

### Task 3: Full gameplay sample (parity with `examples/wgpu`)

**Files:**
- Modify: `examples/gl/main.zig` (replace the minimal scene with the full wgpu gameplay)
- Test: run verification only

**Interfaces:**
- Consumes: `@import("gl_app").GlApp` (Task 2) — same `init`/`run`/`deinit` shape as `ez_app.App`; `ez_engine` gameplay exports (`RenderComponents`, `Script`, `Collision2D`, `SpriteAnimation`, `CameraFollow2D`, `Game`, `World`).
- Produces: nothing new — a complete sample equivalent to `examples/wgpu/main.zig`.

- [ ] **Step 1: Copy the game from `examples/wgpu/main.zig`**

Replace `examples/gl/main.zig` with the full content of `examples/wgpu/main.zig`, changing only the app import/type: `const App = @import("ez_app").App;` → `const App = @import("gl_app").GlApp;` (the rest — Player, Collectible, PickupListener, DebugReporter, scene setup, scheduler wiring — is verbatim).

- [ ] **Step 2: Build**

Run: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" && zig build gl`
Expected: compiles clean.

- [ ] **Step 3: Run gameplay parity check**

Run: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" && GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA timeout 30 zig build gl-run`
Expected: window opens; sprites render (player sheet animate), no llvmpipe warning; sprite orientation correct (player not upside down; matches the wgpu sample's look); F3 toggles the debug stats log; ESC closes; collisions log on pickup. Timeout/Kill exit is acceptable at the end.

- [ ] **Step 4: Test suite stays green**

Run: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" && zig build test`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add examples/gl/main.zig
git commit -m "feat: add OpenGL sample with gameplay parity to wgpu"
```

### Task 4: Documentation

**Files:**
- Modify: `README.md`, `docs/project-management.md`

**Interfaces:**
- Consumes: nothing from code; documents the run command from Task 3.

- [ ] **Step 1: Add the GL run section to `README.md`**

A short "OpenGL sample" section: build with `zig build gl`, run with `GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA zig build gl-run`, plus 2–3 lines of *why* (WSL has no hardware Vulkan for Dawn; Mesa's d3d12 GL driver reaches the discrete GPU; the env vars select the adapter — driver selection stays an environment concern, not code).

- [ ] **Step 2: Mirror the note in `docs/project-management.md`**

Wherever the wgpu sample is documented, add the parallel GL sample with the same run/env note, phrased as the backend-agnostic story (`Backend` vtable, two desktop backends).

- [ ] **Step 3: Verify the documented commands work**

Run: `export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" && timeout 15 zig build gl-run` (no env) — expected: runs, prints llvmpipe warning; then with env: hardware renderer log. This is the doc proof.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/project-management.md
git commit -m "docs: document the OpenGL sample and d3d12 env vars"
```