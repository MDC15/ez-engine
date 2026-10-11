# OpenGL sprite backend for `ez_engine` — design

**Status:** draft, pending builder check and human approval.

## Intent (why)

The engine currently renders only through WebGPU (Dawn, via `zgpu`). On the
user's machine — Ubuntu 26.04 on WSL2, NVIDIA RTX 3060 Laptop as the discrete
GPU — that path runs on the **CPU**: `zgpu` reports `llvmpipe` / `Adapter
type: cpu`. Investigation proved why:

- WSL has no native hardware Vulkan driver; the only Vulkan ICD present is
  `llvmpipe` (software).
- The Vulkan-on-D3D12 path (`dzn`) *does* expose the real GPU to `vulkaninfo`
  (`Microsoft Direct3D12 (NVIDIA GeForce RTX 3060 Laptop GPU)`, discrete), but
  **Dawn rejects `dzn`** because Dawn requires the Vulkan `fullDrawIndexUint32`
  feature and `dzn` reports it unsupported. So the existing WGPU backend cannot
  reach the GPU in WSL no matter how the driver is configured.
- Mesa's **OpenGL-on-D3D12** driver (`d3d12` gallium) *is* available and works:
  `GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA` gives a
  hardware-accelerated GL context on the RTX 3060 (`D3D12 (NVIDIA GeForce RTX
  3060 Laptop GPU)`, `Accelerated: yes`), verified with `glxinfo`,
  `glxgears` (~98 FPS), and `eglinfo` on both the X11/GLX **and**
  Wayland/EGL platforms (`OpenGL core profile renderer: D3D12 (NVIDIA ...)`
  under the same env vars). This matters because GLFW 3.4 prefers Wayland/EGL
  when `WAYLAND_DISPLAY` is set (WSLg sets it); the EGL path is validated,
  so no platform pinning is required — whichever context path GLFW picks is
  hardware-capable with the d3d12 env vars.

