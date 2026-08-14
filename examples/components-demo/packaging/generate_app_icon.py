#!/usr/bin/env python3
"""Generates ComponentsDemo's AppIcon.icns — a simple placeholder, not a designed icon.

Same approach as plate-today's packaging/generate_app_icon.py (no Assets.xcassets/actool pass,
just a Pillow-rendered emoji on a rounded square) — see that script's docstring for why this is
enough for a dev/demo app. Different emoji/color only, so the two apps are visually
distinguishable in the Dock while testing both at once.
"""
import subprocess
import sys
import tempfile
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow is required: pip3 install Pillow", file=sys.stderr)
    sys.exit(1)

SIZES = [16, 32, 64, 128, 256, 512, 1024]
OUTPUT = Path(__file__).parent / "AppIcon.icns"


def render(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    margin = size // 12
    draw.rounded_rectangle(
        [margin, margin, size - margin, size - margin],
        radius=size // 5,
        fill=(120, 70, 200, 255),
    )
    emoji = "🧩"
    font_size = int(size * 0.55)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Apple Color Emoji.ttc", font_size)
    except Exception:
        font = ImageFont.load_default()
    bbox = draw.textbbox((0, 0), emoji, font=font, embedded_color=True)
    text_w, text_h = bbox[2] - bbox[0], bbox[3] - bbox[1]
    draw.text(
        ((size - text_w) / 2 - bbox[0], (size - text_h) / 2 - bbox[1]),
        emoji, font=font, embedded_color=True,
    )
    return img


def main():
    with tempfile.TemporaryDirectory() as tmp:
        iconset = Path(tmp) / "AppIcon.iconset"
        iconset.mkdir()
        for size in SIZES:
            render(size).save(iconset / f"icon_{size}x{size}.png")
            if size <= 512:
                render(size * 2).save(iconset / f"icon_{size}x{size}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iconset), "-o", str(OUTPUT)], check=True)
    print(f"Wrote {OUTPUT}")


if __name__ == "__main__":
    main()
