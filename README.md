# ez-engine

Framework game 2D viết bằng Zig (`ez_engine`, `0.1.0-dev`), tập trung vào ECS
và đường render sprite. Runtime tách dữ liệu gameplay khỏi backend đồ họa:
gameplay chạy trên ECS, mỗi frame extract sprite ra `RenderWorld` (dữ liệu CPU
thuần), rồi backend vẽ lên GPU.

```text
Game.frame
  → run ECS systems
  → extract Transform + SpriteRenderer
  → cull theo Camera2D → sort + batch
  → Backend.render(RenderWorld)
```

Đây là framework nền tảng đang phát triển, chưa phải engine production-ready.

## Yêu cầu

- Zig 0.16.0.
- Linux x86_64 + WSLg (trên WSL) để build/chạy sample WGPU. Library và unit
  tests build được trên mọi target.
- Các dependency Zig khai báo trong `build.zig.zon` (`zglfw`, `zgpu`,
  `zigimg`, Dawn).

Nếu Zig cache trên `/mnt/c` hoặc `/mnt/d` lỗi quyền, đặt cache về filesystem
Linux:

```sh
export PATH="$HOME/.local/opt/zig-0.16.0:$PATH"
export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local"
```

## Build và chạy

Chạy từ thư mục repository:

```sh
zig build             # Build thư viện tĩnh ez_engine
zig build test        # Chạy toàn bộ unit tests
zig build example     # Ví dụ headless (ECS + texture, không cần GPU)
zig build wgpu-clear  # Build sample sprite WGPU (cần Linux x86_64)
zig build wgpu-clear-run  # Chạy sample, cần WSLg
zig build docs        # Xuất API docs ra zig-out/docs
```

Trên target khác Linux x86_64, các step desktop bị bỏ qua kèm warning; lib và
tests vẫn build bình thường.

## Dùng như library

```sh
zig fetch --save git+https://<repo-url>#<rev>
```

```zig
const engine = b.dependency("ez_engine", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("ez_engine", engine.module("ez_engine"));
```

Backend WGPU (`SpriteBackend.init`) nằm ở module riêng `wgpu_backend`, chỉ có
trên Linux x86_64 và không export từ root để lib lõi không phụ thuộc `zgpu`:

```zig
const wgpu_backend = b.createModule(.{
    .root_source_file = engine.path("src/gfx/wgpu/backend.zig"),
    ...
});
wgpu_backend.addImport("ez_engine", engine.module("ez_engine"));
wgpu_backend.addImport("zgpu", zgpu.module("root"));
```

Bảng export public và nguyên tắc API xem [docs/api.md](docs/api.md); breaking
changes xem `CHANGELOG.md`.

## Hỗ trợ nền tảng

| Target | Library + tests | `wgpu-clear` |
|--------|-----------------|--------------|
| Linux x86_64 | ✅ | ✅ (cần WSLg trên WSL) |
| Windows / macOS / khác | ✅ | ⚠️ bỏ qua kèm warning |

## Tạo và quản lý project game

Tạo game project mới không cần Python:

```sh
zig build new -Dname=MyFirstGame
zig build new -Dname=MyFirstGame -Dworkspace=~/Games
```

Mặc định project được tạo trong `projects/`. Lệnh sinh ra cấu trúc chuẩn
(`build.zig` đã nối `ez_engine` + `wgpu_backend`, `build.zig.zon` kèm
fingerprint, `src/main.zig` starter, `Assets/`, `Scenes/`,
`editor_scene.json`, `project.json`, `README.md`, `.gitignore`), copy sẵn
assets mẫu. Chạy lần hai vào chỗ cũ sẽ báo lỗi sạch, không ghi đè. Trong
project mới chạy `zig build run` để build và chạy starter sample. Chi tiết
xem [docs/project-management.md](docs/project-management.md).

## Viết gameplay bằng Script

Behavior là struct thường có `pub fn onUpdate` (và `pub fn onStart` nếu cần
khởi tạo), đăng ký một dòng thay cho system viết tay:

