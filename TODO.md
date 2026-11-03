# TODO — Hoàn thiện ez-engine theo roadmap

Danh sách công việc còn mở sau commit `eba7a55` (`fix: harden runtime and
asset lifetimes`). Thứ tự ưu tiên: hoàn tất từng nhóm P0 trước P1, rồi mới
chuyển sang P2. Mỗi mục chỉ được đánh dấu xong khi tiêu chí nghiệm thu của
mục đó đã được kiểm chứng.

## P0 — Runtime, asset và render cốt lõi

- [x] **Kiểm thử failure-path của runtime và desktop app**
  - [x] Rà soát `Game.init`, WGPU `App.init` và GL `GlApp.init`: từng tài
    nguyên đã tạo có `errdefer` cleanup tương ứng.
  - [x] Test lỗi cấu hình `Game.init`, lỗi system update, renderer resize/render,
    lỗi `renderer.waitIdle` khi shutdown và xác nhận backend vẫn được deinit.
  - [x] Đưa chuỗi init của WGPU `App` và GL `GlApp` qua stage runner dùng
    chung; fault-injection tại mỗi stage kiểm tra cleanup tài nguyên desktop
    đã tạo bằng `std.testing.allocator`.
  - [x] Xác nhận lỗi được trả về hoặc ghi log có chủ đích, không bị đổi thành
    thành công.
  - **Nghiệm thu:** test lỗi từng phần không leak/use-after-free; thứ tự
    shutdown được kiểm chứng khi subsystem phụ thuộc world/assets còn sống.

- [x] **Chốt hợp đồng render 2D**
  - Tài liệu hóa tọa độ/world units, transform, kích thước, UV origin,
    alpha/color, z-order, camera, resize và framebuffer zero-size.
  - Xác nhận backend xử lý texture handle stale/generation và release tài
    nguyên GPU đúng sau khi renderer idle.
  - Quy định rõ hành vi khi không có renderer, resize thất bại hoặc device
    gặp lỗi.
  - **Nghiệm thu:** API docs, tests và sample cùng tuân theo một hợp đồng;
    Headless vẫn chạy độc lập GPU.

- [x] **Tạo render regression trên backend thật**
  - [x] Smoke-run GL trên OpenGL 4.6 / NVIDIA RTX 3060 Laptop và WGPU trên
    Vulkan / llvmpipe; cả hai khởi tạo backend, nạp sample và chạy tới frame
    loop.
  - [x] Thêm pixel/readback regression trên cả OpenGL và WGPU cho UV, alpha,
    z-order, camera và resize; smoke-run không thay cho kiểm tra hình ảnh.
  - **Nghiệm thu:** backend được công bố có bằng chứng render thật; không xem
    test Headless là xác nhận hình ảnh.

- [x] **Đóng các hợp đồng asset còn lại**
  - Quy định và kiểm thử giới hạn byte/dimension, lỗi file/format và shutdown
    manager cho texture, atlas và font.
  - Kiểm tra API nào trả pointer nội bộ; tài liệu hóa thời hạn pointer hợp lệ
    và không cho consumer dùng pointer sau release.
  - **Nghiệm thu:** test cover giới hạn, malformed input, cache hit,
    release/reload, generation và dependency; docs nêu rõ ownership.

## P1 — Platform, physics và audio

- [x] **Hoàn thiện input, tọa độ chuột và resize**
  - [x] Chốt mapping tọa độ chuột từ logical window sang framebuffer pixels,
    gồm DPI/non-uniform scale; cập nhật GLFW adapter.
  - [x] Kiểm thử resize, close request, focus loss, cùng input edges qua
    frame có 0/1/n fixed updates.
  - [x] Smoke-test GLFW desktop adapter qua pixel regressions GL và WGPU trên
    Linux x86_64; các target Windows/macOS hiện chỉ công bố core.
  - **Nghiệm thu:** test tự động và adapter smoke test trên mọi target desktop
    được công bố đều pass.

- [ ] **Công bố target/platform matrix**
  - [x] Xác định target Zig/OS/architecture cho core, GLFW, GL, WGPU và audio
    trong `docs/platform-support.md`.
  - [x] Core build/test tách khỏi phụ thuộc desktop; target không hỗ trợ
    desktop có warning rõ ràng.
  - [x] Cấu hình CI native matrix Linux, Windows và macOS; xác nhận build
    chéo core cho Linux x86_64, Windows x86_64 và macOS arm64 tại máy dev.
  - [ ] Chờ kết quả workflow CI trên các native runner.
  - **Nghiệm thu:** ma trận được ghi trong docs và workflow xanh trên toàn bộ
    target công bố.

- [x] **Kiểm thử giới hạn và lỗi Physics 2D**
  - [x] Test giá trị không finite/không hợp lệ, thứ tự physics-before-
    collision, contact/filter, body types, restitution và vận tốc cao.
  - [x] Ghi rõ collision discrete AABB, pairwise, bỏ qua rotation và không
    có CCD/broad phase; regression xác nhận tunneling ở vận tốc cao.
  - [x] Chưa thêm broad phase/CCD vì không có benchmark/use-case yêu cầu.
  - **Nghiệm thu:** test xác định hành vi và giới hạn; input sai bị từ chối.

