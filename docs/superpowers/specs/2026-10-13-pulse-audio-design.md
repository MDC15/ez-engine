# OS Audio Driver (PulseAudio) — Design

## Intent and why

`ez_engine` games are currently silent: the software mixer (`Audio`) renders
float PCM, but the only `Audio.Device` is `NullDevice`, which discards it.
A real game needs sound effects and music out of the speakers. This project
adds the first real OS audio backend so `Game.audio` can be heard.

## Goals

- A PulseAudio playback device implementing the existing `Audio.Device`
  vtable (`write(frames)`, `deinit`), fed by the existing allocation-free
  `Audio.mix` — no mixer changes.
- Works where the engine runs: Linux desktop and WSLg (a PulseAudio server
  is present in both; verified `unix:/mnt/wslg/PulseServer` here).
- No new system dev packages: headers (`pulse/simple.h`) are absent, so
  bind `pa_simple_*` via `extern fn` + runtime `dlopen("libpulse-simple.so.0")`.
  Missing library or server is a clean error, never a crash or link failure.
- Game keeps running without audio: init failure is returned (not panicked),
  so callers log a warning and continue silent.

## Non-goals

- No recording, no ALSA/WASAPI/CoreAudio backends (PulseAudio covers Linux;
  PipeWire provides a Pulse-compatible server, so this also works there).
- No resampling inside the device: the device opens at the mixer's configured
  rate/channels (default 48000 Hz); foreign-rate clips must be converted with
  the existing offline `Audio.resample` (documented, `SampleRateMismatch`
  stays the error otherwise).
- No low-latency/pro-audio guarantees, no per-voice effects, no format beyond
  float32 (mixer-native, no conversion step).

## Anti-goals

- A second mixer or a parallel audio API. The driver is a thin sink behind the
  `Device` vtable; all mixing policy stays in `Audio`.
- A background audio thread owned by the engine. (See decided: pump model.)

## Constraints

- Zig 0.16.0; `zig build`, `zig build test`, `zig fmt --check` stay green.
- `zig build test` runs headless everywhere (CI has no sound server), so all
  driver tests must pass without a server: error paths + a fake in-memory
  `pa_simple` double, never the real daemon.
- Public API only via `src/root.zig`; CHANGELOG entry under Unreleased.
- No `libc` link requirement beyond what `std.DynLib` needs (dynamic load only).

## Decided (how)

- **Pump model, no thread (my call).** `write(frames)` mixes into a stack buffer
  then one blocking `pa_simple_write`. Caller pumps once per rendered frame
  with frames matching consumed simulation time (docs recipe; `Game`/`App`
  unchanged in v1). Rationale: no thread-lifetime or shutdown-race problems,
  headless default untouched.
- **Format**: `PA_SAMPLE_FLOAT32LE`, rate/channels taken from the attached
  `Audio` mixer at init (`init(audio, app_name, stream_name)`). Mismatch is
  impossible by construction — the device never reinterprets the mix.
- **Loading**: `std.DynLib.open("libpulse-simple.so.0")`, `lookup` of exactly
  `pa_simple_new`, `pa_simple_write`, `pa_simple_drain`, `pa_simple_free`,
  `pa_strerror`. Any failure → `error.AudioLibraryMissing` / `error.NoAudioServer`
  with the Pulse message attached where available. Handle kept in the device;
  `deinit` drains, frees the stream, and closes the library.
- **Location**: `src/audio/pulse.zig`, surfaced as `Audio.PulseDevice`
  (nested in the `Audio` struct next to `NullDevice`, same import graph —
  no new build module; `std.DynLib` needs no headers). Headless `NullDevice`
  stays the default; games opt into Pulse explicitly.
- **Docs**: `docs/api.md` Audio bullets (init/pump/deinit, error table,
  "no server → game continues silent" recipe), CHANGELOG entry.

## Left to the builder

- Exact `pa_simple_new` argument struct layouts (`pa_sample_spec`,
  `pa_buffer_attr`: set latency explicitly or pass null for server default —
  propose in the plan; server default preferred unless tests say otherwise).
- Fake-`pa_simple` test-double shape (vtable injection vs test-only constructor).

## Builder-check resolutions (my calls)

- **Q1 — `pump` IS the `write` vtable impl.** `PulseDevice` is a drop-in
  `Audio.Device`: `write(frames)` mixes into an internal stack buffer
  (same 512-frame chunking as `NullDevice`, allocation-free guarantee kept)
  then one blocking `pa_simple_write`. No parallel API, no caller buffers.
- **Q2 — no `Game`/`App` changes in v1; caller pumps manually.** The spec's
  "`App.run` next to `present`" was wrong about the code (`App` delegates to
  `Game.run`). Recipe in docs: after each `game.tick(dt)`, call
  `device.write(rate * dt)` (frames matching consumed simulation time).
  Keeps headless default untouched and core→driver decoupled.
- **Q3 — pump errors return, never abort the loop.** Mid-game server death
  surfaces as the `write` error; recipe: log once, stop pumping, game
  continues silent. Blocking write is sized by the caller per above, so no
  audio-clock pacing of the render loop by default.
- **Q4 — lifetimes.** `init(audio: *Audio, app_name: [:0]const u8,
  stream_name: [:0]const u8, server: ?[:0]const u8) !PulseDevice` — no
  allocator (stack PCM buffer, like `NullDevice`); name strings and `*Audio`
  are borrowed and must outlive the device (literals are typical).
  `deinit` drains, frees the stream, closes the library. Destroy before
  `Game.audio` (documented order, same as renderer-before-subsystems).
- **Q5 — server selection.** Pass `NULL` (Pulse defaults: `PULSE_SERVER` env
  → client.conf → autospawn). Covers WSLg automatically via its env; no
  hardcoded paths, no new parameter beyond the optional explicit `server`.
