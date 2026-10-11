# Game Loop + Automatic Reclaim Design

> Hướng và các quyết định đã được người dùng duyệt (`ok`). Ngày: 2026-10-10.

## Intent

Hai nhu cầu gắn với nhau ở ranh giới frame:

1. **Vòng lặp có quản lý** — thay vòng lặp variable-dt viết cứng trong
   `Game.run` bằng một tầng điều khiển: chọn variable hay fixed timestep, đặt
   `time_scale`, và bật/tạm dừng/dừng được.
2. **Dọn rác tự động** — cuối mỗi frame, engine tự thu hồi bộ nhớ tạm cấp
   trong frame và xử lý các entity mà game yêu cầu xoá, để gameplay không phải
   gọi `free`/`destroy` thủ công và không xoá entity ngay giữa lúc systems đang
   chạy.

## Hiện trạng (đã đọc code)

- `Game.run(io, window)` là vòng `while` variable-dt: `beginFrame()` →
  `pollEvents` → `clock.tick` → `frame(dt)`. `Game.frame(dt)` gộp cả update
  (`scheduler.run`) lẫn render (extract → cull → sort → render → debug) rồi
  tăng `frame_index`.
- `FixedStepper` (`src/core/time.zig`) đã có (accumulator, cap catch-up,
  `interpolationAlpha`) nhưng **chưa nơi nào dùng**.
- `FrameArena` + `Allocators` (`src/core/allocator.zig`) đã có (arena reset
  `retain_capacity`) nhưng **chưa nơi nào dùng**.
- `World.destroy(entity)` (`src/ecs/world.zig`) xoá ngay; không có hàng đợi.
- `Game.frame(dt)` đang được gọi trực tiếp bởi `tests/script_test.zig`,
  `tests/backend_iface_test.zig`, `examples/sandbox/main.zig`, và các test
  inline `src/game.zig`.

## Quyết định chính

### 1. `GameLoop` (`src/core/game_loop.zig`) — thuần, không phụ thuộc `Game`

```zig
pub const State = enum { running, paused, stopped };
pub const Timing = union(enum) { variable, fixed: FixedStepper };

pub const GameLoop = struct {
    state: State = .running,
    timing: Timing = .variable,
    time_scale: f64 = 1,
    max_frame_seconds: f64 = 0.25, // kẹp frame-time cho mọi caller

    pub fn init() GameLoop;                       // variable
    pub fn initFixed(step_seconds: f64, max_steps: u32) !GameLoop;
    pub fn pause(self: *GameLoop) void;
    pub fn resume(self: *GameLoop) void;
    pub fn stop(self: *GameLoop) void;
    pub fn isStopped(self: GameLoop) bool;
    pub fn stepCount(self: *GameLoop, frame_seconds: f64) u32;
    pub fn stepSeconds(self: GameLoop, frame_seconds: f64) f64;
    pub fn interpolationAlpha(self: GameLoop) f32;  // fixed; 0 khi variable
};
```

- `frame_seconds` trước hết được kẹp vào `[0, max_frame_seconds]`.
- `running`: variable → `stepCount = 1`, `stepSeconds = frame_seconds *
  time_scale`; fixed → `stepCount = stepper.advance(frame_seconds *
  time_scale)`, `stepSeconds = stepper.step_seconds`.
- `paused` / `stopped`: `stepCount = 0`.
- `time_scale` được coi là **không âm**: `stepCount`/`stepSeconds` kẹp
  `@max(0, time_scale)`. `0` = đóng băng (không lỗi); âm cũng như `0` để hai
  timing không lệch nhau.
- Builder call: giữ `GameLoop` thuần dữ liệu/logic để test không cần window.

### 2. Hàng đợi huỷ trong `World` + `Reclaimer` (`src/core/reclaimer.zig`)

Hàng đợi huỷ nằm ở `World` (`src/ecs/world.zig`) vì đây là vòng đời entity —
dùng được cả khi không có `Game`:

```zig
pub fn destroyDeferred(self: *World, entity: Entity) !void; // dồn, không xoá ngay
pub fn flushDeferred(self: *World) void;                    // huỷ hết ở ranh giới an toàn
pub fn pendingDestroyCount(self: *const World) usize;
```

`flushDeferred`: với từng entity, `destroy` nuốt lỗi `InvalidEntity` (dồn trùng /
đã chết thì vô hại); lỗi khác (chỉ có `OutOfMemory` từ `free_ids.reserve`) thì
**giữ entity đó lại trong hàng đợi để thử lần sau** — không xoá ngầm.

`Reclaimer` chỉ sở hữu arena tạm:

