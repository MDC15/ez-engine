# Lộ trình hoàn thiện ez-engine thành framework game 2D

**Cập nhật:** 2026-11-03
**Mục tiêu:** Hoàn thiện framework 2D tập trung vào game sprite, có API ổn định, dễ bảo trì và có ranh giới module để bổ sung tính năng sau này.
**Tiến độ:** Roadmap đang được triển khai theo từng lát cắt có test; các mục
được đánh dấu hoàn thành bên dưới chỉ phản ánh phần đã có code và kiểm chứng.

## 1. Định hướng sản phẩm

ez-engine nên được định nghĩa là **framework game 2D viết bằng Zig**, không phải engine tổng quát thay thế mọi công cụ:

- Core cần cung cấp runtime, ECS, vòng đời game, input, asset lifetime, render 2D và các abstraction để game có thể cắm gameplay riêng.
- Module cốt lõi giữ API nhỏ và ổn định; tính năng bổ sung được phát triển thành module độc lập, tránh buộc mọi game phụ thuộc vào editor, renderer cụ thể hoặc nền tảng desktop.
- Zig là ngôn ngữ gameplay và mở rộng chính. Không ưu tiên scripting VM, hot reload hay 3D trước khi core 2D có hợp đồng/lifecycle vững.
- Từng giai đoạn phải build, test, có tài liệu và ví dụ sử dụng được. Không triển khai đồng thời nhiều subsystem lớn.

## 2. Hiện trạng đã có

| Năng lực | Hiện trạng trong source |
|---|---|
| ECS và scheduler | [World](src/ecs/world.zig), [Query](src/ecs/query.zig), [Scheduler](src/ecs/scheduler.zig), generational `Entity`, system dependency và deferred destroy. Component là plain data, không có destructor. |
| Runtime | [Game](src/game.zig) ghép world, scheduler, assets, audio, input, render world và loop; có variable/fixed step, platform event loop và `Reclaimer`. |
| Render 2D | [RenderComponents](src/gfx/render_components.zig), [RenderWorld](src/gfx/render_world.zig), camera/culling/batching, renderer vtable, Headless, WGPU và OpenGL. |
| Asset đồ họa | [Asset Manager](src/asset/manager.zig) cache texture/atlas/font theo path; PNG/ZTEX, packed atlas, sprite animation, bitmap-font text. |
| Input/platform | Input state và action mapping; [Platform.Window](src/gfx/platform.zig) cùng GLFW adapter; desktop helper riêng. |
| Va chạm/chuyển động | [Collision2D](src/physics/collision2d.zig) AABB và contact events; [Physics2D](src/physics/physics2d.zig) velocity, gravity, damping, restitution cơ bản. |
| Audio | [Audio mixer](src/audio/audio.zig), WAV decode/resample, `NullDevice` và [PulseDevice](src/audio/pulse.zig). Thiết bị và thời gian pump chưa được runtime quản lý thống nhất. |
| Scene/gameplay | [Scene.Document](src/scene/scene.zig) JSON tối giản, [SceneSpawn](src/scene/spawn.zig), [Script](src/script/script.zig) Zig-native và `Mover2D`. |

Đây là nền tảng tốt cho prototype/game 2D nhỏ, nhưng các API hiện tại chưa tự động đồng nghĩa với lifecycle sản phẩm hoàn chỉnh. Các mục dưới đây là việc cần làm/kiểm chứng trước khi tuyên bố framework sẵn sàng; không phải tất cả đều cần hoàn thành để làm prototype.

## 3. Nguyên tắc kiến trúc cần giữ

### 3.1 Chiều phụ thuộc

Giữ dependency một chiều, tránh để gameplay hoặc ECS gọi thẳng backend:

```text
game code
  -> public facade (ez_engine)
      -> runtime / ECS / input / assets / 2D systems
          -> interfaces: platform, renderer, audio device
              -> backend cụ thể (GLFW, WGPU, OpenGL, PulseAudio, ...)
```

- `ecs/` và `math/` không phụ thuộc GPU, cửa sổ hoặc hệ điều hành.
- Gameplay dùng API public, không import nội bộ của backend.
- `RenderWorld` là dữ liệu CPU; backend tiêu thụ dữ liệu render, không sở hữu ECS.
- Interface được thêm khi có ít nhất một consumer thực tế và một implementation/test double; không tạo plugin framework tổng quát trước nhu cầu.

### 3.2 Hợp đồng mở rộng

