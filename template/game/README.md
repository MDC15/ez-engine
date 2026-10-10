# @NAME@

Game project created with ez-engine (`zig build new`).

## Build and run (Linux x86_64, WSLg on WSL)

```sh
zig build run
```

## Layout (kiểu Unity, gọn hơn)

```text
src/main.zig          # bootstrap: window → load scene → spawn → gắn scripts → run
src/scripts/player.zig  # MonoBehaviour Player (WASD/arrows + animation)
src/scripts/pickup.zig  # tag Collectible + PickupListener (nhặt đồ)
Scenes/editor_scene.json  # Scene: vị trí + kích thước mọi object
project.json          # startup_scene phải khớp scene main nạp
Assets/               # textures
```

## Where to go next

- Đổi gameplay bằng cách sửa `Scenes/editor_scene.json` (vị trí,
  kích thước), không cần đụng code. Mỗi object nở thành 1 entity:
  `sprite` → player, `pickup` → vật phẩm, `obstacle` → tường tĩnh.
- Viết behavior mới: tạo struct có `pub fn onUpdate` trong
  `src/scripts/`, rồi `Script.init(&game, &behavior)` +
  `register(&game.scheduler, "Name")` trong `main.zig` (xem
  `player.zig`). Cần `onStart` thì dùng `initWithStart`.
- Put textures in `Assets/`, scene data in `Scenes/` (`ez_engine.Scene`
  format, version 1; sample at `Scenes/editor_scene.json`). Project metadata is in `project.json`.
