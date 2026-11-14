#!/usr/bin/env python3
"""Render mock screen dumps (from tests, via SCREENS=dir) into PNG images.

Usage: python3 tools/render_screens.py <dump dir> <output dir> [name ...]

Each dump starts with "size<TAB>W<TAB>H" (older dumps: 160x50), then has one "char<TAB>fg<TAB>bg"
line per cell.
Block characters are drawn as shapes so bars and sparklines look right with any font.
Requires Pillow: `make dev` installs it into .venv (see requirements.txt).
"""
import os
import sys

from PIL import Image, ImageDraw, ImageFont

CW, CH = 8, 16
SPARK = "▁▂▃▄▅▆▇"
FONTS = [
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/Library/Fonts/DejaVuSansMono.ttf",
    "/System/Library/Fonts/Menlo.ttc",
    "C:/Windows/Fonts/consola.ttf",
]


def load_font():
    for path in FONTS:
        if os.path.exists(path):
            return ImageFont.truetype(path, 13)
    return ImageFont.load_default()


def render(src, dst, font):
    with open(src, encoding="utf-8") as f:
        cells = f.read().split("\n")
    W, H = 160, 50
    if cells and cells[0].startswith("size\t"):
        _, w, h = cells.pop(0).split("\t")
        W, H = int(w), int(h)
    img = Image.new("RGB", (W * CW, H * CH))
    draw = ImageDraw.Draw(img)
    for i, line in enumerate(cells):
        if not line:
            continue
        ch, fg, bg = line.split("\t")
        x, y = (i % W) * CW, (i // W) * CH
        draw.rectangle([x, y, x + CW - 1, y + CH - 1], fill="#" + bg)
        if ch == "█":
            draw.rectangle([x, y, x + CW - 1, y + CH - 1], fill="#" + fg)
        elif ch == "▀":  # the splash logo: two pixels a cell, the top one in fg
            draw.rectangle([x, y, x + CW - 1, y + CH // 2 - 1], fill="#" + fg)
        elif ch in SPARK:
            h = (SPARK.index(ch) + 1) * CH // 8
            draw.rectangle([x, y + CH - h, x + CW - 1, y + CH - 1], fill="#" + fg)
        elif ch == "│":
            draw.line([x + CW // 2, y, x + CW // 2, y + CH], fill="#" + fg)
        elif ch != " ":
            draw.text((x, y + 1), ch, font=font, fill="#" + fg)
    img.save(dst)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(1)
    src_dir, out_dir, names = sys.argv[1], sys.argv[2], sys.argv[3:]
    os.makedirs(out_dir, exist_ok=True)
    font = load_font()
    for fname in sorted(os.listdir(src_dir)):
        name, ext = os.path.splitext(fname)
        if ext != ".txt" or (names and name not in names):
            continue
        render(os.path.join(src_dir, fname), os.path.join(out_dir, name + ".png"), font)
        print("rendered", name + ".png")


if __name__ == "__main__":
    main()
