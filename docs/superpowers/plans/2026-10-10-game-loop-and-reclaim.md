# Game Loop + Automatic Reclaim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a managed game loop (variable/fixed timestep, pause/resume/stop, time scale) and end-of-frame reclamation (deferred entity destroy + per-frame arena) to `ez_engine`, without changing existing `Game.frame` behavior.

**Architecture:** A pure `GameLoop` decides how many simulation steps a rendered frame runs; a `World`-owned deferred-destroy queue plus a `Reclaimer`-owned `FrameArena` are flushed at the end of `present`. `Game` gains `update`/`present`/`tick` and wires both in.

**Tech Stack:** Zig 0.16.0, std ECS + `FixedStepper`/`FrameArena` already present. No new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-10-game-loop-and-reclaim-design.md`

## Global Constraints

- Zig version: **0.16.0** (`zig version`). Build/test with `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local"` (already exported in this environment; add the prefix only if `zig test` complains).
- `std.ArrayListUnmanaged` must be initialized with `.empty`, never `.{}` (this Zig version).
- `Game.frame(dt)` **must keep its current behavior** (update then present, `frame_index += 1` once) so `tests/script_test.zig`, `tests/backend_iface_test.zig`, `src/game.zig` inline tests and `examples/sandbox/main.zig` stay green unchanged.
- Default timing is `variable` and default `max_frame_seconds = 0.25`; `time_scale` is treated as non-negative.
- No ref-counted handles, no deferred asset release, no `Debug.Stats` additions, no `stepOnce()` in this plan (spec Non-goals).
- Every new source file gets its inline tests collected by adding a `_ = @import(...)` line to the `test {}` block in `src/root.zig`.
- Commit after each task.

## Review Focus

Input classes / failure modes the spec implies but no existing test exercises; the owning task's tests pin each one.

1. **Loop starts `paused` (or fixed with 0 steps) — does `onStart` still fire exactly once?** A reasonable user expects a script's start hook to run when the simulation first actually ticks. → Task 6 test.
2. **Fixed timestep with an edge-triggered input — one press firing several times.** A user expects one press = one action, even when a rendered frame runs N fixed steps. → Task 5 test.
3. **A long stall (huge frame time) spiralling the fixed accumulator.** A user expects catch-up to be capped, not to freeze the game. → Task 1 test (`max_steps`).
4. **`destroyDeferred` called twice, or on an already-dead entity.** A user expects this to be harmless, not a crash or a resurrect. → Task 2 test.
5. **Frame allocator data crossing a frame boundary.** A user expects `frameAllocator()` memory to be gone after the frame, yet the allocator reusable next frame. → Tasks 3, 5, 7 tests.

---

### Task 1: `GameLoop`

**Files:**
- Create: `src/core/game_loop.zig`
- Modify: `src/root.zig` (export + test block)
- Test: inline `test` blocks in `src/core/game_loop.zig`

**Interfaces:**
- Consumes: `FixedStepper` from `src/core/time.zig` (existing: `init(step_seconds, max_steps) !FixedStepper`, `advance(frame_seconds) u32`, `step_seconds: f64`, `interpolationAlpha() f32`).
- Produces:
  - `pub const State = enum { running, paused, stopped };`
  - `pub const Timing = union(enum) { variable, fixed: FixedStepper };`
  - `pub const GameLoop = struct { state: State = .running, timing: Timing = .variable, time_scale: f64 = 1, max_frame_seconds: f64 = 0.25, ... }`
  - `pub fn init() GameLoop`, `pub fn initFixed(step_seconds: f64, max_steps: u32) !GameLoop`
  - `pub fn pause(*GameLoop) void`, `unpause`, `stop`, `isStopped(GameLoop) bool`
  - `pub fn clampFrameSeconds(GameLoop, frame_seconds: f64) f64`
  - `pub fn stepCount(*GameLoop, frame_seconds: f64) u32`
  - `pub fn stepSeconds(GameLoop, frame_seconds: f64) f64`
  - `pub fn interpolationAlpha(GameLoop) f32`
  - root export: `ez_engine.GameLoop`

- [ ] **Step 1: Write the failing tests**

Append to `src/core/game_loop.zig` (create the file with the `const std`/`FixedStepper` imports and the type below the tests will need, or write tests first and let Step 2 fail to compile):

