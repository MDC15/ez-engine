# Contributing to ez-engine

## Setup

- Install Zig 0.16.0 and put it on `PATH`.
- If the Zig cache lives on `/mnt/c` or `/mnt/d` and hits permission errors,
  point it at a Linux filesystem:

  ```sh
  export PATH="$HOME/.local/opt/zig-0.16.0:$PATH"
  export ZIG_LOCAL_CACHE_DIR="$HOME/.cache/zig-local"
  ```

## Workflow

- `zig build` — build the `ez_engine` static library.
- `zig build test` — run the full unit + integration suite. Must be green
  before every commit.
- `zig fmt --check .` — formatting gate (same command CI runs).
- `zig build docs` — emit API docs to `zig-out/docs`.

## Rules

- TDD: write the failing test first, watch it fail, then implement.
- Public API is exported only via `src/root.zig`; note breaking changes in
  `CHANGELOG.md` under `Unreleased`.
- Components must stay plain data (byte-copied, no destructors) — see
  `docs/architecture.md` and `tests/ecs_lifetime_test.zig`.
- One concern per commit, with a `feat:` / `fix:` / `docs:` / `chore:` prefix.
