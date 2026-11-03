# Platform support

The core library and its optional desktop adapters have different support
boundaries. The CI matrix builds, tests, and emits API docs on each listed
native runner.

| Target | Core build/tests | GLFW window + OpenGL/WGPU | PulseAudio output |
|---|---|---|---|
| Linux x86_64 | CI | Available; requires a working display and graphics driver | Available; requires `libpulse-simple` and a Pulse-compatible server |
| Windows x86_64 | CI | Not currently wired | Not supported |
| macOS arm64 | CI | Not currently wired | Not supported |

The desktop modules are wired only for Linux x86_64 in `build.zig`. Selecting
another target still builds the core library and its tests, and emits a
warning that desktop steps are unavailable. Core input, physics, collision,
software audio, WAV decoding, and the headless renderer do not require a
desktop target or device.

CI checks native core builds, tests, docs, and formatting on Linux, Windows,
and macOS. The actual GL/WGPU pixel-readback regressions require an interactive
Linux x86_64 display and are run explicitly with `zig build gl-render-test`
or `zig build wgpu-render-test`; they are not part of headless CI.

PulseAudio has fake-device and failure-path tests in the portable test suite.
Live output must be smoke-tested on a Linux x86_64 host with a configured
Pulse-compatible service; CI does not claim that a real audio device is
available.
