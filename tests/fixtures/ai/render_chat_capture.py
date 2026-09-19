"""Render a real tmux capture-pane -e grid as PNG (optional Pillow dependency).

This converts captured cells and SGR colors; it does not reconstruct the UI.
"""
import argparse
from pathlib import Path
import re
import unicodedata

from PIL import Image, ImageDraw, ImageFont


def render(source, destination, columns):
    normal = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf", 16)
    bold_font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf", 16)
    rows = source.read_text().splitlines()
    cell, height = 10, 21
    background, foreground = (28, 28, 28), (199, 199, 199)
    canvas = Image.new("RGB", (columns * cell, len(rows) * height), background)
    draw = ImageDraw.Draw(canvas)
    fg, bg, bold, inverse = foreground, background, False, False
    palette = [(0, 0, 0), (205, 0, 0), (0, 205, 0), (205, 205, 0),
               (0, 0, 238), (205, 0, 205), (0, 205, 205), (229, 229, 229),
               (127, 127, 127), (255, 0, 0), (0, 255, 0), (255, 255, 0),
               (92, 92, 255), (255, 0, 255), (0, 255, 255), (255, 255, 255)]
    def color(index):
        if index < 16:
            return palette[index]
        if index >= 232:
            return (8 + 10 * (index - 232),) * 3
        index -= 16
        levels = [0, 95, 135, 175, 215, 255]
        return tuple(levels[value] for value in (index // 36, index // 6 % 6, index % 6))
    for y, row in enumerate(rows):
        x = 0
        for part in re.split(r"(\x1b\[[0-9;]*m)", row):
            if part.startswith("\x1b["):
                codes = [int(value or 0) for value in part[2:-1].split(";")]
                i = 0
                while i < len(codes):
                    code = codes[i]
                    if code in (38, 48) and i + 2 < len(codes):
                        if codes[i + 1] == 2:
                            value = tuple(codes[i + 2:i + 5])
                            i += 4
                        else:
                            value = color(codes[i + 2])
                            i += 2
                        if code == 38:
                            fg = value
                        else:
                            bg = value
                    elif code == 0:
                        fg, bg, bold, inverse = foreground, background, False, False
                    elif code in (1, 22):
                        bold = code == 1
                    elif code in (7, 27):
                        inverse = code == 7
                    elif code == 39:
                        fg = foreground
                    elif code == 49:
                        bg = background
                    elif 30 <= code <= 37 or 90 <= code <= 97:
                        fg = palette[code - (30 if code < 90 else 82)]
                    elif 40 <= code <= 47 or 100 <= code <= 107:
                        bg = palette[code - (40 if code < 100 else 92)]
                    i += 1
                continue
            for char in part:
                width = 0 if unicodedata.combining(char) else 2 if unicodedata.east_asian_width(char) in ("F", "W") else 1
                ink, paper = (bg, fg) if inverse else (fg, bg)
                draw.rectangle((x * cell, y * height, (x + width) * cell - 1, (y + 1) * height - 1), fill=paper)
                draw.text((x * cell, y * height), char, font=bold_font if bold else normal, fill=ink)
                x += width
        if x < columns:
            draw.rectangle((x * cell, y * height, columns * cell, (y + 1) * height - 1), fill=fg if inverse else bg)
    destination.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(destination)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    parser.add_argument("--columns", type=int, required=True)
    args = parser.parse_args()
    render(args.source, args.destination, args.columns)
