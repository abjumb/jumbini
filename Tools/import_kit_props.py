#!/usr/bin/env python3
"""Import Alex's hand-made prop/FX art into the app's resources.

`jumbini-kit/sprites/` is the durable source copy of the delivered art and is
never modified. This tool copies the files the app actually loads into
Sources/Jumbini/Resources/sprites/, exactly as delivered, with one exception:
a few frames came back from the drawing tool with the editor's transparency
checkerboard flattened into the image as opaque pixels. Those are listed in
STRIP_BACKDROP and get an edge flood-fill that clears the grey backdrop —
the same shape of cleanup import_jumba.py does for the dog's white backdrop.

Usage: python3 Tools/import_kit_props.py
"""
import os
import struct
import sys
import zlib
from collections import deque

# ------------------------------------------------------------- PNG codec
# Same 8-bit RGBA reader/writer as import_jumba.py — the kit is all colortype 6.


def read_png(path):
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
    assert w is not None and h is not None, f"{path}: missing IHDR"
    raw = zlib.decompress(idat)
    stride = w * 4
    rows, prev, p = [], bytearray(stride), 0
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
                line[i] = (line[i] + ((line[i - 4] if i >= 4 else 0) + prev[i]) // 2) & 255
        elif ft == 4:
            for i in range(stride):
                a = line[i - 4] if i >= 4 else 0
                b = prev[i]
                c = prev[i - 4] if i >= 4 else 0
                pp = a + b - c
                pa, pb, pc = abs(pp - a), abs(pp - b), abs(pp - c)
                line[i] = (line[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        rows.append(line)
        prev = line
    return w, h, rows


def write_png(path, w, h, rows):
    raw = b"".join(b"\x00" + bytes(r) for r in rows)
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(
            b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9))
            + chunk(b"IEND", b"")
        )

# ------------------------------------------------------------- cleanup


def strip_backdrop(w, h, rows, sat=16, value=110):
    """Clear the flat grey editor backdrop connected to the image border.

    BFS from the edges through pixels that are transparent OR "backdrop-ish"
    (near-greyscale AND dark), clearing the opaque ones. Coloured art (the
    rope's orange hemp) stops the fill, and anything enclosed by it survives.
    Deliberately opt-in per file: run against art with a legitimately dark
    silhouette (shadow_blob) it would eat the sprite.
    """
    def is_backdrop(x, y):
        r, g, b, a = rows[y][x * 4:x * 4 + 4]
        return a > 0 and max(r, g, b) - min(r, g, b) <= sat and max(r, g, b) <= value

    def is_outside(x, y):
        return rows[y][x * 4 + 3] == 0 or is_backdrop(x, y)

    seen = [[False] * w for _ in range(h)]
    queue = deque()
    for x in range(w):
        for y in (0, h - 1):
            if is_outside(x, y) and not seen[y][x]:
                queue.append((x, y)); seen[y][x] = True
    for y in range(h):
        for x in (0, w - 1):
            if is_outside(x, y) and not seen[y][x]:
                queue.append((x, y)); seen[y][x] = True
    cleared = 0
    while queue:
        x, y = queue.popleft()
        if is_backdrop(x, y):
            rows[y][x * 4 + 3] = 0
            cleared += 1
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and is_outside(nx, ny):
                seen[ny][nx] = True
                queue.append((nx, ny))
    return cleared

# ------------------------------------------------------------- import

# What the app loads. Kept as an explicit list rather than a glob so an
# unreviewed file appearing in the kit can't silently enter the bundle.
IMPORT = [
    # Deposits: three fresh variants, plus the dried-out one an old pile ages
    # into, plus the flies that find it.
    "deposit_1", "deposit_2", "deposit_3", "deposit_dry", "fly_0", "fly_1",
    # Frisbee: spin frames + the edge-on sprite for the carry.
    # frisbee_3 is NOT imported — it came back as a checkerboard dither smear
    # rather than a disc. Redraw it and add it back here (and bump the frame
    # count in PetScene.frisbeeSpinFrames).
    "frisbee_0", "frisbee_1", "frisbee_2", "frisbee_mouth",
    # Tug rope. The rope_taut_* set is NOT imported: rope_taut_mid is a
    # humanoid character sprite, rope_taut_left is a bar on a baked
    # checkerboard, rope_taut_right is a scatter of loose fibres. The
    # "rope strains under a hard pull" swap is waiting on redrawn art.
    "rope_left", "rope_mid", "rope_right",
    # Squeaky toy: rest pose + the squash cycle he shakes it through.
    "toy_chicken", "toy_squash_0", "toy_squash_1", "toy_squash_2",
    # Contact shadow under his feet on a window ledge / mid-fall.
    "shadow_blob",
    # FX.
    "bark_puff_0", "bark_puff_1", "bark_puff_2",
    "dust_0", "dust_1", "dust_2", "dust_3",
    "sparkle_0", "sparkle_1", "sparkle_2", "sparkle_3",
    "steam_0",
    "confetti_0", "confetti_1",
]

# Delivered but not imported, and why:
#   confetti_2   - a humanoid character sprite, not confetti
#   frisbee_3    - checkerboard dither smear
#   rope_taut_*  - see above
#   steam_1      - black box with the editor backdrop baked in
#   steam_2      - a purple/green blob, doesn't read as steam
#   rain_0..2,
#   puddle       - drawn for a weather feature that does not exist (Jumbini
#                  does no networking). Held in the kit until there's one.

# Files whose backdrop needs clearing (see strip_backdrop).
STRIP_BACKDROP = {"rope_mid"}

# The treat box, which replaces the peanut butter jar. It lives in its own kit
# folder and its frames are two-digit, so it's renamed on the way in to the
# `name_<n>` convention SpriteLibrary.propSequence reads. The kit's topdown/,
# opened/, crushed/ and candidates/ folders are design exploration and are
# deliberately not imported.
#   source (relative to jumbini-kit/treat-box) -> Resources/sprites name
TREAT_BOX = {"treat_box_base.png": "treat_box"}
TREAT_BOX.update({
    f"wobble/treat_box_wobble_{i:02d}.png": f"treat_box_wobble_{i}" for i in range(9)
})


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    kit = os.path.join(here, "..", "jumbini-kit")
    src = os.path.join(kit, "sprites")
    dst = os.path.join(here, "..", "Sources", "Jumbini", "Resources", "sprites")

    jobs = [(os.path.join(src, n + ".png"), n) for n in IMPORT]
    jobs += [(os.path.join(kit, "treat-box", rel), name) for rel, name in TREAT_BOX.items()]

    missing = [path for path, _ in jobs if not os.path.exists(path)]
    if missing:
        print(f"error: missing sources: {', '.join(missing)}")
        return 1
    for path, name in jobs:
        w, h, rows = read_png(path)
        if name in STRIP_BACKDROP:
            cleared = strip_backdrop(w, h, rows)
            print(f"  {name}: cleared {cleared} backdrop pixels")
        write_png(os.path.join(dst, name + ".png"), w, h, rows)
    print(f"imported {len(jobs)} props -> {dst}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
