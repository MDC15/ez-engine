# Tình trạng dự án (2026-10-11)

`ez-engine` (`ez_engine`, `0.1.0`) là framework game 2D viết bằng Zig
0.16.0: ECS archetype-based + đường render sprite (extract → cull → batch →
backend). Runtime tách gameplay khỏi GPU; sample WGPU dùng GLFW + Dawn.

## Đã có

- **ECS**: `World` (generational entity, add/remove/get/has/query),
  `Scheduler` tuần tự có topo-sort + phát hiện cycle, `Query`
  (Read/Optional/Exclude). Component phải là plain data.
- **Render 2D**: `Transform/SpriteRenderer/SpriteSheet/SpriteAnimation`,
  `RenderWorld` sprites-only, `Camera2D` + follow, batch theo texture/layer,
  nearest + alpha blend. Backend `Headless` trong lib, `SpriteBackend`
  (WGPU) ở module riêng `wgpu_backend`.
- **Asset**: handle generational cache theo path; PNG (zigimg) + ZTEX nội bộ.
- **Khác**: input không phụ thuộc OS, WAV decode + mixer (chưa device),
  collision AABB + event begin/stay/end, logger level/category, debug stats,
  `Scene` save/load JSON version 1.
- **Scripting**: behavior `onStart`/`onUpdate` (`Script.init/initWithStart` +
  `register`), `Mover2D` built-in, `App` gom window + graphics + game.
- **Scaffold**: `zig build new -Dname=...` sinh project chuẩn, nối `App`,
  `Script` và `wgpu_backend`.
- **Ví dụ + test**: 1 example (`wgpu`), suite
  (`zig build test` xanh) gồm test script/mover/backend-interface.
- **Docs**: README (tổng quan), `docs/architecture.md`, `docs/api.md`,
  `docs/project-management.md`, CHANGELOG, `zig build docs`.

## Phạm vi hiện tại

Framework tập trung vào game 2D với ECS, render sprite, input, audio mixer,
va chạm, scene JSON và scripting Zig-native. Các công cụ project tạo game
được triển khai trong Zig và dùng `zig build new`.

## Còn thiếu để thành lib hoàn chỉnh

- [x] **P0**: `LICENSE`, `CONTRIBUTING.md`, CI (`zig build`, `test`,
  `fmt --check`); version `0.1.0`.
- [ ] **P1**: test golden-image cho WGPU; audio-device backend; kiểm chứng
  quy tắc component lifetime (đã ghi trong TODO); bảng tương thích mở rộng
  ngoài Linux x86_64.
- [ ] **P2**: packed atlas + animation clip phức tạp; JPEG; mô phỏng vật lý;
  pipeline scene → runtime; bench hiệu năng (`cull`/`batch`/ECS iter).

Việc dở dang chi tiết xem `TODO.md`.
