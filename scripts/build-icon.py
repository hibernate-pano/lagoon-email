#!/usr/bin/env python3
"""Generate the Lagoon app icon at all required macOS sizes.

Produces a `.iconset/` folder with the 10 PNG sizes macOS expects, then
runs `iconutil` to fold them into `Support/Lagoon.icns`.

Design: ivory rounded square with the ripple drawn in lagoon teal
(plus the warm accent on the outermost arc) — a light icon that reads
cleanly against both light and dark Finder backgrounds.

Run from the repo root:
    python3 scripts/build-icon.py
"""
from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw
except ImportError:
    print("Pillow is required: python3 -m pip install --user Pillow", file=sys.stderr)
    sys.exit(1)

REPO_ROOT = Path(__file__).resolve().parent.parent
ICONSET = REPO_ROOT / "Support" / "Lagoon.iconset"
ICNS = REPO_ROOT / "Support" / "Lagoon.icns"

# (filename suffix, pixel size) for every size macOS expects.
SIZES: list[tuple[str, int]] = [
    ("16x16", 16),
    ("16x16@2x", 32),
    ("32x32", 32),
    ("32x32@2x", 64),
    ("128x128", 128),
    ("128x128@2x", 256),
    ("256x256", 256),
    ("256x256@2x", 512),
    ("512x512", 512),
    ("512x512@2x", 1024),
]

# Brand palette — ivory ground, teal mark (light icon, not dark).
BG_TOP = (255, 255, 255)      # #FFFFFF pure white at the top
BG_BOTTOM = (253, 248, 238)   # #FDF8EE ivory at the bottom
ACCENT = (232, 163, 92)       # #E8A35C (sundown orange)
TEAL = (31, 111, 132)         # #1F6F84 — the mark colour on ivory
WHITE = (255, 255, 255)


def lerp(a: int, b: int, t: float) -> int:
    return int(a + (b - a) * t)


def vertical_gradient(size: int) -> Image.Image:
    """White → ivory gradient that fills the entire square."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        t = y / max(1, size - 1)
        r = lerp(BG_TOP[0], BG_BOTTOM[0], t)
        g = lerp(BG_TOP[1], BG_BOTTOM[1], t)
        b = lerp(BG_TOP[2], BG_BOTTOM[2], t)
        for x in range(size):
            px[x, y] = (r, g, b)
    return img


def rounded_mask(size: int) -> Image.Image:
    """Mask that clips the square to a rounded-rect (the macOS app-icon
    silhouette). Radius ~22% of size — the same proportion Apple's
    Squircle template uses."""
    mask = Image.new("L", (size, size), 0)
    radius = int(size * 0.2237)
    draw = ImageDraw.Draw(mask)
    draw.rounded_rectangle((0, 0, size - 1, size - 1), radius=radius, fill=255)
    return mask


def ripple_arcs(size: int) -> Image.Image:
    """Three concentric arcs (a calm ripple), lower-right of the icon.
    Drawn in teal at varying opacities for the inner two; the outer
    arc keeps the accent colour so it reads as 'sun on water'.

    Coordinates are normalised to size so the same drawing scales to
    every PNG dimension without per-size logic.
    """
    overlay = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(overlay)
    # Centre of the ripple, gently offset toward the lower-right but
    # pulled in far enough that the outermost ring sits well inside the
    # rounded square's corner. The previous draft had the outer ring
    # kissing the corner and the resulting .icns looked cropped.
    cx = int(size * 0.55)
    cy = int(size * 0.60)
    # Three radii, in order: outermost (accent), middle (teal 70%),
    # innermost (teal 95%). Stroke width scales with size.
    stroke = max(1, int(size * 0.022))
    rings = [
        (int(size * 0.27), ACCENT + (255,), stroke),
        (int(size * 0.19), TEAL + (175,), max(1, stroke - 1)),
        (int(size * 0.11), TEAL + (240,), max(1, stroke - 1)),
    ]
    for radius, color, width in rings:
        bbox = (cx - radius, cy - radius, cx + radius, cy + radius)
        draw.ellipse(bbox, outline=color, width=width)
    return overlay


def render(size: int) -> Image.Image:
    """Compose the icon at the given pixel size."""
    bg = vertical_gradient(size)
    mask = rounded_mask(size)
    icon = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    icon.paste(bg, (0, 0))
    icon.putalpha(mask)
    icon.alpha_composite(ripple_arcs(size))
    return icon


def main() -> int:
    if not ICONSET.exists():
        ICONSET.mkdir(parents=True, exist_ok=True)

    for suffix, size in SIZES:
        out = ICONSET / f"icon_{suffix}.png"
        render(size).save(out, "PNG")
        print(f"  wrote {out.relative_to(REPO_ROOT)} ({size}×{size})")

    # iconutil needs to run on the .iconset folder.
    if ICNS.exists():
        ICNS.unlink()
    subprocess.run(
        ["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)],
        check=True,
    )
    size_bytes = ICNS.stat().st_size
    print(f"  wrote {ICNS.relative_to(REPO_ROOT)} ({size_bytes:,} bytes)")
    if size_bytes < 50_000:
        print("WARNING: .icns file is unexpectedly small", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())