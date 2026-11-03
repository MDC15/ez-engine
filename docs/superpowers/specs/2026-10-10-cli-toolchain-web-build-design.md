# CLI Toolchain + Web Build Design

> Version đầu tiên: **0.0.1**. Ngày: 2026-10-10.

## Intent (vì sao)

Người dùng muốn một **bộ công cụ dòng lệnh** để tạo / xóa / quản lý project
game, và từ **một máy Linux duy nhất** build ra game chạy được trên **desktop
Linux** lẫn **trên trình duyệt (web)** để chia sẻ link cho người khác chơi thử.
Bản web phải gần giống bản desktop và chạy trên các trình duyệt phổ biến hiện
nay.

Kết quả mong đợi: sau khi `zig build new`, người dùng có một project hoàn
chỉnh; `zig build run` mở cửa sổ trên Linux; `zig build web` sinh bundle chạy
trong browser; `zig build web-run` serve cục bộ để xem thử.

## Goals (0.0.1)

1. **CLI toolchain** chạy trong checkout engine: `zig build new`,
   `zig build delete`, `zig build list`, `zig build version`.
2. **Template project hoàn chỉnh**, có `project.json` mô tả game (tên,
   version `0.0.1`, engine yêu cầu, scene khởi động, cấu hình cửa sổ).
3. **Build web (wasm) từ máy Linux**, tái dùng backend WGPU hiện có qua
   Emscripten; step `web` (sinh bundle) và `web-run` (serve + mở browser).
4. **Phát hành web**: bundle tĩnh deploy được **và** hướng dẫn host (MIME cho
   `.wasm`/`.data`, cấu hình host như GitHub Pages/itch) để chia sẻ link thật.
5. **Desktop Linux giữ nguyên hành vi** (`zig build run`).
6. Version khởi tạo của project mới và của toolchain là **0.0.1**.
7. **Nghiệm thu web trên Chrome/Edge** (WebGPU ổn định nhất). Firefox/Safari
   chỉ hỗ trợ best effort, không nằm trong tiêu chí đạt 0.0.1.

## Non-goals (0.0.1)

- macOS và Windows (để phase sau; zgpu hỗ trợ native hai nền này nhưng cần
  binary Dawn tương ứng, macOS còn cần SDK).
- Backend WebGL fallback hay parity đầy đủ Firefox/Safari.
- Audio device trên web (mixer phần mềm vẫn dùng được nếu build được).
- Visual editor, 3D, hot reload, packed atlas.

## Anti-goals

- **Không** được làm hỏng `zig build test`, sample WGPU Linux, hay `zig build
  new` hiện có.
- **Không** thêm công cụ build ngoài Zig.
- Core lib (`ez_engine` root) **không** được phụ thuộc `zgpu`/`zglfw`/
  emscripten.

## Constraints

- Zig 0.16.0 (`minimum_zig_version`).
- Web cần **Emscripten (emsdk)**; `zemscripten` lo phần sinh bước `emcc`/
  `emrun`.
- Đường emscripten của `zgpu` dùng `emscripten_sleep` → cần `-sASYNC`
  (Asyncify) và `-sASYNCIFY`; canvas HTML selector cố định là `#canvas`.
- Assets (PNG) + scene JSON phải được **preload** vào filesystem của wasm để
  `Assets.loadTextureFile`/`Scene.load` đọc như trên desktop.
- WebGPU trình duyệt: nghiệm thu trên **Chrome/Edge**; Safari 26 và Firefox
  141+ (mới trên Windows) hỗ trợ best effort, không phải tiêu chí đạt 0.0.1.

## Quyết định chính

1. **Tái dùng backend WGPU, không viết renderer WebGL.** `zgpu` đã có sẵn nhánh
   emscripten (`createInstance`, `SurfaceDescriptorFromCanvasHTMLSelector`,
   `emscripten_sleep`), nên `src/gfx/wgpu/backend.zig` biên dịch cho wasm với
   thay đổi tối thiểu. *Đây là quyết định của builder.*
2. **Web app là module riêng `ez_app_web`** (`src/app/web.zig`,
   emscripten-only, không export từ root), song song với `ez_app` desktop.
   Khác desktop ở chỗ:
   - Không có GLFW; canvas lấy qua selector `#canvas`.
   - Không chạy vòng lặp blocking `Game.run`; thay bằng một hàm export cho JS
     gọi mỗi `requestAnimationFrame`, gọi `game.frame(dt)`.
   - Input nạp trực tiếp từ callback HTML5 của emscripten →
     `Platform.feedInput(&game.input, event)`, không cần `Platform.Window`.
3. **`project.json` lên format version 2**: thêm `version`, `window`
   (`width`, `height`, `title`), giữ `engine`, `startup_scene`. Generator đọc
   `window` + `version` để sinh starter; **chỉ là metadata cho generator** —
   build/runtime không đọc file này ở 0.0.1. *Builder call; đã hỏi user.*
