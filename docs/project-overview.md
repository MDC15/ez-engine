# Tổng quan dự án (2026-11-03)

`ez-engine` là framework game 2D viết bằng Zig 0.16.0. Hướng chính là
gameplay ECS và render sprite; framework hiện phù hợp để làm prototype hoặc
game nhỏ, chưa tuyên bố production-ready. Lộ trình hoàn thiện core nằm trong
[nghiệm thu.md](../nghiệm%20thu.md).

## Core hiện có

- **Runtime/ECS:** generational entities, archetype-based `World`, query,
  scheduler topo-order, dependency giữa systems, deferred destroy,
  fixed/variable timestep và frame allocator.
- **System lifecycle:** scheduler hỗ trợ cleanup callback theo thứ tự ngược
  dependency; system context do caller sở hữu và phải sống đến khi scheduler
  deinit. `Game.deinit()` đợi renderer idle, chạy cleanup, rồi mới hủy
  renderer/world/assets.
- **Render 2D:** transform/sprite, camera orthographic, culling, painter order,
  batching, post-process cơ bản và backend interface. Có Headless cho test,
  WGPU và OpenGL cho desktop Linux x86_64.
- **Đồ họa/assets:** cache generational cho texture PNG/ZTEX, packed atlas,
  sprite animation, bitmap font UTF-8 và text glyph sprites. Texture chưa thể
  release khi atlas/font còn tham chiếu.
- **Input/platform:** keyboard, mouse, scroll, action/axis mapping và GLFW
  adapter; desktop helper hiện hướng tới Linux x86_64.
- **Va chạm/chuyển động:** AABB discrete với event begin/stay/end, layer/mask;
  Physics2D tích phân velocity, gravity, damping và restitution cơ bản.
- **Audio:** WAV decode/resample, software mixer, `NullDevice` và
  PulseAudio `PulseDevice` trên Linux; game tự quản lý device/pump.
- **Gameplay/tooling:** Zig-native `Script`/`Mover2D`, document scene JSON
  mẫu, project scaffold, sample WGPU/OpenGL.

## Giới hạn được công bố

- Chỉ render 2D sprite; chưa có tilemap, UI widget/layout, particle system,
  editor hoặc hot reload.
- Physics chưa phải rigid-body solver: không CCD, joints, rotation-aware
  collider hoặc broad phase cho scene lớn.
- Scene JSON chưa serialize tổng quát mọi ECS component và chưa có pipeline
  editor-to-runtime.
- Audio device chưa đa nền tảng; app tích hợp chịu trách nhiệm lifetime và
  thời điểm pump.
- GPU render regression/golden-image và ma trận CI nhiều hệ điều hành chưa
  được hoàn thiện.

## Build và test

Từ repository root:

```sh
zig build
zig build test
zig fmt --check src tests tools template examples build.zig build.zig.zon
zig build docs
```

WGPU/OpenGL desktop samples cần Linux x86_64 theo cấu hình build hiện tại.
Chi tiết API xem [api.md](api.md); ranh giới module/ownership xem
[architecture.md](architecture.md).
