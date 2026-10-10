# Screen JSON Runtime Loading Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Game example và project template nạp toàn bộ màn chơi từ `screens/screen.json` lúc runtime thay vì spawn tay trong code.

**Architecture:** Thêm `Scene.Screen` (schema JSON version 1: textures + objects + camera) vào `src/scene/scene.zig` với parse hai pha (validate hết rồi mới spawn — lỗi thì world nguyên vẹn); `Screen.load(game, io, path)` nạp texture, spawn entity + components, trả handles để `main` gắn script/systems.

**Tech Stack:** Zig 0.16.0, `zig build/test/fmt`, JSON parser của std, không thêm dep.

**Spec:** Chat 2026-10-11 (user): screens/screen.json lưu mọi thứ game example đang có (player/sprite/pickup/wall + texture + camera); main chỉ nạp screen, gắn Player script, chạy.

## Global Constraints

- Zig 0.16.0 (`build.zig.zon` minimum_zig_version).
- Không đổi schema `Scene.Document` hiện có; không đụng `Scheduler` core.
- `src/scene/scene.zig` được import `game.zig` — kiểm tra không tạo import cycle (game.zig hiện không import scene).
- Mọi task kết thúc bằng `zig build test` PASS + `zig fmt --check` sạch cho file chạm tới.
- Core lib không phụ thuộc `zgpu`/`zglfw` (loader chỉ dùng Assets/World/Game).

## Review Focus

- `screen.json` có `version != 1` phải lỗi sạch và không spawn gì — mong đợi: `error.UnsupportedSceneVersion`, `aliveCount() == 0`.
- Object trỏ texture key không khai báo phải lỗi trước khi spawn bất cứ gì — mong đợi: `error.UnknownTexture`, world nguyên vẹn (validate hai pha).
- Số liệu vô lý (size âm/bằng 0, sheet 0, fps <= 0, id trùng) phải lỗi sạch — mong đợi: `error.InvalidScreen`, world nguyên vẹn.
- File không tồn tại phải propagate lỗi đọc file, không panic — mong đợi: test load path ma trả lỗi.
- Loader phải gán đúng entity cho camera follow và Player script — mong đợi: test assert handle player trỏ entity có đủ Transform + SpriteAnimation + Collider2D.

---

### Task 1: Screen schema + parse/validate thuần túy

**Files:**
- Modify: `src/scene/scene.zig` (thêm types, KHÔNG đụng Document)
- Create: `tests/screen_test.zig`
- Modify: `build.zig` (thêm `"screen_test.zig"` vào vòng test)

**Interfaces:**
- Consumes: `std.json`, `std.testing.allocator` (parse không cần file, không cần Game)
- Produces: `Scene.ScreenData{ version: u32, textures: []TextureEntry{name, path}, objects: []ScreenObject, camera: ScreenCamera }`, `ScreenObject{ id: u32, kind: ScreenKind(player|sprite|pickup|wall), texture: []const u8, position: [2]f32, size: [2]f32, tint: [4]f32 = 1, z_index: i32 = 0, sheet: ?Sheet{columns, rows} = null, animation: ?Clip{first_frame, frame_count, fps} = null, collider: ?Collider{size: [2]f32, solid: bool = false, static: bool = false} = null }`, `ScreenCamera{ follow: ?u32 = null, speed: f32 = 0 }`, `Screen.parse(allocator, json_bytes) !Parsed` + `Screen.validate(data) !void` (`UnsupportedSceneVersion` nếu version != 1; `InvalidScreen` nếu id trùng/size <= 0/không finite/sheet 0/fps <= 0/kind-texture quy tắc: player bắt buộc có sheet+animation+collider, pickup/wall bắt buộc collider).

- [ ] **Step 1: Viết failing test**

Trong `tests/screen_test.zig`, dùng đúng JSON mẫu của game example (player/pickup/wall/sprite + camera follow id 1 speed 7):

