# CLI Toolchain + Web Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bản 0.0.1: từ một máy Linux, người dùng tạo/xóa/list/version project game bằng toolchain CLI, sinh project hoàn chỉnh (`project.json` v2), `zig build run` chạy desktop Linux, `zig build web`/`web-run` build + chạy bản web trên Chrome/Edge, và có bundle tĩnh deploy được kèm hướng dẫn host.

**Architecture:** Tái dùng backend WGPU qua nhánh emscripten của `zgpu` (canvas `#canvas`, không viết renderer mới). Web chạy bằng `emscripten_set_main_loop` gọi `game.frame(dt)`, input từ callback HTML5 → `Platform.feedInput`. `build.zig` phân nhánh theo target: native → link zglfw/zdawn/X11/dawn; `wasm32-emscripten` → `zemscripten` sinh `emcc` với `-sASYNCIFY`, preload `Assets/`+`Scenes/`. CLI là một exe `tools/ez.zig` với subcommand, phơi qua bước build `new|delete|list|version`.

**Tech Stack:** Zig 0.16.0, `zgpu` 0.12.0-dev (emscripten path sẵn có), `zemscripten` + `emsdk` (mới), `emcc`/`emrun`, Chrome/Edge để nghiệm thu web.

**Spec:** `docs/superpowers/specs/2026-10-10-cli-toolchain-web-build-design.md`

## Global Constraints

- Zig 0.16.0 (`minimum_zig_version`), không thêm bước Python.
- Core lib (`ez_engine` root) KHÔNG phụ thuộc `zgpu`/`zglfw`/emscripten — mọi module web/platform là module riêng chỉ wire khi target phù hợp.
- Mỗi task kết thúc bằng `zig build test` PASS + `zig fmt --check` sạch cho file chạm tới (trừ Task 1 spike, chạy `zig fmt --check` trên file spike).
- Nghiệm thu web = Chrome/Edge trên máy Linux host (WSLg hoặc headless không cần — chỉ cần mở được tab). Firefox/Safari best effort, không phải tiêu chí.
- Web cần Emscripten; dùng `zemscripten.activateEmsdkStep` để có emsdk (tải về khi chạy lần đầu).
- `project.json` là metadata cho generator; runtime/build KHÔNG đọc nó.
- Version: toolchain và project mới = `0.0.1`; `ez_engine` giữ `0.1.0-dev`.
- `zig build new` hiện có phải giữ hành vi (fail sạch khi dir tồn tại, không ghi đè, fingerprint được patch).

## Review Focus

- `zig build new` vào thư mục đã tồn tại → fail sạch, project cũ nguyên vẹn, không ghi đè.
- `zig build delete` không `-Dforce=true` hoặc project nằm ngoài workspace → từ chối, không xóa gì.
- Core lib + `zig build test` phải không đổi khi thêm module web/emsdk — web chỉ compile khi `-Dtarget=wasm32-emscripten`.
- Đổi `zig build new` → `zig build delete`/`list` với cùng `-Dname` phải không xóa nhầm sang project khác.
- `list` khi workspace rỗng → in ra thông báo thân thiện, exit code 0.

---

### Task 1: Spike web (chứng minh `wgpu_backend` + `zgpu` vẽ được sprite trong Chrome)

Throwaway-proof: không cần test unit; đích là một sprite màu hiện đúng trong tab Chrome khi chạy `zig build web-run -Dtarget=wasm32-emscripten` từ repo engine. Kết quả cho biết các flag/phiên bản cần có, và nếu emscripten path của `zgpu` 0.12 không dùng được thì dừng plan (báo user, đề xuất đổi design).

**Files:**
- Create: `examples/web_probe/src/main.zig`, `examples/web_probe/index.html` (shell có `<canvas id="canvas">`), `examples/web_probe/build.zig` (hoặc nhánh web trong `build.zig` chính — chọn 1, ưu tiên nhánh trong `build.zig` chính để dùng chung module `wgpu_backend` + `ez_engine`)
- Modify: `build.zig.zon` (thêm `zemscripten`, `emsdk`), `build.zig` (nhánh emscripten: static lib → `emccStep` → step `web`/`web-run`; preload `assets/` + scene probe; `-sASYNCIFY`)