```zig
test "variable timing runs one step scaled by time_scale" {
    var loop = GameLoop.init();
    loop.max_frame_seconds = 1;
    try std.testing.expectEqual(@as(u32, 1), loop.stepCount(0.1));
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), loop.stepSeconds(0.1), 1e-9);
    loop.time_scale = 2;
    try std.testing.expectApproxEqAbs(@as(f64, 0.2), loop.stepSeconds(0.1), 1e-9);
}

test "fixed timing steps at fixed dt and caps catch-up" {
    var loop = try GameLoop.initFixed(0.1, 2);
    try std.testing.expectEqual(@as(u32, 1), loop.stepCount(0.15));
    try std.testing.expectApproxEqAbs(@as(f64, 0.1), loop.stepSeconds(0.15), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), loop.interpolationAlpha(), 1e-4);
    try std.testing.expectEqual(@as(u32, 2), loop.stepCount(1));
}

test "pause and stop gate stepping" {
    var loop = GameLoop.init();
    loop.pause();
    try std.testing.expectEqual(@as(u32, 0), loop.stepCount(0.1));
    loop.unpause();
    try std.testing.expectEqual(@as(u32, 1), loop.stepCount(0.1));
    loop.stop();
    try std.testing.expect(loop.isStopped());
    try std.testing.expectEqual(@as(u32, 0), loop.stepCount(0.1));
}

test "time_scale zero or negative freezes" {
    var loop = GameLoop.init();
    loop.max_frame_seconds = 1;
    loop.time_scale = 0;
    try std.testing.expectApproxEqAbs(@as(f64, 0), loop.stepSeconds(0.1), 1e-9);
    loop.time_scale = -3;
    try std.testing.expectApproxEqAbs(@as(f64, 0), loop.stepSeconds(0.1), 1e-9);
}

test "frame time is clamped to max_frame_seconds" {
    var loop = GameLoop.init();
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), loop.stepSeconds(10), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), loop.stepSeconds(-1), 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), loop.stepSeconds(std.math.inf(f64)), 1e-9);
}

test "initFixed rejects invalid step" {
    try std.testing.expectError(error.InvalidStep, GameLoop.initFixed(0, 8));
    try std.testing.expectError(error.InvalidStep, GameLoop.initFixed(1.0 / 60.0, 0));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig test src/core/game_loop.zig`
Expected: FAIL — compile error, `GameLoop` / `GameLoop.init` not declared.

- [ ] **Step 3: Implement `src/core/game_loop.zig`**

Type shape (bodies are mechanical; only `stepCount` mutates the stepper):

```zig
const std = @import("std");
const FixedStepper = @import("time.zig").FixedStepper;

pub const State = enum { running, paused, stopped };
pub const Timing = union(enum) { variable, fixed: FixedStepper };

pub const GameLoop = struct {
    state: State = .running,
    timing: Timing = .variable,
    time_scale: f64 = 1,
    max_frame_seconds: f64 = 0.25,

    pub fn init() GameLoop { return .{}; }

    pub fn initFixed(step_seconds: f64, max_steps: u32) !GameLoop {
        return .{ .timing = .{ .fixed = try FixedStepper.init(step_seconds, max_steps) } };
    }

    pub fn pause(self: *GameLoop) void { self.state = .paused; }
    pub fn unpause(self: *GameLoop) void { self.state = .running; }
    pub fn stop(self: *GameLoop) void { self.state = .stopped; }
    pub fn isStopped(self: GameLoop) bool { return self.state == .stopped; }

    /// Non-finite frame times clamp to `max_frame_seconds`; otherwise `[0, max]`.
    pub fn clampFrameSeconds(self: GameLoop, frame_seconds: f64) f64 {
        if (!std.math.isFinite(frame_seconds)) return self.max_frame_seconds;
        return std.math.clamp(frame_seconds, 0, self.max_frame_seconds);
    }

    fn scaled(self: GameLoop, frame_seconds: f64) f64 {
        return self.clampFrameSeconds(frame_seconds) * @max(0, self.time_scale);
    }

    pub fn stepCount(self: *GameLoop, frame_seconds: f64) u32 {
        if (self.state != .running) return 0;
        return switch (self.timing) {
            .variable => 1,
            .fixed => |*stepper| stepper.advance(self.scaled(frame_seconds)),
        };
    }

    pub fn stepSeconds(self: GameLoop, frame_seconds: f64) f64 {
        return switch (self.timing) {
            .variable => self.scaled(frame_seconds),
            .fixed => |stepper| stepper.step_seconds,
        };
    }

    pub fn interpolationAlpha(self: GameLoop) f32 {
        return switch (self.timing) {
            .variable => 0,
            .fixed => |stepper| stepper.interpolationAlpha(),
        };
    }
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig test src/core/game_loop.zig`
Expected: PASS — all 6 tests.

