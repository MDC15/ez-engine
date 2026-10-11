# Physics, collision layers, and ergonomic gameplay — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a game author filter collisions by a collider tag/layer, move entities with a small 2D physics step (velocity/gravity/damping/bounce), and write gameplay without touching `Script.Ctx`.

**Architecture:** Extend the existing AABB `Collision2D` with a layer/mask filter and a restitution response; add a new `Physics2D` integrator module that runs before collision; extend the `Script` comptime adapter to accept `onUpdate(self, game, dt)`; refresh the scaffold template to wire the defaults and turn debug on.

**Tech Stack:** Zig 0.16.0, in-engine, no new dependencies.

**Spec:** `docs/superpowers/specs/2026-10-10-physics-and-ergonomics-design.md`

## Global Constraints

- Zig 0.16.0; build/test with `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local"` (already exported in this environment).
- No new dependencies. `ez_engine` module stays graphics-backend free; `Physics2D` must not import `Collision2D` (avoids an import cycle) — `Collision2D` imports `Physics2D` for `Velocity`.
- Backward compatibility: existing `Collider2D` defaults and existing `Script` `onUpdate(self, *Ctx)` behaviors keep working; `zig build test` must stay green.
- Component values are plain data, alignment <= 16 bytes (ECS requirement).
- `std.ArrayListUnmanaged` initializes to `.empty`, never `.{}`.
- Every changed `src/`/`tests/` file must pass `zig fmt`.
- Work stays on `master` at the human partner's request (no worktree/branch).

## Review Focus

Inputs/conditions the spec implies but no task's own happy-path test covers — each gets a test in the owning task:

1. One-sided mask mismatch: `a.collides_with` includes `b.layer` but `b.collides_with` excludes `a.layer` — a reasonable person expects **no** contact (the rule is AND). (Task 1)
2. `Velocity` present but no `RigidBody2D` — expects constant-velocity motion with **no** gravity. (Task 2)
3. `kinematic` body overlapping a `dynamic` body — expects the kinematic body to **not** be pushed. (Task 3)
4. Non-finite or negative `dt` passed to the physics step — expects a clean error, not NaN written into transforms. (Task 2)
5. New-shape `onUpdate(self, game, dt)` whose return type is `void` (no `!`) — expects it to compile and run, like the legacy `void` form. (Task 4)

---

### Task 1: Collision layer/mask filtering

**Files:**
- Modify: `src/physics/collision2d.zig`
- Test: `src/physics/collision2d.zig` (inline `test` blocks)

**Interfaces:**
- Consumes: existing `Collider2D`, `System.update`.
- Produces: `Collider2D.layer: u4`, `Collider2D.collides_with: u16`, `Collision2D.layerBit(index: u4) u16`.

- [ ] **Step 1: Write the failing tests**

Add to `src/physics/collision2d.zig`:

```zig
test "non-matching layers produce no contact" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const a = try world.create();
    const b = try world.create();
    try world.add(a, Components.Transform{});
    try world.add(b, Components.Transform{});
    try world.add(a, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 1, .collides_with = layerBit(1) });
    try world.add(b, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 2, .collides_with = layerBit(2) });
    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(usize, 0), system.active_contacts.items.len);
}

test "one-sided mask mismatch produces no contact" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const a = try world.create();
    const b = try world.create();
    try world.add(a, Components.Transform{});
    try world.add(b, Components.Transform{});
    try world.add(a, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 1, .collides_with = layerBit(1) | layerBit(2) });
    try world.add(b, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 2, .collides_with = layerBit(2) });
    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(usize, 0), system.active_contacts.items.len);
}

test "matching layers still report a contact" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const a = try world.create();
    const b = try world.create();
    try world.add(a, Components.Transform{});
    try world.add(b, Components.Transform{});
    try world.add(a, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 1, .collides_with = layerBit(2) });
    try world.add(b, Collider2D{ .size = .{ .x = 10, .y = 10 }, .layer = 2, .collides_with = layerBit(1) });
    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(usize, 1), system.active_contacts.items.len);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test 2>&1 | grep -i error | head`
Expected: compile error `no field named 'layer'` / `no field named 'collides_with'` / `layerBit` undefined (the first two tests cannot even compile without the new fields). Note the third test would also fail on `layerBit` being undefined.

- [ ] **Step 3: Implement the fields and filter**

In `Collider2D` add after `is_static`:

```zig
    /// Collision layer bit index (0..15). Like an id/tag for the collider.
    layer: u4 = 0,
    /// Which layers this collider reacts to. Default: every layer.
    collides_with: u16 = 0xffff,
```