```zig
pub const Reclaimer = struct {
    pub fn init(allocator: std.mem.Allocator) Reclaimer;
    pub fn deinit(self: *Reclaimer) void;
    pub fn frameAllocator(self: *Reclaimer) std.mem.Allocator; // FrameArena
    pub fn arenaBytes(self: *const Reclaimer) usize;           // diagnostics
    /// flush hàng đợi của world rồi reset arena.
    pub fn collect(self: *Reclaimer, world: *World) void;
};
```

- `collect` = `world.flushDeferred()` + `arena.reset(.retain_capacity)`.
- Builder call: `Reclaimer` không giữ con trỏ tới `World`/`Game`; nhận `*World`
  ở `collect`.

### 3. Tích hợp vào `Game` (`src/game.zig`)

Thêm field `loop: GameLoop = .{}` và `reclaimer: Reclaimer` (init trong
`Game.init`, `deinit` trong `Game.deinit`). Tách `Game.frame` thành:

```zig
pub fn update(self: *Game, dt: f32) !void;      // validate dt; scheduler.run;
                                                 // update_count += 1
pub fn present(self: *Game, frame_seconds: f32) !void;
                                                 // extract → cull → sort →
                                                 // render → debug.captureFrame
                                                 // → frame_index++ →
                                                 // reclaimer.collect(&world)
pub fn frame(self: *Game, dt: f32) !void;        // update(dt) rồi present(dt)
pub fn tick(self: *Game, frame_seconds: f64) !void; // dùng loop:
                                                 // N=stepCount lần update(stepSeconds)
                                                 // rồi present 1 lần
pub fn destroyDeferred(self: *Game, entity: Entity) !void; // -> world.destroyDeferred
pub fn frameAllocator(self: *Game) std.mem.Allocator;      // -> reclaimer.frameAllocator
```

- `Game.run`: thân vòng lặp thành `self.tick(clock.tick(io))`. Clamp 0.25s nay
  nằm trong `GameLoop.max_frame_seconds` (giữ nguyên giá trị mặc định nên hành
  vi không đổi). Điều kiện dừng thêm `!self.loop.isStopped()`.
- `frame(dt)` giữ nguyên hành vi cũ (một bước + một present + tăng
  `frame_index`) để mọi test/call site hiện tại không đổi.
- `tick` khi `paused`: 0 update, **vẫn present** (giữ hình cuối). Khi `stopped`:
  không update, không present (vòng lặp `run` cũng đã thoát).

### 4. Input edge với fixed-step (chống double-fire)

Một rendered frame có thể chạy N update, nhưng `Input.beginFrame()` chỉ reset
cờ `justPressed/justReleased` một lần đầu frame → một cú bấm sẽ kích ở cả N
bước. Giải:

- `Input.clearEdges()` (`src/input/input.zig`): xoá `pressed`/`released` (giữ
  `down`).
- `Game.tick` gọi `self.input.clearEdges()` **sau bước update đầu tiên** trong
  frame, để mỗi cạnh chỉ tiêu thụ đúng một lần. Với `frame(dt)` (1 bước) hành vi
  không đổi (cạnh đã dùng, đầu frame sau `beginFrame` đã xoá).
- `paused`/0 bước: không có update nên không xoá cạnh (input vẫn "đứng yên"
  đúng như không có bước mô phỏng).

### 5. `update_count` cho `onStart`

`frame_index` đếm **frame hiển thị** (tăng một lần trong `present`). Thêm
`update_count: u64` (tăng ở cuối `Game.update`) đếm **bước mô phỏng**;
`Script.systemFn` chuyển từ `frame_index == 0` sang `game.update_count == 0` để
chạy `onStart` ở update đầu tiên. Nhờ vậy `onStart` vẫn đúng khi loop start ở
`paused`, hoặc khi fixed-step có nhiều tick 0 bước trước update thật.
`Game.frame(dt)` giữ nguyên hành vi (update trước present nên test cũ xanh).

### 6. Ranh giới frame & an toàn

- `reclaimer.collect` chạy ở cuối `present`, tức **ngoài** lúc systems đang lặp
  query → huỷ entity an toàn.
- Gọi `destroyDeferred` cho entity đã chết hoặc dồn hai lần: lần huỷ đầu đổi
  generation; lần sau `destroy` trả `InvalidEntity`, bị nuốt.
- `Game.deinit` gọi `reclaimer.deinit()` (giải phóng arena) trước
  `world.deinit()`; entity còn dồn mà chưa `collect` không cần xử lý riêng
  (world tự dọn khi `deinit`).
- `World.deinit` cũng giải phóng danh sách hàng đợi.

### 7. Điều gì "tự động" thực sự

