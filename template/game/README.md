# @NAME@

Game project created with ez-engine (`zig build new`).

## Build, test and run

Requires Linux x86_64; on WSL, WSLg must be available for the game window.

```sh
zig build test
zig build run
```

`zig build test` runs the project tests in `tests.zig`. Add test blocks there
or import modules containing tests.

## Project structure

- `src/main.zig` initializes the app, loads the scene, creates entities and
  registers gameplay scripts and systems.
- `src/scripts/` contains gameplay behaviors. The starter includes player
  movement and animation, plus a pickup listener.
- `Scenes/editor_scene.json` stores the sample scene's objects, positions and
  sizes; `project.json` identifies the startup scene.
- `Assets/` contains sprites, audio, fonts and shaders. Shader changes take
  effect after rebuilding.

## Extending the starter

- Edit `Scenes/editor_scene.json` to adjust the sample objects.
- Add a behavior struct with `pub fn onUpdate` under `src/scripts/`, then
  register it with `Script` in `src/main.zig`. Use `initWithStart` when the
  behavior needs an `onStart` callback. See `docs/api.md` in the framework.
- Add tests to `tests.zig`; import a module there to include its test blocks.
- Configure post-processing through `game.post_process`: `grayscale` and
  `vignette` accept `0...1`, while `exposure` accepts `0...8`.

The WGPU starter uses FIFO presentation (VSync). Avoid adding a second software
frame cap with `game.setTargetFps(...)` unless presentation is not synchronized;
pass `0` to disable software frame pacing.
