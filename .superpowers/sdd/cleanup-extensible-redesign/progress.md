# SDD ledger — plan: docs/superpowers/plans/2026-10-10-cleanup-extensible-redesign.md
Pre-flight: tasks 2->3 (render path -> facade), 2->4 (backend uses Renderer.Backend, unaffected by mesh removal), 3->4/5 (rename affects imports). No conflicts blocking; rename applied after removal.
Ruling: no git repo -> will git init + initial commit before any delete for rollback safety.
Task 1: complete (tests: zig build test → PASS)
Task 2: complete (tests: zig build test → PASS)
Task 2: Ruling: also removed MeshHandle/ShaderHandle (not just MaterialHandle) since mesh/shader loaders deleted — cost if wrong: re-add one-line handle aliases.
