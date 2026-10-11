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
zig build wgpu        # Build sample sprite WGPU (cần Linux x86_64)
zig build wgpu-run    # Chạy sample, cần WSLg
zig build gl          # Build sample OpenGL (cần Linux x86_64)
zig build gl-run      # Chạy sample OpenGL, cần WSLg
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

| Target | Library + tests | `wgpu` | `gl` |
|--------|-----------------|--------|------|
| Linux x86_64 | ✅ | ✅ (cần WSLg trên WSL) | ✅ (cần WSLg trên WSL) |
| Windows / macOS / khác | ✅ | ⚠️ bỏ qua kèm warning | ⚠️ bỏ qua kèm warning |

## Tạo và quản lý project game

Tạo game project mới bằng `zig build new` (chạy từ thư mục checkout của
framework, không cần Python):

```sh
zig build new -Dname=MyFirstGame
zig build new -Dname=MyFirstGame -Dworkspace="$HOME/Games"
```

Mặc định project được tạo trong `projects/`. Lệnh sinh ra cấu trúc chuẩn
(`build.zig` đã nối `ez_engine` + `wgpu_backend`, `build.zig.zon` kèm
fingerprint, `src/main.zig` starter, `Assets/`,
`Scenes/editor_scene.json`, `project.json`, `README.md`, `.gitignore`), copy sẵn
assets mẫu. Chạy lần hai vào chỗ cũ sẽ báo lỗi sạch, không ghi đè. Trong
project mới chạy `zig build run` để build và chạy starter sample. Chi tiết
xem [docs/project-management.md](docs/project-management.md).

## Viết gameplay bằng Script

Behavior là struct thường có `pub fn onUpdate` (và `pub fn onStart` nếu cần
khởi tạo), đăng ký một dòng thay cho system viết tay. Viết `onUpdate(self,
game, dt)` để không phải chạm `Ctx`; dạng cũ `onUpdate(self, ctx)` vẫn chạy:

```zig
const Player = struct {
    mover: game.Script.Mover2D = .{},

    pub fn onUpdate(self: *Player, game: *game.Game, dt: f32) !void {
        const direction = try self.mover.update(game, dt); // WASD + arrows
        const animation = try game.world.get(self.mover.entity.?, game.RenderComponents.SpriteAnimation);
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
mặc định 260 đơn vị/giây qua `mover.update(game, dt)`. Chi tiết API xem
[docs/api.md](docs/api.md).

## Vật lí & va chạm

`Physics2D` tích phân vận tốc vào `Transform` (trọng lực, giảm tốc, độ nảy);
`Collision2D` đẩy các vật `solid` ra và dội vận tốc theo `restitution`. Lọc
va chạm bằng layer/mask: mỗi collider mang một `layer`, và chỉ đụng với layer
có trong `collides_with` của nó (hai bên phải cùng đồng ý):

```zig
// Player: layer 1, đụng mọi thứ. Wall: layer 2, chỉ đụng player + wall.
try world.add(wall, game.Collision2D.Collider2D{
    .size = .{ .x = 64, .y = 64 },
    .solid = true,
    .is_static = true,
    .layer = 2,
    .collides_with = game.Collision2D.layerBit(1) | game.Collision2D.layerBit(2),
});

// Vật rơi: chạy Physics2D.System TRƯỚC Collision2D.System.
try world.add(box, game.Physics2D.Velocity{});
try world.add(box, game.Physics2D.RigidBody2D{ .restitution = 0.4 });
```

Chi tiết trong [docs/api.md](docs/api.md).

## Input

`game.input` giữ trạng thái input theo frame; lớp GLFW đổ sự kiện vào đó.
Tra phím bằng tên (enum `Key` phủ đủ bộ mã GLFW), hoặc qua hành động có tên
trong `game.input_map`:

```zig
// Theo phím trực tiếp.
if (game.input.justPressed(.space)) jump();
if (game.input.isDown(.left_shift)) sprint();
const dx = game.input.mouse_delta_x;

// Theo hành động / trục có tên.
try game.input_map.bind("jump", .{ .key = .space });
try game.input_map.bind("jump", .{ .key = .w });
try game.input_map.bind("move_left", .{ .key = .a });
try game.input_map.bind("move_right", .{ .key = .d });