Add, near `Event`/`EventKind`:

```zig
/// Mask with exactly `index` set — the bit that stands for layer `index`.
pub fn layerBit(index: u4) u16 {
    return @as(u16, 1) << index;
}
```

In `System.update`, inside the pair loop, add the filter as the first check:

```zig
        for (self.bodies.items, 0..) |*lhs, lhs_index| {
            for (self.bodies.items[lhs_index + 1 ..]) |*rhs| {
                if (!interacts(lhs.collider, rhs.collider)) continue;
                if (!overlaps(lhs.*, rhs.*)) continue;
```

Add the helper near `overlaps`:

```zig
fn interacts(a: *const Collider2D, b: *const Collider2D) bool {
    return (a.collides_with & layerBit(b.layer)) != 0 and
        (b.collides_with & layerBit(a.layer)) != 0;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test --summary all 2>&1 | grep -E "Build Summary|error"`
Expected: `Build Summary: ... succeeded; N/N tests passed` (N = previous 69 + 3).

- [ ] **Step 5: Commit**

```bash
git add src/physics/collision2d.zig
git commit -m "feat: filter collisions by collider layer and mask"
```

---

### Task 2: Physics2D integrator

**Files:**
- Create: `src/physics/physics2d.zig`
- Modify: `src/root.zig` (export + test-import block)
- Test: `src/physics/physics2d.zig` (inline `test` blocks)

**Interfaces:**
- Consumes: `World`, `RenderComponents.Transform`, `Vec2`, `Query.Optional`.
- Produces:
  - `Physics2D.Velocity { linear: Vec2 = .zero }`
  - `Physics2D.BodyType = enum { static, kinematic, dynamic }`
  - `Physics2D.RigidBody2D { body_type: BodyType = .dynamic, gravity_scale: f32 = 1, linear_damping: f32 = 0, restitution: f32 = 0 }`
  - `Physics2D.System { gravity: Vec2 = .{ .x = 0, .y = -981 } }` with `init()`, `updateSystem(?*anyopaque, *World, f32) anyerror!void`, `update(*World, f32) !void`.

- [ ] **Step 1: Write the failing tests**

Create `src/physics/physics2d.zig` with the header and tests only (implementation comes next):

```zig
const std = @import("std");
const World = @import("../ecs/world.zig").World;
const Components = @import("../gfx/render_components.zig");
const Vec2 = @import("../math/vec2.zig").Vec2;
const Query = @import("../ecs/query.zig");

test "gravity accelerates a dynamic body and integrates position" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try world.add(e, Components.Transform{});
    try world.add(e, Velocity{});
    try world.add(e, RigidBody2D{ .gravity_scale = 1 });
    var system = System{ .gravity = .{ .x = 0, .y = -10 } };
    try system.update(&world, 0.5);
    try std.testing.expectEqual(@as(f32, -5), (try world.get(e, Velocity)).linear.y);
    try std.testing.expectEqual(@as(f32, -2.5), (try world.get(e, Components.Transform)).position.y);
}

test "linear damping slows a body" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try world.add(e, Components.Transform{});
    try world.add(e, Velocity{ .linear = .{ .x = 10, .y = 0 } });
    try world.add(e, RigidBody2D{ .gravity_scale = 0, .linear_damping = 1 });
    var system = System{ .gravity = .zero };
    try system.update(&world, 0.5);
    try std.testing.expectEqual(@as(f32, 5), (try world.get(e, Velocity)).linear.x);
    try std.testing.expectEqual(@as(f32, 2.5), (try world.get(e, Components.Transform)).position.x);
}

test "velocity without a rigid body has no gravity" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const e = try world.create();
    try world.add(e, Components.Transform{});
    try world.add(e, Velocity{ .linear = .{ .x = 4, .y = 0 } });
    var system = System{ .gravity = .{ .x = 0, .y = -10 } };
    try system.update(&world, 0.5);
    try std.testing.expectEqual(@as(f32, 4), (try world.get(e, Velocity)).linear.x);
    try std.testing.expectEqual(@as(f32, 0), (try world.get(e, Velocity)).linear.y);
    try std.testing.expectEqual(@as(f32, 2), (try world.get(e, Components.Transform)).position.x);
}

test "kinematic moves by velocity and static does not move" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const k = try world.create();
    const s = try world.create();
    try world.add(k, Components.Transform{});
    try world.add(k, Velocity{ .linear = .{ .x = 2, .y = 0 } });
    try world.add(k, RigidBody2D{ .body_type = .kinematic });
    try world.add(s, Components.Transform{ .position = .{ .x = 7 } });
    try world.add(s, Velocity{ .linear = .{ .x = 2, .y = 0 } });
    try world.add(s, RigidBody2D{ .body_type = .static });
    var system = System{ .gravity = .{ .x = 0, .y = -10 } };
    try system.update(&world, 0.5);
    try std.testing.expectEqual(@as(f32, 1), (try world.get(k, Components.Transform)).position.x);
    try std.testing.expectEqual(@as(f32, 2), (try world.get(k, Velocity)).linear.x);
    try std.testing.expectEqual(@as(f32, 7), (try world.get(s, Components.Transform)).position.x);
}

test "non-finite or negative dt is rejected" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    var system = System{};
    try std.testing.expectError(error.InvalidDeltaTime, system.update(&world, -1));
    try std.testing.expectError(error.InvalidDeltaTime, system.update(&world, std.math.nan(f32)));
}
```

