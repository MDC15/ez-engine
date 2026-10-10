# ez-engine

Framework game viết bằng Zig, hiện tập trung vào ECS và đường render sprite
2D. Runtime tách dữ liệu gameplay khỏi backend đồ họa; sample WGPU dùng GLFW và
Dawn/WebGPU.

## Yêu cầu

- Zig 0.16.0.
- WSL2/Linux để build và chạy sample WGPU; WSLg cần bật để mở cửa sổ đồ họa.
- Các dependency Zig được khai báo trong `build.zig.zon`.

Nếu Zig cache trên `/mnt/c` hoặc `/mnt/d` gặp lỗi quyền truy cập, đặt cache về
filesystem Linux:

```sh
export PATH="$HOME/.local/opt/zig-0.16.0:$PATH"
export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local"
```

## Build và chạy

Chạy từ thư mục repository trong WSL:

```sh
zig build             # Build thư viện
zig build test        # Chạy unit tests
zig build example     # Chạy ví dụ ECS + texture, không cần GPU
zig build wgpu-clear  # Build sample sprite WGPU
zig build wgpu-clear-run  # Chạy sample, cần WSLg
zig build editor      # Build editor, cần Linux x86_64
zig build editor-run  # Chạy editor, cần WSLg
```

## Dùng như library

Package `ez_engine` (`0.1.0-dev`, Zig 0.16.0). Migration từ tên cũ:
`@import("game_lib")` → `@import("ez_engine")`.

```sh
zig fetch --save git+https://<repo-url>#<rev>
```

```zig
const engine = b.dependency("ez_engine", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ez_engine", engine.module("ez_engine"));
```

`zig build docs` để xem API docs. Chi tiết đổi breaking xem `CHANGELOG.md`.

## Hỗ trợ nền tảng

| Target | Library + tests | `wgpu-clear` / `editor` |
|--------|-----------------|-------------------------|
| Linux x86_64 | ✅ | ✅ (cần WSLg trên WSL) |
| Windows / macOS / khác | ✅ | ⚠️ bỏ qua kèm warning, chỉ build lib + tests |

## Tạo và quản lý project game

Project manager tạo game project mới, liệt kê project trong workspace và mở
project bằng editor desktop. Mặc định project được tạo trong `projects/`:

```sh
python3 tools/ez_project.py new MyFirstGame
python3 tools/ez_project.py list
python3 tools/ez_project.py open MyFirstGame
```

Đổi nơi lưu bằng `--workspace`, ví dụ:

```sh
python3 tools/ez_project.py --workspace ~/Games new MyFirstGame
python3 tools/ez_project.py --workspace ~/Games list
python3 tools/ez_project.py --workspace ~/Games open MyFirstGame
```

Project có `project.json`, scene mẫu, thư mục `Assets/`, `Scenes/`, `src/` và
`Build/`, cùng `build.zig` đã nối tới bản framework hiện tại. Trong project mới,
chạy `zig build run` để build và chạy starter sample. Đọc
[docs/project-management.md](docs/project-management.md) để biết chi tiết.

Editor MVP có Hierarchy để tạo/chọn/xóa object, Scene View để xem và chọn
object, Inspector để chỉnh vị trí/kích thước, cùng Save/Open scene JSON. Mở
chi tiết trong [docs/editor.md](docs/editor.md). Hiện Scene View dùng hình khối
màu đại diện; editor chưa nạp PNG vào preview và chưa ghi scene thành runtime
game.

Sample đồ họa nằm ở `examples/wgpu_clear`; `assets/player_sheet.png` có một
frame idle và bốn frame đi bộ. Dùng WASD để di chuyển, chạm vật phẩm màu cam
để nhặt. Khi chạm hoặc rời tường, log `begin`/`end` sẽ hiện kèm ID entity;
F3 bật/tắt frame stats. Camera bám theo nhân vật; nhấn Escape hoặc đóng cửa sổ
để thoát.

## Tạo sprite

`Game` sở hữu ECS, asset manager và render world. Thêm `Transform` cùng
`SpriteRenderer` cho entity; `Game.frame` sẽ chạy systems, extract sprite,
cull theo camera 2D, sắp thứ tự và gửi render world đến backend.

```zig
const texture = try game.assets.loadTextureFile(
    init.io,
    "assets/sprite.png",
    16 * 1024 * 1024,
);

const player = try game.world.create();
try game.world.add(player, game.RenderComponents.Transform{
    .position = .{ .x = 0, .y = 0 },
});
try game.world.add(player, game.RenderComponents.SpriteRenderer{
    .texture = texture,
    .size = .{ .x = 64, .y = 64 },
    .tint = .one,
    .z_index = 0,
});
```

`size` dùng đơn vị world. Sprite xoay theo `Transform.rotation`, scale theo
`Transform.scale`; `z_index` thấp hơn được vẽ trước. Texture được cache theo
đường dẫn và trả về generational handle. Asset manager giữ pixel CPU; backend
giữ texture GPU. Xem [docs/architecture.md](docs/architecture.md) để biết
ownership và định dạng texture.

## Phạm vi hiện tại

- Sprite 2D: transform, tint, alpha blend, camera orthographic, culling và
  batching theo texture/layer liền kề.
- Sprite sheet dạng lưới và animation ECS cơ bản.
- Collider AABB 2D phát event begin/stay/end và đẩy vật thể solid ra khỏi
  collider chồng lấn; chưa có mô phỏng vật lý.
- Asset texture: PNG và định dạng nội bộ ZTEX RGBA8/BGRA8.
- Có ECS, scheduler tuần tự, input state, decoder WAV/mixer phần mềm và
  backend headless.
- GLFW platform adapter dùng `Game.run`: bàn phím, chuột, scroll, đóng cửa sổ
  và framebuffer resize.
- Logger có level/category và debug stats tùy chọn cho frame, FPS, entity,
  culling và render batch.
- Editor scene MVP: tạo/chọn/xóa sprite, obstacle, pickup; chỉnh transform;
  lưu/mở scene JSON.
- Project manager CLI: tạo project từ starter, liệt kê theo workspace, mở
  project bằng editor desktop.
- Chưa có renderer mesh/material, atlas, decoder JPEG, audio device, mô phỏng
  vật lý hoặc pipeline đưa scene editor vào runtime game.

Đây là framework nền tảng đang phát triển, chưa phải engine production-ready.