```zig
test "screen parses example screen and validates" {
    const data = try ez_engine.Scene.Screen.parse(std.testing.allocator, example_json);
    defer data.deinit();
    try data.validate();
    try std.testing.expectEqual(@as(usize, 4), data.objects.len);
}

test "screen rejects bad version, dup ids and bad numbers" {
    // version 2 → UnsupportedSceneVersion; id trùng → InvalidScreen;
    // size âm → InvalidScreen; fps 0 → InvalidScreen
}
```

- [ ] **Step 2: Chạy test, verify fail**

Run: `zig build test`
Expected: FAIL (`Scene.Screen` chưa tồn tại).

- [ ] **Step 3: Implement schema + parse + validate trong `src/scene/scene.zig`**

Dùng `std.json.parseFromSlice` với struct khớp schema; `validate` duyệt objects kiểm tra quy tắc trên. Không đụng `Document`.

- [ ] **Step 4: Chạy suite, verify pass**

Run: `zig build test && zig fmt --check src/scene/scene.zig tests/screen_test.zig`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/scene/scene.zig tests/screen_test.zig build.zig
git commit -m "feat: add Screen JSON schema with parse and validate"
```

### Task 2: Spawn loader + fixture test với assets thật

**Files:**
- Modify: `src/scene/scene.zig` (thêm `Screen.Handles` + `load`), `src/root.zig` (re-export nếu cần — `Scene` đã export cả module nên `Scene.Screen` tự có)
- Create: `tests/fixtures/screen.json` (dùng `assets/sprite.png` có sẵn)
- Modify: `tests/screen_test.zig` (thêm test load)

**Interfaces:**
- Consumes: Task 1 (`parse`, `validate`), `Game{world, assets}`, `Assets.loadTextureFile(io, path, max)`, `RenderComponents.*`, `Collision2D.Collider2D`, `Scene.Pickup` marker mới (`pub const Pickup = struct{}`)
- Produces: `Screen.Handles{ player: ?Entity, camera_target: ?Entity }`, `Screen.load(game: *Game, io: std.Io, path: []const u8) !Handles` — đọc file (tối đa 1MB như Document), parse, validate, rồi mới: load từng texture trong map (tối đa 16MB/file như example), spawn entity theo từng object (Transform luôn có; SpriteRenderer từ texture/size/tint/z; SpriteAnimation nếu có animation (sheet bắt buộc đi kèm); Collider2D nếu có collider; `Pickup` marker nếu kind == pickup). Camera: nếu `camera.follow` trỏ id object nào thì `camera_target` là entity đó. Lỗi ở bất kỳ bước nào trước khi spawn xong object đầu tiên đều để world nguyên vẹn (nhờ validate hai pha + load texture trước khi spawn).

- [ ] **Step 1: Viết failing test**

```zig
test "screen loads fixture and spawns gameplay entities" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    const handles = try ez_engine.Scene.Screen.load(&game, test_io, "tests/fixtures/screen.json");
    // handles.player có Transform + SpriteAnimation + Collider2D; aliveCount == số object;
    // camera_target == player
}

test "screen load with unknown texture spawns nothing" {
    // fixture biến thể trỏ texture key không khai báo → error.UnknownTexture, aliveCount == 0
}

test "screen load of missing file returns error" {
    // load path không tồn tại → lỗi (không panic), aliveCount == 0
}
```

(Ghi chú: `test_io` lấy thế nào tuỳ implementer tìm trong repo — example `main` nhận `std.process.Init`; test dùng `std.testing.io` nếu tồn tại, nếu không thì mở file trực tiếp qua `std.Io`. Ghi ruling vào ledger nếu phải chọn.)

- [ ] **Step 2: Chạy test, verify fail**

Run: `zig build test`
Expected: FAIL (`Screen.load`/`Pickup` chưa tồn tại).

- [ ] **Step 3: Implement `Pickup` + `Screen.load`**

Spawn theo thứ tự objects trong file; texture load trước, entity spawn sau.

- [ ] **Step 4: Chạy suite, verify pass**

Run: `zig build test && zig fmt --check src/scene/scene.zig tests/screen_test.zig`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/scene/scene.zig tests/screen_test.zig tests/fixtures/screen.json
git commit -m "feat: spawn gameplay entities from screen JSON"
```

