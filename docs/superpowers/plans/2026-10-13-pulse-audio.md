# PulseAudio Driver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `Game.audio` audible on Linux/WSLg through a PulseAudio playback device implementing the existing `Audio.Device` vtable, loaded at runtime with no dev-header or link dependency.

**Architecture:** New `src/audio/pulse.zig` declares the 5 `pa_simple_*` extern signatures plus `pa_sample_spec` layout, loads them from `libpulse-simple.so.0` via `std.DynLib`, and exposes `PulseDevice` (nested as `Audio.PulseDevice`) whose `write` mixes into a stack buffer and performs one blocking `pa_simple_write`. Tests use a fake function table and never touch a real server.

**Tech Stack:** Zig 0.16.0, `ez_engine` lib, PulseAudio Simple API (runtime-loaded), `zig build test`.

**Spec:** `docs/superpowers/specs/2026-10-13-pulse-audio-design.md` (including Builder-check resolutions — they override the body where they differ).

## Global Constraints

- Zig 0.16.0 only; `zig build`, `zig build test`, `zig fmt --check src tests tools template examples build.zig build.zig.zon` stay green on Linux x86_64.
- No new system dev packages and no new link-time dependency: `std.DynLib` only; missing library/server is a clean error, never a crash.
- `zig build test` runs headless (CI has no sound server): every driver test passes with no daemon — fake function table only.
- Public API only via `src/root.zig` (as `Audio.PulseDevice`); CHANGELOG entry under Unreleased as additive.
- ECS/mixer untouched; no `Game`/`App` changes in v1 (manual-pump recipe in docs).

## Review Focus

- Library absent (`dlopen` fails) must return `error.AudioLibraryMissing`, never crash — expect `expectError` on a bogus library name.
- Explicit bogus server must fail init fast with a named error and leak nothing observable — expect `expectError` (and a second init attempt also fails cleanly).
- Mid-stream `pa_simple_write` failure must propagate out of `write` — expect `expectError` from the fake returning -1.
- `deinit` must drain before freeing the stream — expect fake `drain_count == 1` and `free_count == 1` with drain recorded first.
- `write(0)` must be a harmless no-op performing zero `pa_simple_write` calls — expect fake `write_count == 0` and no error.

---

### Task 1: pa_simple bindings + runtime loader

**Files:**
- Create: `src/audio/pulse.zig`
- Test: inline in `src/audio/pulse.zig` (runs under existing `library_tests`; no `build.zig` change — a standalone `tests/` file linking this module segfaults this toolchain, see P1/atlas ledgers)

**Interfaces:**
- Consumes: `std.DynLib.open/lookup/close` (`open(path) !DynLib`, `close(*DynLib)`, `lookup(T, name[:0]) ?T`); `Audio` mixer types NOT needed yet.
- Produces (exact names later tasks use verbatim):
  - `pub const PulseError = error{ AudioLibraryMissing, MissingPulseSymbol, NoAudioServer, PulseWriteFailed }`
  - `pub const SampleSpec = extern struct { format: c_int, rate: u32, channels: u8 }` (`@sizeOf == 12`, `FLOAT32LE = 5`, `PLAYBACK = 1`)
  - `pub const FnTable = struct { pa_new: *const fn ([?:0]const u8, [?:0]const u8, c_int, [?:0]const u8, [?:0]const u8, *const SampleSpec, ?*const anyopaque, ?*const anyopaque, *c_int) callconv(.c) ?*anyopaque, pa_write: *const fn (*anyopaque, [*]const u8, usize, *c_int) callconv(.c) c_int, pa_drain: *const fn (*anyopaque, *c_int) callconv(.c) c_int, pa_free: *const fn (*anyopaque) callconv(.c) void }`
  - `pub const PulseLib = struct { lib: std.DynLib, fns: FnTable, pub fn load(path: []const u8) PulseError!PulseLib, pub fn loadFns(lib: *std.DynLib) PulseError!FnTable, pub fn close(self: *PulseLib) void }`

- [ ] **Step 1: Write failing tests in `src/audio/pulse.zig`**

```zig
test "loader reports a missing library without crashing" {
    try std.testing.expectError(error.AudioLibraryMissing, PulseLib.load("libpulse-simple-does-not-exist.so.0"));
}

test "loader reports a missing symbol without crashing" {
    var lib = PulseLib{ .lib = try std.DynLib.open("libc.so.6"), .fns = undefined };
    defer lib.close();
    try std.testing.expectError(error.MissingPulseSymbol, PulseLib.loadFns(&lib.lib));
}

test "sample spec matches the C ABI" {
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(SampleSpec));
    try std.testing.expectEqual(@as(c_int, 5), FLOAT32LE);
    try std.testing.expectEqual(@as(c_int, 1), PLAYBACK);
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -8`
Expected: FAIL — `pulse.zig` has no member `PulseLib` / file has no such decls (unreachable until wired; wire the module by adding `_ = @import("audio/pulse.zig");` to the `src/root.zig` test block first so the tests execute).

- [ ] **Step 3: Implement bindings + `PulseLib.load/loadFns/close` in `src/audio/pulse.zig`**

`load`: `DynLib.open` (map any error to `AudioLibraryMissing`), then `loadFns` (any null lookup → close lib, `MissingPulseSymbol`). Symbol names as C strings: `"pa_simple_new"`, `"pa_simple_write"`, `"pa_simple_drain"`, `"pa_simple_free"` (`pa_strerror` is intentionally NOT bound — errors surface as the three codes above; document why in a comment). `close` frees nothing else.

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: all steps green.

