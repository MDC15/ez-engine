# Project management

`tools/ez_project.py` manages local game projects for the current checkout of
ez-engine. Run it from WSL/Ubuntu with Python 3 and Zig on `PATH`.

## Create a project

```sh
python3 tools/ez_project.py new MyFirstGame
```

The default workspace is `projects/` beside the framework. To use another
workspace:

```sh
python3 tools/ez_project.py --workspace ~/Games new MyFirstGame
```

The starter includes:

- `project.json` with project name, format version and startup scene.
- `editor_scene.json` in the `ez_engine.Scene` format (version 1).
- `Assets/`, `Scenes/`, `src/` and `Build/` directories.
- `build.zig` and `build.zig.zon`, configured to use this framework checkout.
- `src/main.zig`, the WGPU/GLFW game loop, and sample sprite textures.

From the project folder, build and run the starter window with:

```sh
zig build run
```

On WSL, WSLg must be available for the WGPU window. The starter includes an
animated player, WASD movement, a pickup, and a wall collision sample.

## List projects

```sh
python3 tools/ez_project.py list
```

The manager lists valid `project.json` files directly inside the workspace.

Pass the same `--workspace` value to each command when projects are stored
outside the default folder. A project uses a relative local dependency path to
this framework checkout; keep the framework checkout available at that path
when building the game.