- [ ] **Step 5: Export from root and run the full suite**

Add to `src/root.zig` after `pub const Time = ...;`:
```zig
pub const GameLoop = @import("core/game_loop.zig").GameLoop;
```
and inside the `test {}` block add `_ = @import("core/game_loop.zig");`.

Run: `zig build test`
Expected: all suites pass (existing + new).

- [ ] **Step 6: Commit**

```bash
git add src/core/game_loop.zig src/root.zig
git commit -m "feat: add GameLoop timing controller"
```

---

### Task 2: `World` deferred destruction

**Files:**
- Modify: `src/ecs/world.zig` (field, `deinit`, three methods, inline test)

**Interfaces:**
- Consumes: existing `World.destroy(entity) !void` (error set includes `error.InvalidEntity` and `error.OutOfMemory`), `World.isAlive`, `Entity`.
- Produces (on `World`):
  - `pub fn destroyDeferred(*World, entity: Entity) !void`
  - `pub fn flushDeferred(*World) void`
  - `pub fn pendingDestroyCount(*const World) usize`

- [ ] **Step 1: Write the failing test**

Append to `src/ecs/world.zig`:

```zig
test "destroyDeferred queues until flush and ignores already dead" {
    const Tag = struct { x: f32 };

    var world = World.init(std.testing.allocator);
    defer world.deinit();

    const a = try world.create();
    const b = try world.create();
    try world.add(a, Tag{ .x = 1 });
    try world.destroyDeferred(a);
    try world.destroyDeferred(b);
    try world.destroyDeferred(a);

    try std.testing.expect(world.isAlive(a));
    try std.testing.expectEqual(@as(usize, 3), world.pendingDestroyCount());

    world.flushDeferred();
    try std.testing.expect(!world.isAlive(a));
    try std.testing.expect(!world.isAlive(b));
    try std.testing.expectEqual(@as(usize, 0), world.pendingDestroyCount());
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/ecs/world.zig`
Expected: FAIL — `destroyDeferred` not declared.

- [ ] **Step 3: Implement**

Add field after `archetypes` (line ~23):
```zig
pending_destroys: std.ArrayListUnmanaged(Entity) = .empty,
```
In `deinit` add:
```zig
self.pending_destroys.deinit(self.allocator);
```
Add methods (place near `destroy`):
```zig
/// Queue an entity for destruction at a safe boundary (end of frame).
/// Destroying while a query is iterating is unsafe; use `flushDeferred`.
pub fn destroyDeferred(self: *World, entity: Entity) !void {
    try self.pending_destroys.append(self.allocator, entity);
}

/// Destroys every queued entity. Already-dead entities are dropped; an
/// entity whose destroy fails with OutOfMemory stays queued for a retry.
pub fn flushDeferred(self: *World) void {
    var index: usize = 0;
    while (index < self.pending_destroys.items.len) {
        const entity = self.pending_destroys.items[index];
        if (self.destroy(entity)) {
            _ = self.pending_destroys.swapRemove(index);
        } else |err| switch (err) {
            error.InvalidEntity => _ = self.pending_destroys.swapRemove(index),
            else => index += 1,
        }
    }
}

pub fn pendingDestroyCount(self: *const World) usize {
    return self.pending_destroys.items.len;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/ecs/world.zig`
Expected: PASS (existing world test + new test).

- [ ] **Step 5: Commit**

```bash
git add src/ecs/world.zig
git commit -m "feat: add deferred entity destruction to World"
```

---

### Task 3: `Reclaimer`

**Files:**
- Create: `src/core/reclaimer.zig`
- Modify: `src/root.zig` (export + test block)
- Test: inline `test` in `src/core/reclaimer.zig`

