#!/usr/bin/env python3
"""Generate the Lagoon app icon at all required macOS sizes.

Produces a `.iconset/` folder with the 10 PNG sizes macOS expects, then
runs `iconutil` to fold them into `Support/Lagoon.icns`.

Design ("the becalmed envelope"): on a warm ivory squircle (Apple's
Big Sur grid — 824pt artwork on a 1024pt canvas), a white envelope
rests in still lagoon water. Its flap IS the waterline: a calm teal
wave that dips to the centre the way an envelope fold does, so the
mark reads as both "mail" and "water" in one shape. A soft reflection
line, a water shadow and two ripple rings hold it in place.

The palette carries the app's brand colours: lagoon teal #1F6F84 on
ivory — a light icon that reads cleanly against light and dark
Finder/Dock backgrounds. Detail is adaptive: sizes below 48px drop
the reflection line and ripple rings, the way Apple's own icons do.

Run from the repo root:
    python3 scripts/build-icon.py
"""
from __future__ import annotations

import math
import subprocess
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFilter
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

# ---- palette -----------------------------------------------------------
BG_TOP = (255, 254, 251)      # #FFFEFB warm white
BG_BOTTOM = (239, 228, 206)   # #EFE4CE ivory sand
FLAP_TOP = (69, 183, 178)     # #45B7B2 shallow water
FLAP_BOTTOM = (31, 111, 132)  # #1F6F84 lagoon teal (brand)
RIPPLE = (95, 185, 179)       # #5FB9B3
ECHO = (127, 203, 197)        # #7FCBC5 reflection line
SHADOW = (14, 58, 74)         # #0E3A4A deep water (soft shadow)
WHITE = (255, 255, 255)

# ---- geometry, normalised to the 1024pt Apple icon grid ----------------
SQUIRCLE_INSET = 100 / 1024    # Big Sur grid: 824pt artwork on 1024pt canvas
SQUIRCLE_RADIUS = 185 / 1024

ENV = (262 / 1024, 330 / 1024, 500 / 1024, 316 / 1024)  # x y w h
ENV_RADIUS = 46 / 1024
WAVE_INSET = 8 / 1024          # wave line stops short of the envelope edge

WAVE_BASE = 452 / 1024         # waterline height at the envelope edges
WAVE_AMP = 82 / 1024           # dip at the centre (the "flap tip")
WAVE_MOD = 10 / 1024           # gentle symmetric undulation

ECHO_BASE = 526 / 1024         # the reflection line, inside the body
ECHO_AMP = 70 / 1024
ECHO_MOD = 8 / 1024

RIPPLE_CX, RIPPLE_CY = 0.5, 652 / 1024
RIPPLES = [                    # rx, ry, opacity; drawn at >=64px
    (350 / 1024, 60 / 1024, 0.26),
    (286 / 1024, 47 / 1024, 0.50),
]
SHADOW_RX, SHADOW_CY, SHADOW_RY = 230 / 1024, 640 / 1024, 30 / 1024
SHADOW_OPACITY = 0.16

MIN_SIZE_ECHO = 48             # below this the fine detail is dropped
MIN_SIZE_INNER_RIPPLE = 48
MIN_SIZE_OUTER_RIPPLE = 64


def wave_points(size: int, base: float, amp: float, mod: float):
    """Sample the waterline: a cosine dipping to the centre (the flap
    tip) with a symmetric ripple modulation — same curve in every size,
    ~10pt sampling steps at the 1024pt reference size."""
    x0 = ENV[0] + WAVE_INSET
    x1 = ENV[0] + ENV[2] - WAVE_INSET
    half = (x1 - x0) / 2
    count = max(8, int((x1 - x0) * 1024 / 10))
    pts = []
    for i in range(count + 1):
        x = x0 + (x1 - x0) * i / count
        t = (x - x0) / half
        y = base - amp * math.cos(math.pi * t) + mod * math.cos(2 * math.pi * t)
        pts.append((x * size, y * size))
    return pts


def vertical_gradient(size: int, top: tuple, bottom: tuple) -> Image.Image:
    """1px-wide gradient strip resized to full size — fast and smooth."""
    strip = Image.new("RGB", (1, size))
    for y in range(size):
        t = y / max(1, size - 1)
        strip.putpixel(
            (0, y),
            tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)),
        )
    return strip.resize((size, size), Image.BICUBIC)


