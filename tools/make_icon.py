#!/usr/bin/env python3
"""Draw the app icon: dark green tile, white peaks, yellow road, observatory dome.

Writes assets/icon/icon.png (full icon, 1024 px) and
assets/icon/foreground.png (Android adaptive-icon foreground, transparent).
"""
from pathlib import Path

from PIL import Image, ImageDraw

OUT = Path(__file__).resolve().parent.parent / "assets" / "icon"
S = 4096  # draw large, downsample for smooth edges
GREEN = (11, 61, 30)
SNOW = (245, 245, 240)
ROCK = (196, 204, 198)
YELLOW = (242, 196, 0)
DOME = (255, 255, 255)


def p(x, y, scale, off):
    return (off + x * scale, off + y * scale)


def draw_art(d, scale=1.0, off=0.0):
    """Artwork in a 0..S square; scale/off shrink it into a safe zone."""
    P = lambda x, y: p(x, y, scale, off)
    # Back peak (left) and main peak (right) with a flat summit for the dome.
    d.polygon([P(-200, 3500), P(1250, 1700), P(2300, 3500)], fill=ROCK)
    d.polygon([P(800, 3500), P(2300, 1300), P(2900, 1300), P(4300, 3500)], fill=SNOW)
    # Shadow side of the main peak.
    d.polygon([P(2900, 1300), P(4300, 3500), P(3150, 3500), P(2750, 1300)], fill=ROCK)
    # Ground.
    d.rectangle([P(-200, 3400), P(4300, 4300)], fill=GREEN)
    # Road: switchbacks climbing to the summit.
    road = [P(800, 4300), P(1800, 3300), P(3050, 3000), P(1900, 2450),
            P(2850, 1950), P(2350, 1600), P(2600, 1330)]
    d.line(road, fill=GREEN, width=int(250 * scale), joint="curve")
    d.line(road, fill=YELLOW, width=int(150 * scale), joint="curve")
    # Observatory dome sitting on the summit.
    cx, base = P(2600, 1300)
    r = 300 * scale
    wall = 150 * scale
    w = int(36 * scale)
    d.rectangle([cx - r, base - wall, cx + r, base], fill=DOME, outline=GREEN, width=w)
    d.pieslice([cx - r, base - wall - r, cx + r, base - wall + r], 180, 360, fill=DOME, outline=GREEN, width=w)
    d.rectangle([cx - 50 * scale, base - wall - r + 40 * scale, cx + 50 * scale, base - wall], fill=GREEN)  # slit


def save(img, name):
    img.resize((1024, 1024), Image.LANCZOS).save(OUT / name)


OUT.mkdir(parents=True, exist_ok=True)

icon = Image.new("RGB", (S, S), GREEN)
d = ImageDraw.Draw(icon)
draw_art(d, scale=0.82, off=S * 0.09)
save(icon, "icon.png")

# Adaptive foreground: launchers crop to a circle/squircle in the middle 66%.
fg = Image.new("RGBA", (S, S), (0, 0, 0, 0))
mask = Image.new("L", (S, S), 0)
art = Image.new("RGBA", (S, S), GREEN + (255,))
draw_art(ImageDraw.Draw(art), scale=0.56, off=S * 0.22)
ImageDraw.Draw(mask).rectangle([S * 0.17, S * 0.17, S * 0.83, S * 0.83], fill=255)
fg.paste(art, (0, 0), mask)
save(fg, "foreground.png")
print("wrote", *sorted(f.name for f in OUT.iterdir()))
