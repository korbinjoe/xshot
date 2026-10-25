#!/usr/bin/env python3
"""Build original outlined lettering and review sources; no font dependency."""
from pathlib import Path
import json

ROOT = Path(__file__).resolve().parents[3]
FINAL = Path(__file__).resolve().parent
MASTERS = FINAL / "masters"
geometry = (MASTERS / "xshot-symbol-color.svg").read_text().split(' d="')[1].split('"')[0]
letters = [
    (0, "M0 0H16.57L72 96H55.43Z M55.43 0H72L16.57 96H0Z"),
    (86, "M64 6V22C50 12 16 10 16 28C16 36 22 40 34 44L44 48C62 54 70 64 70 78C70 102 22 104 2 90V72C22 90 54 90 54 76C54 68 48 64 36 60L24 56C6 50 0 42 0 28C0 2 40 -8 64 6Z"),
    (172, "M0 0H14V36C20 28 30 24 40 26C54 28 60 38 60 54V96H46V56C46 44 40 40 32 40C22 40 14 48 14 58V96H0Z"),
    (246, "M30 24C50 24 62 38 62 60C62 84 50 98 30 98C10 98 -2 84 -2 60C-2 38 10 24 30 24Z M30 38C18 38 12 46 12 60C12 76 18 84 30 84C42 84 48 76 48 60C48 46 42 38 30 38Z"),
    (318, "M12 10H26V28H46V42H26V72C26 82 30 86 40 86C44 86 48 84 50 82V96C44 100 38 100 32 100C16 100 12 90 12 74V42H0V28H12Z"),
]
word = "".join(f'<path transform="translate({x} 0)" fill-rule="{"evenodd" if x == 246 else "nonzero"}" d="{d}"/>' for x, d in letters)
head = '<svg xmlns="http://www.w3.org/2000/svg" '
for version, mark, text in [("color", "#3478F6", "#161B25"), ("black", "#000000", "#000000"), ("white", "#FFFFFF", "#FFFFFF")]:
    horizontal = head + f'viewBox="0 0 680 256" role="img" aria-labelledby="title"><title id="title">XShot horizontal {version}</title><path fill="{mark}" d="{geometry}"/><g transform="translate(280 80)" fill="{text}">' + word + '</g></svg>'
    (MASTERS / f"xshot-horizontal-{version}.svg").write_text(horizontal + "\n")
    stacked = head + f'viewBox="0 0 400 376" role="img" aria-labelledby="title"><title id="title">XShot stacked {version}</title><path transform="translate(84.8 0) scale(0.9)" fill="{mark}" d="{geometry}"/><g transform="translate(80.4 256) scale(0.65)" fill="{text}">' + word + '</g></svg>'
    (MASTERS / f"xshot-stacked-{version}.svg").write_text(stacked + "\n")
(MASTERS / "xshot-wordmark.svg").write_text(head + 'viewBox="-8 -8 384 116" role="img" aria-labelledby="title"><title id="title">XShot original outlined wordmark</title><g fill="#161B25">' + word + '</g></svg>\n')

app = (MASTERS / "xshot-app-icon.svg").read_text()
blue = (MASTERS / "xshot-symbol-color.svg").read_text()
template = (ROOT / "Resources/Logo/XShotTemplate.svg").read_text()


def sized(svg, width, height=None):
    return svg.replace('role="img"', f'width="{width}" height="{height or width}" role="img"')


html = '''<!doctype html><html><head><meta charset="utf-8"><style>body{background:#f3f4f6;color:#161b25;font:18px -apple-system,sans-serif;margin:40px}h1{font-size:28px}h2{font-size:18px;font-weight:600}.row{display:flex;align-items:center;gap:24px;margin:24px 0}.panel{background:white;border-radius:24px;padding:24px}.dark{background:#161b25}small{color:#737780}.col{display:flex;flex-direction:column;align-items:center;gap:10px}.icons{height:310px;align-items:end;gap:28px}</style></head><body><h1>XShot - Approved A - Final assets</h1><h2>macOS app icon - direct SVG rasterisation</h2><div class="row icons">'''
html += ''.join('<div class="col">' + sized(app, n) + f'<small>{n} px</small></div>' for n in [256, 128, 64, 32, 16])
html += '</div><h2>Symbol and menu bar template</h2><div class="row panel">' + sized(blue, 120) + sized(template, 36) + sized(template, 18)
html += '</div><div class="row panel dark">' + sized(template.replace('#000000', '#FFFFFF'), 36) + sized(template.replace('#000000', '#FFFFFF'), 18)
html += '</div><h2>Original outlined XShot lettering</h2><div class="row panel">' + sized((MASTERS / 'xshot-horizontal-color.svg').read_text(), 510, 192) + sized((MASTERS / 'xshot-stacked-color.svg').read_text(), 200, 188) + '</div></body></html>'
(ROOT / 'artifacts/logo-concepts/final-review.html').write_text(html)
spec = {
    'brand': 'XShot', 'tagline': 'Capture, annotate, pin',
    'brief': 'A restrained, precise identity for a native macOS screenshot utility. Approved concept A.',
    'adjectives': ['Simple', 'Precise', 'Light'],
    'criteria': 'Readable in one color and at 16 px; preserve the approved open-corner silhouette.',
    'industry': 'consumer-app', 'brand_color': '#3478F6', 'tile_color': '#3478F6',
    'greyscale': False, 'final': True, 'round': 2,
    'concepts': [{
        'name': 'Open corner', 'symbol': 'masters/xshot-symbol-color.svg',
        'lockup': 'masters/xshot-horizontal-color.svg', 'stacked': 'masters/xshot-stacked-color.svg',
        'avatar': 'masters/xshot-app-icon.svg', 'symbol_on_tile': 'masters/xshot-symbol-white.svg',
        'lockup_on_dark': 'masters/xshot-horizontal-white.svg', 'stacked_on_dark': 'masters/xshot-stacked-white.svg',
        'idea': 'Open a corner. Take a frame.',
        'rationale': ['One distinctive interruption in a familiar boundary.', 'Blue in the app; monochrome in the menu bar.', 'Vector outlines without font or image dependencies.'],
    }],
    'recommendation': 'Approved A: Open corner.', 'next_steps': ['Verify in the actual menu bar and Dock.'],
}
(FINAL / 'presentation-spec.json').write_text(json.dumps(spec, indent=2))