**Interfaces:**
- Produces: các bước build mẫu cho emscripten dùng lại ở Task 2–3: `zemscripten.activateEmsdkStep(b)`, `emccDefaultFlags(b.allocator, .{ .optimize = optimize })`, `emccDefaultSettings(..., .{ .optimize = optimize })` + `ASYNCIFY`/`ALLOW_MEMORY_GROWTH` + `FILESYSTEM`, `emccStep(b, &.{}, &.{wasm_lib}, .{ .preload_paths = &.{Assets}, .out_file_name = "probe.html", .shell_file_path = ... })`, `emrunStep(...)`. Cần `-sASYNCIFY` vì `zgpu` dùng `emscripten_sleep` (xem `src/zgpu.zig:157,237,1127`).

- [ ] **Step 1: Thêm deps vào `build.zig.zon`**
  - [ ] Lấy URL/hash: `zig fetch --save=zemscripten https://github.com/zig-gamedev/zemscripten/archive/...tar.gz` và `zig fetch --save=emsdk https://github.com/emscripten-core/emsdk/archive/refs/tags/4.0.3.tar.gz` (theo README zemscripten).
- [ ] **Step 2: Viết probe game nhỏ** (`examples/web_probe/src/main.zig`): `main(init)` dựng `zgpu.GraphicsContext.create` với `WindowProvider` chỉ cần `fn_getTime = emscripten_performance_now` + `fn_getFramebufferSize` đọc kích thước canvas; `SpriteBackend.init`; tạo 1 entity `Transform` + `SpriteRenderer` với texture lấy từ 1 file PNG nhỏ trong `assets/`; vòng lặp `emscripten_set_main_loop` gọi `game.frame(dt)`.
- [ ] **Step 3: Nhánh emscripten trong `build.zig`** + shell `index.html` có `<canvas id="canvas" style="width:100%;height:100%">`; preload path trỏ `assets/` (tên hằng của `emcc --preload-file`).
- [ ] **Step 4: Chạy thử — mở Chrome**
  - [ ] RUN: `zig build web-run -Dtarget=wasm32-emscripten` → emsdk tự tải, trang mở trong Chrome.
  - [ ] Expected: một sprite hiển thị trên nền được clear; console không có lỗi WebGPU. Nếu fail vì core API (Asyncify/JSPI/`std.Io` dưới emscripten), ghi rõ vào `docs/superpowers/plans/spike-web-findings.md` và dừng plan (báo user).
- [ ] **Step 5: Ghi findings + commit**
  - [ ] Lưu kết quả (flag emcc, phiên bản emsdk cần, API vướng, kích thước bundle) vào `docs/superpowers/plans/spike-web-findings.md`.
  - [ ] COMMIT: `git add examples/web_probe build.zig build.zig.zon docs/superpowers/plans/spike-web-findings.md && git commit -m "spike: engine renders a sprite in the browser via emscripten"`

### Task 2: Module web app `ez_app_web` trong engine

**Files:**
- Create: `src/app/web.zig`
- Modify: `build.zig` (module `ez_app_web` khi target emscripten; sample `examples/web_probe` dùng nó), `src/gfx/renderer.zig` (không đổi — kiểm tra Backend vtable đủ)

