# SDD ledger — plan: docs/superpowers/plans/2026-10-10-cleanup-extensible-redesign.md
Pre-flight: tasks 2->3 (render path -> facade), 2->4 (backend uses Renderer.Backend, unaffected by mesh removal), 3->4/5 (rename affects imports). No conflicts blocking; rename applied after removal.
Ruling: no git repo -> will git init + initial commit before any delete for rollback safety.
Task 1: complete (tests: zig build test → PASS)
Task 2: complete (tests: zig build test → PASS)
Task 2: Ruling: also removed MeshHandle/ShaderHandle (not just MaterialHandle) since mesh/shader loaders deleted — cost if wrong: re-add one-line handle aliases.
Task 3: complete (tests: zig build test → PASS, fmt clean)
Task 3: Ruling: kept InputModule alias (used by glfw_window.zig:102), removed only unused AssetStore/AudioModule — cost if wrong: one-line re-add.
Task 3: Ruling: fingerprint regenerated to 0x419a7f6d1d385927 after rename (zig required) — cost if wrong: fetch failures for consumers.
Task 4: complete (tests: zig build test → PASS, zig build wgpu-clear → PASS)
Task 4: Ruling: backend lives in src/gfx/wgpu/backend.zig as separate linux-only module, NOT exported from root.zig — core lib stays zgpu-free and cross-platform. Plan assumed lib export; cost if wrong: desktop consumers import wgpu_backend module instead of ez_engine.Wgpu.
Task 4: Ruling: replaced `orelse unreachable` with `return error.InvalidTextureHandle` in backend draw loop — cost if wrong: none, strictly better diagnostics.
Task 5: complete (tests: zig build test → PASS)
