# Project management

Build the CLI once from the framework checkout and add it to `PATH`:

```sh
zig build install
export PATH="$PWD/zig-out/bin:$PATH"
```

Then scaffold a game project from the framework checkout — no Python needed:

```sh
ez build new MyFirstGame
ez build new MyFirstGame --workspace="$HOME/Games"
```

The default workspace is `projects/` beside the framework. The generator
(`tools/scaffold.zig`, template in `template/game/`) creates the standard
structure and refuses to overwrite an existing directory:

```text
MyFirstGame/
  build.zig            # wires ez_engine + wgpu_backend + ez_app, step `run`
  build.zig.zon        # deps pinned like the framework, fingerprint included
  src/main.zig         # bootstrap: window → load scene → spawn → scripts → run
  src/scripts/         # one MonoBehaviour-style file per behavior
  src/scripts/player.zig    # Player movement + animation
  src/scripts/pickup.zig    # Collectible tag + pickup listener
  Assets/              # sample sprites copied from the framework
  Scenes/              # scene files (ez_engine.Scene format)
  Scenes/editor_scene.json  # sample scene, format version 1
  project.json         # name, format version, startup scene
  README.md            # where to go next
  .gitignore
```

From the project folder, build and run the starter window with:

```sh
zig build run
```

On WSL, WSLg must be available for the desktop window. The framework has
two desktop backends behind one `Backend` vtable: WGPU (Dawn) and OpenGL.
The samples run on either — `zig build wgpu-run` or `zig build gl-run`.
`wgpu-run` sets `DRI_PRIME=1` by default to prefer a discrete Mesa Vulkan
device, and `zgpu` requests a high-performance adapter. This only works when
the Vulkan driver exposes the GPU to Dawn; startup adapter information shows
what was actually selected. If it reports `llvmpipe` / `cpu`, Vulkan hardware
acceleration is unavailable in that environment, and resizing the window
does not switch the adapter.

`gl-run` also prefers discrete GPUs through Mesa; on WSLg it selects the X11
platform to avoid Mesa EGL device-probe warnings, uses the OpenGL-on-D3D12
driver, and prefers the NVIDIA adapter. Existing driver/adapter settings are
preserved. For a different WSL GPU, set
`MESA_D3D12_DEFAULT_ADAPTER_NAME` to a substring of its adapter name before
running. If hardware acceleration is unavailable, GL may fall back to
llvmpipe (software) and logs a warning. The starter is
organized like Unity: `Scenes/editor_scene.json` holds every object's
position and size, `src/main.zig` only bootstraps (window → load scene →
spawn entities → wire systems → run), and each behavior lives in its
own file under `src/scripts/` (`Player` movement + animation, pickup
listener, wall collision sample). Behaviors use the ctx-free
`onUpdate(self, game, dt)` form, and `main.zig` wires physics + collision +
camera and turns debug on (fps/entity stats) for you — all written with the
`Script` API from `docs/api.md`, so it doubles as the recommended starting
point for your own behaviors. Edit the scene JSON to change gameplay without
touching code.

A project references this framework checkout by relative path; keep the
checkout available at that path when building the game.

## Scene files

There is no visual editor. Edit scene JSON by hand following the
`Scene.Document` schema (`id`, `kind: sprite|obstacle|pickup`, `position`,
`size`; see `docs/architecture.md`), and spawn runtime entities in code —
the starter constructs its entities programmatically. The sample scene lives
at `Scenes/editor_scene.json` and `project.json` points `startup_scene`
there.
