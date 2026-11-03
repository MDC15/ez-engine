# Repo Cleanup + Extensible Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Xóa code/artifacts chết và tái cấu trúc `ez-engine` thành lib 2D gọn, dễ mở rộng.

**Architecture:** Giữ core ECS/math/runtime; tách `gfx-2d` + `backends/` (headless trong lib, wgpu từ example chuyển vào); xóa `vulkan/` + mesh/material chết; facade `src/root.zig` gọn với import namespaced và `version`.

**Tech Stack:** Zig 0.16.0, `zig build/test/fmt`, zgpu/zglfw/zgui/zigimg (giữ nguyên pin).

**Spec:** Không có design doc riêng — quyết định từ audit trực tiếp (yêu cầu user "làm luôn" ngày 2026-10-10). Nguồn: `README.md`, `TODO.md`, `build.zig`, `build.zig.zon`, `src/root.zig:4-43`, `docs/architecture.md`.

## Global Constraints

- Zig 0.16.0 (`build.zig.zon` minimum_zig_version).
- Không đổi hành vi sprite 2D hiện tại (tint, z_index, batching, AABB, WAV mixer).
- Mọi task kết thúc bằng `zig build test` PASS và `zig fmt --check` sạch cho file chạm tới.
- Không thêm dependency mới.

## Review Focus

- Example `wgpu_clear` vẫn build/chạy sau khi backend chuyển vào lib — mong đợi: `zig build wgpu-clear` PASS trên linux x86_64.
- `Game.frame` vẫn cull/batch sprite giống trước khi xóa MeshRenderer path — mong đợi: sandbox headless log `submitted` như cũ.
- Scene JSON cũ (`version:1`) vẫn load được sau khi chuyển vào lib — mong đợi: round-trip test PASS.
- Consumer dùng `@import("game_lib")` cũ bị gãy sau rename — mong đợi: README ghi rõ migration 1 dòng.
- Xóa `vulkan/` không làm mất API nào example dùng — mong đợi: grep `vulkan_api|Vulkan` chỉ còn trong CHANGELOG ghi chú xóa.

---

### Task 1: Safe artifact cleanup

**Files:**
- Delete: `.zig-cache/`, `zig-out/`, `zig-pkg/`, `.verify-projects/`, `tools/__pycache__/`, `imgui.ini`
- Modify: `.gitignore:1-3`

**Interfaces:**
- Consumes: none
- Produces: `.gitignore` mới gồm `.zig-cache/ zig-out/ zig-pkg/ .verify-projects/ tools/__pycache__/ imgui.ini`

- [ ] **Step 1: Xóa artifacts và patch .gitignore**

Xóa 6 path trên bằng `rm -rf`, sửa `.gitignore` thành 6 dòng trên.

- [ ] **Step 2: Verify build còn chạy**

Run: `zig build test` (cho phép fetch lại dep sau xóa `zig-pkg`)
Expected: PASS (lần đầu chậm do fetch).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "chore: remove build artifacts and expand gitignore"
```

### Task 2: Remove dead 3D/Vulkan + mesh/material loaders

**Files:**
- Delete: `src/gfx/vulkan/` (17 file, ~1900 dòng), `src/gfx/mesh.zig`, `src/gfx/material.zig`, `src/asset/mesh_loader.zig`, `src/asset/shader_loader.zig`
- Modify: `src/root.zig:35-43,64-67,79`, `build.zig:27-43`, `src/gfx/render_world.zig:18,34,88-93`, `src/gfx/render_components.zig:14-16`, `src/game.zig:140`, `src/core/handle.zig:22`

**Interfaces:**
- Consumes: none
- Produces: `RenderWorld` chỉ còn sprite path: `extract(world)`, `cullSprites2D(cam)`, `sortForBatching()`, `batches()` (không còn `MeshRenderer` branch)

- [ ] **Step 1: Viết test khóa hành vi sprite hiện tại**

Trong `tests/render_world_sprite_test.zig`, tạo world 3 sprite khác texture/z_index, gọi `extract → cullSprites2D → sortForBatching`, assert số batch và thứ tự z_index.

- [ ] **Step 2: Run test, verify PASS trước khi xóa**

Run: `zig build test`
Expected: PASS (test mới xanh, chứng minh baseline).

- [ ] **Step 3: Xóa 21 file chết và gỡ import**

`rm -rf src/gfx/vulkan src/gfx/mesh.zig src/gfx/material.zig src/asset/mesh_loader.zig src/asset/shader_loader.zig`; xóa `vulkan` module ở `build.zig:27-33` + `game.addImport("vulkan_api",...)`; xóa `pub const Vulkan/Mesh/Material/AssetLoading.Mesh/...` ở `src/root.zig`.

- [ ] **Step 4: Gỡ MeshRenderer khỏi render path**

Trong `render_components.zig` xóa `MeshRenderer`; `render_world.zig` xóa `RenderItem.kind=mesh` branch + field `mesh/material`, giữ sprite fields; `game.zig:29` xóa `camera: Camera` 3D (giữ `camera_2d`); `handle.zig` xóa `MaterialHandle` (giữ `TextureHandle`); fix mọi compile error còn lại.

- [ ] **Step 5: Run tests**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "chore: remove unused vulkan/mesh/material code, sprites-only render path"
```

### Task 3: Facade public API + rename package