- [ ] **Step 5: Commit**

```bash
git add src/audio/pulse.zig src/root.zig
git commit -m "feat: add PulseAudio runtime bindings loader"
```

### Task 2: PulseDevice (drop-in Audio.Device)

**Files:**
- Modify: `src/audio/pulse.zig` (add `PulseDevice`)
- Modify: `src/audio/audio.zig` (add `pub const PulseDevice = @import("pulse.zig").PulseDevice;` inside `Audio` — same proven file-cycle pattern as manager↔atlas)
- Test: inline in `src/audio/pulse.zig`

**Interfaces:**
- Consumes: Task 1 (`PulseLib`, `FnTable`, `SampleSpec`, errors); `Audio.init/play/mix`, `Audio.Device` vtable shape, `NullDevice` 512-frame chunking pattern (`src/audio/audio.zig`).
- Produces:
  - `pub const PulseDevice = struct { audio: *Audio, lib: PulseLib, stream: *anyopaque, pub fn init(audio: *Audio, app_name: [:0]const u8, stream_name: [:0]const u8, server: ?[:0]const u8) PulseError!PulseDevice, pub fn device(self: *PulseDevice) Audio.Device, pub fn deinit(self: *PulseDevice) void }`
  - Test-only `pub fn initTest(audio: *Audio, fns: FnTable) PulseDevice` (fake table, no library/stream; `deinit` on it only drains/frees via fakes and never closes a real lib)

- [ ] **Step 1: Write failing tests in `src/audio/pulse.zig`**

```zig
test "device writes mixed frames and drains on deinit" {
    var audio = try Audio.init(std.testing.allocator, 1);
    defer audio.deinit();
    const clip = Clip{ .sample_rate = 48000, .channels = 1, .samples = &.{ 0.5, -0.5 } };
    _ = try audio.play(&clip, 1);
    var fake = FakePulse{}; // counters + captured bytes + programmable results
    var dev = PulseDevice.initTest(&audio, fake.fns());
    var device = dev.device();
    try device.write(2);
    try std.testing.expectEqual(@as(usize, 1), fake.write_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), fake.captured[0], 1e-5);
    device.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.drain_count);
    try std.testing.expect(fake.drained_before_freed);
}

test "write error propagates and zero write is a no-op" {
    // fake.write_result = -1 → expectError on device.write(2)
    // fresh fake → device.write(0) → no error, write_count == 0
}

test "init against a bogus server fails cleanly" {
    // Explicit nonexistent socket fails fast with no daemon involved.
    // Accepts AudioLibraryMissing too, so machines without libpulse pass.
    var audio = try Audio.init(std.testing.allocator, 2);
    defer audio.deinit();
    for ([_]void{ {}, {} }) |_| {
        if (PulseDevice.init(&audio, "ez-test", "sfx", "unix:/nonexistent-pulse-socket-xyz")) |*dev| {
            dev.deinit();
            try std.testing.expect(false); // a bogus socket must never connect
        } else |err| {
            try std.testing.expect(err == error.NoAudioServer or err == error.AudioLibraryMissing);
        }
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `zig build test 2>&1 | tail -6`
Expected: FAIL — `PulseDevice` / `initTest` undefined.

- [ ] **Step 3: Implement `PulseDevice` in `src/audio/pulse.zig` + nest in `Audio`**

`init`: `PulseLib.load("libpulse-simple.so.0")`, build `SampleSpec{ .format = FLOAT32LE, .rate = audio.output_sample_rate, .channels = audio.output_channels }`, `pa_new(server, app_name, PLAYBACK, null dev, stream_name, &spec, null map, null attr, &err)`; null stream → close lib, `NoAudioServer`. `write`: chunk like `NullDevice` (512 frames), `mix` into stack buffer, `pa_write` bytes; nonzero return → `PulseWriteFailed`. `device()` returns vtable `{ .write = writeImpl, .deinit = deinitImpl }` mirroring `NullDevice`. `deinit`: drain (ignore its error — shutdown path), free stream, close lib. Borrowed `*Audio`/name strings documented as must-outlive-device. `FakePulse` lives in the test section only (never exported).

- [ ] **Step 4: Run to verify it passes**

Run: `zig build test --summary all 2>&1 | grep -E "Build Summary"`
Expected: all steps green, including all pre-existing mixer tests.

- [ ] **Step 5: Commit**

```bash
git add src/audio/pulse.zig src/audio/audio.zig
git commit -m "feat: add PulseAudio playback device"
```

### Task 3: Docs + usage recipe

**Files:**
- Modify: `docs/api.md` (Audio section), `CHANGELOG.md` (Unreleased/Added)

**Interfaces:**
- Consumes: Tasks 1–2 final names.
- Produces: docs only.

- [ ] **Step 1: Write docs**

`docs/api.md`: `Audio.PulseDevice.init(audio, app, stream, server)`, per-frame `device.write(rate * dt)` recipe after `game.tick`, error table (`AudioLibraryMissing`/`NoAudioServer`/`PulseWriteFailed`), "no server → log once, stop pumping, game continues silent", destroy-before-`Game.audio` order. `CHANGELOG.md`: one Added bullet.

- [ ] **Step 2: Verify + commit**

Run: `zig build test --summary all 2>&1 | grep -E "Build Summary"` (docs-only, must stay green) and `zig fmt --check src tests tools template examples build.zig build.zig.zon`.
```bash
git add docs/api.md CHANGELOG.md
git commit -m "docs: PulseAudio device usage and errors"
```