**Interfaces:**
- Consumes: `FrameArena` from `src/core/allocator.zig` (`init(parent)`, `allocator()`, `endFrame()`, `deinit()`, field `arena: std.heap.ArenaAllocator`); `World.flushDeferred()` from Task 2.
- Produces:
  - `pub const Reclaimer = struct { arena: FrameArena, ... }`
  - `pub fn init(std.mem.Allocator) Reclaimer`, `pub fn deinit(*Reclaimer) void`
  - `pub fn frameAllocator(*Reclaimer) std.mem.Allocator`
  - `pub fn arenaBytes(*const Reclaimer) usize`
  - `pub fn collect(*Reclaimer, world: *World) void`
  - root export: `ez_engine.Reclaimer`

- [ ] **Step 1: Write the failing test**

Create `src/core/reclaimer.zig` with imports and the test (implementation added in Step 3):

```zig
const std = @import("std");
const FrameArena = @import("allocator.zig").FrameArena;
const World = @import("../ecs/world.zig").World;

test "collect flushes deferred destroys and resets the frame arena" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var reclaimer = Reclaimer.init(std.testing.allocator);
    defer reclaimer.deinit();

    const entity = try world.create();
    try world.destroyDeferred(entity);

    const scratch = try reclaimer.frameAllocator().alloc(u8, 1024);
    scratch[0] = 7;
    try std.testing.expect(reclaimer.arenaBytes() > 0);

    reclaimer.collect(&world);
    try std.testing.expect(!world.isAlive(entity));
    try std.testing.expectEqual(@as(usize, 0), world.pendingDestroyCount());

    // Arena is reusable after the reset.
    const again = try reclaimer.frameAllocator().alloc(u8, 32);
    again[0] = 1;
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/core/reclaimer.zig`
Expected: FAIL — `Reclaimer` not declared.

- [ ] **Step 3: Implement**

```zig
/// End-of-frame reclamation: flushes `World`'s deferred destroys and resets
/// the per-frame arena. Call `collect` once per rendered frame, after systems
/// have finished iterating.
pub const Reclaimer = struct {
    arena: FrameArena,

    pub fn init(allocator: std.mem.Allocator) Reclaimer {
        return .{ .arena = FrameArena.init(allocator) };
    }

    pub fn deinit(self: *Reclaimer) void {
        self.arena.deinit();
    }

    /// Allocator for temporary, frame-scoped data. Freed at the next `collect`.
    pub fn frameAllocator(self: *Reclaimer) std.mem.Allocator {
        return self.arena.allocator();
    }

    /// Bytes currently held by the frame arena (retained across resets).
    pub fn arenaBytes(self: *const Reclaimer) usize {
        return self.arena.arena.queryCapacity();
    }

    pub fn collect(self: *Reclaimer, world: *World) void {
        world.flushDeferred();
        self.arena.endFrame();
    }
};
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/core/reclaimer.zig`
Expected: PASS.

- [ ] **Step 5: Export from root and run the full suite**

Add to `src/root.zig`:
```zig
pub const Reclaimer = @import("core/reclaimer.zig").Reclaimer;
```
and `_ = @import("core/reclaimer.zig");` in the `test {}` block.

Run: `zig build test`
Expected: all suites pass.

- [ ] **Step 6: Commit**

```bash
git add src/core/reclaimer.zig src/root.zig
git commit -m "feat: add Reclaimer frame-scoped cleanup"
```

---

### Task 4: `Input.clearEdges`

**Files:**
- Modify: `src/input/input.zig` (method + inline test)

**Interfaces:**
- Produces: `pub fn clearEdges(*Input) void` — clears `pressed`/`released` on all keys and mouse buttons, keeps `down`.

- [ ] **Step 1: Write the failing test**

Append to `src/input/input.zig`:

```zig
test "clearEdges drops edges but keeps held state" {
    var input: Input = .{};
    input.setKey(.space, true);
    input.setMouseButton(.left, true);
    input.clearEdges();
    try std.testing.expect(input.isDown(.space));
    try std.testing.expect(!input.justPressed(.space));
    try std.testing.expect(input.mouseButton(.left).down);
    try std.testing.expect(!input.mouseButton(.left).pressed);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig test src/input/input.zig`
Expected: FAIL — `clearEdges` not declared.

- [ ] **Step 3: Implement**