**Interfaces:**
- Consumes: `zgpu.GraphicsContext.create(allocator, WindowProvider{ .window=anyopaque, .fn_getTime, .fn_getFramebufferSize }, .{})` (emscripten chỉ cần 2 hàm này — xác nhận từ `src/zgpu.zig:21-71,1639-1753`); `SpriteBackend.init(allocator, graphics, &game.assets)`; `Game.init/frame/deinit`; `Platform.feedInput(&game.input, ev)`; emscripten HTML5 externs.
- Produces: `src/app/web.zig` (module `ez_app_web`) với `pub const App`:
  - `init(self: *App, allocator: std.mem.Allocator) !void` — canvas `#canvas` (giả định shell có), `emscripten_get_canvas_element_size` đọc kích thước; dựng graphics → game → backend.
  - `start(self: *App) void` — `emscripten_set_main_loop(loopFn, 0, 1)`; mỗi frame tính `dt` từ `emscripten_get_now()`, update `game.framebuffer_extent` từ canvas, gọi `game.frame(dt)`.
  - `deinit(self: *App) void`.
  - Input callbacks (keydown/keyup/mousedown/mouseup/mousemove/wheel) đăng ký lúc `init`, ánh xạ mã phím web → `ez_engine.Key` cho bộ phím template dùng (A–Z, 0–9, arrows, space, escape, F1–F12, modifiers) → `Platform.feedInput`.
  - Không dùng `Platform.Window` (không vòng lặp blocking); không dùng `std.process.Args` ngoài mức tối thiểu.

- [ ] **Step 1: Viết `src/app/web.zig`** hoàn chỉnh (compile-only; không tách test unit vì phụ thuộc emscripten externs — verification là compile cho target emscripten ở Step 3). Không export từ `src/root.zig`; chỉ wire ở `build.zig` như `wgpu_backend`.
- [ ] **Step 2: Wire `ez_app_web` trong `build.zig`** — chỉ khi `target.result.os.tag == .emscripten`: tạo module với imports (`ez_engine`, `zgpu`, `wgpu_backend`); sửa `examples/web_probe` để dùng `App` này thay cho code tự viết ở Task 1.
- [ ] **Step 3: Verify native không hỏng + web compile**
  - [ ] RUN: `zig build test` → PASS nguyên suite (module web không được reference khi native).
  - [ ] RUN: `zig build web-run -Dtarget=wasm32-emscripten` (từ repo) → sprite hiện trong Chrome; WASD chưa cần (chưa có Mover2D trong probe).
  - [ ] RUN: `zig fmt --check src/app/web.zig build.zig examples/web_probe/src/main.zig`
- [ ] **Step 4: Commit**
  - [ ] `git add src/app/web.zig build.zig examples/web_probe && git commit -m "feat: emscripten web app module (ez_app_web) for the engine"`

### Task 3: Template project hoàn chỉnh + step web

**Files:**
- Modify: `template/game/build.zig`, `template/game/build.zig.zon`, `template/game/project.json`, `template/game/src/main.zig`, `template/game/README.md`, `tools/scaffold.zig`
- Modify: `build.zig` (nếu `tools/scaffold.zig` đổi tên file — Task 4), `docs/project-management.md`
- Create: `template/game/src/app_web.zig`? KHÔNG — web App nằm trong engine (`ez_app_web`); template chỉ dùng module.

**Interfaces:**
- Consumes: Task 2 (`ez_app_web` module — template dùng `engine.path("src/app/web.zig")` cho nhánh web, giống cách dùng `wgpu_backend` hiện tại), `tools/scaffold.zig` (Task 4 thay thế, nhưng task này vẫn cần generator hiện có để sinh project mới khi verify).
- Produces: template mới:
  - `project.json` v2:
    ```json
    {
      "format_version": 2,
      "name": "@NAME@",
      "version": "@VERSION@",
      "engine": { "name": "ez-engine", "version": "0.1.0-dev" },
      "startup_scene": "Scenes/editor_scene.json",
      "window": { "width": @WINDOW_WIDTH@, "height": @WINDOW_HEIGHT@, "title": "@TITLE@" }
    }
    ```
    với mặc định `@VERSION@`=`0.0.1`, `@WINDOW_WIDTH@`=`1280`, `@WINDOW_HEIGHT@`=`720` (generator điền, runtime không đọc).
  - `build.zig`: bỏ `@panic`; nhánh `.emscripten` → `emccStep` (zemscripten) preload `Assets`+`Scenes`, `out_file_name = "<slug>.html"`, shell có canvas; step `web` (install vào `zig-out/web`) + `web-run` (`emrunStep`); nhánh còn lại giữ desktop như hiện tại (giữ check Linux x86_64 cho desktop).
  - `build.zig.zon`: thêm `zemscripten` + `emsdk` dep; `.version = "0.0.1"`.
  - `src/main.zig`: tách gameplay chung thành hàm `setupGame(game: *ez_engine.Game, io: std.Io) !void` (giữ nguyên code step 2–4 hiện có); `main` rẽ nhánh comptime `.emscripten` → `ez_app_web` (`WebApp.init` → `setupGame` → `start`) else desktop `App` (như hiện tại).
  - Placeholder mới: `@VERSION@`, `@WINDOW_WIDTH@`, `@WINDOW_HEIGHT@`.

