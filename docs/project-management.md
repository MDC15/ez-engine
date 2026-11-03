# Project management

Build the CLI once from the framework checkout and add it to `PATH`:

```sh
zig build install
export PATH="$PWD/zig-out/bin:$PATH"
```

Create a game project from the framework checkout:

```sh
ez build new MyFirstGame
ez build new MyFirstGame --workspace="$HOME/Games"
```

The default workspace is `projects/` beside the framework. The generator
(`tools/scaffold.zig`, template in `template/game/`) creates the standard
structure and refuses to overwrite an existing directory:

```text
MyFirstGame/
  build.zig            # wires ez_engine + wgpu_backend + ez_app, steps `run` and `test`
  build.zig.zon        # deps pinned like the framework, fingerprint included
  src/main.zig         # initializes the app, loads the scene, creates entities and systems
  src/scripts/         # gameplay behaviors
  src/scripts/player.zig    # Player movement + animation
  src/scripts/pickup.zig    # Collectible tag + pickup listener
  Assets/              # Sprites/Audio/Fonts/Shaders copied from the framework
  Scenes/              # scene files (ez_engine.Scene format)
  Scenes/editor_scene.json  # sample scene, format version 2
  Prefabs/pickup.json  # reusable single-object prefab, format version 2
  project.json         # name, format version, startup scene
  README.md            # where to go next
  .gitignore
```

From the project folder, run tests and build or start the game with:

```sh
zig build test
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
llvmpipe (software) and logs a warning.

The starter scene is stored in `Scenes/editor_scene.json`. The entry point in
`src/main.zig` loads the document, resolves its project-relative texture paths,
spawns a tracked `SceneSpawn.Instance`, parses and spawns the pickup prefab,
adds gameplay-specific components, registers scripts and systems, then starts
the app. Both instances despawn their entities before the game runtime is
destroyed. Gameplay behaviors live in separate files under
`src/scripts/`; the sample includes player movement and animation, a pickup
listener, collision, physics and camera follow. Use the `Script` API described
in `docs/api.md` as a starting point for additional behaviors. Edit the scene
JSON to adjust object positions and sizes.

A project references this framework checkout by relative path; keep the
checkout available at that path when building the game.

## Scene files

There is no visual editor. Edit scene JSON by hand following
`Scene.Document` version 2 (`id`, `kind`, `position`, `size`, and optional
project-relative `asset_path`; see `docs/architecture.md`). Reusable single
objects use `Scene.Prefab` version 2, as shown in `Prefabs/pickup.json`.
Version 1 files
remain readable and save as version 2. Use `SceneSpawn.spawnDocumentResolved`
with an asset resolver to get an `Instance` that maps document IDs to entities
and supports deterministic scene teardown. Game-specific components such as
pickup markers are attached after spawning. The sample scene lives at
`Scenes/editor_scene.json` and `project.json` points `startup_scene` there.

From the engine checkout, `zig build scaffold-smoke` generates a fresh project
under `.zig-cache`, builds its starter executable and test target, then removes
only that temporary generated directory.