Add to `Input` (near `beginFrame`):
```zig
/// Clears pressed/released edges while keeping held state. Call after the
/// first simulation step of a frame so edge-triggered actions fire once even
/// when a frame runs several fixed steps.
pub fn clearEdges(self: *Input) void {
    for (&self.keys) |*button| {
        button.pressed = false;
        button.released = false;
    }
    for (&self.mouse_buttons) |*button| {
        button.pressed = false;
        button.released = false;
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `zig test src/input/input.zig`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/input/input.zig
git commit -m "feat: add Input.clearEdges for fixed-step edge handling"
```

---

### Task 5: `Game` integration (loop + reclaimer)

**Files:**
- Modify: `src/game.zig` (imports, fields, `init`/`deinit`, split `frame`, add `update`/`present`/`tick`/`destroyDeferred`/`frameAllocator`, `run`; inline tests)

**Interfaces:**
- Consumes: `GameLoop` (Task 1), `Reclaimer` (Task 3), `World.destroyDeferred` (Task 2), `Input.clearEdges` (Task 4), `Entity`.
- Produces (on `Game`):
  - fields: `loop: GameLoop = .{}`, `reclaimer: Reclaimer`
  - `pub fn update(*Game, dt: f32) !void`
  - `pub fn present(*Game, frame_seconds: f32) !void`
  - `pub fn frame(*Game, dt: f32) !void` (unchanged behavior)
  - `pub fn tick(*Game, frame_seconds: f64) !void`
  - `pub fn destroyDeferred(*Game, entity: Entity) !void`
  - `pub fn frameAllocator(*Game) std.mem.Allocator`

- [ ] **Step 1: Write the failing tests**

Append to `src/game.zig` (add near the other inline tests):

```zig
test "game tick runs fixed steps and presents once" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop = try GameLoop.initFixed(0.1, 8);

    var updates: u32 = 0;
    const Counter = struct {
        fn run(context: ?*anyopaque, _: *World, _: f32) anyerror!void {
            const count: *u32 = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    _ = try game.scheduler.addSystem("Count", &updates, Counter.run);

    try game.tick(0.25);
    try std.testing.expectEqual(@as(u32, 2), updates);
    try std.testing.expectEqual(@as(u64, 1), game.frame_index);
}

test "paused loop presents without stepping" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop.pause();

    var updates: u32 = 0;
    const Counter = struct {
        fn run(context: ?*anyopaque, _: *World, _: f32) anyerror!void {
            const count: *u32 = @ptrCast(@alignCast(context.?));
            count.* += 1;
        }
    };
    _ = try game.scheduler.addSystem("Count", &updates, Counter.run);

    try game.tick(0.25);
    try std.testing.expectEqual(@as(u32, 0), updates);
    try std.testing.expectEqual(@as(u64, 1), game.frame_index);
}

test "stopped loop does not present or step" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop.stop();
    try std.testing.expect(game.loop.isStopped());
    try game.tick(0.25);
    try std.testing.expectEqual(@as(u64, 0), game.frame_index);
}

test "fixed loop consumes an input edge once per frame" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop = try GameLoop.initFixed(0.1, 8);
    game.input.setKey(.space, true);

    var presses: u32 = 0;
    const Probe = struct {
        game: *Game,
        presses: *u32,
        fn run(context: ?*anyopaque, _: *World, _: f32) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            if (self.game.input.justPressed(.space)) self.presses.* += 1;
        }
    };
    var probe = Probe{ .game = &game, .presses = &presses };
    _ = try game.scheduler.addSystem("Probe", &probe, Probe.run);

    try game.tick(0.25);
    try std.testing.expectEqual(@as(u32, 1), presses);
}

test "deferred entity is destroyed after a frame" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    const entity = try game.world.create();
    try game.destroyDeferred(entity);
    try std.testing.expect(game.world.isAlive(entity));
    try game.frame(1.0 / 60.0);
    try std.testing.expect(!game.world.isAlive(entity));
}

test "frame allocator is reusable across frames" {
    var game = try Game.init(std.testing.allocator, 2);
    defer game.deinit();
    const first = try game.frameAllocator().alloc(u8, 256);
    first[0] = 1;
    try game.frame(1.0 / 60.0);
    const second = try game.frameAllocator().alloc(u8, 256);
    second[0] = 2;
    try std.testing.expect(game.reclaimer.arenaBytes() > 0);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `zig build test 2>&1 | tail -40`
Expected: FAIL — no field `loop`, no method `tick`, etc.

- [ ] **Step 3: Implement**

Imports (add): `const Entity = @import("ecs/entity.zig").Entity;`, `const GameLoop = @import("core/game_loop.zig").GameLoop;`, `const Reclaimer = @import("core/reclaimer.zig").Reclaimer;`.

Fields (add): `loop: GameLoop = .{},` and `reclaimer: Reclaimer,`.

`init`: add `.reclaimer = Reclaimer.init(allocator),`.

`deinit`: add `self.reclaimer.deinit();` before `self.world.deinit();`.

Replace the existing `frame` body with these three functions (the old body becomes `present`, minus the dt validation which moves to `update`; `debug.captureFrame` now takes `frame_seconds`):

```zig
pub fn update(self: *Game, dt: f32) !void {
    if (!std.math.isFinite(dt) or dt < 0) return error.InvalidDeltaTime;
    try self.scheduler.run(&self.world, dt);
}

