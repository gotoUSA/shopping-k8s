"""Render captured command output (evidence/*.txt) to terminal-style PNG images."""

import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

SIZE = 15
MONO = ImageFont.truetype("C:/Windows/Fonts/consola.ttf", SIZE)
HANGUL = ImageFont.truetype("C:/Windows/Fonts/malgun.ttf", SIZE)
CELL = MONO.getlength("M")
LINE = SIZE + 6
PAD = 14
BG, FG, CMD = (24, 24, 27), (228, 228, 231), (125, 211, 252)


def width_of(ch: str) -> int:
    return 2 if ord(ch) > 0x2E7F else 1


def render(src: Path) -> Path:
    lines = [
        "".join(c for c in raw if ord(c) <= 0xFFFF).rstrip()
        for raw in src.read_text(encoding="utf-8", errors="ignore").splitlines()
    ]
    columns = max(sum(width_of(c) for c in line) for line in lines)
    image = Image.new(
        "RGB", (int(columns * CELL) + PAD * 2, len(lines) * LINE + PAD * 2), BG
    )
    draw = ImageDraw.Draw(image)
    for row, line in enumerate(lines):
        color = CMD if line.startswith("$ ") else FG
        x = PAD
        for ch in line:
            draw.text(
                (x, PAD + row * LINE),
                ch,
                font=HANGUL if ord(ch) > 0x2E7F else MONO,
                fill=color,
            )
            x += width_of(ch) * CELL
    out = src.with_suffix(".png")
    image.save(out)
    return out


if __name__ == "__main__":
    for name in sys.argv[1:]:
        print(render(Path(name)))
