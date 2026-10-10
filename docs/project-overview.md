# Tổng quan dự án và khoảng cách tới lib hoàn chỉnh

> Ngày: 2026-10-10. Nguồn: `README.md`, `TODO.md`, `build.zig`, `build.zig.zon`, `src/root.zig`, `docs/architecture.md`.

## 1. Dự án này là gì?

**ez-engine** (thư mục hiện tại `ez-engnine` — typo cần sửa) là framework game viết bằng **Zig 0.16.0**, hiện tập trung vào **ECS + đường render sprite 2D**.

Triết lý: runtime tách dữ liệu gameplay khỏi backend đồ họa.

```
Game.frame
  → run ECS systems
  → extract Transform + SpriteRenderer
  → cull theo Camera2D → sort + batch
  → Backend.render(RenderWorld)
```

### Module đã có (`src/root.zig:4-43`)

| Nhóm | File | Có gì |
|------|------|-------|
| ECS | `src/ecs/world.zig`, `scheduler.zig`, `query.zig`, `entity.zig`, `archetype.zig`, `storage.zig` | Archetype-based, `World{create,destroy,add,remove,get,has}`, `Scheduler.addSystem/dependsOn/run` topological + phát hiện cycle, `Query(Read/Optional/Exclude)` |
| Math | `src/math/vec2.zig`, `vec3.zig`, `vec4.zig`, `quat.zig`, `mat4.zig` | Vec/Quat/Mat4 cơ bản |
| Render 2D | `src/gfx/render_components.zig`, `render_world.zig`, `camera.zig`, `camera_follow.zig`, `sprite_animation.zig`, `renderer.zig` | `Transform/SpriteRenderer/SpriteSheet/SpriteAnimation`, `RenderWorld.extract/cullSprites2D/sortForBatching`, `Camera2D`, batch theo texture/layer liền kề, nearest + alpha blend |
| Asset | `src/asset/manager.zig`, `texture_loader.zig`, `mesh_loader.zig`, `shader_loader.zig` | Generational handle cache theo path, PNG (qua zigimg) + ZTEX nội bộ RGBA8/BGRA8 |
| Input | `src/input/input.zig` | Không phụ thuộc OS, key/mouse/scroll, edge `pressed/released` 1 frame |
| Audio | `src/audio/audio.zig` | Software mixer + decode WAV (PCM16/float32), chưa device backend |
| Collision | `src/physics/collision2d.zig` | Overlap AABB, event begin/stay/end, resolve solid trục nông nhất, chưa vật lý |
| Core | `src/core/log.zig`, `debug.zig`, `time.zig`, `handle.zig`, `allocator.zig` | Logger level/category, stats frame/FPS/culling/batch, Clock/FixedStepper |
| Platform | `src/gfx/platform.zig`, `src/platform/glfw_window.zig` | `Platform.Window` vtable, adapter GLFW → `Platform.Event`, `Game.run` loop |
| Vulkan | `src/gfx/vulkan/` (14 file) | Wrapper thô Instance/Device/Swapchain/Pipeline/... — sample hiện dùng `zgpu` thay vì module này |
| Game | `src/game.zig` | `Game{world,scheduler,assets,audio,render_world,camera,renderer}` + `init/frame/run/deinit` |

### Examples / Tools

- `examples/sandbox/main.zig`: headless, minimal tốt.
- `examples/wgpu_clear/main.zig` (~566 dòng): vừa gameplay (WASD, pickup, wall, camera follow) vừa chứa `SpriteBackend` WGPU — lẽ ra backend phải nằm trong lib.
- `examples/editor/main.zig` + `scene.zig`: editor imgui MVP (Hierarchy/SceneView placeholder màu/Inspector/Save-Open JSON).
- `tools/ez_project.py`: `new/list/open` project starter.
- `assets/player_sheet.png`: 1 frame idle + 4 frame walk.

### Phạm vi hiện tại (theo `README.md:102-121`)

Đã xong: sprite 2D, animation lưới đều, collider AABB trigger, asset PNG/ZTEX, ECS scheduler tuần tự, input, WAV mixer, backend headless, GLFW adapter, logger/debug stats, editor MVP, project CLI.

Chưa: renderer mesh/material, atlas packed, JPEG, audio device, mô phỏng vật lý, pipeline scene editor → runtime.

