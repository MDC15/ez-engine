# Scripting + Scaffolding Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Người dùng viết gameplay bằng behavior `onStart`/`onUpdate` và tạo project chuẩn bằng `zig build new`.

**Architecture:** `Script` là comptime adapter bọc struct thường thành ECS system (không đụng `Scheduler` core); `App` gom boilerplate desktop vào một module riêng Linux-only; generator Zig copy `template/game/` + thế placeholder.

**Tech Stack:** Zig 0.16.0, `zig build/test/fmt`, deps hiện có (không thêm dep).

**Spec:** `docs/superpowers/specs/2026-10-11-scripting-scaffolding-design.md`

## Global Constraints

- Zig 0.16.0 (`build.zig.zon` minimum_zig_version).
- Không đổi `Scheduler.UpdateFn` hay chữ ký ECS hiện có; system viết tay cũ vẫn chạy.
- Không thêm dependency mới vào `build.zig.zon`.
- Mọi task kết thúc bằng `zig build test` PASS + `zig fmt --check` sạch cho file chạm tới.
- Core lib (`ez_engine` root) không được phụ thuộc `zgpu`/`zglfw`.

## Review Focus

- Lỗi từ behavior `onUpdate` phải abort `Game.frame` với đúng error đó, như system viết tay — mong đợi: frame trả error, không swallow.
- `onStart` của system register sau frame đầu không bao giờ chạy — mong đợi: được document + có test khóa hành vi hiện tại.
- `Mover2D` chưa gán entity phải báo lỗi sạch, không crash — mong đợi: `error.UnboundEntity`.
- `zig build new` vào thư mục đã tồn tại phải fail sạch, không ghi đè — mong đợi: lỗi rõ ràng, project cũ nguyên vẹn.
- Project sinh ra phải chứa đúng đường dẫn engine và fingerprint hợp lệ — mong đợi: `build.zig`/`build.zig.zon` có nội dung thay thế đầy đủ, `zig fmt --check` starter sạch.

---

### Task 1: Script core (`onStart`/`onUpdate` behaviors)

**Files:**
- Create: `src/script/script.zig`, `tests/script_test.zig`
- Modify: `src/root.zig:35-36` (thêm `pub const Script`), `build.zig:46` (thêm `"script_test.zig"`)

**Interfaces:**
- Consumes: `World`, `Game` (lấy `*Game` từ caller), `Scheduler.addSystem(name: []const u8, context: ?*anyopaque, update: UpdateFn) !SystemId`
- Produces: `Script.Ctx{ world: *World, game: *Game, dt: f32 }`; `Script{ init(game: *Game, behavior: anytype) Script, initWithStart(game: *Game, behavior: anytype) Script, register(self: *Script, sched: *Scheduler, name: []const u8) !void }`. Behavior bắt buộc `pub onUpdate(*T, *Ctx) (!void|void)`; `initWithStart` yêu cầu thêm `pub onStart` cùng dạng. `onStart` chạy khi `game.frame_index == 0`. `Script` do caller sở hữu, phải outlive scheduler (ghi trong doc comment).

- [ ] **Step 1: Viết failing test**

Trong `tests/script_test.zig`:

```zig
test "script calls onStart once and onUpdate every frame" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    var behavior = Counter{};
    var script = ez_engine.Script.init(&game, &behavior);
    try script.register(&game.scheduler, "Counter");
    try game.frame(1.0 / 60.0);
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), behavior.starts);
    try std.testing.expectEqual(@as(u32, 2), behavior.updates);
    try std.testing.expect(behavior.saw_game);
}
```

(`Counter` có `onStart` set `starts += 1`, `onUpdate` set `updates += 1` và `saw_game = (ctx.game.frame_index >= 0)`.)

- [ ] **Step 2: Chạy test, verify fail**

Run: `zig build test`
Expected: FAIL (`Script` chưa tồn tại).

- [ ] **Step 3: Implement `src/script/script.zig`**

Comptime adapter: `init` kiểm tra `onUpdate`, bọc optional `onStart`; `register` gọi `sched.addSystem(name, self, systemFn)`; `systemFn` cast ctx về `*Script`, dựng `Ctx`, gọi `onStart` nếu `frame_index == 0` rồi gọi `onUpdate`. Thêm `pub const Script` vào `src/root.zig`, thêm test vào vòng lặp `build.zig:46`.

- [ ] **Step 4: Thêm test khóa Review Focus**

```zig
test "script error aborts frame and late onStart never runs" {
    // behavior onUpdate trả error.Boom → expectError khi game.frame
    // register behavior thứ hai SAU 1 frame → starts vẫn 0 sau frame tiếp
}
```