Then register the module in `src/root.zig` (this is what makes the tests run):

Add near the other exports (after `Collision2D`):

```zig
pub const Physics2D = @import("physics/physics2d.zig");
```

Add inside `test { ... }` (after the `physics/collision2d.zig` line):

```zig
    _ = @import("physics/physics2d.zig");
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test 2>&1 | grep -iE "error|physics2d" | head`
Expected: compile errors — `use of undeclared identifier 'Velocity'`, `'RigidBody2D'`, `'System'`.

- [ ] **Step 3: Implement the module**

Add before the tests in `src/physics/physics2d.zig`:

```zig
/// Linear velocity in world units per second.
pub const Velocity = struct {
    linear: Vec2 = .zero,
};

/// How a body responds to the physics step and to collisions.
pub const BodyType = enum { static, kinematic, dynamic };

/// Motion parameters for a `Velocity` body. Add this to enable gravity,
/// damping and bounce; omit it for constant-velocity motion.
pub const RigidBody2D = struct {
    body_type: BodyType = .dynamic,
    gravity_scale: f32 = 1,
    linear_damping: f32 = 0,
    restitution: f32 = 0,
};

/// Integrates `Velocity` into `Transform` each step. Run it before the
/// `Collision2D` system so contacts see the moved positions.
pub const System = struct {
    gravity: Vec2 = .{ .x = 0, .y = -981 },

    pub fn init() System {
        return .{};
    }

    pub fn updateSystem(context: ?*anyopaque, world: *World, dt: f32) anyerror!void {
        const self: *System = @ptrCast(@alignCast(context.?));
        try self.update(world, dt);
    }

    pub fn update(self: *System, world: *World, dt: f32) !void {
        if (!std.math.isFinite(dt) or dt < 0) return error.InvalidDeltaTime;
        var query = world.query(.{ Components.Transform, Velocity, Query.Optional(RigidBody2D) });
        while (query.next()) |item| {
            const body_type: BodyType = if (item.RigidBody2D) |body| body.body_type else .dynamic;
            if (body_type == .static) continue;
            const gravity_scale: f32 = if (item.RigidBody2D) |body| body.gravity_scale else 0;
            const damping: f32 = if (item.RigidBody2D) |body| body.linear_damping else 0;

            const velocity = &item.Velocity.linear;
            if (body_type == .dynamic) {
                velocity.x += self.gravity.x * gravity_scale * dt;
                velocity.y += self.gravity.y * gravity_scale * dt;
                if (damping > 0) {
                    const factor = @max(@as(f32, 0), 1 - damping * dt);
                    velocity.x *= factor;
                    velocity.y *= factor;
                }
            }
            item.Transform.position.x += velocity.x * dt;
            item.Transform.position.y += velocity.y * dt;
        }
    }
};
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test --summary all 2>&1 | grep -E "Build Summary|error"`
Expected: `Build Summary: ... succeeded; N/N tests passed` (N = previous + 5).

- [ ] **Step 5: Commit**

```bash
git add src/physics/physics2d.zig src/root.zig
git commit -m "feat: add Physics2D velocity, gravity and damping step"
```

---

### Task 3: Restitution and kinematic bodies in collision resolution

**Files:**
- Modify: `src/physics/collision2d.zig`
- Test: `src/physics/collision2d.zig` (inline)

**Interfaces:**
- Consumes: `Physics2D.Velocity`, `Physics2D.RigidBody2D`, `Physics2D.BodyType` (Task 2).
- Produces: no new public API; `resolve` now adjusts velocity.

- [ ] **Step 1: Write the failing tests**

Add to `src/physics/collision2d.zig`:

