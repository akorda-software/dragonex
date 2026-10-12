#!/usr/bin/env python3
"""Generate the Dragonex pixel wordmark (priv/static/assets/wordmark.svg).

16-bit title lettering: chunky two-pixel stems on a nine-row grid, banded
gold-to-ember fill, a one-pixel dark outline and a two-pixel ember extrusion,
matching the stepped RPG frames of the app. Run: python3 scripts/gen_wordmark.py
"""
from pathlib import Path

GLYPHS = {
    "D": ["111110", "110111", "110011", "110011", "110011", "110011", "110011", "110111", "111110"],
    "R": ["111110", "110111", "110011", "110111", "111110", "111100", "110110", "110111", "110011"],
    "A": ["011110", "111111", "110011", "110011", "111111", "111111", "110011", "110011", "110011"],
    "G": ["011111", "111111", "110000", "110000", "110111", "110111", "110011", "111111", "011110"],
    "O": ["011110", "111111", "110011", "110011", "110011", "110011", "110011", "111111", "011110"],
    "N": ["1100011", "1110011", "1111011", "1101111", "1100111", "1100111", "1100011", "1100011", "1100011"],
    "E": ["111111", "111111", "110000", "110000", "111110", "110000", "110000", "111111", "111111"],
    "X": ["1100011", "1100011", "0110110", "0111110", "0011100", "0111110", "0110110", "1100011", "1100011"],
}

# Row bands, top to bottom: highlight, gold, gold, gold, deep gold, torch, torch, ember, ember.
BANDS = ["#fff1b0", "#ffe27a", "#ffd23f", "#ffd23f", "#ffc22e", "#ffa424", "#ff8a1f", "#e8651a", "#c2410c"]
OUTLINE = "#07050b"
EXTRUDE = "#7c1a22"
GAP, PAD, DEPTH = 1, 1, 2


def pixels(word):
    x, out = PAD, set()
    for ch in word:
        rows = GLYPHS[ch]
        for y, row in enumerate(rows):
            for dx, bit in enumerate(row):
                if bit == "1":
                    out.add((x + dx, PAD + y))
        x += len(rows[0]) + GAP
    return out, x - GAP + PAD


def exterior(fill, width, height):
    seen, stack = set(), [(-1, -1)]
    while stack:
        x, y = stack.pop()
        if (x, y) in seen or (x, y) in fill or not (-1 <= x <= width and -1 <= y <= height):
            continue
        seen.add((x, y))
        stack += [(x + 1, y), (x - 1, y), (x, y + 1), (x, y - 1)]
    return seen


def path(cells):
    return "".join(f"M{x} {y}h1v1h-1z" for x, y in sorted(cells))


def main():
    word = "DRAGONEX"
    fill, width = pixels(word)
    rows = len(BANDS)
    extrusion = {(x, y + d) for x, y in fill for d in range(1, DEPTH + 1)} - fill
    # Extrude only into the open background: counters (D, R, A, O…) stay clear.
    extrusion &= exterior(fill, width, PAD + len(BANDS) + DEPTH + PAD)
    body = fill | extrusion
    outline = {(x + dx, y + dy) for x, y in body for dx in (-1, 0, 1) for dy in (-1, 0, 1)} - body
    height = PAD + rows + DEPTH + PAD
    bands = [
        f'<path fill="{color}" d="{path({c for c in fill if c[1] - PAD == i})}"/>'
        for i, color in enumerate(BANDS)
    ]
    svg = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-1 -1 {width + 2} {height + 1}" '
        f'shape-rendering="crispEdges" role="img" aria-label="Dragonex">'
        f'<path fill="{OUTLINE}" d="{path(outline)}"/>'
        f'<path fill="{EXTRUDE}" d="{path(extrusion)}"/>'
        + "".join(bands)
        + "</svg>\n"
    )
    target = Path(__file__).resolve().parent.parent / "priv/static/assets/wordmark.svg"
    target.write_text(svg)
    print(f"wrote {target} ({width + 2}x{height + 1} px grid)")


if __name__ == "__main__":
    main()
