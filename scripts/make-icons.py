#!/usr/bin/env python3
"""Rebuild XShot's approved A logo and macOS assets.

Requires macOS iconutil and a renderer supported by logo-design/render_png.py
(Chrome is available on the development machine). No network or package install.
Pass --renderer-script when the logo-design skill is installed elsewhere.
"""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BLUE = "#3478F6"
INK = "#161B25"
GEOMETRY = "M56 32H132L160 60H68A8 8 0 0 0 60 68V188A8 8 0 0 0 68 196H188A8 8 0 0 0 196 188V96L224 124V200A24 24 0 0 1 200 224H56A24 24 0 0 1 32 200V56A24 24 0 0 1 56 32Z M168 32H200A24 24 0 0 1 224 56V88L196 60Z"


def symbol(color: str, viewbox: str = "0 0 256 256", title: str = "XShot 开角") -> str:
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{viewbox}" role="img" '
            f'aria-labelledby="title"><title id="title">{title}</title>'
            f'<path fill="{color}" d="{GEOMETRY}"/></svg>\n')


def write_sources() -> tuple[Path, Path, Path]:
    masters = ROOT / "Design/Logo/Final/masters"
    resources = ROOT / "Resources/Logo"
    masters.mkdir(parents=True, exist_ok=True)
    resources.mkdir(parents=True, exist_ok=True)
    for name, color in [("color", BLUE), ("black", "#000000"), ("white", "#FFFFFF"), ("ink", INK)]:
        (masters / f"xshot-symbol-{name}.svg").write_text(symbol(color))
    # Tight viewport changes only clear space, preserving approved geometry.
    small = masters / "xshot-symbol-small.svg"
    small.write_text(symbol(BLUE, "24 24 208 208"))
    template = resources / "XShotTemplate.svg"
    template.write_text(symbol("#000000", "24 24 208 208", "XShot menu bar template"))
    app_icon = masters / "xshot-app-icon.svg"
    app_icon.write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" role="img" '
        'aria-labelledby="title"><title id="title">XShot macOS app icon</title>'
        '<rect x="100" y="100" width="824" height="824" rx="184" fill="#FFFFFF"/>'
        f'<path transform="translate(128 128) scale(3)" fill="{BLUE}" d="{GEOMETRY}"/>'
        '</svg>\n')
    (resources / "XShotMark.svg").write_text(symbol(BLUE))
    return app_icon, resources / "XShotMark.svg", template


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--renderer-script", type=Path,
                        default=Path.home() / ".codex/skills/logo-design/scripts/render_png.py")
    args = parser.parse_args()
    if not args.renderer_script.is_file():
        parser.error("Pass the installed logo-design render_png.py with --renderer-script")
    if not shutil.which("iconutil"):
        parser.error("macOS iconutil is required to build ICNS")
    app_icon, mark, template = write_sources()

    def render(source: Path, output: Path, size: int) -> None:
        subprocess.run(["python3", str(args.renderer_script), str(source), "-o", str(output),
                        "--size", str(size)], check=True)

    # Rasterise each resolution from vector, never enlarge a small bitmap.
    with tempfile.TemporaryDirectory(prefix="xshot-icons-") as temp:
        iconset = Path(temp) / "XShot.iconset"
        iconset.mkdir()
        jobs: list[tuple[Path, Path, int]] = []
        for points in [16, 32, 128, 256, 512]:
            jobs.append((app_icon, iconset / f"icon_{points}x{points}.png", points))
            jobs.append((app_icon, iconset / f"icon_{points}x{points}@2x.png", points * 2))
        jobs.extend([
            (app_icon, ROOT / "Resources/XShot-icon.png", 1024),
            (mark, ROOT / "Resources/Logo/XShotMark.png", 512),
            (template, ROOT / "Resources/Logo/XShotTemplate.png", 18),
            (template, ROOT / "Resources/Logo/XShotTemplate@2x.png", 36),
        ])
        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda job: render(*job), jobs))
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(ROOT / "Resources/XShot.icns")], check=True)
        preview = ROOT / "Design/Logo/Final/exports/app-icon-sizes"
        preview.mkdir(parents=True, exist_ok=True)
        for name, size in [("icon_16x16.png", 16), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
                           ("icon_128x128.png", 128), ("icon_256x256.png", 256), ("icon_512x512.png", 512),
                           ("icon_512x512@2x.png", 1024)]:
            shutil.copyfile(iconset / name, preview / f"xshot-{size}.png")
    print("Built Resources/XShot.icns, XShot-icon.png and Logo assets")


if __name__ == "__main__":
    main()
