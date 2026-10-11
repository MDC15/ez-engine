# Project management

Game projects are scaffolded from the framework checkout with `zig build new`
— no Python needed:

```sh
zig build new -Dname=MyFirstGame
zig build new -Dname=MyFirstGame -Dworkspace="$HOME/Games"
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

On WSL, WSLg must be available for the WGPU window. The starter is
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
