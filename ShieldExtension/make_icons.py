#!/usr/bin/env python3
"""Draws src/icons: roko's Eclipse (AppIcon.eclipse in Sources/Roko/AppIcon.swift),
bare, in black where Shield is on (light where the browser is dark), and opened
into a grey ring where it is off or paused, at the sizes Chrome asks for. Plain
Python, so it needs nothing."""

import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent / "src" / "icons"
# roko's ink and its light mark (AppIconChoice.standard), for light and dark
# toolbars, and a grey that reads on both.
COLOURS = {"on": (0x0E, 0x0E, 0x0F), "on-dark": (0xE7, 0xE7, 0xE4), "off": (0x8E, 0x8E, 0x8C)}
SAMPLES = 6


def coverage(size, x, y, margin, opened=False):
    """How much of pixel (x, y) the mark covers: the disc less its hole, even-odd.
    Opened, as the popup draws it where Shield is off: the hole moved to the
    middle and widened, a ring left."""
    cx, r = (300, 224) if opened else (394, 150)
    side = size - 2 * margin
    hits = 0
    for sy in range(SAMPLES):
        for sx in range(SAMPLES):
            px = (x + (sx + 0.5) / SAMPLES - margin) / side * 600
            py = (y + (sy + 0.5) / SAMPLES - margin) / side * 600
            disc = (px - 300) ** 2 + (py - 300) ** 2 <= 300 ** 2
            hole = (px - cx) ** 2 + (py - 300) ** 2 <= r ** 2
            hits += disc != hole
    return hits / SAMPLES ** 2


def png(size, colour, margin, opened=False):
    rows = b""
    for y in range(size):
        row = b"\x00"
        for x in range(size):
            row += bytes(colour) + bytes([round(255 * coverage(size, x, y, margin, opened))])
        rows += row
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xFFFFFFFF)
    header = struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", header) + chunk(b"IDAT", zlib.compress(rows, 9)) + chunk(b"IEND", b"")


OUT.mkdir(parents=True, exist_ok=True)
for name, colour in COLOURS.items():
    for size in (16, 32, 48, 128):
        # Chrome's own grid: a 128 icon's mark is 96 across.
        margin = 16 if size == 128 else max(1, round(size / 16))
        (OUT / f"{name}-{size}.png").write_bytes(png(size, colour, margin, opened=name == "off"))
print(sorted(p.name for p in OUT.iterdir()))
