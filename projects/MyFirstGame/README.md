# MyFirstGame

Game project created with ez-engine (`zig build new`).

## Build and run (Linux x86_64, WSLg on WSL)

```sh
zig build run
```

## Where to go next

- Gameplay lives in `src/main.zig`: the `Player` script (WASD/arrows +
  animation), a pickup listener, a wall, and camera follow.
- Write a new behavior as a struct with `pub fn onUpdate`, wrap it with
  `ez_engine.Script.init(&game, &behavior)` and `register(&game.scheduler,
  "Name")`. Add `initWithStart` when you need `onStart`.
- Put textures in `Assets/`, scene data in `Scenes/` (`ez_engine.Scene`
  format, version 1). Project metadata is in `project.json`.
