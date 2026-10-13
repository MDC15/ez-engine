# Assets

Standard asset folders for games scaffolded with `zig build new`
(the whole tree is copied to the project's `Assets/`).

```text
Sprites/          finished art: PNG or ZTEX + atlas JSON sidecars
UI/               buttons, panels, icons, cursors (see UI/README.md)
Audio/Music/      looping tracks (WAV 48 kHz; resample offline if needed)
Audio/SFX/        one-shot sounds (WAV 48 kHz)
Fonts/            reserved — the engine has no font renderer yet
Shaders/          engine shaders (copied as-is, don't rename)
```

Conventions: textures load with `Assets.loadTextureFile`, sounds decode
with `Audio.decodeWav` (WAV only), scene data lives in `Scenes/`
(`ez_engine.Scene` format), never in `Assets/`.
