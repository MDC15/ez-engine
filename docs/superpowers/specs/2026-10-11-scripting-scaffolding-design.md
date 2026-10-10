# Scripting + Scaffolding Design

> Quyết định của builder (user skip hỏi đáp). Ngày: 2026-10-11.

## Intent

Người dùng viết gameplay với ít boilerplate kiểu lib game hiện đại
(Unity `MonoBehaviour`: `onStart`/`onUpdate`), và tạo project chuẩn không cần
Python — scaffold xong là `zig build run` được ngay.

## Quyết định chính

1. **Scripting = Zig-native, không nhúng Lua.** Zig không có runtime
   reflection; dùng comptime adapter biến struct thường thành ECS system.
   Không hot-reload, không VM — ngoài scope.
2. **`src/script/script.zig` trong core lib** (không dependency mới):
   - `Script.Ctx{ world: *World, game: *Game, dt: f32 }`.
   - `Script.init(game, &behavior)` nhận mọi struct có
     `pub onUpdate(*T, *Ctx) (!void|void)`;
     `Script.initWithStart` yêu cầu thêm `pub onStart` cùng dạng
     (2 constructor tường minh vì Zig không probe được method optional
     qua behavior/lib reference cycle — xem ledger).
   - `Script.register(&scheduler, name)` Ribbon: một dòng thay cho
     `@ptrCast` + `world.get` thủ công. `Script` do user sở hữu trên stack,
     phải outlive scheduler (document + debug note, không runtime check).
   - Behavior thiếu `onUpdate` → `@compileError` với message rõ ràng.
   - Lỗi từ `onUpdate` propagate qua `Game.frame` như system thường.
3. **`Mover2D` built-in** (`entity: ?Entity = null`, `speed = 260`):
   đọc WASD + arrows qua `ctx.game.input`, normalize đường chéo, đẩy
   `Transform`. `update` trả về hướng đã normalize để behavior khác
   (vd. chọn animation clip) tái dùng. Entity null → `error.UnboundEntity`.
4. **Desktop `App` helper ngoài core lib** (`src/app/desktop.zig`, module
   `ez_app`, chỉ Linux x86_64 như `wgpu_backend`): `App.init(alloc, title,
   w, h)` dựng window → graphics → game → `SpriteBackend.init`;
   `app.run(io)`; `deinit()` (game dọn backend qua renderer, rồi mới hủy
   graphics/window). Không đưa vào `root.zig` để core build mọi target.
5. **Scaffold bằng Zig, bỏ Python**: `zig build new -Dname=X
   [-Dworkspace=Y]` chạy generator `tools/scaffold.zig`, copy từ
   `template/game/` + thế placeholder (`@NAME@`, `@TITLE@`,
   `@ENGINE_PATH@`), copy assets, tự dò fingerprint bằng
   `zig build --help` (mẹo cũ của script Python), từ chối khi thư mục đích
   đã tồn tại. Xóa `tools/ez_project.py` (lệnh `list`/`open` theo đó bỏ;
   project chỉ là thư mục).
6. **Project chuẩn sinh ra** gồm: `build.zig` (đã nối `ez_engine` +
   `wgpu_backend`, step `run`), `build.zig.zon` (+fingerprint),
   `src/main.zig` starter dùng App + Script (~120 dòng: player di chuyển +
   animation, pickup, wall, camera follow), `Assets/`, `Scenes/`,
   `project.json`, `README.md`, `.gitignore`.

## Non-goals

Lua/Wren embedding, hot reload, visual editor, 3D, thay đổi `Scheduler`
core (không đụng `UpdateFn` — Script bọc ngoài, tương thích hệ cũ).
