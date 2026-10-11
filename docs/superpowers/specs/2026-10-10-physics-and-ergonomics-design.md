# Physics, collision layers, and ergonomic gameplay — design

**Status:** approved-by-default. The human partner asked to skip questions
("ok triển khai"), so the choices below are the builder's calls, stated so
they can be checked and reversed.

## Intent (why)

Two things a person making a game with `ez_engine` currently fights:

1. **Plumbing leaks into gameplay.** To add one behavior you construct a
   `Script`, thread a `Script.Ctx{ world, game, dt, frame_allocator }`
   through every `onUpdate`, hand-register every system, and keep the
   behavior alive for the whole run. The template `main.zig` is mostly
   infrastructure. The person only wants to say "this entity moves" and
   "when I touch that, collect it".
2. **Collision and physics are one-size-fits-all.** Every `Collider2D`
   collides with every other one (no way to say "player ignores other
   bullets"), and nothing moves on its own: there is overlap push-out but
   no velocity, gravity, or bounce.

## Goals

- Filter collisions by an entity-level tag/layer, declared next to the
  collider, so a user writes *who hits whom* instead of *everything hits
  everything*.
- A small, honest 2D physics step: velocity, gravity, linear damping,
  restitution (bounce), kinematic bodies — built on the existing AABB
  collision, not a new engine.
- Gameplay code that does not mention `Ctx`: a behavior can be written as
  `onUpdate(self, game, dt)` / `onStart(self, game)` and the engine
  supplies `game`.
- A template whose `main.zig` is bootstrap only, with the default systems
  (animation, physics, collision, camera) wired once and debug on.

## Non-goals

- No rotation, torques, joints, or full impulse solver. AABB only.
- No dynamic tag strings. "Tag" is a layer bit on the collider; ECS marker
  components remain the way to tag entities in queries.
- No dynamic-vs-dynamic momentum exchange beyond positional separation and
  per-body bounce off immovable bodies.
- No visual debug overlay or text rendering. "Debug on" means the existing
  `Debug.Monitor` collects stats and the template logs them periodically.
- No change to `GameLoop`, `Reclaimer`, `World`, or the renderer.

## Decisions

### D1 — Collision layers via `Collider2D` (tag/id)

`Collider2D` gains `layer: u4 = 0` and `collides_with: u16 = 0xffff`.
Two colliders interact when **both** sides agree:

```
(a.collides_with & bit(b.layer)) != 0  and  (b.collides_with & bit(a.layer)) != 0
```

`layer` names the collider (like an id/tag); `collides_with` is the mask of
layers it reacts to. Defaults preserve today's behavior (everything
collides). Helper `Collision2D.layerBit(index: u4) u16` builds masks.

### D2 — `Physics2D` integrator (new module)

`src/physics/physics2d.zig`:

- `Velocity { linear: Vec2 }`
- `BodyType = enum { static, kinematic, dynamic }`
- `RigidBody2D { body_type = .dynamic, gravity_scale = 1, linear_damping = 0, restitution = 0 }`
- `System { gravity: Vec2 = {0, -981} }` with `updateSystem` / `update`

Per dynamic body (has `Transform` + `Velocity`, optional `RigidBody2D`):
`v += gravity * gravity_scale * dt`; `v *= max(0, 1 - damping*dt)`;
`position += v * dt`. `kinematic` moves by velocity, ignores gravity.
`static` is skipped. An entity with `Velocity` and no `RigidBody2D` behaves
as dynamic with `gravity_scale = 0`.

Runs **before** `Collision2D` (the user/wiring orders them).

### D3 — Restitution in `Collision2D`

During solid resolution, a body is *movable* when it is dynamic (or, with no
`RigidBody2D`, the legacy `solid and not is_static`). Positional correction
keeps today's rules (split between two movable bodies; full push otherwise).
Then, for each movable body, remove the velocity component going into the
contact normal and reflect it by `restitution`:

```
if dot(v, n) < 0:  v -= n * dot(v, n) * (1 + restitution)   // n = push direction
```

No `Velocity` -> no velocity change (pure positional, as before).

### D4 — Ctx-free behaviors

`Script` keeps `init` / `initWithStart`, but the adapter accepts two method
shapes and dispatches at comptime:

- `onUpdate(self, *Ctx)` — existing (legacy, unchanged).
- `onUpdate(self, *Game, f32)` — new; no `Ctx` in user code.
- `onStart(self, *Ctx)` / `onStart(self, *Game)` — chosen by argument type.

`Mover2D.update` becomes `(self, game: *Game, dt: f32)` so the built-in
mover is also Ctx-free (it reads `game.world` / `game.input`).

### D5 — Template

`template/game/` wires animation + `Physics2D` (gravity zero: top-down
sample) + `Collision2D` + camera follow in one place, sets
`game.debug.enabled = true`, and its behaviors use the D4 shape. Doc copy
in `docs/project-management.md` follows.

### D6 — Debug

Template turns the monitor on and logs `fps`/entity count every ~60 frames
through the existing logger. No new debug module.

## What is left to the builder

Names may be adjusted if they collide, but signatures and the exact filter,
integration, and bounce formulas above are the contract. Tests must prove
each formula, not just "it runs".