So an **OpenGL sprite backend** is the way to let the engine render on the
real GPU inside WSL, and it is what the user asked for ("thêm backend opengl
render bằng gpu rời"). The GPU is simply not reachable through the current
backend on this machine.

## Goals

- A sprite rendering backend implemented over the engine's existing
  `Renderer.Backend` vtable (`resize` / `render` / `waitIdle` / `deinit`),
  with functional parity to the WGPU backend for the 2D sprite sample:
  textured quads, per-quad UV source rect, tint, z-order batching, alpha
  blend, nearest filtering, same clear color, camera-follow independent.
- Rendered via desktop OpenGL 3.3 core, hardware accelerated in WSL through
  Mesa `d3d12`, selecting the NVIDIA discrete GPU via environment variables in
  the run instructions.
- Shipped as a **separate desktop module** (`gl_backend`, plus `gl_app`
  desktop helper and `examples/gl` sample), mirroring how `wgpu_backend` /
  `ez_app` / `examples/wgpu` are wired. The engine library itself stays
  backend-agnostic and headless — no GL dependency leaks into `src/root.zig`
  or the ECS/gameplay modules.
- The WGPU backend, `ez_app`, and `examples/wgpu` remain untouched and
  functional.

## Non-goals (anti-goals)

- **No fix for the WGPU/Dawn path in WSL.** The `dzn` rejection by Dawn is
  documented here but out of scope; we add a second backend instead of fixing
  the first. No system-driver installation is part of this work.
- **No runtime backend switching.** The choice (WGPU vs GL) is compile-time,
  via which desktop app module and sample you build. No env-var renderer
  selection, no shared "choose adapter at startup" machinery.
- **No cross-platform GL backend.** Same `desktop_supported` gate as the wgpu
  sample: Linux x86_64 only.
- **No GL beyond 3.3 core.** No compute, no instancing, no MSAA, no
  framebuffer objects, no GLES. One sampler (nearest), one pipeline.
- **No new GL loader dependency** (not GLAD/GLEW/`zgl`). Load GL via the
  system `GL` library with `@cImport` of the system `GL/glcorearb.h`, falling
  back to a small `zglfw.getProcAddress` loader if headers prove awkward.
- **No unit tests that require a GL context.** Headless `zig build test` must
  keep passing with no display; the GL backend is verified by compiling and by
  running the sample. The one pure-logic check (texture key math) is copied
  from the wgpu backend pattern.
- **Exact color parity with the WGPU backend is not required.** WGPU samples
  sRGB-encoded textures (`rgba8_unorm_srgb`); GL upload uses raw `RGBA8`
  bytes. Minor brightness differences between backends are acceptable.
- **No resize support change** — window stays fixed-size (`resizable =
  false`), consistent with the rest of the repo.

## Constraints

- Zig `0.16.0`; build already uses `use_llvm = true` for the wgpu sample
  (required for `@cImport`). Follow the same pattern.
- `zglfw` is already a dependency and provides `makeContextCurrent`,
  `swapInterval`, `getProcAddress`, and GLFW window hints for `ClientApi` /
  `OpenGLProfile` — verified present in the vendored version.
- System GL development files are present on this machine
  (`/usr/include/GL/glcorearb.h`, `libGL.so` via libgl-dev/glvnd); linking
  the `GL` system library is the chosen loading path.
- Assets: `Assets.TextureData` exposes `width`, `height`, `pixels
  ([]const u8)`, and `format: enum { rgba8, bgra8 }` (`rgba8` is 4 bytes/px;
  `bgra8` is byte-swapped RGBA). `getTexture(handle) ?*TextureData` and
  `loadTextureFile(io, path, max_bytes)` are the public surface.
- The engine's render flow is single-threaded: `Game.run` → poll events →
  `present` → `renderer.render(...)`. GL calls all happen on that one thread;
  the context is current for the main thread's lifetime.

## Decisions

### D1 — New module `gl_backend` at `src/gfx/gl/backend.zig`

Exactly mirrors `src/gfx/wgpu/backend.zig`:

- `SpriteVertex` is the same `extern struct { position: [2]f32, uv: [2]f32,
  tint: [4]f32 }` and the same `appendSpriteVertices` quad/UV code so vertex
  data is bit-identical to the WGPU path.
- `pub const SpriteBackend = struct { allocator, window: *zglfw.Window, assets,
  program: GLuint, vao: GLuint, vbo: GLuint, vertex_capacity = 4096,
  vertices, gl_textures: AutoHashMapUnmanaged(u64, GLuint),
  retired_gl_textures, extent, ... }` with `init`, `deinit`, `backend()`, and
  the same four `*Impl` vtable entries.
- Texture cache keyed by `(generation << 32) | index`, with the same
  eviction rule as WGPU: when `assets.getTexture(handle)` returns null, the
  GL texture is retired and deleted.
- `renderImpl`:
  1. evict released textures;
  2. skip if extent is zero;
  3. `appendSpriteVertices`; ensure VBO capacity (re-create with
     `glBufferData` when growing past capacity, powers of two);
  4. upload all batch textures first upload path via `ensureTexture`;
  5. `glViewport(0, 0, w, h)`; `glClearColor(0.035, 0.055, 0.09, 1);
     glClear(GL_COLOR_BUFFER_BIT)`;
  6. `glUseProgram`; bind VAO; `glBufferSubData` the vertices;
     `glActiveTexture(GL_TEXTURE0)`; set sampler uniform to 0 once;
  7. walk `world.batches()`: `glBindTexture(unit 0, gl_texture[key])`,
     `glDrawArrays(GL_TRIANGLES, first * 6, count * 6)`;
  8. `zglfw.swapBuffers(self.window)` (GL owns the swapchain, like the WGPU
     backend calls `graphics.present()`).
- Blend state matches the WGPU pipeline:
  `glEnable(GL_BLEND); glBlendFuncSeparate(GL_SRC_ALPHA,
  GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA)`.
- `waitIdleImpl` → `glFinish()`. `deinitImpl` deletes textures, buffers, VAO,
  program.
- GLSL 330 core shaders, declared in the file like the WGSL string:
  - vertex: `in vec2 position; in vec2 uv; in vec4 tint; out vec2 vUv; out
    vec4 vTint; gl_Position = vec4(position, 0.0, 1.0);`
  - fragment: `uniform sampler2D sprite_texture; out vec4 fragColor;
    fragColor = texture(sprite_texture, vUv) * vTint;`

### D2 — Texture upload and orientation

- `glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, w, h, 0, format, GL_UNSIGNED_BYTE,
  pixels.ptr)` with `format = GL_RGBA` for `rgba8` and `GL_BGRA` for `bgra8`.
- Filtering `GL_NEAREST`/`GL_NEAREST`; `glTexParameteri` wrap `CLAMP_TO_EDGE`.
- **Orientation (verified during implementation):** the WGPU backend treats
  texture v = 0 as the top of the image (top-left UV origin). GL treats the
  first uploaded row as v = 0 (bottom). To reuse the identical
  `appendSpriteVertices` UV math, **upload rows vertically flipped**
  (first uploaded row = last image row). If the sprite comes out flipped
  anyway, invert v in the shader — the visual check with
  `assets/player_sheet.png` is authoritative; which mechanism is chosen is the
  builder's call, but a flipped sprite is an explicit release-blocker bug.

### D3 — GL function loading: `@cImport` + system `GL`

- `const gl = @cImport({ @cInclude("GL/glcorearb.h"); });` in
  `src/gfx/gl/backend.zig`; executable links `linkSystemLibrary("GL")` (and
  `"X11"`, mirroring the wgpu sample, if GLFW's artifact needs it).
- If the header path proves awkward at build time (macro conflicts), fall
  back to a small comptime loader over `zglfw.getProcAddress` for just the
  ~25 entry points the backend uses. Builder's call; keep it inside the
  `gl_backend` module and off `ez_engine`.

### D4 — `WindowAdapter` gains an OpenGL init path

`src/platform/glfw_window.zig` keeps `init(...)` (no API; used by `ez_app`)
and adds `initOpenGL(width, height, title, resizable)` that:

1. hints `.client_api = .opengl`, `.context_version_major = 3`,
   `.context_version_minor = 3`, `.opengl_profile = .core`,
   `.opengl_forward_compat = true`, `.resizable`;
2. creates the window and installs the same input callbacks (shared private
   helper with `init`);
3. calls `zglfw.makeContextCurrent(window)` before returning.

### D5 — New desktop helper `gl_app` at `src/app/gl_desktop.zig`

`pub const GlApp` mirrors `App` (desktop.zig):

```
init(self, allocator, title, width, height, resizable):
  window = GlfwWindow.initOpenGL(...)      // errdefer deinit
  zglfw.swapInterval(1)                    // vsync, mirrors wgpu present pacing
  game = Game.init(allocator, 2)           // errdefer deinit
  backend = SpriteBackend.init(allocator, window.native(), &game.assets)  // errdefer deinit
  game.renderer = backend.backend()
  same two permanent guard asserts as App

run(io)  -> game.run(io, window.platformWindow())
deinit() -> game.deinit(); window.deinit()
```

### D6 — Sample `examples/gl/main.zig`

Copy of `examples/wgpu/main.zig` with the import and app type changed
(`gl_app.GlApp`), same 1280×720 fixed window, same world/scene/systems
(Player, Collectible, DebugReporter, animation, collision, camera follow). No
backend-specific code — gameplay does not depend on GL.

### D7 — `build.zig` wiring

Inside the existing `desktop_supported` block:

- `gl_backend` module: root `src/gfx/gl/backend.zig`, imports `ez_engine` +
  `zglfw`.
- `gl_app` module: root `src/app/gl_desktop.zig`, imports `ez_engine`, `zglfw`,
  `glfw_window`, `gl_backend`.
- `gl_module`: root `examples/gl/main.zig`, imports `ez_engine`, `gl_app`,
  `glfw_window`.
- `gl` executable: `use_llvm = true`,
  `linkLibrary(zglfw.artifact("glfw"))`, `linkSystemLibrary("GL")` (+ `X11`
  if needed), using the prebuilt rebuild cache env like the rest of the repo.
- Steps `gl` ("Build the OpenGL sprite sample") and `gl-run` ("Run the
  OpenGL sprite sample"). Guard everything behind `desktop_supported`, same as
  wgpu.

### D8 — Run instructions (docs)

`README.md` / `docs/project-management.md` gain a GL section:

```
GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA zig build gl-run
```

with a short note explaining *why* (llvmpipe/HTML5-fallback log, Dawn vs `dzn`
incompatibility, and the d3d12 env vars to force the discrete GPU). Keep it
brief — the D3D12 selection must stay an environment concern, not code.

### D9 — Renderer-string diagnostic at startup

Acceptance for "hardware accelerated on the discrete GPU" must not be silent:
the d3d12 env vars are the whole mechanism and, if forgotten, the sample falls
back to `llvmpipe` with no visible failure. `GlSpriteBackend.init` therefore
logs (via `std.debug.print`, since the backend has no logger handle):

```
gl vendor:  Mesa
gl renderer: D3D12 (NVIDIA GeForce RTX 3060 Laptop GPU)
gl version: 4.1 (Core Profile) Mesa 26.0.8-1ubuntu0.3
```

If `GL_RENDERER` starts with `llvmpipe`, log a prominent warning naming the
two env vars to set. This is a *diagnostic*, not driver-selection machinery —
the env vars remain the only way to choose the adapter (D8).

## What is left to the builder

- Exact GLSL boilerplate and the `@cImport` include adjustments.
- Whether `linkSystemLibrary("X11")` is needed beyond GLFW's artifact.
- The orientation-flip mechanism (upload flip vs shader flip) — must be
  visually verified with the player sheet; a flipped sprite is a bug.
- New names are fine if they collide, but module/sample names (`gl_backend`,
  `gl_app`, `gl`, `gl-run`) and the vtable contract above are the spec.
- The texture key / eviction logic must be ported 1:1 from the wgpu backend;
  `zig build test` must stay green with no display.