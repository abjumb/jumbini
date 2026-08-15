#!/usr/bin/env python3
"""Import the wardrobe and UI art from jumbini-kit into the app's resources.

Two categories, both flattened into Resources/sprites (the one resource
directory Package.swift already ships):

- `jumbini-kit/wardrobe/<item>_<dir>.png` -> `wardrobe_<item>_<dir>.png`
  7 items x 4 front directions (s / se / e / ne). There is deliberately no
  west-side art: the app mirrors the east-side files the same way it mirrors
  the east-only bark frames.
- `jumbini-kit/ui/*.png` -> copied verbatim (emote bubble, 8 icons, trick
  badge, caption plate, paw watermark).

One asset is repaired on the way in. `shades_s` arrived with grey keying
speckle sprayed across the whole canvas (~140 lonely pixels over the frame,
the same class of defect the kit README flags for `bandana_e`): the
sunglasses are in there, buried in static. `despeckle()` erodes the mask
twice, keeps the largest surviving blob, and re-dilates it inside the
original ink, which recovers the glasses and drops the noise. Every other
file is copied byte-for-byte. The originals stay in jumbini-kit/, so
regenerated art can simply be re-imported.

Usage: python3 Tools/import_kit_art.py
"""
import os
import struct
import sys
import zlib
from collections import deque

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KIT = os.path.join(ROOT, "jumbini-kit")
DEST = os.path.join(ROOT, "Sources", "Jumbini", "Resources", "sprites")

WARDROBE_ITEMS = ["party", "tophat", "cowboy", "beanie", "bandana", "shades", "raincoat"]
WARDROBE_DIRECTIONS = ["s", "se", "e", "ne"]
# Files that need the keying speckle scrubbed off before they are usable.
# Empty: shades_s arrived speckled in the first kit and was scrubbed here.
# Alex redrew it clean, so despeckling it now would only risk eating art.
DESPECKLE: set[str] = set()

# ------------------------------------------------------------- PNG codec


def read_png(path):
    """Decode an 8-bit RGBA PNG into (width, height, bytearray of RGBA)."""
    with open(path, "rb") as f:
        data = f.read()
    pos, w, h, idat = 8, None, None, b""
    while pos < len(data):
        ln = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + ln]
        if tag == b"IHDR":
            w, h, bd, ct = struct.unpack(">IIBB", chunk[:10])
            assert (bd, ct) == (8, 6), f"{path}: expected 8-bit RGBA, got depth={bd} type={ct}"
        elif tag == b"IDAT":
            idat += chunk
        pos += 12 + ln
    raw = zlib.decompress(idat)
    stride = w * 4
    out, prev, p = bytearray(), bytearray(stride), 0
    for _ in range(h):
        ft = raw[p]; p += 1
        line = bytearray(raw[p:p + stride]); p += stride
        if ft == 1:
            for i in range(4, stride):
                line[i] = (line[i] + line[i - 4]) & 255
        elif ft == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 255
        elif ft == 3:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 255
        elif ft == 4:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                b, c = prev[i], (prev[i - 4] if i >= 4 else 0)
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 255
        elif ft != 0:
            raise ValueError(f"{path}: unknown filter {ft}")
        out += line
        prev = line
    return w, h, out


def write_png(path, w, h, px):
    raw = bytearray()
    for y in range(h):
        raw.append(0)  # filter: none
        raw += px[y * w * 4:(y + 1) * w * 4]

    def chunk(tag, payload):
        return (struct.pack(">I", len(payload)) + tag + payload
                + struct.pack(">I", zlib.crc32(tag + payload) & 0xFFFFFFFF))

    body = (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
            + chunk(b"IEND", b""))
    with open(path, "wb") as f:
        f.write(body)


# ------------------------------------------------------------- repair


def despeckle(w, h, px):
    """Scrub keying noise: erode twice, keep the biggest blob, re-dilate."""
    ink = [[px[(y * w + x) * 4 + 3] >= 128 for x in range(w)] for y in range(h)]

    def neighbours(mask, y, x):
        return sum(mask[y + dy][x + dx]
                   for dy in (-1, 0, 1) for dx in (-1, 0, 1)
                   if (dy or dx) and 0 <= y + dy < h and 0 <= x + dx < w)

    eroded = [[ink[y][x] and neighbours(ink, y, x) >= 6 for x in range(w)] for y in range(h)]
    eroded = [[eroded[y][x] and neighbours(eroded, y, x) >= 4 for x in range(w)] for y in range(h)]

    seen = [[False] * w for _ in range(h)]
    best = []
    for y in range(h):
        for x in range(w):
            if not eroded[y][x] or seen[y][x]:
                continue
            queue, blob = deque([(y, x)]), []
            seen[y][x] = True
            while queue:
                cy, cx = queue.popleft()
                blob.append((cy, cx))
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        ny, nx = cy + dy, cx + dx
                        if (0 <= ny < h and 0 <= nx < w
                                and eroded[ny][nx] and not seen[ny][nx]):
                            seen[ny][nx] = True
                            queue.append((ny, nx))
            if len(blob) > len(best):
                best = blob

    core = [[False] * w for _ in range(h)]
    for y, x in best:
        core[y][x] = True
    keep = [[ink[y][x] and (core[y][x] or neighbours(core, y, x) >= 3) for x in range(w)]
            for y in range(h)]

    out = bytearray(px)
    dropped = 0
    for y in range(h):
        for x in range(w):
            if ink[y][x] and not keep[y][x]:
                out[(y * w + x) * 4:(y * w + x) * 4 + 4] = b"\x00\x00\x00\x00"
                dropped += 1
    return out, dropped


# ------------------------------------------------------------- import


def copy(src, dst, repair=False):
    if repair:
        w, h, px = read_png(src)
        px, dropped = despeckle(w, h, px)
        write_png(dst, w, h, px)
        print(f"  {os.path.basename(dst)} (despeckled, {dropped}px dropped)")
        return
    with open(src, "rb") as f:
        data = f.read()
    with open(dst, "wb") as f:
        f.write(data)
    print(f"  {os.path.basename(dst)}")


def main():
    if not os.path.isdir(KIT):
        sys.exit(f"no kit at {KIT}")
    os.makedirs(DEST, exist_ok=True)

    print("wardrobe:")
    for item in WARDROBE_ITEMS:
        for direction in WARDROBE_DIRECTIONS:
            name = f"{item}_{direction}"
            src = os.path.join(KIT, "wardrobe", f"{name}.png")
            if not os.path.exists(src):
                sys.exit(f"missing {src}")
            copy(src, os.path.join(DEST, f"wardrobe_{name}.png"), repair=name in DESPECKLE)

    print("ui:")
    for name in sorted(os.listdir(os.path.join(KIT, "ui"))):
        if name.endswith(".png"):
            copy(os.path.join(KIT, "ui", name), os.path.join(DEST, name))


if __name__ == "__main__":
    main()