### Task 3: Port example sang loader

**Files:**
- Modify: `examples/wgpu_clear/main.zig`
- Create: `examples/wgpu_clear/screens/screen.json` (đúng dữ liệu example hiện tại: player 240 sheet 5x1 idle + collider 48 solid; deco 220,60 150 tint xanh z1; pickup 300,0 48 tint cam z1 collider 40; wall 0,150 100x60 tint xám z1 collider solid static; camera follow player speed 7)

**Interfaces:**
- Consumes: Task 2 (`Screen.load` → `Handles{player, camera_target}`, `Scene.Pickup`)
- Produces: example chạy y hệt cũ nhưng không còn spawn tay; `Collectible` local bị xóa, listener dùng `Scene.Pickup`.

- [ ] **Step 1: Viết `screens/screen.json` khớp example từng con số**

Textures map: `player → assets/player_sheet.png`, `deco → assets/sprite.png` (giữ nguyên relative path vì cwd khi chạy là repo root).

- [ ] **Step 2: Sửa `main.zig` dùng loader**

Xóa toàn bộ spawn tay + `Collectible`; `const handles = try Screen.load(game, init.io, "examples/wgpu_clear/screens/screen.json")`; `player.mover.entity = handles.player.?`; listener check `Scene.Pickup`; camera follow dùng `handles.camera_target.?`; giữ nguyên systems còn lại và log.

- [ ] **Step 3: Verify build + chạy thật**

Run: `zig build test && zig build wgpu-clear && timeout 8 zig build wgpu-clear-run` (nếu có display; không có thì ghi ruling bỏ qua bước chạy)
Expected: PASS + game khởi động không lỗi, log sample hiện.

- [ ] **Step 4: Commit**

```bash
git add examples/wgpu_clear/
git commit -m "refactor: example loads screen from JSON"
```

### Task 4: Template + scaffold + docs

**Files:**
- Create: `template/game/screens/screen.json`
- Modify: `template/game/src/main.zig` (dùng loader, path `screens/screen.json`, asset path `Assets/...`), `template/game/project.json` (`startup_scene` → `screens/screen.json`), `tools/scaffold.zig` (copy cả `screens/`), `README.md`, `docs/api.md`, `docs/architecture.md`, `docs/project-management.md`, `template/game/README.md`, `CHANGELOG.md`
- Delete: `template/game/editor_scene.json` (thay bằng screens/screen.json, tránh 2 nguồn sự thật)

**Interfaces:**
- Consumes: Task 2–3 (loader + JSON mẫu đã kiểm chứng ở example)

- [ ] **Step 1: Viết `template/game/screens/screen.json`**

Nội dung = bản example nhưng texture path `Assets/...`; xóa `editor_scene.json`; `project.json` trỏ `screens/screen.json`; scaffold copy `screens/` (sửa danh sách copy nếu đang liệt kê file lẻ).

- [ ] **Step 2: Sửa template `main.zig` + README template**

Main dùng loader y như example Task 3 (giữ Player script, pickup listener với `Scene.Pickup`, camera follow). README template ghi edit `screens/screen.json` thay vì `editor_scene.json`.

- [ ] **Step 3: Verify sinh project + docs**

Run: `rm -rf /tmp/ez-verify && zig build new -Dname=VerifyGame -Dworkspace=/tmp/ez-verify` rồi assert `screens/screen.json` tồn tại, không còn `editor_scene.json`, `zig fmt --check` starter sạch; chạy lại lần hai expect FAIL sạch. Cập nhật README/docs/api/architecture/project-management/CHANGELOG. Rồi `rm -rf /tmp/ez-verify`.

- [ ] **Step 4: Chạy full suite, verify pass**

Run: `zig build test && zig fmt --check src examples tests tools template`
Expected: PASS (lưu ý: file JSON trong template có placeholder thì fmt Zig sẽ lỗi — chỉ fmt file `.zig`).

- [ ] **Step 5: Commit**

```bash
git add template tools README.md docs CHANGELOG.md
git commit -m "feat: template loads screen from JSON, scaffold copies screens"
```
