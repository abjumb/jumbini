#!/usr/bin/env python3
"""Import Jumba's hand-made sprite export into the app's resources.

- Strips baked-in white backgrounds (edge flood fill — interior whites like the
  chest blaze and socks are protected by the dark outline).
- Flattens the export layout into Resources/jumba/<state>_<direction>.png.

Usage: python3 Tools/import_jumba.py /path/to/jumbini-poopchini
"""
import os
import struct
import sys
import zlib
from collections import deque

# ------------------------------------------------------------- PNG codec

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

def strip_background(w, h, rows, threshold=240):
    """Clear the near-white backdrop connected to the outside of the sprite.

    BFS from the borders through pixels that are transparent OR near-white,
    clearing only the near-white ones. Interior whites (eye glints) stay —
    they're enclosed by the dog's outline. The dog's own light fur is cream
    (< 225 per channel), well under the threshold.
    """
    def is_white(x, y):
        px = rows[y][x * 4:x * 4 + 4]
        return px[3] > 0 and px[0] >= threshold and px[1] >= threshold and px[2] >= threshold

    def is_outside(x, y):
        return rows[y][x * 4 + 3] == 0 or is_white(x, y)

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
    while queue:
        x, y = queue.popleft()
        if is_white(x, y):
            rows[y][x * 4 + 3] = 0
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and is_outside(nx, ny):
                seen[ny][nx] = True
                queue.append((nx, ny))

# ------------------------------------------------------------- import

DIRECTIONS = ["south", "south-east", "east", "north-east", "north", "north-west", "west", "south-west"]

# app state name -> export folder
STATES = {
    "idle": "Idle",
    "sit": "sitting_down",
    "sleep": "sleeping_curled_up",
    "run1": "sprinting_really_fas",
    "run2": "sprinting_really_fas_2",
}

# Later single-state exports dropped into the repo root, keyed the same way:
# app state name -> folder relative to the repo root.
EXTRA_STATES = {
    "sniff": "sniffing-state/sniffing_the_ground",
    "hunch": "hunched-over-state/hunched_over_defecat",
}


def import_rotations(src_folder, state, dst):
    for direction in DIRECTIONS:
        path = os.path.join(src_folder, "rotations", f"{direction}.png")
        w, h, rows = read_png(path)
        strip_background(w, h, rows)
        write_png(os.path.join(dst, f"{state}_{direction}.png"), w, h, rows)
    return len(DIRECTIONS)


def convert(src, dst):
    # The original Downloads export may be gone — Resources/jumba already holds
    # its imported output, so sources are re-imported only when present.
    count = 0
    if os.path.isdir(src):
        for state, folder in STATES.items():
            count += import_rotations(os.path.join(src, folder), state, dst)
        # Bark: 6 frames, east only (the app mirrors it for west-ish facings).
        for i in range(6):
            path = os.path.join(src, "sitting_down", "animations", "Bark", "east", f"frame_{i:03d}.png")
            w, h, rows = read_png(path)
            strip_background(w, h, rows)
            write_png(os.path.join(dst, f"bark_{i}.png"), w, h, rows)
            count += 1
    else:
        print(f"note: {src} missing, skipping base states (already imported)")
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    for state, folder in EXTRA_STATES.items():
        if os.path.isdir(os.path.join(root, folder)):
            count += import_rotations(os.path.join(root, folder), state, dst)
        else:
            print(f"note: {folder} missing, skipping")
    return count


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Downloads/jumbini-poopchini")
    here = os.path.dirname(os.path.abspath(__file__))
    dst = os.path.join(here, "..", "Sources", "Jumbini", "Resources", "jumba")
    count = convert(src, dst)
    print(f"imported {count} sprites -> {dst}")


if __name__ == "__main__":
    main()
