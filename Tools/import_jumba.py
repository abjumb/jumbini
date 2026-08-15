#!/usr/bin/env python3
"""Import Jumba's hand-made sprite export into the app's resources.

- Strips baked-in white backgrounds (edge flood fill — interior whites like the
  chest blaze and socks are protected by the dark outline), but ONLY when a
  file actually has one. Most of the jumbini-kit art already ships with a
  transparent backdrop; running the fill over those would nibble legitimate
  white pixels (teeth, socks, eye glints) that touch the sprite's edge.
- Flattens the export layout into Resources/jumba/<state>_<direction>.png.

Every source is optional: the importer is re-runnable and silently skips any
folder that isn't in the tree, so an old export going missing can never break
the art that's already committed.

Usage: python3 Tools/import_jumba.py [/path/to/jumbini-poopchini]
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
    found = []
    while queue:
        x, y = queue.popleft()
        if is_white(x, y):
            found.append((x, y))
        for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
            nx, ny = x + dx, y + dy
            if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] and is_outside(nx, ny):
                seen[ny][nx] = True
                queue.append((nx, ny))
    for x, y in found:
        rows[y][x * 4 + 3] = 0
    return len(found)


# A backdrop covers most of the canvas. Anything smaller that the flood fill
# reaches is part of the dog — a white sock, tooth or eye glint that happens to
# sit against the transparent edge — and must be left alone. Measured on
# jumbini-kit: the one backdropped state clears 58-67% of its pixels, every
# already-transparent state clears at most 1%.
BACKDROP_MIN_FRACTION = 0.10


def strip_background_if_backdrop(w, h, rows, threshold=240):
    """Strip the backdrop only if there is one. Returns True if it stripped."""
    probe = [bytearray(r) for r in rows]
    if strip_background(w, h, probe, threshold) < BACKDROP_MIN_FRACTION * w * h:
        return False
    for i, row in enumerate(probe):
        rows[i] = row
    return True

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

# ---------------------------------------------------------------- jumbini-kit
# The full hand-made character kit, committed at jumbini-kit/dog-states. Same
# <state>/rotations/<direction>.png layout as the older exports, 44 states in
# two coat families. This is the authoritative source; the maps above only
# still exist so the pre-kit exports keep importing if someone has them.
KIT_ROOT = "jumbini-kit/dog-states"

# app sprite name -> kit folder. Names on the left are the ones SpriteLoader
# already looks up, so importing a row here is all it takes to light a state up.
#
# idle/sit come from the *_2 folders on purpose: `Idle` and `sitting_down` are
# the pre-fix exports (tan eyes, and `Idle` is the only file in the whole kit
# that still carries a baked white backdrop), while `Idle_2`/`sitting_down_2`
# are the same poses with the corrected white eye glints that every other kit
# state has. Taking the v1s would leave his eyes changing colour every time he
# barked. `sprinting_really_fas`/`_2`, by contrast, are two genuine run frames.
KIT_STATES = {
    "idle": "Idle_2",
    "sit": "sitting_down_2",
    "sleep": "sleeping_curled_up",
    "run1": "sprinting_really_fas",
    "run2": "sprinting_really_fas_2",
    "sniff": "sniffing_the_ground",
    "hunch": "hunched_over_defecat",
    "bark": "barking",
    "stalk": "stalk",
    "pounce": "pounce",
    "paw": "paw",
    "highfive": "highfive",
    "playdead": "playdead",
    "fall": "fall",
    "land": "land",
    "peek": "peek",
    "brace": "brace",
    "alert": "alert",
    "whine": "whine",
    "pin": "pin",
    "growl": "growling_very_angril",
}

# The alternate coat, imported under a `shaggy_` prefix so SpriteLoader can
# resolve `shaggy_<state>_<direction>` and fall back to classic per animation.
# Shaggy has no second sprint frame and no `Very_Shaggy` counterpart for the
# other poses; SpriteLoader covers the gaps.
KIT_SHAGGY_STATES = {
    "shaggy_idle": "Shaggy",
    "shaggy_sit": "Shaggy_sitting",
    "shaggy_sleep": "Shaggy_sleeping",
    "shaggy_run1": "Shaggy_sprinting",
    "shaggy_sniff": "Shaggy_sniffing",
    "shaggy_hunch": "Shaggy_hunched",
    "shaggy_bark": "Shaggy_barking",
    "shaggy_stalk": "Shaggy_stalk",
    "shaggy_pounce": "Shaggy_pounce",
    "shaggy_paw": "Shaggy_paw",
    "shaggy_highfive": "Shaggy_highfive",
    "shaggy_playdead": "Shaggy_playdead",
    "shaggy_fall": "Shaggy_fall",
    "shaggy_land": "Shaggy_land",
    "shaggy_peek": "Shaggy_peek",
    "shaggy_brace": "Shaggy_brace",
    "shaggy_alert": "Shaggy_alert",
    "shaggy_whine": "Shaggy_whine",
    "shaggy_pin": "Shaggy_pin",
    "shaggy_growl": "Shaggy_growling",
}


def import_rotations(src_folder, state, dst):
    for direction in DIRECTIONS:
        path = os.path.join(src_folder, "rotations", f"{direction}.png")
        w, h, rows = read_png(path)
        strip_background_if_backdrop(w, h, rows)
        write_png(os.path.join(dst, f"{state}_{direction}.png"), w, h, rows)
    return len(DIRECTIONS)


def import_states(root, states, dst):
    """Import a folder->state map, skipping sources that aren't there."""
    count = 0
    for state, folder in states.items():
        src = os.path.join(root, folder)
        if os.path.isdir(os.path.join(src, "rotations")):
            count += import_rotations(src, state, dst)
        else:
            print(f"note: {folder} missing, skipping")
    return count


def convert(src, dst):
    # The original Downloads export may be gone — Resources/jumba already holds
    # its imported output, so sources are re-imported only when present.
    count = 0
    if os.path.isdir(src):
        count += import_states(src, STATES, dst)
        # Bark: 6 frames, east only. Superseded by the kit's 8-rotation
        # `barking` state, but kept as SpriteLoader's mirrored fallback.
        for i in range(6):
            path = os.path.join(src, "sitting_down", "animations", "Bark", "east", f"frame_{i:03d}.png")
            w, h, rows = read_png(path)
            strip_background_if_backdrop(w, h, rows)
            write_png(os.path.join(dst, f"bark_{i}.png"), w, h, rows)
            count += 1
    else:
        print(f"note: {src} missing, skipping base states (already imported)")
    root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    count += import_states(root, EXTRA_STATES, dst)
    kit = os.path.join(root, KIT_ROOT)
    if os.path.isdir(kit):
        count += import_states(kit, KIT_STATES, dst)
        count += import_states(kit, KIT_SHAGGY_STATES, dst)
    else:
        print(f"note: {KIT_ROOT} missing, skipping the character kit")
    return count


def main():
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.expanduser("~/Downloads/jumbini-poopchini")
    here = os.path.dirname(os.path.abspath(__file__))
    dst = os.path.join(here, "..", "Sources", "Jumbini", "Resources", "jumba")
    count = convert(src, dst)
    print(f"imported {count} sprites -> {dst}")


if __name__ == "__main__":
    main()
