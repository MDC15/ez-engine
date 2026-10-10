#!/usr/bin/env python3
"""Create and manage local ez-engine game projects."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


ENGINE_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WORKSPACE = ENGINE_ROOT / "projects"
PROJECT_FILE = "project.json"


def project_slug(name: str) -> str:
    slug = re.sub(r"[^A-Za-z0-9_-]+", "-", name.strip()).strip("-_")
    if not slug:
        raise ValueError("Project name must contain letters or numbers.")
    return slug


def package_identifier(name: str) -> str:
    identifier = project_slug(name).replace("-", "_")
    if identifier[0].isdigit():
        identifier = f"game_{identifier}"
    if len(identifier.encode("ascii")) > 32:
        raise ValueError("Project name must produce a Zig package name of at most 32 characters.")
    return identifier


def write_project(target: Path, name: str) -> None:
    dependency_path = Path(os.path.relpath(ENGINE_ROOT, target)).as_posix()
    (target / "Assets").mkdir(parents=True)
    (target / "Scenes").mkdir()
    (target / "src").mkdir()
    (target / "Build").mkdir()
    shutil.copy2(ENGINE_ROOT / "assets" / "sprite.ztex", target / "Assets" / "sprite.ztex")
    shutil.copy2(ENGINE_ROOT / "assets" / "player_sheet.png", target / "Assets" / "player_sheet.png")
    shutil.copy2(ENGINE_ROOT / "assets" / "sprite.png", target / "Assets" / "sprite.png")
    shutil.copy2(ENGINE_ROOT / "src" / "platform" / "glfw_window.zig", target / "src" / "glfw_window.zig")

    metadata = {
        "format_version": 1,
        "name": name,
        "engine": "ez-engine",
        "startup_scene": "editor_scene.json",
    }
    (target / PROJECT_FILE).write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")

    scene = {
        "version": 1,
        "objects": [
            {"id": 1, "kind": "sprite", "position": [0, 0], "size": [64, 64]},
            {"id": 2, "kind": "obstacle", "position": [100, 80], "size": [64, 64]},
            {"id": 3, "kind": "pickup", "position": [220, -100], "size": [64, 64]},
        ],
    }
    (target / "editor_scene.json").write_text(json.dumps(scene, indent=2) + "\n", encoding="utf-8")

    (target / "build.zig.zon").write_text(
        f'''.{{
    .name = .{package_identifier(name)},
    .version = "0.1.0",
    .minimum_zig_version = "0.16.0",
    .dependencies = .{{
        .ez_engine = .{{ .path = "{dependency_path}" }},
        .zglfw = .{{
            .url = "git+https://github.com/zig-gamedev/zglfw#f04fdbfc5b6d8c9a12025013992ac1d48653931e",
            .hash = "zglfw-0.10.0-dev-zgVDNNu5IQAk-UK7gIg0LWMmMzxj4sK9xCSTisLhjgI1",
        }},
        .zgpu = .{{
            .url = "git+https://github.com/zig-gamedev/zgpu#e6d8103b3c34ce1d6aab4db86dedf9ac889b4e67",
            .hash = "zgpu-0.12.0-dev-nqFT5DSoCACIu3-Gnwlg3Gv1if5vU5RBhpk8o6r6-vqk",
        }},
        .dawn_x86_64_linux_gnu = .{{
            .url = "https://github.com/michal-z/webgpu_dawn-x86_64-linux-gnu/archive/7d70db023bf254546024629cbec5ee6113e12a42.tar.gz",
            .hash = "N-V-__8AAK7XUQNKNRnv1J6i189jtURJKjp3HTftoyD4Y4CB",
        }},
    }},
    .paths = .{{ "build.zig", "build.zig.zon", "src", "Assets", "Scenes", "project.json", "editor_scene.json", "README.md" }},
}}
''',
        encoding="utf-8",
    )
    (target / "build.zig").write_text(
        '''const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    if (target.result.os.tag != .linux or target.result.cpu.arch != .x86_64) return;

    const engine = b.dependency("ez_engine", .{ .target = target, .optimize = optimize });
    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize, .shared = true });
    const zgpu = b.dependency("zgpu", .{ .target = target, .optimize = optimize });
    const dawn = b.dependency("dawn_x86_64_linux_gnu", .{});

    const wgpu_backend = b.createModule(.{
        .root_source_file = engine.path("src/gfx/wgpu/backend.zig"),
        .target = target,
        .optimize = optimize,
    });
    wgpu_backend.addImport("ez_engine", engine.module("ez_engine"));
    wgpu_backend.addImport("zgpu", zgpu.module("root"));

    const glfw_window = b.createModule(.{
        .root_source_file = b.path("src/glfw_window.zig"),
        .target = target,
        .optimize = optimize,
    });
    glfw_window.addImport("ez_engine", engine.module("ez_engine"));
    glfw_window.addImport("zglfw", zglfw.module("root"));

    const game_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    game_module.addImport("ez_engine", engine.module("ez_engine"));
    game_module.addImport("zglfw", zglfw.module("root"));
    game_module.addImport("zgpu", zgpu.module("root"));
    game_module.addImport("wgpu_backend", wgpu_backend);
    game_module.addImport("glfw_window", glfw_window);

    const game = b.addExecutable(.{
        .name = "game",
        .root_module = game_module,
        .use_llvm = true,
    });
    game.root_module.linkLibrary(zglfw.artifact("glfw"));
    game.root_module.linkLibrary(zgpu.artifact("zdawn"));
    game.root_module.linkSystemLibrary("X11", .{});
    game.root_module.addLibraryPath(dawn.path(""));
    game.root_module.linkSystemLibrary("dawn", .{});
    const run = b.addRunArtifact(game);
    const run_step = b.step("run", "Build and run the game");
    run_step.dependOn(&run.step);
}
''',
        encoding="utf-8",
    )
    starter_source = (ENGINE_ROOT / "examples" / "wgpu_clear" / "main.zig").read_text(encoding="utf-8")
    starter_source = starter_source.replace('"assets/player_sheet.png"', '"Assets/player_sheet.png"')
    starter_source = starter_source.replace('"assets/sprite.png"', '"Assets/sprite.png"')
    (target / "src" / "main.zig").write_text(starter_source, encoding="utf-8")
    (target / "README.md").write_text(
        f'''# {name}

Game project created with ez-engine.

## Build and run

```sh
zig build
zig build run
```

The starter opens a WGPU game window with an animated player, movement, and
basic collision sample. WSL users need WSLg. Edit `src/main.zig`, put textures
in `Assets/`, and edit `editor_scene.json` by hand (it uses the `ez_engine.Scene`
format, version 1). Project metadata is in `project.json`.
''',
        encoding="utf-8",
    )
    initialize_package_fingerprint(target)


def initialize_package_fingerprint(target: Path) -> None:
    result = subprocess.run(
        ["zig", "build", "--help"],
        cwd=target,
        capture_output=True,
        text=True,
        check=False,
    )
    output = result.stdout + result.stderr
    suggestion = re.search(r"suggested value: (0x[0-9a-fA-F]{16})", output)
    if suggestion is None:
        if result.returncode == 0:
            return
        raise RuntimeError(f"Could not initialize Zig package fingerprint:\n{output.strip()}")

    manifest_path = target / "build.zig.zon"
    manifest = manifest_path.read_text(encoding="utf-8")
    manifest = manifest.replace(
        '    .version = "0.1.0",\n',
        f'    .version = "0.1.0",\n    .fingerprint = {suggestion.group(1)},\n',
        1,
    )
    manifest_path.write_text(manifest, encoding="utf-8")


def create_project(name: str, workspace: Path) -> Path:
    slug = project_slug(name)
    workspace = workspace.expanduser().resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    destination = workspace / slug
    if destination.exists():
        raise FileExistsError(f"Project directory already exists: {destination}")

    staging = Path(tempfile.mkdtemp(prefix=f".{slug}-", dir=workspace))
    try:
        write_project(staging, name.strip())
        staging.rename(destination)
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return destination


def find_projects(workspace: Path) -> list[tuple[Path, dict[str, object]]]:
    if not workspace.exists():
        return []
    projects = []
    for metadata_file in workspace.glob(f"*/{PROJECT_FILE}"):
        try:
            metadata = json.loads(metadata_file.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        if metadata.get("engine") == "ez-engine" and metadata.get("format_version") == 1:
            projects.append((metadata_file.parent, metadata))
    return sorted(projects, key=lambda item: str(item[1].get("name", "")).casefold())


def main() -> int:
    parser = argparse.ArgumentParser(prog="ez-project", description="Create and manage ez-engine game projects")
    parser.add_argument("--workspace", type=Path, default=DEFAULT_WORKSPACE, help=f"Projects folder (default: {DEFAULT_WORKSPACE})")
    commands = parser.add_subparsers(dest="command", required=True)

    create = commands.add_parser("new", help="Create a new game project")
    create.add_argument("name", help="Project name")

    commands.add_parser("list", help="List projects in the workspace")

    args = parser.parse_args()
    try:
        if args.command == "new":
            project = create_project(args.name, args.workspace)
            print(f"Created {project}")
            print(f"Next: cd '{project}' && zig build run")
        elif args.command == "list":
            projects = find_projects(args.workspace.expanduser().resolve())
            if not projects:
                print(f"No projects found in {args.workspace}")
            else:
                for project_path, metadata in projects:
                    print(f"{metadata['name']}\t{project_path}")
        return 0
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"ez-project: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