def rounded_mask(size: int, inset: float, radius: float) -> Image.Image:
    mask = Image.new("L", (size, size), 0)
    m = round(inset * size)
    ImageDraw.Draw(mask).rounded_rectangle(
        (m, m, size - 1 - m, size - 1 - m), radius=round(radius * size), fill=255
    )
    return mask


def draw_flap(size: int) -> Image.Image:
    """The teal waterline-flap, clipped to the envelope's rounded rect."""
    ex, ey, ew, _ = (v * size for v in ENV)
    rx = ENV_RADIUS * size
    pts = wave_points(size, WAVE_BASE, WAVE_AMP, WAVE_MOD)
    x0, x1 = pts[0][0], pts[-1][0]

    flap = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    poly = [(x, y) for x, y in pts] + [(x1, ey), (x0, ey)]

    # vertical gradient sized to the polygon's bbox, shown through the wave
    ys = [p[1] for p in pts]
    grad = vertical_gradient(size, FLAP_TOP, FLAP_BOTTOM)
    mask = Image.new("L", (size, size), 0)
    ImageDraw.Draw(mask).polygon(poly, fill=255)
    flap.paste(grad, (0, 0), mask)

    # clip everything to the envelope silhouette
    clip = Image.new("L", (size, size), 0)
    ImageDraw.Draw(clip).rounded_rectangle(
        (ex, ey, ex + ew, ey + ENV[3] * size), radius=rx, fill=255
    )
    r, g, b, a = flap.split()
    flap = Image.merge("RGBA", (r, g, b, Image.composite(a, Image.new("L", (size, size), 0), clip)))
    return flap


def draw_wave_line(size: int, base: float, amp: float, mod: float,
                   color: tuple, width_px: int, opacity: int) -> Image.Image:
    """The reflection line: a stroked waterline with round caps."""
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(layer)
    pts = wave_points(size, base, amp, mod)
    draw.line(pts, fill=color + (opacity,), width=width_px, joint="curve")
    r = width_px / 2
    for x, y in (pts[0], pts[-1]):
        draw.ellipse((x - r, y - r, x + r, y + r), fill=color + (opacity,))
    return layer


def render(size: int) -> Image.Image:
    icon = vertical_gradient(size, BG_TOP, BG_BOTTOM).convert("RGBA")
    icon.putalpha(rounded_mask(size, SQUIRCLE_INSET, SQUIRCLE_RADIUS))

    scene = Image.new("RGBA", (size, size), (0, 0, 0, 0))

    # water shadow under the envelope
    shadow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    sx, sy = RIPPLE_CX * size, SHADOW_CY * size
    srx, sry = SHADOW_RX * size, SHADOW_RY * size
    ImageDraw.Draw(shadow).ellipse(
        (sx - srx, sy - sry, sx + srx, sy + sry), fill=SHADOW + (round(255 * SHADOW_OPACITY),)
    )
    if size >= 32:
        shadow = shadow.filter(ImageFilter.GaussianBlur(max(1.0, size * 0.008)))
    scene.alpha_composite(shadow)

    # ripple rings (dropped at small sizes)
    for rx, ry, op in RIPPLES:
        min_size = MIN_SIZE_OUTER_RIPPLE if (rx, ry, op) == RIPPLES[0] else MIN_SIZE_INNER_RIPPLE
        if size < min_size:
            continue
        cx, cy = RIPPLE_CX * size, RIPPLE_CY * size
        width = max(1, round(10 / 1024 * size))
        ImageDraw.Draw(scene).ellipse(
            (cx - rx * size, cy - ry * size, cx + rx * size, cy + ry * size),
            outline=RIPPLE + (round(255 * op),), width=width,
        )

    # envelope body + wave flap + reflection line
    ex, ey, ew, eh = (v * size for v in ENV)
    ImageDraw.Draw(scene).rounded_rectangle(
        (ex, ey, ex + ew, ey + eh), radius=ENV_RADIUS * size, fill=WHITE + (255,)
    )
    scene.alpha_composite(draw_flap(size))
    if size >= MIN_SIZE_ECHO:
        scene.alpha_composite(
            draw_wave_line(size, ECHO_BASE, ECHO_AMP, ECHO_MOD, ECHO,
                           max(1, round(9 / 1024 * size)), 128)
        )

    icon.alpha_composite(scene)
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