if (game.input_map.justPressed(&game.input, "jump")) jump();
const move = game.input_map.axis(&game.input, "move_left", "move_right"); // -1..1
```

`bind` nhận `ez_engine.InputBinding` (`key`, `key_code` hoặc `mouse`) và copy
tên hành động, nên đổi phím chỉ sửa bảng bind — không đụng gameplay.
`justPressed`/`justReleased` chỉ đúng ở frame có cạnh lên/xuống.

## Game loop & dọn rác

`Game` có sẵn một `GameLoop`: mặc định `variable` (mỗi frame một bước), hoặc
`fixed` để bước cố định — hợp với mô phỏng cần ổn định:

```zig
game.loop = try ez_engine.GameLoop.initFixed(1.0 / 60.0, 8); // 60 Hz, tối đa 8 bước/frame
game.loop.time_scale = 0.5; // slow-motion (0 hoặc âm = đóng băng)
game.loop.pause();          // vẫn present, không mô phỏng
game.loop.unpause();
game.loop.stop();           // vòng `Game.run` dừng hẳn
```

`Game.tick(frame_seconds)` chạy 0..N bước mô phỏng rồi present một lần;
frame-time được kẹp ở `loop.max_frame_seconds` (mặc định 0.25s) để tránh
"spiral of death". `Game.frame(dt)` vẫn giữ nguyên hành vi cũ (một update +
một present).

Cuối mỗi frame, rác được dọn tự động:

```zig
try game.destroyDeferred(entity);      // hủy ở ranh giới frame (an toàn khi đang query)
const tmp = try game.frameAllocator().alloc(u8, 128); // cấp tạm, tự thu hồi cuối frame
```

Trong behavior, dùng `ctx.frame_allocator` cho dữ liệu chỉ sống trong frame.
`World.destroy` vẫn hủy ngay lập tức khi bạn chắc chắn không đang lặp query.

## Sample WGPU

Sample nằm ở `examples/wgpu` (gameplay thuần túy; backend render nằm
trong lib). `assets/player_sheet.png` có một frame idle và bốn frame đi bộ.
Dùng WASD để di chuyển, chạm vật phẩm màu cam để nhặt. Khi chạm hoặc rời
tường, log `begin`/`end` hiện kèm ID entity; F3 bật/tắt frame stats. Camera
bám theo nhân vật; nhấn Escape hoặc đóng cửa sổ để thoát.

## Sample OpenGL

Sample thứ hai nằm ở `examples/gl` (gameplay y hệt sample WGPU; backend
render nằm trong `src/gfx/gl`). Build bằng `zig build gl`, chạy bằng:

```sh
GALLIUM_DRIVER=d3d12 MESA_D3D12_DEFAULT_ADAPTER_NAME=NVIDIA zig build gl-run
```

Trên WSL, Dawn không có Vulkan tăng tốc phần cứng nên sample WGPU phải chạy
trên CPU; driver OpenGL-on-D3D12 của Mesa (`d3d12`) mới chạm tới được GPU rời.
Hai biến môi trường chỉ chọn adapter — chọn driver vẫn là chuyện của môi
trường, không phải của code. Không đặt biến, GL rơi về llvmpipe (phần mềm) và
app log cảnh báo.

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
  gfx/gl/             # SpriteBackend OpenGL (module riêng, chỉ Linux x86_64)
  asset/              # Manager (cache handle), texture_loader (PNG + ZTEX)
  audio/              # WAV decoder + software mixer (chưa có audio device)
  input/              # Key/MouseButton/Input + InputMap, không phụ thuộc OS
  physics/            # Collision2D (AABB + layer/mask) + Physics2D (velocity/gravity)
  platform/           # GLFW window adapter
  scene/              # Scene document: save/load JSON (ez_engine.Scene)
  script/             # Script behaviors (onStart/onUpdate) + Mover2D
  app/                # App helper (module riêng ez_app, chỉ Linux x86_64)
template/game/        # Project chuẩn cho `zig build new` (starter App + Script)
examples/
  wgpu/               # Sample game WGPU (~160 dòng gameplay)
  gl/                 # Sample game OpenGL (gameplay y hệt WGPU)
tests/                # Test tích hợp (ECS, query, math, render_world, backend, script, mover, input)
tools/                # scaffold.zig: `zig build new` generator
```

## Phạm vi hiện tại

- Sprite 2D: transform, tint, alpha blend, camera orthographic, culling và
  batching theo texture/layer liền kề.
- Sprite sheet dạng lưới đều + animation ECS cơ bản.
- Collider AABB 2D phát event begin/stay/end, đẩy vật solid khỏi chồng lấn;
  chưa có mô phỏng vật lý (lực, ma sát, CCD).
- Asset texture: PNG (qua zigimg) và ZTEX nội bộ RGBA8/BGRA8; chưa có JPEG.
- ECS archetype-based, scheduler tuần tự có kiểm tra dependency cycle, input
  state, action/axis mapping có tên (`InputMap`), WAV decoder + mixer phần
  mềm (chưa có audio device).
- GLFW adapter dùng `Game.run`: phím, chuột, scroll, đóng cửa sổ, resize.
- Logger level/category và debug stats (frame, FPS, entity, culling, batch).
- Scene document: object sprite/obstacle/pickup, lưu/mở JSON version 1.
- Scripting Zig-native: behavior `onStart`/`onUpdate` + `Mover2D` built-in,
  đăng ký một dòng qua `Script.register`.
- Project scaffold: `zig build new -Dname=...` sinh cấu trúc project chuẩn
  (starter dùng App + Script, đã nối `wgpu_backend`).
- Chưa có: mesh/material 3D, packed atlas, audio device, vật lý mô phỏng,
  pipeline đưa scene vào runtime, CI, license file.
