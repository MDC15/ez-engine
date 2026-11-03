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

- [ ] **Hoàn thiện input, tọa độ chuột và resize**
  - Chốt coordinate mapping giữa logical window, framebuffer và DPI scale;
    bổ sung event/API cần thiết cho adapter.
  - Kiểm thử resize, close request, focus loss, input edges qua frame có
    0/1/n fixed updates.
  - **Nghiệm thu:** kiểm thử tự động cho input/resize/fixed-step và smoke
    test adapter trên từng OS được công bố.

- [ ] **Công bố target/platform matrix**
  - Xác định target Zig/OS/architecture được hỗ trợ cho core, GLFW, GL, WGPU
    và audio.
  - Đảm bảo core build/test không kéo phụ thuộc desktop ngoài phạm vi.
  - **Nghiệm thu:** ma trận được ghi trong docs và được chạy trong CI; target
    không hỗ trợ trả thông báo rõ ràng.

- [ ] **Kiểm thử giới hạn và lỗi Physics 2D**
  - Bổ sung test cho giá trị không finite/không hợp lệ, thứ tự system,
    contact/filter, body types, restitution và vận tốc cao/tunneling.
  - Ghi rõ collision hiện là discrete AABB và các giới hạn đã xác nhận.
  - Chỉ thêm broad phase/CCD nếu benchmark hoặc game mục tiêu yêu cầu.
  - **Nghiệm thu:** tests xác định được hành vi hỗ trợ và giới hạn; API không
    âm thầm chấp nhận input sai.

- [ ] **Hoàn thiện workflow audio theo target**
  - Đưa WAV load/decode, resample, playback và device pump vào ví dụ dùng
    được; giữ quy tắc clip phải sống tới khi voice dừng/kết thúc.
  - Test voice lifetime, rate conversion, clipping, thiết bị lỗi và shutdown.
  - Chọn và kiểm chứng backend audio cho từng target muốn công bố; không tuyên
    bố cross-platform nếu mới xác nhận PulseAudio.
  - **Nghiệm thu:** sample phát được trên thiết bị target đã công bố; lỗi
    thiết bị được surface/log theo hợp đồng.

## P2 — Scene/gameplay utilities và phát hành

- [ ] **Hoàn thiện scene/prefab lifecycle**
  - Tách document, validation, asset resolution và spawn/despawn.
  - Dùng asset references ổn định trong dữ liệu lưu; không serialize raw
    pointer hoặc index/generation runtime làm ID lâu dài.
  - Thêm round-trip/version migration và lỗi asset rõ ràng.
  - **Nghiệm thu:** sample gameplay load scene/prefab qua public API; test
    round-trip, version, lỗi asset và cleanup.

- [ ] **Chọn tiện ích gameplay theo use-case**
  - Chỉ chọn tilemap, UI, particles hoặc editor khi có nhu cầu game cụ thể.
  - Mỗi tiện ích nằm trong module riêng, có test/example trước khi export API.
  - **Nghiệm thu:** không làm phình core vì tính năng chưa có consumer; module
    mới có tài liệu và ví dụ.

- [ ] **Thiết lập CI theo target**
  - Chạy format, build, tests và docs trên ma trận platform đã công bố.
  - Tránh format hoặc lint dependency vendored ngoài phạm vi dự án.
  - **Nghiệm thu:** workflow CI tái lập được và xanh trên mọi target được hỗ
    trợ.

- [ ] **Thêm benchmark baseline**
  - Đo ECS iteration, render extraction/culling/batching, collision và asset
    load với input/kích thước workload được ghi rõ.
  - Lưu cách chạy và baseline; chỉ tối ưu sau khi có số liệu.
  - **Nghiệm thu:** benchmark có thể chạy lặp lại và kết quả so sánh được.

- [ ] **Hoàn thiện chính sách release và scaffold smoke test**
  - Công bố semver, chính sách breaking changes, migration notes,
    dependencies/toolchain và supported platforms.
  - Tạo project mới từ template trong kiểm thử sạch, build và chạy smoke test.
  - **Nghiệm thu:** release checklist hoàn chỉnh; scaffold chỉ dùng public API
    và build được từ đầu.

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
