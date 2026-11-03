# Project Guidelines

## Build and test

- Use Zig `0.16.0` (the package minimum and CI version).
- `zig build` builds the static library.
- `zig build test` runs the full unit and integration suite.
- To run a single named test: `zig build test -- --test-filter "test name"`.
- `zig fmt --check src tests tools template examples build.zig build.zig.zon` is the CI formatting gate.
- `zig build docs` emits API documentation under `zig-out/docs`.
- `zig build gl` / `zig build wgpu` build desktop samples; `zig build gl-run` / `zig build wgpu-run` run them. These steps require Linux x86_64; library and tests are available on other targets.

See [CONTRIBUTING.md](../CONTRIBUTING.md) and [README.md](../README.md) for setup and sample runtime details.

## Architecture

- `src/root.zig` is the public `ez_engine` facade. `build.zig` wires internal modules such as `ez_input` and `ez_platform`; consumers should use the public facade rather than those build-time import names.
- `Game` owns the ECS world, system scheduler, assets, audio, and CPU-side render world. A frame runs scheduled gameplay systems, extracts sprites, culls and sorts them, then submits to the optional renderer and reclaims deferred entities. The app/window layer owns platform integration and feeds events into the game.
- The ECS in `src/ecs/` uses generational entities and archetype/column storage. The scheduler uses explicit dependencies to build a topological execution order.
- Rendering is backend-independent until submission: `RenderWorld` contains CPU render items and texture handles, and `Renderer.Backend` consumes it. Headless rendering lives in the core library; WGPU and desktop app modules are separate and intentionally not exported by `src/root.zig`, keeping core builds independent of GPU dependencies.

For detailed frame flow, ownership, and backend boundaries, see [docs/architecture.md](../docs/architecture.md).

## Repository conventions

- Export public API additions through `src/root.zig`; keep the API reference in `docs/api.md` aligned. Record breaking API changes in `CHANGELOG.md` under `Unreleased`.
- ECS components are byte-copied on add and archetype migration, and are discarded without destructors. Keep them plain data; do not put owning allocations, resources, or values requiring cleanup in a component. Put ownership in a manager/system and store only non-owning data in components.
- Express required system ordering with `Scheduler.dependsOn(before, after)` rather than relying on registration order.
- Keep graphics-specific resource work in the backend. Backends resolve texture handles through the asset manager; ECS components and `RenderWorld` must not own GPU objects.
- Tests are wired in `build.zig`; add new test files to its `test` step. Follow the existing test-first workflow and run the focused test plus `zig build test`.