- [ ] **Step 1: Nâng template files** (build.zig/b`.zon`/project.json/main.zig/README) theo Interfaces; giữ nguyên `src/scripts/`, `Scenes/`, `Assets/` copy từ repo.
- [ ] **Step 2: Cập nhật `tools/scaffold.zig`** để thay `@VERSION@`/`@WINDOW_WIDTH@`/`@WINDOW_HEIGHT@` (mặc định 0.0.1/1280/720), và đổi anchor fingerprint trong `patchFingerprint` từ `"    .version = \"0.1.0\",\n"` → `"    .version = \"0.0.1\",\n"`.
- [ ] **Step 3: Verify sinh project + desktop + web**
  - [ ] RUN: `rm -rf /tmp/ezv && zig build new -Dname=Tester -Dworkspace=/tmp/ezv` → expect thành công, `project.json` chứa `"version": "0.0.1"`, không còn placeholder, fingerprint `0x` có trong zon.
  - [ ] RUN: `cd /tmp/ezv/Tester && zig build run` → cửa sổ Linux mở (như cũ).
  - [ ] RUN: `cd /tmp/ezv/Tester && zig build web-run -Dtarget=wasm32-emscripten` → browser Chrome mở starter, WASD di chuyển nhân vật (giống desktop).
  - [ ] RUN: `zig build test` (repo) vẫn PASS; `zig fmt --check` template files sạch.
- [ ] **Step 4: Commit**
  - [ ] `git add template tools/scaffold.zig build.zig docs && git commit -m "feat: complete project template with web build (project.json v2)"`

### Task 4: CLI toolchain `new | delete | list | version`

**Files:**
- Create: `tools/ez.zig` (gộp từ `tools/scaffold.zig`)
- Delete: `tools/scaffold.zig`
- Modify: `build.zig` (compile `tools/ez.zig`; step `new`, `delete`, `list`, `version`; options `-Dname`, `-Dworkspace`, `-Dforce`), `docs/project-management.md`, `README.md`
- Test: không test unit — verify bằng lệnh shell (Review Focus 1–5).

**Interfaces:**
- Consumes: `tools/scaffold.zig` logic hiện có (slugify/identifier/substitute/patchFingerprint), `template/` như Task 3.
- Produces: `tools/ez.zig` với `main` parse subcommand đầu tiên:
  - `ez new --name N [--workspace W] [--engine ROOT]` — hành vi y hệt scaffold hiện tại + thay placeholder mới (Task 3).
  - `ez delete --name N [--workspace W] [--engine ROOT] --force` — resolve `$workspace/$slug`; từ chối khi không `--force` (in rõ sẽ xóa gì) hoặc path đích không nằm trong workspace (chứa containment check); xóa đệ quy; in xác nhận.
  - `ez list [--workspace W] [--engine ROOT]` — duyệt workspace, in `slug (version từ project.json)` cho từng mục có `project.json`; workspace rỗng/không tồn tại → in thông báo thân thiện, exit 0.
  - `ez version` — in `ez toolchain 0.0.1` + `ez_engine 0.1.0-dev` (hằng số local trong `ez.zig`, chú thích giữ đồng bộ tay với `src/root.zig`).
  - `build.zig`: `-Dname` (chung new/delete), `-Dworkspace` (mặc định `projects/`), `-Dforce` (bool); step `delete` chạy `ez.zig delete ...`, step `list` chạy `ez.zig list ...`, step `version` chạy `ez.zig version`.