**Files:**
- Modify: `build.zig.zon:9,13`, `build.zig:35-49`, `src/root.zig` (toàn file), `examples/*/main.zig` (`@import("game_lib")`), project management utility, `README.md`

**Interfaces:**
- Consumes: Task 2 (root đã gọn)
- Produces: `pub const version: []const u8 = "0.1.0-dev"`, module `ez_engine`, exports: `World Entity Scheduler Query Vec2 Vec3 Quat Mat4 TextureHandle RenderWorld RenderComponents SpriteAnimation Collision2D Camera2D CameraFollow2D Renderer Platform Input Audio Assets Game Time Logging Debug AllocatorTools Texture`

- [ ] **Step 1: Đổi tên + version + namespaced imports**

`build.zig.zon`: `.name = .ez_engine`, `.version = "0.1.0-dev"`; `build.zig`: `b.addModule("ez_engine", ...)` + `addImport("ez_platform",...)`, `addImport("ez_input",...)`, `addImport("ez_zigimg",...)` (bỏ tên chung `platform/input_module/vulkan_api`); `src/root.zig` sửa `@import("platform")` → `@import("ez_platform")` tương ứng, xóa alias trùng `AssetStore/InputModule/AudioModule`, thêm `pub const version`.

- [ ] **Step 2: Sửa consumer**

`examples/sandbox|wgpu_clear|editor/main.zig`: `@import("game_lib")` → `@import("ez_engine")`; project generator: template build.zig.zon mới; README snippet `zig fetch --save` mới.

- [ ] **Step 3: Run tests**

Run: `zig build test && zig fmt --check src/root.zig build.zig`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: rename game_lib to ez_engine, namespace imports, add version"
```

### Task 4: Extract WGPU sprite backend into lib

**Files:**
- Create: `src/gfx/wgpu/backend.zig`
- Modify: `examples/wgpu_clear/main.zig` (~566 dòng), `build.zig:94-127`, `src/gfx/renderer.zig`, `src/root.zig`

**Interfaces:**
- Consumes: Task 3 (`Renderer.Backend` vtable `{resize,render,waitIdle,deinit}`)
- Produces: `pub const SpriteBackend = struct { init(alloc, device, queue, format) !SpriteBackend, backend(self) Renderer.Backend, deinit() }`

- [ ] **Step 1: Viết integration test headless cho backend interface**

Dùng `Headless` backend hiện có: `Game.init → loadTextureFile("assets/sprite.ztex") → frame(1/60) → assert headless.submitted == 1`. Đặt trong `tests/backend_iface_test.zig`, wired vào `build.zig:55-64`.

- [ ] **Step 2: Run test, verify PASS**

Run: `zig build test`
Expected: PASS.

- [ ] **Step 3: Chuyển code SpriteBackend từ example vào lib**

Cắt phần pipeline WGSL + vertex buffer grow-pow2 + `HashMap<u64>` gpu_textures + evict + batch loop từ `examples/wgpu_clear/main.zig:400-520` sang `src/gfx/wgpu/backend.zig`, implement `Renderer.Backend` vtable; example chỉ còn gameplay (player/decor/pickup/wall + systems) và gọi `WgpuBackend.init(...).backend()`.

- [ ] **Step 4: Run tests + build sample**

Run: `zig build test && zig build wgpu-clear`
Expected: PASS cả hai.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: move wgpu sprite backend from example into lib"
```

### Task 5: Promote scene serialization into lib

**Files:**
- Create: `src/scene/scene.zig` (chuyển từ `examples/editor/scene.zig`)
- Modify: `examples/editor/main.zig`, `build.zig:65-70`, `src/root.zig`

**Interfaces:**
- Consumes: none
- Produces: `pub const Scene = struct { Object{id,kind,position,size}, Document{add,remove,get,save,load} }`

- [ ] **Step 1: Move file, giữ nguyên logic + test round-trip**

`git mv examples/editor/scene.zig src/scene/scene.zig`; `src/root.zig` thêm `pub const Scene`; editor `main.zig` đổi import; `build.zig` đổi test path sang `src/scene/scene.zig`.

- [ ] **Step 2: Run tests**

Run: `zig build test`
Expected: PASS (round-trip JSON version=1 vẫn xanh).

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: promote editor scene into lib"
```

### Task 6: Build system + docs hardening

**Files:**
- Modify: `build.zig:86` (bỏ early-return linux-only), `build.zig` (thêm step `docs`), `README.md`, `docs/architecture.md:121-130`, `TODO.md`, `CHANGELOG.md` (mới)

**Interfaces:**
- Consumes: Task 1-5
- Produces: `zig build docs` (autodoc), support-matrix trong README, CHANGELOG ghi breaking changes (xóa vulkan/mesh, rename)

- [ ] **Step 1: Thay early-return bằng feature-detect**

`build.zig:86`: nếu không phải linux x86_64 thì vẫn khai báo `wgpu-clear/editor` steps nhưng in warning + headless fallback thay vì `return` lặng lẽ.

- [ ] **Step 2: Thêm docs step + viết CHANGELOG**

Thêm `b.step("docs", ...)` emit autodoc từ `src/root.zig`; tạo `CHANGELOG.md` (Unreleased: removed/renamed/fixed); cập nhật README support matrix + migration `game_lib → ez_engine`.

- [ ] **Step 3: Verify toàn bộ**

Run: `zig build && zig build test && zig fmt --check src examples tests`
Expected: PASS hết.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: cross-platform build guard, docs step, changelog"
```