- **Entity**: `game.destroyDeferred(e)` (hoặc `world.destroyDeferred`) → engine
  dọn ở cuối frame. Đây là phần "GC" rõ ràng.
- **Bộ nhớ tạm**: `game.frameAllocator()` và `Script.Ctx.frame_allocator` cấp
  phát trong frame, tự thu hồi ở `collect`. Gameplay cứ
  `ctx.frame_allocator.dupe(...)` cho dữ liệu tạm, không cần free. **Không**
  instrument mọi `allocator.alloc` để tự đoán. Trong frame path hiện tại
  `RenderWorld` tái dùng buffer nên chưa có chỗ cấp phát tạm nào phải chuyển.

## Non-goals

- Đếm tham chiếu cho handle (entity/asset/texture) và thu hồi khi không còn ai
  dùng (phase 2).
- `GameLoop.stepOnce()` (step từng bước khi debug) — để sau.
- Thống kê loop/reclaimer trong `Debug.Stats` — để sau.
- Instrument toàn cục để "đoán" rác trong allocator tùy ý.
- Dồn giải phóng asset (`releaseTexture`) trong v1.
- Đổi ngữ nghĩa `World.destroy` (vẫn xoá ngay) hay hành vi `Game.frame(dt)`.
- Interpolation được áp vào sprite (chỉ tính và expose
  `interpolationAlpha`).
- Thread/async, đổi scheduler, physics, audio.

## Kiểm thử (TDD)

- `GameLoop`: variable → 1 bước, dt = frame × time_scale; fixed → số bước đúng
  và dt = step; pause/stop → 0 bước; `time_scale` (0/âm = đóng băng);
  `max_frame_seconds` kẹp frame lớn; `interpolationAlpha`; `initFixed` bước ≤ 0
  hoặc max_steps = 0 → error.
- `World`: `destroyDeferred` không xoá ngay; `flushDeferred` xoá đúng; dồn
  trùng/`InvalidEntity` vô hại; `pendingDestroyCount`.
- `Reclaimer`: `collect` flush world rồi reset arena (cấp phát trong frame →
  collect → cấp phát lại được); `arenaBytes`; `deinit`.
- `Input`: `clearEdges` xoá `pressed`/`released` nhưng giữ `down`.
- `Game`: loop fixed → `tick` chạy N update và present một lần; input edge chỉ
  kích ở update đầu; tick khi paused không đẩy system nhưng vẫn present; entity
  dồn bị huỷ sau frame; `onStart` chạy đúng khi start paused; `frame(dt)` giữ
  nguyên (test cũ xanh).
- Integration (`tests/`): API public — system đếm update, `Ctx.frame_allocator`,
  loop fixed, pause, `destroyDeferred`.

## Docs

- `README.md`: mục "Game loop & dọn rác".
- `docs/api.md`: `GameLoop`, `Reclaimer`, `World`/`Game`/`Input` method mới.
- `CHANGELOG.md`: mục Added/Changed.

## Xử lý góp ý builder-check

Một reviewer đọc doc đã nêu 4 điểm còn mơ hồ; cả 4 đều là kỹ thuật và đã được
chốt (ghi trong thân doc):

1. **`onStart` với fixed/paused**: dùng `Game.update_count == 0` thay
   `frame_index == 0` (mục 5).
2. **Clamp frame-time**: `GameLoop.max_frame_seconds` (mặc định 0.25) kẹp trong
   `tick`/`stepCount` cho mọi caller (mục 1, 3).
3. **`flushDeferred` và lỗi khác `InvalidEntity`**: giữ entity lỗi `OutOfMemory`
   lại để thử lần sau (mục 2).
4. **`time_scale`**: coi là không âm, `0`/âm = đóng băng (mục 1).

## Cải tiến bổ sung (đã chốt cùng user)

1. Chống double-fire input edge với fixed-step (`Input.clearEdges` + `tick`).
2. Clamp frame-time gom vào `GameLoop`.
3. Hàng đợi huỷ đặt ở `World`, `Reclaimer` chỉ giữ arena.
4. `Script.Ctx.frame_allocator` để gameplay dùng bộ nhớ tạm tự thu hồi.

## Call của builder (để user soi lại)

- `GameLoop` tách khỏi `Game`; `Reclaimer` nhận `*World` ở `collect`.
- `World.destroy` giữ nguyên tức thời; đường tự động là `destroyDeferred`.
- Hàng đợi huỷ ở `World`, không ở `Reclaimer`.
- `frame_index` đếm frame hiển thị; `update_count` đếm bước mô phỏng.
- `paused` vẫn present; `stopped` thì thôi.
- `time_scale` không âm; `max_frame_seconds` mặc định 0.25.