4. **CLI**: gộp `tools/scaffold.zig` thành `tools/ez.zig` với subcommand
   `new|delete|list|version`; `build.zig` phơi step tương ứng và forward
   `-Dname`, `-Dworkspace`, `-Dforce`. `delete` từ chối xóa khi thư mục không
   nằm trong workspace hoặc khi không có `-Dforce=true` (tránh xóa nhầm).
   *Builder call.*
5. **Version**: `ez_engine` giữ `0.1.0-dev`; **toolchain** và **project mới**
   bắt đầu ở `0.0.1`. `zig build version` in version toolchain + version engine.
   *Builder call — cần user xác nhận nếu muốn khác.*
6. **Dependency mới**: `zemscripten` (và tuỳ chọn `emsdk`) thêm vào
   `build.zig.zon` của **template** (và repo engine cho sample web). *Builder
   call.*

## Kiến trúc

### Phân nhánh target trong `build.zig` của project

- **Linux native**: như hiện tại — link `zglfw`, `zgpu`, `zdawn`, `X11`,
  `dawn`; step `run`.
- **wasm32-emscripten**: không link `zdawn`/`zglfw`; dùng `zemscripten` để
  chạy `emcc` với `-sASYNCIFY`, preload `Assets/` + `Scenes/`, shell HTML có
  `<canvas id="canvas">`; step `web` (ra `zig-out/web/<name>.html`) và
  `web-run` (`emrun`).
- Xóa `@panic("this starter requires Linux x86_64")`; thay bằng rẽ nhánh.

### Tầng platform web

- `Platform.Window` vtable (đã có) **không đổi**; trên web không dùng nó.
- `src/app/web.zig` cấp `App` với `init` (canvas → graphics → game →
  `SpriteBackend.init`), `start` (đăng ký `emscripten_set_main_loop` gọi
  `frame`), `deinit`. Input đăng ký callback key/mouse/scroll/resize.
- Vòng đời: `main()` trên web chỉ `init` rồi `start`; frame do browser lái.

### Assets

- Preload cả cây `Assets/` và `Scenes/` bằng `--preload-file`; đường dẫn tương
  đối (`Assets/...`) giữ nguyên nên code gameplay không đổi.

## Phases

### Phase 0 — Spike (giảm rủi ro, vứt được)

Chứng minh `wgpu_backend` + `zgpu` biên dịch và **vẽ được một sprite** trong
browser từ máy Linux. Dùng một scene tối thiểu (`#canvas`, một sprite). Nếu
Asyncify/`std.Io`/`std.process.Init` trên emscripten vướng, ghi lại và điều
chỉnh design. **Đây là điều kiện tiên quyết của mọi phase sau.**

### Phase 1 — Tầng web trong engine

`src/app/web.zig` (`ez_app_web`), wiring build cho target emscripten, input
callbacks, preload assets. Test: `zig build test` vẫn PASS (web chỉ compile khi
target emscripten).

### Phase 2 — Template + project.json + step web

Nâng template: bỏ panic, thêm nhánh emscripten, `project.json` v2, step
`run`/`web`/`web-run`, README hướng dẫn. Kiểm: sinh project thật, `zig build
run` (Linux) và `zig build web-run` (browser) chạy starter.

### Phase 3 — CLI toolchain

`tools/ez.zig` với `new|delete|list|version`; step `build.zig`; `delete` an
toàn; `version` in `0.0.1`.

### Phase 4 — Phát hành web + Docs + version

Bundle tĩnh deploy được + hướng dẫn host (MIME `.wasm`/`.data`, ví dụ GitHub
Pages/itch); cập nhật README, `docs/project-management.md`,
`docs/architecture.md`, `CHANGELOG.md`; đặt version 0.0.1; ghi hướng dẫn cài
emsdk.

## Risks

- **Tương tác Zig 0.16 × Emscripten × Asyncify của zgpu** — rủi ro cao nhất;
  Phase 0 giải quyết.
- `std.Io`/`std.process.Init` dưới emscripten có thể cần shim.
- Kích thước bundle do preload toàn bộ assets (chấp nhận cho bản đầu).
- Firefox/Safari WebGPU chưa đều — chỉ hỗ trợ best effort.

## Điều builder đã tự quyết

- **Canvas web responsive**: canvas lấp đầy vùng hiển thị của browser và lái
  `framebuffer_extent`/tỉ lệ camera giống desktop; `window{width,height}` trong
  `project.json` là kích thước cửa sổ desktop và kích thước canvas mặc định
  trước khi resize. (Không đặt canvas cố định, để hành vi giống desktop.)
- **`examples/wgpu` được thêm step web** làm nơi dogfood/kiểm thử Phase 0–1,
  nhưng **không** nằm trong tiêu chí nghiệm thu 0.0.1 (nghiệm thu là template
  sinh ra từ CLI).

## Điều còn để builder tự quyết

- Chi tiết wiring `emcc` (static lib + `emccStep` hay Zig link emscripten).
- Ngưỡng/`-Dforce` của `delete` và thông điệp lỗi.
- Có dùng `emrun` hay server tĩnh tự viết cho `web-run`.
- Tên hàm export giữa Zig và JS, vị trí shell HTML, MIME/cấu hình host.
