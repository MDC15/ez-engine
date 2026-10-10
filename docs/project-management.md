# Project management

Game projects are scaffolded with the `ez` command — no Python needed, works
from any directory (it delegates to `zig build new` in the framework
checkout):

```sh
./ez new MyFirstGame
./ez new MyFirstGame --workspace ~/Games
```

The default workspace is `projects/` beside the framework. The generator
(`tools/scaffold.zig`, template in `template/game/`) creates the standard
structure and refuses to overwrite an existing directory:

```text
MyFirstGame/
  build.zig            # wires ez_engine + wgpu_backend + ez_app, step `run`
  build.zig.zon        # deps pinned like the framework, fingerprint included
  src/main.zig         # starter: App + Player script, pickup, wall, camera
  Assets/              # sample sprites copied from the framework
  Scenes/              # for your scene files (ez_engine.Scene format)
  editor_scene.json    # sample scene, format version 1
  project.json         # name, format version, startup scene
  README.md            # where to go next
  .gitignore
```

From the project folder, build and run the starter window with:

```sh
zig build run
```

On WSL, WSLg must be available for the WGPU window. The starter includes an
animated player (WASD/arrows), a pickup, and a wall collision sample — all
written with the `Script` API from `docs/api.md`, so it doubles as the
recommended starting point for your own behaviors.

A project references this framework checkout by relative path; keep the
checkout available at that path when building the game.

## Scene files

There is no visual editor. Edit scene JSON by hand following the
`Scene.Document` schema (`id`, `kind: sprite|obstacle|pickup`, `position`,
`size`; see `docs/architecture.md`), and spawn runtime entities in code —
the starter constructs its entities programmatically.