- [ ] **Step 5: Chạy suite, verify pass**

Run: `zig build test && zig fmt --check src/script/script.zig tests/script_test.zig src/root.zig`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/script/script.zig tests/script_test.zig src/root.zig build.zig
git commit -m "feat: add Script behavior system with onStart/onUpdate"
```

### Task 2: `Mover2D` built-in

**Files:**
- Modify: `src/script/script.zig` (thêm `Mover2D`)
- Create: `tests/mover_test.zig`
- Modify: `build.zig:46` (thêm `"mover_test.zig"`)

**Interfaces:**
- Consumes: Task 1 (`Script.Ctx` với `ctx.game.input`, `ctx.world`, `ctx.dt`)
- Produces: `Script.Mover2D{ entity: ?Entity = null, speed: f32 = 260, update(self: *Mover2D, ctx: *Ctx) !Vec2 }` — đọc WASD + arrows (`.key(.a/.d/.s/.w/.left/.right/.up/.down).down`), normalize chéo hệ số `0.70710678`, cộng `direction * speed * dt` vào `Transform.position` của entity, trả về direction. Entity null → `error.UnboundEntity`.

- [ ] **Step 1: Viết failing test**

```zig
test "mover2d moves bound entity and rejects unbound" {
    // Game headless + entity có Transform tại (0,0) + Mover2D{ .entity = e }
    // game.input.setKey(.d, true); game.frame(1/60) → position.x == 260/60
    // Mover2D{} (entity null) update trực tiếp → error.UnboundEntity
}
```

- [ ] **Step 2: Chạy test, verify fail**

Run: `zig build test`
Expected: FAIL (`Mover2D` chưa tồn tại).

- [ ] **Step 3: Implement `Mover2D` trong `src/script/script.zig`**

Dùng `ctx.world.get(entity, RenderComponents.Transform)` (import tương đối `../gfx/render_components.zig`, `../ecs/entity.zig`, `../math/vec2.zig`).

- [ ] **Step 4: Chạy suite, verify pass**

Run: `zig build test && zig fmt --check src/script/script.zig tests/mover_test.zig`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/script/script.zig tests/mover_test.zig build.zig
git commit -m "feat: add Mover2D scripted movement behavior"
```

### Task 3: Desktop `App` helper

**Files:**
- Create: `src/app/desktop.zig`
- Modify: `build.zig` (module `ez_app` sau `wgpu_backend`, imports `ez_engine`/`zglfw`/`zgpu`/`glfw_window`/`wgpu_backend`; KHÔNG export từ root), `examples/wgpu_clear/main.zig` (dùng `App`, giữ gameplay cũ)

**Interfaces:**
- Consumes: `WindowAdapter.init(w, h, title)`, `zgpu.GraphicsContext.create`, `SpriteBackend.init(allocator, graphics, assets)`, `Game.init`, `Game.run(io, window)`
- Produces: `App{ game: Game, init(allocator: Allocator, title: [:0]const u8, width: u32, height: u32) !App, run(self: *App, io: std.Io) !void, deinit(self: *App) void }`. Thứ tự init: window → graphics → game → backend (`game.renderer = backend.backend()`); deinit: `game.deinit()` (dọn backend qua renderer) → `graphics.destroy` → `window.deinit()`.

- [ ] **Step 1: Tạo `src/app/desktop.zig` với `App` đầy đủ**

Chuyển nguyên khối setup từ `examples/wgpu_clear/main.zig` (window/graphics) vào `init`; dùng `SpriteBackend.init` có sẵn.

- [ ] **Step 2: Port example sang `App`, giữ nguyên gameplay**

`main` còn: `App.init(&app, ...)` → spawn entities/systems cũ → `app.run(init.io)` → `app.deinit()`. Xóa `GlfwWindow`/`zgpu.GraphicsContext`/`SpriteBackend` setup khỏi example.

- [ ] **Step 3: Verify build desktop + suite**

Run: `zig build test && zig build wgpu-clear`
Expected: PASS cả hai (App chỉ được compile qua example trên Linux x86_64).

- [ ] **Step 4: Commit**

```bash
git add src/app/desktop.zig build.zig examples/wgpu_clear/main.zig
git commit -m "feat: add desktop App helper, example uses it"
```

### Task 4: Viết gameplay example bằng Script (dogfood)

**Files:**
- Modify: `examples/wgpu_clear/main.zig`

**Interfaces:**
- Consumes: Task 1 (`Script`), Task 2 (`Mover2D.update` trả về direction), Task 3 (`App`)

- [ ] **Step 1: Viết `Player` behavior thay `PlayerController`**