```zig
test "dynamic body falling onto a static floor separates and stops" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const player = try world.create();
    const floor = try world.create();
    try world.add(player, Components.Transform{ .position = .{ .y = 6 } });
    try world.add(player, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try world.add(player, Physics2D.Velocity{ .linear = .{ .y = -20 } });
    try world.add(player, Physics2D.RigidBody2D{});
    try world.add(floor, Components.Transform{});
    try world.add(floor, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true, .is_static = true });

    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(f32, 10), (try world.get(player, Components.Transform)).position.y);
    try std.testing.expectEqual(@as(f32, 0), (try world.get(player, Physics2D.Velocity)).linear.y);
}

test "restitution one reflects the normal velocity" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const player = try world.create();
    const floor = try world.create();
    try world.add(player, Components.Transform{ .position = .{ .y = 6 } });
    try world.add(player, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try world.add(player, Physics2D.Velocity{ .linear = .{ .y = -20 } });
    try world.add(player, Physics2D.RigidBody2D{ .restitution = 1 });
    try world.add(floor, Components.Transform{});
    try world.add(floor, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true, .is_static = true });

    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(f32, 20), (try world.get(player, Physics2D.Velocity)).linear.y);
}

test "kinematic body is not pushed by an overlapping dynamic body" {
    var world = World.init(std.testing.allocator);
    defer world.deinit();
    const moving = try world.create();
    const platform = try world.create();
    try world.add(moving, Components.Transform{ .position = .{ .x = 6 } });
    try world.add(moving, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try world.add(moving, Physics2D.Velocity{});
    try world.add(moving, Physics2D.RigidBody2D{});
    try world.add(platform, Components.Transform{});
    try world.add(platform, Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try world.add(platform, Physics2D.RigidBody2D{ .body_type = .kinematic });

    var system = System.init(std.testing.allocator);
    defer system.deinit();
    try system.update(&world);
    try std.testing.expectEqual(@as(f32, 0), (try world.get(platform, Components.Transform)).position.x);
    try std.testing.expectEqual(@as(f32, 10), (try world.get(moving, Components.Transform)).position.x);
}
```

Add the import at the top of `src/physics/collision2d.zig`:

```zig
const Physics2D = @import("physics2d.zig");
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test 2>&1 | grep -iE "error|expected" | head`
Expected: the three tests fail on the position/velocity assertions (resolution currently ignores velocity, and a kinematic body is treated as movable because it is `solid` and not `is_static`).

- [ ] **Step 3: Implement movable/immovable and bounce**

Extend `Body`:

```zig
const Body = struct {
    entity: Entity,
    center: Vec2,
    half_size: Vec2,
    transform: *Components.Transform,
    collider: *Collider2D,
    velocity: ?*Physics2D.Velocity,
    restitution: f32,
    movable: bool,
};
```

In `makeBody`, populate them:

```zig
    const velocity = world.get(entity, Physics2D.Velocity) catch null;
    const rigid = world.get(entity, Physics2D.RigidBody2D) catch null;
    const movable = if (rigid) |body|
        body.body_type == .dynamic
    else
        collider.solid and !collider.is_static;
```

and include in the returned struct:

```zig
        .velocity = velocity,
        .restitution = if (rigid) |body| body.restitution else 0,
        .movable = movable,
```

`makeBody` must take `world` (it already does). Replace `resolve` with:

```zig
fn resolve(lhs: *Body, rhs: *Body) void {
    if (!lhs.movable and !rhs.movable) return;

    const dx = lhs.center.x - rhs.center.x;
    const dy = lhs.center.y - rhs.center.y;
    const penetration_x = lhs.half_size.x + rhs.half_size.x - @abs(dx);
    const penetration_y = lhs.half_size.y + rhs.half_size.y - @abs(dy);
    const direction = if (penetration_x < penetration_y)
        Vec2{ .x = if (dx < 0) -1 else 1, .y = 0 }
    else
        Vec2{ .x = 0, .y = if (dy < 0) -1 else 1 };
    const penetration = if (direction.x != 0) penetration_x else penetration_y;
    if (penetration <= 0) return;

    if (lhs.movable and !rhs.movable) {
        moveBody(lhs, Vec2.scale(direction, penetration));
    } else if (!lhs.movable and rhs.movable) {
        moveBody(rhs, Vec2.scale(direction, -penetration));
    } else {
        const half_penetration = penetration * 0.5;
        moveBody(lhs, Vec2.scale(direction, half_penetration));
        moveBody(rhs, Vec2.scale(direction, -half_penetration));
    }

    if (lhs.movable) bounce(lhs, direction);
    if (rhs.movable) bounce(rhs, Vec2.scale(direction, -1));
}

fn bounce(body: *Body, normal: Vec2) void {
    const velocity = body.velocity orelse return;
    const normal_speed = Vec2.dot(velocity.linear, normal);
    if (normal_speed >= 0) return;
    const factor = 1 + body.restitution;
    velocity.linear.x -= normal.x * normal_speed * factor;
    velocity.linear.y -= normal.y * normal_speed * factor;
}
```