- Mỗi subsystem có ranh giới rõ: dữ liệu/components, system/update, resource ownership, lỗi, và điều kiện `deinit`.
- System người dùng đăng ký vào scheduler phải có lifetime được quy định rõ hơn hiện tại. Context pointer không được treo sau khi system bị hủy.
- Asset handles có generation để phát hiện stale handle; tài liệu phải nói rõ ai load/release, resource nào phụ thuộc resource khác, và lúc nào GPU resource được thu hồi.
- Platform/backend cụ thể nằm ngoài core. Thêm backend mới không buộc thay đổi gameplay API hoặc core render data.
- Không mở rộng component thành owning object; resource phức tạp nằm trong manager/system và component chỉ giữ handle/plain data.

## 4. Lộ trình theo thứ tự ưu tiên

### Giai đoạn 0 — Chốt hợp đồng và cập nhật trạng thái dự án

**Ưu tiên: P0 · Chặn hiểu sai API**

- Cập nhật [README.md](README.md), [docs/architecture.md](docs/architecture.md), [docs/api.md](docs/api.md), [docs/project-overview.md](docs/project-overview.md) để phản ánh code hiện tại.
- Ghi rõ phạm vi hỗ trợ: framework 2D, renderer/platform build được ở target nào, tình trạng audio backend, giới hạn physics và scene.
- Xóa trạng thái/todo lỗi thời; không ghi một tính năng là “chưa có” nếu code đã có implementation.
- Xác định ví dụ starter là đường chính thức để dev mới tạo, chạy, cập nhật và dọn game.

**Nghiệm thu:** ví dụ trong tài liệu compile được; API docs và README không mâu thuẫn với code; các giới hạn được ghi thành giới hạn, không mô tả thành tính năng đã hoàn chỉnh.

### Giai đoạn 1 — Runtime, system lifecycle và lỗi khởi tạo/dọn dẹp

**Ưu tiên: P0 · Nền tảng cho mọi module**

**Nơi làm:** [src/game.zig](src/game.zig), [src/ecs/scheduler.zig](src/ecs/scheduler.zig), [src/ecs/system.zig](src/ecs/system.zig), `src/core/`, tests runtime.

- Quy định system context thuộc ai, phải sống bao lâu, thứ tự gọi `init/update/deinit` và xử lý khi đăng ký thất bại.
- Thiết kế thứ tự shutdown nhất quán: ngừng loop → chờ backend → hủy system phụ thuộc world/assets → hủy renderer/device → hủy assets/world/allocator. Chỉ đưa subsystem vào `Game` ownership nếu không tạo vòng phụ thuộc.
- Kiểm tra các đường lỗi từng phần trong `Game.init`/desktop `App.init`: mọi bước đã khởi tạo trước lỗi phải được giải phóng.
- Chốt fixed-step/input semantics: input edge được tiêu thụ ở bước mô phỏng nào; present chạy khi pause/0-step ra sao; destroy/reclaim flush tại boundary nào.
- Chuẩn hóa lỗi runtime; lỗi update/render/audio phải trả về hoặc được log có chủ đích, không bị nuốt thành thành công.

**Nghiệm thu:** test lỗi giữa quá trình khởi tạo, thứ tự shutdown, system context lifetime, pause/stop/fixed-step và deferred destroy; không có use-after-free khi shutdown/restart theo lifecycle được hỗ trợ.

### Giai đoạn 2 — Asset/resource lifecycle thống nhất

**Ưu tiên: P0 · Tránh stale handle và lỗi ownership**

**Nơi làm:** [src/asset/manager.zig](src/asset/manager.zig), [src/core/handle.zig](src/core/handle.zig), `src/gfx/texture.zig`, `src/gfx/atlas.zig`, `src/gfx/font.zig`, test asset.

- Định nghĩa một quy tắc cache path (chuẩn hóa path hoặc quy định path key chính xác), lỗi khi cache hỏng, và hành vi sau release.
- Kiểm tra quan hệ phụ thuộc: atlas/font tham chiếu texture nhưng `releaseTexture` hiện có thể được gọi riêng. Chọn chính sách an toàn (reference count, dependency ownership, hoặc từ chối release khi còn consumer) và test rõ.
- Quy định clip/audio assets tương tự: ai sở hữu samples, handle có stale-generation không, và release trong khi voice đang phát xử lý ra sao.
- Thêm API load/release kiểu nhất quán và giới hạn byte/dimension cho từng asset type.
- Chưa cần async loader/hot reload ở giai đoạn này; thiết kế interface sao cho có thể bổ sung mà không đổi component data.

**Nghiệm thu:** test cache hit, release/reload, generation reuse, lỗi file/format, path aliases theo policy, asset dependency và shutdown manager. Không consumer nào giữ pointer nội bộ qua release nếu API không cam kết pointer ổn định.

### Giai đoạn 3 — Render 2D và tài nguyên backend

**Ưu tiên: P0 · Hợp đồng hiển thị cốt lõi**