- [ ] **Hoàn thiện workflow audio theo target**
  - [x] Thêm ví dụ WAV decode/resample/playback/device pump; clip còn sống
    tới khi voice dừng; build bằng `zig build audio-example`.
  - [x] Test voice lifetime, rate conversion, clipping, device failure và
    shutdown.
  - [x] Chỉ công bố PulseAudio trên Linux x86_64; software mixer/WAV API
    portable nhưng không tuyên bố có thiết bị output trên target khác.
  - [ ] Chạy sample phát thực tế trên PulseAudio/PipeWire Pulse; môi trường
    hiện tại chưa xác nhận live playback.
  - **Nghiệm thu:** sample phát được trên thiết bị đã công bố; lỗi thiết bị
    được surface/log theo hợp đồng.

## P2 — Scene/gameplay utilities và phát hành

- [x] **Hoàn thiện scene/prefab lifecycle**
  - [x] Tách document validation, asset resolution, runtime spawn và
    per-object/whole-scene despawn; prefab single-object dùng cùng resolver.
  - [x] Lưu asset path tương đối ổn định; không serialize raw pointer hay
    runtime handle/generation.
  - [x] Đọc scene/prefab v1, migrate và ghi v2; test duplicate/invalid data,
    asset resolution failure atomicity, entity mapping và teardown.
  - [x] Starter load scene qua public API; scaffold gồm prefab pickup mẫu.
  - **Nghiệm thu:** tests và `zig build scaffold-smoke` pass; game-specific
    components vẫn do game bổ sung sau spawn.

- [x] **Chọn tiện ích gameplay theo use-case**
  - [x] Chưa thêm tilemap, general UI, particles hoặc editor vào core vì chưa
    có consumer/use-case cụ thể; ghi quyết định trong architecture docs.
  - [x] Reusable single-object prefab nằm trong module Scene riêng; không thêm
    tiện ích gameplay mới ngoài phạm vi.
  - **Nghiệm thu:** core không phình thêm tiện ích chưa được yêu cầu.

- [ ] **Thiết lập CI theo target**
  - [x] Thêm native CI matrix chạy format, build, tests và docs cho Linux,
    Windows và macOS.
  - [x] Thêm Linux scaffold smoke job và xác nhận `zig build scaffold-smoke`
    chạy thành công tại máy dev.
  - [ ] Xác nhận workflow xanh trên hosted runner Linux/Windows/macOS.
  - Tránh format hoặc lint dependency vendored ngoài phạm vi dự án.
  - **Nghiệm thu:** workflow CI tái lập được và xanh trên mọi target được hỗ
    trợ.

- [x] **Thêm benchmark baseline**
  - [x] Đo ECS iteration, render extraction/culling/batching, pairwise
    collision và ZTEX decode với workload cố định, lặp lại được.
  - [x] Ghi cách chạy và lần baseline đầu trong `docs/benchmarks.md`; thời
    gian là số đo tham khảo của máy dev, không phải ngưỡng CI.
  - **Nghiệm thu:** `zig build bench -Doptimize=ReleaseFast` chạy lặp lại.

- [x] **Hoàn thiện chính sách release và scaffold smoke test**
  - [x] Công bố semver trước/sau 1.0, migration notes, dependency/toolchain
    pinning, platform matrix và release checklist.
  - [x] Tạo project mới vào workspace riêng trong `.zig-cache`, build starter
    executable + test target và tự dọn chính thư mục tạm vừa sinh.
  - [x] Scaffold sample compile qua public scene/spawn API.
  - **Nghiệm thu:** `zig build scaffold-smoke` thành công; publish/tag vẫn cần
    quyền release tường minh.

## P0 đã hoàn tất

- `zig build gl-render-test` và `zig build wgpu-render-test` kiểm tra lỗi init
  sau từng stage với allocator kiểm tra rò rỉ và cleanup ngược.
- `zig build gl-render-test` và `zig build wgpu-render-test` đọc pixel từ
  render target thật; các test cần Linux x86_64 và môi trường desktop/GPU.

## Đã hoàn thành
- Scheduler-managed system cleanup và shutdown ordering cơ bản.
- Texture/atlas/font lifetime guards khi asset được entity tham chiếu.
- Input reset khi cửa sổ mất focus; invalid raw key code được log.
- Audio owned clip release được bảo vệ khi voice còn sử dụng.
- Asset cache path policy dùng nguyên chuỗi đầu vào; release/reload kiểm tra
  generation.
- Game propagates system/resize/render errors; shutdown vẫn dọn renderer khi
  `waitIdle` báo lỗi; framebuffer rỗng bỏ qua resize/submission nhưng vẫn hoàn
  tất bookkeeping.
- Render contract được tài liệu hóa; culling tính bounds theo góc quay, có
  regression test sprite không vuông.
- ZTEX giới hạn decoded bytes trước khi cấp phát, kiểm tra độ dài payload,
  dimension, version và format.
- Desktop app init dùng chung stage runner có fault-injection test; renderer
  GL/WGPU có regression đọc pixel cho UV, alpha, z-order, camera và resize.
- Tài liệu và kiểm thử đã cập nhật trong commit `eba7a55`.
