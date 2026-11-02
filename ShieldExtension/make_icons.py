#!/usr/bin/env python3
"""Draws src/icons: roko's Eclipse (AppIcon.eclipse in Sources/Roko/AppIcon.swift),
bare, in the iPhone app's orange where Shield is on and in grey where it is off
or paused, at the sizes Chrome asks for. Plain Python, so it needs nothing."""

import struct
import zlib
from pathlib import Path

OUT = Path(__file__).resolve().parent / "src" / "icons"
COLOURS = {"on": (0xFF, 0x5B, 0x1F), "off": (0x8E, 0x8E, 0x8C)}
SAMPLES = 6


def coverage(size, x, y, margin):
    """How much of pixel (x, y) the mark covers: the disc less its hole, even-odd."""
    side = size - 2 * margin
    hits = 0
    for sy in range(SAMPLES):
        for sx in range(SAMPLES):
            px = (x + (sx + 0.5) / SAMPLES - margin) / side * 600
            py = (y + (sy + 0.5) / SAMPLES - margin) / side * 600
            disc = (px - 300) ** 2 + (py - 300) ** 2 <= 300 ** 2
            hole = (px - 394) ** 2 + (py - 300) ** 2 <= 150 ** 2
            hits += disc != hole
    return hits / SAMPLES ** 2


def png(size, colour, margin):
    rows = b""
    for y in range(size):
        row = b"\x00"
        for x in range(size):
            row += bytes(colour) + bytes([round(255 * coverage(size, x, y, margin))])
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
        (OUT / f"{name}-{size}.png").write_bytes(png(size, colour, margin))
print(sorted(p.name for p in OUT.iterdir()))