## 2. Còn thiếu gì để thành lib hoàn chỉnh?

### P0 — chặn release

- [ ] **Pháp lý + version:** thêm `LICENSE` (MIT/Apache-2.0), `CHANGELOG.md`, `CONTRIBUTING.md`. `build.zig.zon:13` đang `.version = "0.0.0"` → đổi sang `0.1.0-dev`, thêm `pub const version` trong `src/root.zig`, init git + tag. Hiện `Is git repo: no`.
- [ ] **Tên package:** `build.zig.zon:9` `.name = .game_lib` lệch với `README.md:1` `# ez-engine` và typo thư mục `ez-engnine`. Đổi thành `.ez_engine`, đồng bộ `build.zig:35,45`, `@import("game_lib")` trong examples, `tools/ez_project.py`.
- [ ] **CI tối thiểu:** chưa có `.github/workflows/`. Thêm job `zig build`, `zig build test`, `zig fmt --check` trên ubuntu + check cross-compile windows/macos.
- [ ] **Ổn định public API:** `src/root.zig:26-34` có alias trùng (`AssetStore==Assets`, `Input==InputModule`, `Audio==AudioModule`), expose `pub const Vulkan` cho mọi user 2D gây phình API + kéo `link_libc`. Cần: ẩn Vulkan thành private/lazy, hoặc xóa `Mesh/Material` chưa được vẽ khỏi public, thêm `docs/api.md` + policy breaking-change + `zig build docs`.
- [ ] **Consumer docs:** thêm snippet `zig fetch --save` + `b.dependency("ez_engine").module(...)` vào README, bổ sung `LICENSE/CHANGELOG` vào `.paths` (`build.zig.zon:60-70`).

### P1 — quan trọng

- [ ] **Error handling:** error sets đang rải rác (`InvalidTexture/InvalidCollider/InvalidWav/...`), còn `unreachable` tại `examples/wgpu_clear/main.zig:235`, sample dùng `page_allocator`. Cần thống nhất error + doc fallible API.
- [ ] **Test:** `tests/` chỉ 3 file mỏng; coverage thực nằm inline trong `src/`. Thiếu test `render_world/camera/sprite_animation/vulkan/glfw_window`, thiếu golden-image WGPU (đã ghi trong `TODO.md:6`), example phụ thuộc cwd `assets/...`. Cần leak-check `testing.allocator` + coverage trong CI.
- [ ] **Cross-platform:** `build.zig:86` `if (target != linux x86_64) return;` bỏ lặng lẽ `wgpu-clear/editor` trên macOS/Windows. Cần feature-detect Dawn theo OS + fallback headless + bảng support matrix trong README.
- [ ] **Tách backend:** chuyển `SpriteBackend` từ `examples/wgpu_clear` thành `src/gfx/wgpu_backend.zig` trong lib; example chỉ còn gameplay. Hardcode keycode số trong sample cần thay bằng `Key` enum.
- [ ] **Chuẩn hóa docs:** README lẫn Anh/Việt, `docs/` chỉ có narrative (architecture/editor/project-management), thiếu `docs/api.md` và `examples/README.md`.

### P2 — hoàn thiện

- [ ] **Bench:** thêm `bench/` + `zig build bench` (ECS iter, cull, batch) + doc perf.
- [ ] **Lifetime/thread-safety:** quy tắc `plain-data only` đã có ở `docs/architecture.md:26` nhưng chưa test (đúng `TODO.md:12`). Cần doc allocator, `Game.run` reentrancy.
- [ ] **Roadmap lib:** atlas packed + animation clip (`TODO.md:5`), JPEG, audio-device backend (`TODO.md:11`), mesh/material hoặc xóa, pipeline scene → runtime, undo/redo editor.

## 3. Đề xuất bước tiếp theo

1. Fix tên + version + LICENSE + git tag (P0, nhanh).
2. Thêm CI + `zig fmt --check` (P0).
3. Viết `docs/api.md` + dọn `src/root.zig` (P0).
4. Tách `wgpu_backend` vào lib (P1).
5. Bổ sung test còn thiếu + golden-image (P1).

Chi tiết hiện trạng build/test xem `README.md:21-33`, giới hạn renderer xem `docs/architecture.md:121-130`, việc dở dang xem `TODO.md:1-16`.