Note: the old `static-static` early return is replaced by `!lhs.movable and !rhs.movable`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test --summary all 2>&1 | grep -E "Build Summary|error"`
Expected: `Build Summary: ... succeeded; N/N tests passed` (N = previous + 3).

- [ ] **Step 5: Commit**

```bash
git add src/physics/collision2d.zig
git commit -m "feat: apply restitution and kinematic response in collision"
```

---

### Task 4: Ctx-free behavior shape and Mover2D

**Files:**
- Modify: `src/script/script.zig`
- Modify: `tests/mover_test.zig`
- Modify: `tests/script_test.zig`
- Modify: `README.md` (the "Viết gameplay bằng Script" example only)

**Interfaces:**
- Produces: `Script.init`/`initWithStart` accept behaviors with `onUpdate(self, *Game, f32)` and `onStart(self, *Game)`; `Mover2D.update(self, game: *Game, dt: f32) !Vec2`.

- [ ] **Step 1: Write the failing tests**

Append to `tests/script_test.zig`:

```zig
const Modern = struct {
    starts: u32 = 0,
    updates: u32 = 0,
    saw_world: bool = false,

    pub fn onStart(self: *Modern, game: *ez_engine.Game) !void {
        _ = game;
        self.starts += 1;
    }

    pub fn onUpdate(self: *Modern, game: *ez_engine.Game, dt: f32) !void {
        _ = dt;
        self.updates += 1;
        self.saw_world = game.world.aliveCount() >= 0;
    }
};

test "ctx-free behavior receives game and dt" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    var behavior = Modern{};
    var script = ez_engine.Script.initWithStart(&game, &behavior);
    try script.register(&game.scheduler, "Modern");
    try game.frame(1.0 / 60.0);
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), behavior.starts);
    try std.testing.expectEqual(@as(u32, 2), behavior.updates);
    try std.testing.expect(behavior.saw_world);
}

const ModernVoid = struct {
    updates: u32 = 0,
    pub fn onUpdate(self: *ModernVoid, game: *ez_engine.Game, dt: f32) void {
        _ = game;
        _ = dt;
        self.updates += 1;
    }
};

test "ctx-free behavior may return void" {
    var game = try ez_engine.Game.init(std.testing.allocator, 2);
    defer game.deinit();
    var behavior = ModernVoid{};
    var script = ez_engine.Script.init(&game, &behavior);
    try script.register(&game.scheduler, "ModernVoid");
    try game.frame(1.0 / 60.0);
    try std.testing.expectEqual(@as(u32, 1), behavior.updates);
}
```

Update `tests/mover_test.zig` line 10 and the two `update` calls to the new signature:

```zig
    var ctx = game.Script.Ctx{ ... };  // REMOVE this line entirely
    game.input.setKey(.d, true);
    const dir = try mover.update(&game, 1.0 / 60.0);
```

and the unbound case:

```zig
    var unbound = ez_engine.Script.Mover2D{};
    try std.testing.expectError(error.UnboundEntity, unbound.update(&game, 1.0 / 60.0));
```

(The `ctx` variable and its `.frame_allocator` are no longer used — delete the whole declaration.)

- [ ] **Step 2: Run tests to verify they fail**

Run: `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test 2>&1 | grep -iE "error|expected" | head`
Expected: compile error calling `mover.update(&game, dt)` (expects `*Ctx`), and the new `Modern`/`ModernVoid` tests do not run yet.

- [ ] **Step 3: Implement comptime dispatch and the new Mover2D**

In `src/script/script.zig`, replace `Mover2D.update`:

```zig
        pub fn update(self: *Mover2D, game: *Game, dt: f32) !Vec2 {
            const entity = self.entity orelse return error.UnboundEntity;
            var direction = Vec2.zero;
            const input = &game.input;
            if (input.isDown(.a) or input.isDown(.left)) direction.x -= 1;
            if (input.isDown(.d) or input.isDown(.right)) direction.x += 1;
            if (input.isDown(.s) or input.isDown(.down)) direction.y -= 1;
            if (input.isDown(.w) or input.isDown(.up)) direction.y += 1;
            if (direction.x != 0 and direction.y != 0) direction = Vec2.scale(direction, 0.70710678);
            const transform = try game.world.get(entity, Components.Transform);
            transform.position.x += direction.x * self.speed * dt;
            transform.position.y += direction.y * self.speed * dt;
            return direction;
        }