**Nơi làm:** [src/gfx/render_world.zig](src/gfx/render_world.zig), [src/gfx/renderer.zig](src/gfx/renderer.zig), `src/gfx/camera.zig`, `src/gfx/gl/`, `src/gfx/wgpu/`, render tests.

- Đóng băng semantics `Transform`, kích thước sprite, origin/pivot, UV origin, z-order, alpha/color, resize/zero-size và camera coordinates.
- Bảo đảm render data độc lập backend; backend phải xử lý texture generation/stale handle và tài nguyên GPU khi texture bị release.
- Thêm render regression/integration path cho GL và WGPU (ít nhất capture hoặc test smoke trên môi trường hỗ trợ); Headless chỉ xác nhận submission, không xác nhận hình ảnh.
- Chốt render lifecycle: resize, wait-idle, device-loss/error và shutdown; API xử lý target không có backend rõ ràng.
- Không thêm material/scene graph trừ khi có use-case 2D; giữ đường sprite hiện tại nhỏ.

**Nghiệm thu:** sample render được trên các backend được công bố; kiểm tra thứ tự draw, alpha/UV/camera/resize và texture lifecycle; test Headless vẫn chạy không cần GPU.

### Giai đoạn 4 — Input, cửa sổ và game loop ổn định

**Ưu tiên: P1 · Chạy được game trên target cam kết**

**Nơi làm:** `src/input/`, [src/gfx/platform.zig](src/gfx/platform.zig), `src/platform/`, [src/game.zig](src/game.zig), `build.zig`, CI.

- Tách event capture khỏi gameplay input state; đảm bảo keyboard/mouse/scroll edge không mất khi fixed timestep chạy 0 hoặc nhiều bước.
- Chốt resize, focus loss, close request, input reset và DPI/coordinate mapping cho mouse.
- Tạo ma trận target chính thức. Giữ platform-specific modules riêng để core build/test không phụ thuộc desktop libraries.
- Gamepad chỉ triển khai khi cần cho game mục tiêu; thiết kế action mapping để có thể thêm binding type mà không sửa gameplay.

**Nghiệm thu:** automated tests cho edge/fixed-step/focus-loss/resize; build core trên target cam kết; smoke test cửa sổ trên OS được công bố.

### Giai đoạn 5 — Physics 2D và audio MVP

**Ưu tiên: P1 · Hệ thống phổ biến, nhưng không mở rộng quá nhu cầu**

**Nơi làm:** [src/physics/physics2d.zig](src/physics/physics2d.zig), [src/physics/collision2d.zig](src/physics/collision2d.zig), [src/audio/audio.zig](src/audio/audio.zig), `src/audio/`, examples/tests.

- Physics: mô tả đúng discrete AABB và giới hạn; kiểm tra invalid/non-finite parameters, thứ tự system, body type, restitution và tunneling. Thêm broad phase trước khi tối ưu số lượng collider lớn. Chỉ thêm CCD/joints/forces nếu game mục tiêu cần.
- Audio: đưa decode/load/lifetime/playback/device pumping vào workflow rõ; tránh bắt từng game tự tính frame pump tùy ý. Giữ mixer độc lập thiết bị, interface device có test double và error surfaced.
- Chọn audio device theo target; `PulseDevice` hiện không đủ để tuyên bố audio cross-platform.

**Nghiệm thu:** physics tests cho contact/filters/overspeed và invalid input; audio tests cho voice lifetime, rate conversion, clipping, device failure; example nghe được trên thiết bị target đã công bố.

### Giai đoạn 6 — Scene, prefab và tiện ích làm game

**Ưu tiên: P2 · Sau khi runtime/resource contracts ổn định**

**Nơi làm:** `src/scene/`, `src/gfx/` hoặc `src/input/` theo module; `examples/`, `template/game/`, `tools/`.

- Thay scene demo hard-code bằng format có versioning, asset references ổn định và extension point cho game-specific data; không serialize raw pointer/handle index như ID lâu dài.
- Tách scene document, validation, asset resolution và spawn lifecycle.
- Thêm tilemap, UI widgets, particles hoặc editor theo nhu cầu thật; mỗi hệ thống ở module riêng, API public chỉ export sau khi có test/example.
- Không biến bitmap text thành UI framework; UI có layout/input/focus lifecycle riêng.

**Nghiệm thu:** round-trip/version migration, lỗi asset rõ ràng, spawn/despawn an toàn; sample gameplay sử dụng scene/prefab mà không phụ thuộc implementation nội bộ.

### Giai đoạn 7 — Release, hiệu năng và cam kết ổn định

**Ưu tiên: P2 · Trước khi phát hành cho người dùng ngoài**

**Nơi làm:** `build.zig`, `.github/workflows/`, `tests/`, `examples/`, `docs/`, `CHANGELOG.md`.