- [ ] **Step 1: Chuyển `tools/scaffold.zig` → `tools/ez.zig`** thêm subcommand parser; giữ nguyên hành vi `new`.
- [ ] **Step 2: Thêm `delete`**
  - [ ] Verify: `zig build delete -Dname=DoesNotExist -Dforce=true` → lỗi sạch "not found"; `zig build delete -Dname=Real -Dworkspace=/tmp/ezv` (không force) → từ chối, dir còn nguyên.
- [ ] **Step 3: Thêm `list` và `version`**
  - [ ] Verify: `zig build list -Dworkspace=/tmp/ezv` in `Tester (0.0.1)`; `/tmp/ezv` trống → thông báo thân thiện exit 0; `zig build version` in `ez toolchain 0.0.1`.
- [ ] **Step 4: Verify Review Focus (+ force xóa thật)**
  - [ ] So sánh path: tạo project trong workspace, chạy `delete` với `-Dname` khác → không đụng project đích. Xóa thật bằng `-Dforce=true` → dir biến mất, `list` cập nhật.
  - [ ] RUN: `zig build test` PASS; `zig fmt --check tools/ez.zig build.zig`.
- [ ] **Step 5: Commit**
  - [ ] `git add tools/ez.zig build.zig docs README.md && git rm tools/scaffold.zig && git commit -m "feat: CLI toolchain new/delete/list/version (0.0.1)"`

### Task 5: Bundle deploy web + docs + version 0.0.1

**Files:**
- Modify: `template/game/build.zig` (nếu cần: step `web` lắp thêm file duy nhất `index.html` mặc định hoặc `web-deploy`), `template/game/README.md`, `README.md`, `docs/project-management.md`, `docs/architecture.md` (ghi nhận `ez_app_web`), `CHANGELOG.md`
- Create: `docs/web-hosting.md` (MIME `.wasm` = `application/wasm`, `.data` = `application/octet-stream`, `Cache-Control`; ví dụ GitHub Pages/itch; lưu ý cần HTTPS + secure context cho WebGPU)

**Interfaces:**
- Consumes: output `zig build web` (Task 3) — cây tĩnh trong `zig-out/web/`.
- Produces: tài liệu deploy để chia sẻ link thật.

- [ ] **Step 1: Viết `docs/web-hosting.md`** và cập nhật README/doc/changelog (thêm mục toolchain + web; CHANGELOG thêm `0.0.1` Added: CLI, template v2, web build; note emsdk cài tự động).
- [ ] **Step 2: Verify docs lệnh khớp với hành vi thật**
  - [ ] Sinh project mới, chạy `zig build web` → `zig-out/web/<name>.html` + `.wasm` + `.data` tồn tại; các lệnh trong docs chạy lại không lỗi.
- [ ] **Step 3: Commit**
  - [ ] `git add docs README.md CHANGELOG.md template/game/README.md && git commit -m "docs: web hosting guide and 0.0.1 changelog"`

---

## Post-plan verification (chạy cuối cùng trước khi báo xong)

- `zig build test` PASS; `zig fmt --check` toàn repo (trừ các file không do plan chạm tới nếu đã dơ từ trước — ghi nhận nếu có).
- Từ `/tmp` mới: `zig build new -Dname=Final` → `zig build run` (Linux) + `zig build web-run -Dtarget=wasm32-emscripten` (Chrome) đều chạy; `list`, `delete -Dforce=true` hoạt động; `version` in 0.0.1.