pub fn present(self: *Game, frame_seconds: f32) !void {
    try self.render_world.extract(&self.world);
    const extracted_render_items = self.render_world.items.items.len;
    if (self.framebuffer_extent.width > 0 and self.framebuffer_extent.height > 0) {
        const aspect = @as(f32, @floatFromInt(self.framebuffer_extent.width)) /
            @as(f32, @floatFromInt(self.framebuffer_extent.height));
        self.camera_2d.viewport_size.y = self.camera_2d.viewport_size.x / aspect;
    }
    try self.render_world.cullSprites2D(self.camera_2d);
    self.render_world.sortForBatching();
    if (self.renderer) |renderer| {
        if (self.framebuffer_extent.width > 0 and self.framebuffer_extent.height > 0 and
            (self.framebuffer_extent.width != self.rendered_extent.width or
                self.framebuffer_extent.height != self.rendered_extent.height))
        {
            try renderer.resize(.{
                .width = self.framebuffer_extent.width,
                .height = self.framebuffer_extent.height,
            });
            self.rendered_extent = self.framebuffer_extent;
        }
        try renderer.render(&self.render_world);
    }
    self.frame_index += 1;
    self.debug.captureFrame(
        self.frame_index,
        frame_seconds,
        self.world.aliveCount(),
        extracted_render_items,
        &self.render_world,
    );
    self.reclaimer.collect(&self.world);
}

pub fn frame(self: *Game, dt: f32) !void {
    try self.update(dt);
    try self.present(dt);
}

pub fn tick(self: *Game, frame_seconds: f64) !void {
    if (self.loop.isStopped()) return;
    const steps = self.loop.stepCount(frame_seconds);
    var index: u32 = 0;
    while (index < steps) : (index += 1) {
        const step_dt: f32 = @floatCast(self.loop.stepSeconds(frame_seconds));
        try self.update(step_dt);
        if (index == 0) self.input.clearEdges();
    }
    try self.present(@floatCast(self.loop.clampFrameSeconds(frame_seconds)));
}

pub fn destroyDeferred(self: *Game, entity: Entity) !void {
    try self.world.destroyDeferred(entity);
}