```zig
const Player = struct {
    mover: ez.Script.Mover2D = .{},
    idle_clip: AnimClip = .{ .first_frame = 0, .frame_count = 1, .frames_per_second = 1 },
    walk_clip: AnimClip = .{ .first_frame = 1, .frame_count = 4, .frames_per_second = 8 },
    fn onUpdate(self: *Player, ctx: *ez.Script.Ctx) !void {
        const dir = try self.mover.update(ctx);
        if (keyDown(ctx, escape)) ctx.game.running = false;
        const anim = try ctx.world.get(self.mover.entity.?, Animation);
        anim.play(if (dir.x == 0 and dir.y == 0) self.idle_clip else self.walk_clip);
    }
};
```

(`keyDown` đọc `ctx.game.input.keyCode`; Escape = 256 nhưng dùng `ez.Key.escape`.) Gán `mover.entity` sau khi spawn; một `Script.init/register` thay `addSystem` thủ công. Giữ nguyên pickup listener, camera follow, debug reporter systems.

- [ ] **Step 2: Verify**

Run: `zig build test && zig build wgpu-clear && zig fmt --check examples/wgpu_clear/main.zig`
Expected: PASS; example ngắn hơn rõ rệt, hành vi giữ nguyên (WASD, pickup, wall, F3, Escape).

- [ ] **Step 3: Commit**

```bash
git add examples/wgpu_clear/main.zig
git commit -m "refactor: example gameplay uses Script behaviors"
```

### Task 5: Scaffold `zig build new` + project chuẩn

**Files:**
- Create: `template/game/build.zig`, `template/game/build.zig.zon`, `template/game/src/main.zig`, `template/game/Scenes/editor_scene.json`, `template/game/project.json`, `template/game/README.md`, `template/game/.gitignore`, `tools/scaffold.zig`
- Modify: `build.zig` (options `-Dname`/`-Dworkspace`, scaffold exe, step `new`), `README.md`, `docs/api.md`, `docs/project-management.md`, `docs/architecture.md` (mục scripting), `CHANGELOG.md`

**Interfaces:**
- Consumes: Task 1–3 (starter dùng `App` + `Script.Mover2D` + animation/pickup/wall/camera như example Task 4, ~120 dòng)
- Produces: `zig build new -Dname=Foo [-Dworkspace=DIR]` sinh project đầy đủ và in bước tiếp theo; chạy lần hai vào chỗ cũ → lỗi sạch không ghi đè.

Placeholder trong template: `@NAME@` (tên hiển thị + window title), `@ENGINE_PATH@` (relative path từ project tới framework, tính lúc generate), deps `zglfw`/`zgpu`/`dawn` pin y nguyên `build.zig.zon` của repo. Generator chạy `zig build --help` với cwd=target, đọc `suggested value: 0x…` rồi cập nhật fingerprint trong manifest. Assets copy từ repo `assets/` lúc generate. `project.json` giữ `{format_version: 1, engine: "ez-engine", startup_scene}`.

- [ ] **Step 1: Viết template starter `template/game/src/main.zig`**

Dùng `App` + `Player` script (Mover2D + 2 clips) + pickup + wall + camera follow + F3 đã có ở example; asset path `Assets/...`; window title `@TITLE@`.

- [ ] **Step 2: Viết các file template còn lại + `tools/scaffold.zig`**

Generator: tạo target rỗng thì fail `Project directory already exists`; copy cây template với thay placeholder; copy `assets/*` → `Assets/`; dò fingerprint; in `Next: cd ... && zig build run`.

- [ ] **Step 3: Nối generator vào build.zig**

`build.zig`: options `name` (bắt buộc khi chạy `new`), `workspace` (mặc định `projects/`); compile `tools/scaffold.zig` thành exe, step `new` chạy exe với args; gỡ tiện ích quản lý project cũ.

- [ ] **Step 4: Verify sinh project thật**

Run: `rm -rf /tmp/ez-verify && zig build new -Dname=VerifyGame -Dworkspace=/tmp/ez-verify && grep -c ENGINE_SUBSTITUTED /tmp/ez-verify/VerifyGame/build.zig` (expect 0 — placeholder đã thay hết), kiểm tra `fingerprint = 0x` có trong zon, `zig fmt --check` starter sạch, chạy lại lần hai expect FAIL sạch. Rồi `rm -rf /tmp/ez-verify`.

- [ ] **Step 5: Cập nhật docs + commit**

README (mục project/scripting mới), `docs/api.md` (+Script/App/Mover2D), `docs/project-management.md` (flow `zig build new`), `docs/architecture.md` (+mục scripting), CHANGELOG (added/removed).

```bash
git add template tools build.zig README.md docs CHANGELOG.md
git commit -m "feat: zig build new scaffolding and standard project template"
```
