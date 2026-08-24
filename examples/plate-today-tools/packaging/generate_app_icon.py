#!/usr/bin/env python3
"""Generates PlateToday's app icon images into Resources/Assets.xcassets/AppIcon.appiconset.

A placeholder design, not a real one. Writes PNGs only — build-and-sign.sh/build-and-sign-mas.sh
run `actool` afterward to compile this into Assets.car (and derive AppIcon.icns from it). Both are
required in the shipped app: CFBundleIconName (already set in Info.plist) resolves through
Assets.car, which is what App Store Connect's asset-catalog validation and System Settings'
Privacy & Security pane actually read; a bare .icns via CFBundleIconFile alone renders fine in
Finder/Dock but isn't sufficient for either of those — same finding locallmlab-main's own
packaging/generate_app_icon.py already documents for the main app's icon.
"""
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Pillow is required: pip3 install Pillow", file=sys.stderr)
    sys.exit(1)

APPICONSET = Path(__file__).parent / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"

# (filename, pixel size) — the standard macOS app icon set, matching AppIcon.appiconset/Contents.json.
ICON_FILES = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]


def render(size: int) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    margin = size // 12
    draw.rounded_rectangle(
        [margin, margin, size - margin, size - margin],
        radius=size // 5,
        fill=(45, 120, 210, 255),
    )
    emoji = "🍽️"
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
    APPICONSET.mkdir(parents=True, exist_ok=True)
    for filename, size in ICON_FILES:
        render(size).save(APPICONSET / filename)
    print(f"Wrote {len(ICON_FILES)} icon images to {APPICONSET}")


if __name__ == "__main__":
    main()