```

Replace `wrapUpdate` and `wrapStart` with type-dispatched versions:

```zig
    fn methodArgIsGame(comptime Fn: type) bool {
        const params = @typeInfo(Fn).@"fn".params;
        return params.len >= 2 and params[1].type.? == *Game;
    }

    fn wrapUpdate(comptime T: type) *const fn (*anyopaque, *Ctx) anyerror!void {
        const Fn = @TypeOf(T.onUpdate);
        const wants_game = methodArgIsGame(Fn);
        return struct {
            fn f(ptr: *anyopaque, ctx: *Ctx) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                const R = @typeInfo(Fn).@"fn".return_type orelse void;
                if (wants_game) {
                    if (R == void) self.onUpdate(ctx.game, ctx.dt) else try self.onUpdate(ctx.game, ctx.dt);
                } else {
                    if (R == void) self.onUpdate(ctx) else try self.onUpdate(ctx);
                }
            }
        }.f;
    }

    fn wrapStart(comptime T: type) *const fn (*anyopaque, *Ctx) anyerror!void {
        const Fn = @TypeOf(T.onStart);
        const wants_game = methodArgIsGame(Fn);
        return struct {
            fn f(ptr: *anyopaque, ctx: *Ctx) anyerror!void {
                const self: *T = @ptrCast(@alignCast(ptr));
                const R = @typeInfo(Fn).@"fn".return_type orelse void;
                if (wants_game) {
                    if (R == void) self.onStart(ctx.game) else try self.onStart(ctx.game);
                } else {
                    if (R == void) self.onStart(ctx) else try self.onStart(ctx);
                }
            }
        }.f;
    }
```

Update the `init`/`initWithStart` doc comments to mention `onUpdate(self, game, dt)`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test --summary all 2>&1 | grep -E "Build Summary|error"`
Expected: `Build Summary: ... succeeded; N/N tests passed` (N = previous + 2), and the legacy `Counter`/`Boom`/`Late` tests still pass.

- [ ] **Step 5: Update the README example**

In `README.md`, change the `Player` snippet's signature to the Ctx-free form:

```zig
    pub fn onUpdate(self: *Player, game: *game.Game, dt: f32) !void {
        const direction = try self.mover.update(game, dt); // WASD + arrows
        const animation = try game.world.get(self.mover.entity.?, game.RenderComponents.SpriteAnimation);
        animation.play(if (direction.x == 0 and direction.y == 0) idle else walk);
    }
```

- [ ] **Step 6: Commit**

```bash
git add src/script/script.zig tests/mover_test.zig tests/script_test.zig README.md
git commit -m "feat: allow ctx-free onUpdate(self, game, dt) behaviors"
```

---

### Task 5: Template refresh and debug on

**Files:**
- Modify: `template/game/src/main.zig`
- Modify: `template/game/src/scripts/player.zig`
- Test: template compilation check (see Step 4)

**Interfaces:**
- Consumes: `Physics2D`, `Collision2D` layers, the Ctx-free behavior shape.

- [ ] **Step 1: Rewrite the Player behavior Ctx-free**

Replace `template/game/src/scripts/player.zig` body's `onUpdate`:

```zig
    pub fn onUpdate(self: *Player, game: *ez_engine.Game, dt: f32) !void {
        if (game.input.isDown(.escape)) game.running = false;
        const direction = try self.mover.update(game, dt);
        const animation = try game.world.get(self.mover.entity.?, Animation);
        animation.play(if (direction.x == 0 and direction.y == 0) idle_clip else walk_clip);
    }
```

- [ ] **Step 2: Wire physics + debug in `main.zig`**

After the collision system registration block, add (physics first, collision second):

```zig
    var physics = ez_engine.Physics2D.System{ .gravity = .zero }; // top-down: no gravity
    const physics_id = try game.scheduler.addSystem("2D physics", &physics, ez_engine.Physics2D.System.updateSystem);
    const collision_id = try game.scheduler.addSystem("2D collision", &collisions, ez_engine.Collision2D.System.updateSystem);
    try game.scheduler.dependsOn(physics_id, collision_id);

    game.debug.enabled = true;
```

and remove the now-duplicated original `addSystem("2D collision", ...)` line. Add a tiny stats logger system in `main.zig`:

```zig
    const Stats = struct {
        tick: u32 = 0,
        fn update(context: ?*anyopaque, _: *ez_engine.World, _: f32) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.tick +%= 1;
            if (self.tick % 60 != 0) return;
            const stats = game.debug.stats;
            try game.logger.formatCategory(game.allocator, .debug, "stats", "fps={d:.0} entities={d}", .{ stats.fps, stats.entity_count });
        }
    };
    var stats = Stats{};
    _ = try game.scheduler.addSystem("debug stats", &stats, Stats.update);
```

- [ ] **Step 3: Give the player and walls a collision layer (illustrative)**

In `spawnPlayer`, set `.layer = 1` on the `Collider2D`; in `spawnWall`, set `.layer = 2, .collides_with = ez_engine.Collision2D.layerBit(1) | ez_engine.Collision2D.layerBit(2)`. In `spawnPickup`, set `.layer = 3, .collides_with = ez_engine.Collision2D.layerBit(1)`. (Player keeps the default `collides_with = all`, so player–wall and player–pickup still connect, while pickup–wall does not.)

- [ ] **Step 4: Verify the template compiles**

The framework `build.zig` does not compile `template/`. Scaffold a throwaway project and build it:

```bash
ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build new -Dname=EzTemplateCheck --workspace /tmp/opencode
cd /tmp/opencode/EzTemplateCheck && ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build 2>&1 | tail -20
```

Expected: build succeeds (exit 0). If the environment cannot fetch/link desktop deps offline, record the failure verbatim in the commit message and fall back to `zig fmt --check template/game/src/main.zig template/game/src/scripts/player.zig`.

- [ ] **Step 5: Commit**

```bash
git add template/game/src/main.zig template/game/src/scripts/player.zig
git commit -m "feat(template): ctx-free behaviors, physics wiring, debug stats"
```

---

### Task 6: Integration test through the public API

**Files:**
- Create: `tests/physics_layers_test.zig`
- Modify: `build.zig:48` (add `"physics_layers_test.zig"` to the test list)
- Test: `tests/physics_layers_test.zig`

**Interfaces:**
- Consumes: `Game`, `Physics2D`, `Collision2D`, `Script`.

- [ ] **Step 1: Write the failing test file**

Create `tests/physics_layers_test.zig`:

```zig
const std = @import("std");
const ez = @import("ez_engine");

test "gravity settles a dynamic box onto a static floor" {
    var game = try ez.Game.init(std.testing.allocator, 2);
    defer game.deinit();

    const body = try game.world.create();
    try game.world.add(body, ez.RenderComponents.Transform{ .position = .{ .y = 8 } });
    try game.world.add(body, ez.Collision2D.Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true });
    try game.world.add(body, ez.Physics2D.Velocity{});
    try game.world.add(body, ez.Physics2D.RigidBody2D{});

    const floor = try game.world.create();
    try game.world.add(floor, ez.RenderComponents.Transform{});
    try game.world.add(floor, ez.Collision2D.Collider2D{ .size = .{ .x = 10, .y = 10 }, .solid = true, .is_static = true });

    var physics = ez.Physics2D.System{ .gravity = .{ .x = 0, .y = -100 } };
    const physics_id = try game.scheduler.addSystem("physics", &physics, ez.Physics2D.System.updateSystem);
    var collision = ez.Collision2D.System.init(std.testing.allocator);
    defer collision.deinit();
    const collision_id = try game.scheduler.addSystem("collision", &collision, ez.Collision2D.System.updateSystem);
    try game.scheduler.dependsOn(physics_id, collision_id);

    try game.frame(0.1);

    try std.testing.expectEqual(@as(f32, 10), (try game.world.get(body, ez.RenderComponents.Transform)).position.y);
    try std.testing.expectEqual(@as(f32, 0), (try game.world.get(body, ez.Physics2D.Velocity)).linear.y);
}

test "colliders on disjoint layers ignore each other" {
    var game = try ez.Game.init(std.testing.allocator, 2);
    defer game.deinit();

    const body = try game.world.create();
    try game.world.add(body, ez.RenderComponents.Transform{ .position = .{ .y = 8 } });
    try game.world.add(body, ez.Collision2D.Collider2D{
        .size = .{ .x = 10, .y = 10 },
        .solid = true,
        .layer = 1,
        .collides_with = ez.Collision2D.layerBit(1),
    });
    try game.world.add(body, ez.Physics2D.Velocity{});
    try game.world.add(body, ez.Physics2D.RigidBody2D{});

    const floor = try game.world.create();
    try game.world.add(floor, ez.RenderComponents.Transform{});
    try game.world.add(floor, ez.Collision2D.Collider2D{
        .size = .{ .x = 10, .y = 10 },
        .solid = true,
        .is_static = true,
        .layer = 2,
        .collides_with = ez.Collision2D.layerBit(2),
    });

    var physics = ez.Physics2D.System{ .gravity = .{ .x = 0, .y = -100 } };
    const physics_id = try game.scheduler.addSystem("physics", &physics, ez.Physics2D.System.updateSystem);
    var collision = ez.Collision2D.System.init(std.testing.allocator);
    defer collision.deinit();
    const collision_id = try game.scheduler.addSystem("collision", &collision, ez.Collision2D.System.updateSystem);
    try game.scheduler.dependsOn(physics_id, collision_id);

    try game.frame(0.1);

    // No contact: the body keeps falling through the floor.
    try std.testing.expectEqual(@as(f32, 7), (try game.world.get(body, ez.RenderComponents.Transform)).position.y);
}
```