pub fn frameAllocator(self: *Game) std.mem.Allocator {
    return self.reclaimer.frameAllocator();
}
```

`run`: replace the body's `while` condition and inner frame call:
```zig
while (self.running and !self.loop.isStopped() and !window.shouldClose()) {
    self.beginFrame();
    try window.pollEvents(onPlatformEvent, self);
    if (!self.running or window.shouldClose()) break;
    try self.tick(clock.tick(io));
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -40`
Expected: PASS — new Game tests plus all existing suites (notably `script_test.zig` and the two original `game.zig` frame tests).

- [ ] **Step 5: Commit**

```bash
git add src/game.zig
git commit -m "feat: wire GameLoop and Reclaimer into Game"
```

---

### Task 6: `update_count` and `onStart`

**Files:**
- Modify: `src/game.zig` (field + increment in `update`)
- Modify: `src/script/script.zig` (systemFn gate)
- Test: `tests/script_test.zig`

**Interfaces:**
- Produces: `Game.update_count: u64` (increments once per executed `update`); `Script.systemFn` runs `onStart` when `game.update_count == 0`.
- Depends on Task 5 (`Game.tick`, `Game.loop`).

- [ ] **Step 1: Write the failing test**

Append to `tests/script_test.zig`:

```zig
test "onStart runs on the first update even when the loop starts paused" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop.pause();

    var counter = Counter{};
    var script = ez_engine.Script.initWithStart(&game, &counter);
    try script.register(&game.scheduler, "PausedCounter");

    try game.tick(0.25);
    try std.testing.expectEqual(@as(u32, 0), counter.starts);
    try std.testing.expectEqual(@as(u32, 0), counter.updates);

    game.loop.unpause();
    try game.tick(0.25);
    try std.testing.expectEqual(@as(u32, 1), counter.starts);
    try std.testing.expectEqual(@as(u32, 1), counter.updates);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -40`
Expected: FAIL — `counter.starts == 0` after resume (the `frame_index == 0` gate was already consumed by the paused `tick`).

- [ ] **Step 3: Implement**

`src/game.zig`: add field `update_count: u64 = 0,` (near `frame_index`). In `update`, after `try self.scheduler.run(&self.world, dt);` add `self.update_count += 1;`.

`src/script/script.zig` line 87: change `if (self.game.frame_index == 0) {` to `if (self.game.update_count == 0) {`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -40`
Expected: PASS — new test plus the three existing `script_test.zig` tests (unchanged behavior).

- [ ] **Step 5: Commit**

```bash
git add src/game.zig src/script/script.zig tests/script_test.zig
git commit -m "fix: run onStart on first update, not first presented frame"
```

---

### Task 7: `Script.Ctx.frame_allocator`

**Files:**
- Modify: `src/script/script.zig` (`Ctx` field + `systemFn`)
- Test: `tests/script_test.zig`

**Interfaces:**
- Consumes: `Game.frameAllocator()` (Task 5).
- Produces: `Script.Ctx{ world, game, dt, frame_allocator: std.mem.Allocator }`.

- [ ] **Step 1: Write the failing test**

Append to `tests/script_test.zig`:

```zig
test "script context exposes a reusable frame allocator" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();

    const Allocator = struct {
        bytes: usize = 0,
        pub fn onUpdate(self: *@This(), ctx: *ez_engine.Script.Ctx) !void {
            const buffer = try ctx.frame_allocator.alloc(u8, 64);
            self.bytes += buffer.len;
        }
    };
    var behavior = Allocator{};
    var script = ez_engine.Script.init(&game, &behavior);
    try script.register(&game.scheduler, "Allocator");

    try game.frame(1.0 / 60.0);
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(usize, 128), behavior.bytes);
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `zig build test 2>&1 | tail -40`
Expected: FAIL — `Ctx` has no field `frame_allocator`.

- [ ] **Step 3: Implement**

In `src/script/script.zig`, add to `Ctx`: `frame_allocator: std.mem.Allocator,`. In `systemFn`, change the context construction to:
```zig
var ctx = Ctx{
    .world = world,
    .game = self.game,
    .dt = dt,
    .frame_allocator = self.game.frameAllocator(),
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `zig build test 2>&1 | tail -40`
Expected: PASS — no leak reported by `std.testing.allocator` (the arena is freed by `game.deinit`).

- [ ] **Step 5: Commit**

```bash
git add src/script/script.zig tests/script_test.zig
git commit -m "feat: expose frame allocator on Script.Ctx"
```

---

### Task 8: Integration test, build wiring, docs

**Files:**
- Create: `tests/loop_reclaim_test.zig`
- Modify: `build.zig` (register the test file)
- Modify: `docs/api.md`, `CHANGELOG.md`, `README.md`

**Interfaces:**
- Consumes: all public exports from Tasks 1–7.
- Produces: none (verification + documentation).

- [ ] **Step 1: Write the integration test**

Create `tests/loop_reclaim_test.zig`:

```zig
const std = @import("std");
const ez = @import("ez_engine");

test "public GameLoop drives fixed steps and reclaims deferred entities" {
    var game = try ez.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    game.loop = try ez.GameLoop.initFixed(0.1, 8);

    const entity = try game.world.create();
    try game.destroyDeferred(entity);

    try game.tick(0.25);
    try std.testing.expect(!game.world.isAlive(entity));
    try std.testing.expectEqual(@as(u64, 1), game.frame_index);
    _ = game.reclaimer.arenaBytes();
}

test "Reclaimer works without a Game" {
    var world = ez.World.init(std.testing.allocator);
    defer world.deinit();
    var reclaimer = ez.Reclaimer.init(std.testing.allocator);
    defer reclaimer.deinit();

    const entity = try world.create();
    try world.destroyDeferred(entity);
    try std.testing.expectEqual(@as(usize, 1), world.pendingDestroyCount());

    reclaimer.collect(&world);
    try std.testing.expect(!world.isAlive(entity));
    try std.testing.expectEqual(@as(usize, 0), world.pendingDestroyCount());

    const buffer = try reclaimer.frameAllocator().alloc(u8, 8);
    buffer[0] = 1;
}
```

- [ ] **Step 2: Register the test file in `build.zig`**

In the `inline for (.{ ... })` list at line 48, add `"loop_reclaim_test.zig"` (after `"input_test.zig"`).

- [ ] **Step 3: Run the new test**

Run: `zig build test 2>&1 | tail -40`
Expected: PASS — including the new integration file.

- [ ] **Step 4: Update `docs/api.md`**

In the "Game loop" section, extend the bullets:
- `Game.tick(frame_seconds: f64) !void` — drives `GameLoop`: runs 0..N simulation steps then one present; clamps frame time to `loop.max_frame_seconds`.
- `Game.update(dt: f32) !void` / `Game.present(frame_seconds: f32) !void` — the split halves of `frame(dt)`.
- `Game.loop: GameLoop` — timing controller (`time_scale`, `pause`/`resume`/`stop`, `GameLoop.initFixed(step, max_steps)`).
- `Game.destroyDeferred(entity)` and `Game.frameAllocator() !void`-style helpers; `game.reclaimer`.
Add a new bullet under "ECS" for `World.destroyDeferred(entity)`, `World.flushDeferred()`, `World.pendingDestroyCount()`.
Add under "Input, platform, scene": `Input.clearEdges()`.
Extend the `Script.Ctx{ world, game, dt }` line to `{ world, game, dt, frame_allocator }` and note `GameLoop`/`Reclaimer` in the "Stability/other exports" list (line ~94).

- [ ] **Step 5: Update `CHANGELOG.md`**

Under `## Unreleased` → `### Added`, append:
```
- Managed game loop: `GameLoop` (variable/fixed timestep via `FixedStepper`,
  `time_scale`, pause/unpause/stop, frame-time clamp) and `Game.tick`; `Game`
  gains split `update`/`present` (with `frame(dt)` unchanged).
- Automatic end-of-frame reclamation: `World.destroyDeferred`/`flushDeferred`,
  `Reclaimer` + per-frame `FrameArena` (`Game.frameAllocator`,
  `Script.Ctx.frame_allocator`), and `Input.clearEdges` so edge-triggered
  actions fire once per rendered frame under fixed timestep.
```

- [ ] **Step 6: Update `README.md`**

Add a short "Game loop & dọn rác" section documenting: choose `variable` (default) or `game.loop = try GameLoop.initFixed(step, max_steps)`; `loop.pause()/unpause()/stop()`; `game.destroyDeferred(entity)` destroys at end of frame; `game.frameAllocator()` / `ctx.frame_allocator` are reclaimed each frame.

- [ ] **Step 7: Full verification**

Run each and confirm:
- `zig build test 2>&1 | tail -20` → all pass.
- `zig build` → exit 0.
- `zig fmt --check src tests build.zig` → exit 0 (run `zig fmt src tests build.zig` first if it reports diffs).

- [ ] **Step 8: Commit**

```bash
git add tests/loop_reclaim_test.zig build.zig docs/api.md CHANGELOG.md README.md
git commit -m "test+docs: cover loop/reclaim integration and document it"
```

---

## Self-Review Notes

- **Spec coverage:** §1 GameLoop → Task 1; §2 World queue + Reclaimer → Tasks 2–3; §3 Game integration → Task 5; §4 input edges → Tasks 4–5; §5 update_count → Task 6; §7 frame allocator for gameplay → Task 7; docs → Task 8. Non-goals intentionally absent.
- **Type consistency:** `stepCount`/`stepSeconds`/`clampFrameSeconds`/`interpolationAlpha`, `destroyDeferred`/`flushDeferred`/`pendingDestroyCount`, `frameAllocator`/`arenaBytes`/`collect`, `update`/`present`/`frame`/`tick`, `update_count`, `Ctx.frame_allocator` are named identically across producing and consuming tasks.
- **Review Focus:** each of the five items has an owning test (Task 1 `max_steps`, Task 2 duplicate/dead, Task 3+5+7 frame allocator, Task 5 input edge, Task 6 paused start).
