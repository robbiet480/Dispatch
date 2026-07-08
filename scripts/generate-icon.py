#!/usr/bin/env python3
"""Generate Dispatch's app icon.

Renders a 1024x1024 PNG: a flat tomato background with a white-stroked
hexagon made of triangle facets, three of which are filled in the app's
accent colors (teal, pink, chartreuse). This is an original geometric
mark designed for Dispatch -- it does not reproduce the artwork of the
original (discontinued) Reporter app.

Usage:
    python3 scripts/generate-icon.py

Requires Pillow (PIL). Install with `pip3 install pillow` if missing.
"""

import math
import os
import sys

try:
    from PIL import Image, ImageDraw
except ImportError:
    sys.exit(
        "Pillow is required to generate the icon.\n"
        "Install it with: pip3 install pillow"
    )

SIZE = 1024

BACKGROUND = (250, 91, 61, 255)   # tomato #FA5B3D
TEAL = (32, 190, 198, 255)        # #20BEC6
PINK = (242, 104, 241, 255)       # #F268F1
CHARTREUSE = (203, 216, 43, 255)  # #CBD82B
WHITE = (255, 255, 255, 255)


def hex_point(center, radius, index, rotation_deg=-90):
    """Return the (x, y) of hexagon vertex `index` (0-5)."""
    angle = math.radians(rotation_deg + index * 60)
    return (center[0] + radius * math.cos(angle), center[1] + radius * math.sin(angle))


def main():
    # Supersample for clean anti-aliased edges, then downscale.
    scale = 4
    canvas_size = SIZE * scale
    img = Image.new("RGBA", (canvas_size, canvas_size), BACKGROUND)
    draw = ImageDraw.Draw(img)

    center = (canvas_size / 2, canvas_size / 2)
    radius = canvas_size * 0.34
    stroke_width = int(canvas_size * 0.012)

    outer = [hex_point(center, radius, i) for i in range(6)]

    # Facet fills: 3 of the 6 triangles (center -> two adjacent vertices)
    # are colored; the rest remain background (tomato) so the mark reads
    # as a partially-filled hexagon of triangle facets.
    facet_colors = {
        0: TEAL,
        2: PINK,
        4: CHARTREUSE,
    }

    for i in range(6):
        color = facet_colors.get(i)
        if color is None:
            continue
        triangle = [center, outer[i], outer[(i + 1) % 6]]
        draw.polygon(triangle, fill=color)

    # Internal spoke lines (center to each vertex) to show the facets.
    for i in range(6):
        draw.line([center, outer[i]], fill=WHITE, width=stroke_width // 2)

    # Outer hexagon stroke.
    draw.polygon(outer, outline=WHITE, width=stroke_width)
    # Close the outline crisply at each vertex with a small disc.
    for pt in outer:
        r = stroke_width / 2
        draw.ellipse([pt[0] - r, pt[1] - r, pt[0] + r, pt[1] + r], fill=WHITE)

    img = img.resize((SIZE, SIZE), Image.LANCZOS)

    out_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "App", "Assets.xcassets", "AppIcon.appiconset",
    )
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "icon-1024.png")

    # iOS app store icons must not have an alpha channel.
    flat = Image.new("RGB", img.size, BACKGROUND[:3])
    flat.paste(img, mask=img.split()[3])
    flat.save(out_path, "PNG")
    print(f"Wrote {out_path} ({flat.size[0]}x{flat.size[1]})")


if __name__ == "__main__":
    main()