Add `"physics_layers_test.zig"` to the list in `build.zig` (the `inline for` at line 48, after `"loop_reclaim_test.zig"`).

- [ ] **Step 2: Run tests to verify they fail**

Run: `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test 2>&1 | grep -iE "error|expected" | head`
Expected: compile error if the file is not registered yet, or assertion failure before Tasks 1–3 land (there is no integration behavior). Since Tasks 1–3 are already in, the second test should fail only if wiring/order is wrong.

- [ ] **Step 3: Fix the build list / wiring until green**

The test list registration is the only change needed if the systems work; adjust `dependsOn` order if the first test does not settle.

- [ ] **Step 4: Run tests to verify they pass**

Run: `ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test --summary all 2>&1 | grep -E "Build Summary|error"`
Expected: `Build Summary: ... succeeded; N/N tests passed` (N = previous + 2).

- [ ] **Step 5: Commit**

```bash
git add tests/physics_layers_test.zig build.zig
git commit -m "test: cover physics and collision layers through the public API"
```

---

### Task 7: Documentation

**Files:**
- Modify: `docs/api.md`
- Modify: `CHANGELOG.md`
- Modify: `docs/project-management.md`
- Modify: `README.md` (a short "Vật lí & va chạm" section)

- [ ] **Step 1: Update `docs/api.md`**

In the "Game loop" / ECS area, add entries for `Collider2D.layer`/`collides_with`/`layerBit`, the `Physics2D` module (`Velocity`, `RigidBody2D`, `BodyType`, `System`), and the Ctx-free `onUpdate(self, game, dt)` form of `Script`. Update the module list to include `Physics2D` and `Collision2D` layers.

- [ ] **Step 2: Update `CHANGELOG.md`**

Add under `### Added`:

```markdown
- Collision layers: `Collider2D.layer` / `collides_with` + `Collision2D.layerBit`
  to say which entities hit which.
- `Physics2D`: `Velocity`, `RigidBody2D` (gravity/damping/restitution,
  dynamic/kinematic/static) and an integrator `System`; `Collision2D` now
  applies restitution and treats kinematic bodies as immovable.
- Ctx-free behaviors: `onUpdate(self, game, dt)` / `onStart(self, game)`
  alongside the existing `*Script.Ctx` form; `Mover2D.update(game, dt)`.
```

- [ ] **Step 3: Update `docs/project-management.md` and `README.md`**

Reflect that the template wires physics + collision + debug and uses Ctx-free behaviors, and add a short README section showing a layered collider and a physics body.

- [ ] **Step 4: Verify formatting and the full suite**

```bash
ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig fmt --check src tests build.zig template/game/src
ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build test --summary all 2>&1 | grep "Build Summary"
ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local" zig build
```

Expected: fmt exit 0; `Build Summary: ... succeeded`; `zig build` exit 0.

- [ ] **Step 5: Commit**

```bash
git add docs/api.md CHANGELOG.md docs/project-management.md README.md
git commit -m "docs: document collision layers, Physics2D and ctx-free behaviors"
```

---

## Self-review

- **Spec coverage:** D1→Task 1, D2→Task 2, D3→Task 3, D4→Task 4, D5→Task 5, D6→Task 5 (debug) + Task 7 (docs). All six decisions are covered.
- **Review Focus:** each of the five lines is pinned to a test in its owning task (Task 1 both filter tests, Task 2 `velocity without a rigid body` + `non-finite dt`, Task 3 `kinematic body is not pushed`, Task 4 `ctx-free behavior may return void`).
- **Type consistency:** `layerBit`, `Velocity.linear`, `RigidBody2D.{body_type,gravity_scale,linear_damping,restitution}`, `System.{gravity,init,updateSystem,update}`, `Mover2D.update(*Game, f32)` are used with one spelling throughout.
- **Proportion:** bodies are given only where the signature + tests do not pin the algorithm (the filter, the integrator loop, the bounce formula).