- CI chạy format, build, unit/integration tests và docs trên target được hỗ trợ.
- Thêm benchmarks có baseline cho ECS iteration, render extraction/culling/batching, collision và asset load; tối ưu dựa trên số liệu.
- Công bố semver/chính sách breaking changes, migration notes, supported platforms và dependency/toolchain versions.
- Chạy generated-project smoke test từ đầu để bảo đảm scaffold theo đúng public API.

**Nghiệm thu:** release checklist lặp lại được; sample scaffold build/run; docs khớp API; test và benchmark baseline được lưu cùng release.

## 5. Danh sách việc làm theo thứ tự

1. **P0:** đồng bộ tài liệu và chốt phạm vi/target.
2. **P0:** thiết kế, kiểm thử system/runtime lifecycle và cleanup.
3. **P0:** chốt asset ownership/dependency, nhất là texture với atlas/font và audio clip với voice.
4. **P0:** đóng hợp đồng render 2D/backend, thêm kiểm chứng hình ảnh trên backend thật.
5. **P1:** củng cố input/fixed-step/platform và CI target.
6. **P1:** hoàn thiện workflow audio; test physics cho giới hạn/tunneling.
7. **P2:** scene/prefab tổng quát, tilemap/UI/particles/editor theo nhu cầu.
8. **P2:** benchmark, release policy và compatibility matrix.

Không nên bắt đầu nhiều mục P0 song song. Hoàn tất và nghiệm thu từng giai đoạn; mỗi giai đoạn cần có API, test, docs và ví dụ trước khi chuyển tiếp.

## 6. Tiêu chí nghiệm thu tổng thể

- [ ] Một người mới có thể tạo project từ template, chạy sample và hiểu ownership/lifecycle chỉ từ tài liệu.
- [ ] Core ECS/gameplay build/test được mà không cần GPU hoặc desktop window.
- [ ] System, game, asset, audio và renderer có thứ tự init/shutdown xác định; failure không rò tài nguyên đã sở hữu.
- [ ] Stale handle và resource dependency được xử lý rõ, có test.
- [ ] Backend mới có thể triển khai qua interface mà không sửa gameplay hoặc `RenderWorld`.
- [ ] Fixed timestep và input edge hoạt động đúng ở 0/1/n bước mỗi frame.
- [ ] Các giới hạn của collision/audio/scene/platform được công bố đúng.
- [ ] CI chạy `zig build`, `zig build test`, `zig fmt --check src tests tools template examples build.zig build.zig.zon`, `zig build docs` trên target cam kết.
- [ ] Có smoke/render test backend thật trước khi tuyên bố release-ready.

## 7. Tiến độ triển khai roadmap

- [x] Scheduler hỗ trợ cleanup callback theo thứ tự ngược dependency;
  `Game.deinit()` đợi renderer idle rồi chạy cleanup khi world/assets còn sống.
- [x] Texture không thể release khi còn atlas/font tham chiếu; trả về
  `error.TextureInUse`, dependent assets giữ và nhả reference nhất quán.
- [x] GLFW phát sự kiện mất focus; input nhả phím/chuột đang giữ và bỏ qua
  cursor delta đầu tiên sau khi focus lại.
- [x] Platform ghi log và bỏ qua raw key code không hợp lệ thay vì nuốt lỗi
  âm thầm.
- [x] `Game.releaseTexture` từ chối texture còn được entity dùng trực tiếp và
  đợi renderer idle trước khi giải phóng; API manager thấp cấp không tự quét ECS.
- [x] `Game.releaseAtlas` và `Game.releaseFont` chặn handle còn được
  `AtlasPlayer`/`Text` tham chiếu.
- [x] `Audio.releaseClip` từ chối giải phóng mẫu clip khi voice đang dùng;
  hợp đồng borrowed clip và test release sau stop đã được bổ sung.
- [x] Cache asset dùng chính xác chuỗi path được truyền vào (không normalize);
  docs nêu policy và test xác nhận alias là entry riêng, release/reload đổi
  generation.
- [ ] Giai đoạn 1–3 chưa hoàn tất tổng thể: shutdown mọi subsystem/backend,
  failure-injection đầy đủ, target matrix và GPU render regression vẫn cần
  làm/kiểm chứng riêng.

## 8. Xác minh nền hiện tại

Sau lát cắt quản lý lifetime asset, `zig build test --summary all` đạt
**129/129 tests** sau bổ sung audio ownership và cache path policy; `zig build`
và `zig build docs` cũng thành công ở lượt kiểm tra trước. Format và
`git diff --check` trên thay đổi hiện tại đều đạt.
Đây chưa phải nghiệm thu tổng thể framework; các hạng mục chưa hoàn tất ở
trên vẫn còn mở.