```zig
const Player = struct {
    mover: game.Script.Mover2D = .{},

    pub fn onUpdate(self: *Player, ctx: *game.Script.Ctx) !void {
        const direction = try self.mover.update(ctx); // WASD + arrows
        const animation = try ctx.world.get(self.mover.entity.?, game.RenderComponents.SpriteAnimation);
        animation.play(if (direction.x == 0 and direction.y == 0) idle else walk);
    }
};

var player = Player{};
player.mover.entity = e;
var script = game.Script.init(game, &player);
try script.register(&game.scheduler, "Player movement");
```

Dùng `Script.initWithStart` khi behavior có `onStart` (chạy ở frame đầu
tiên). `Mover2D` built-in đẩy `Transform` theo WASD/arrows với tốc độ
mặc định 260 đơn vị/giây. Chi tiết API xem [docs/api.md](docs/api.md).

## Sample WGPU

Sample nằm ở `examples/wgpu_clear` (gameplay thuần túy; backend render nằm
trong lib). `assets/player_sheet.png` có một frame idle và bốn frame đi bộ.
Dùng WASD để di chuyển, chạm vật phẩm màu cam để nhặt. Khi chạm hoặc rời
tường, log `begin`/`end` hiện kèm ID entity; F3 bật/tắt frame stats. Camera
bám theo nhân vật; nhấn Escape hoặc đóng cửa sổ để thoát.

## Vẽ sprite

`Game` sở hữu ECS, asset manager và render world. Thêm `Transform` cùng
`SpriteRenderer` cho entity; `Game.frame` chạy systems, extract sprite, cull
theo camera 2D, sắp thứ tự và gửi render world đến backend.

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
giữ texture GPU. Ownership, animation, collision và định dạng texture xem
[docs/architecture.md](docs/architecture.md).

## Bố cục repository

```text
src/
  root.zig            # Facade public của ez_engine (+ version)
  game.zig            # Game: world, scheduler, assets, render_world, frame loop
  ecs/                # World, Entity, Scheduler, Query (archetype-based)
  math/               # Vec2/3/4, Quat, Mat4
  core/               # handle, log, debug stats, time, allocator
  gfx/                # render_world, render_components, camera2d, sprite_animation,
                      # renderer (Backend vtable + Headless), texture, platform
  gfx/wgpu/           # SpriteBackend (module riêng, chỉ Linux x86_64)
  asset/              # Manager (cache handle), texture_loader (PNG + ZTEX)
  audio/              # WAV decoder + software mixer (chưa có audio device)
  input/              # Key/MouseButton/Input, không phụ thuộc OS
  physics/            # Collision2D: overlap AABB + event (chưa có vật lý)
  platform/           # GLFW window adapter
  scene/              # Scene document: save/load JSON (ez_engine.Scene)
examples/
  sandbox/            # Headless minimal (không cần GPU)
  wgpu_clear/         # Sample game WGPU đầy đủ (~200 dòng gameplay)
tests/                # Test tích hợp (ECS, query, math, render_world, backend)
tools/                # ez_project.py: new/list project
```

## Phạm vi hiện tại

- Sprite 2D: transform, tint, alpha blend, camera orthographic, culling và
  batching theo texture/layer liền kề.
- Sprite sheet dạng lưới đều + animation ECS cơ bản.
- Collider AABB 2D phát event begin/stay/end, đẩy vật solid khỏi chồng lấn;
  chưa có mô phỏng vật lý (lực, ma sát, CCD).
- Asset texture: PNG (qua zigimg) và ZTEX nội bộ RGBA8/BGRA8; chưa có JPEG.
- ECS archetype-based, scheduler tuần tự có kiểm tra dependency cycle, input
  state, WAV decoder + mixer phần mềm (chưa có audio device).
- GLFW adapter dùng `Game.run`: phím, chuột, scroll, đóng cửa sổ, resize.
- Logger level/category và debug stats (frame, FPS, entity, culling, batch).
- Scene document: object sprite/obstacle/pickup, lưu/mở JSON version 1.
- Scripting Zig-native: behavior `onStart`/`onUpdate` + `Mover2D` built-in,
  đăng ký một dòng qua `Script.register`.
- Project scaffold: `zig build new -Dname=...` sinh cấu trúc project chuẩn
  (starter dùng App + Script, đã nối `wgpu_backend`).
- Chưa có: mesh/material 3D, packed atlas, audio device, vật lý mô phỏng,
  pipeline đưa scene vào runtime, CI, license file.
