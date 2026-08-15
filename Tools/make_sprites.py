#!/usr/bin/env python3
"""Generate Jumbini's pixel-art sprite sheets (pure stdlib, no deps).

The dog (from the reference photo): tri-color cocker-spaniel type — black wavy
coat, long floppy feathered ears, copper eyebrow dots + muzzle, white chest bib
and front paws, pink tongue out.

Outputs one horizontal-strip PNG per animation into Sources/Jumbini/Resources/sprites/
plus an upscaled contact sheet for visual review.
"""
import os
import struct
import sys
import zlib

# ---------------------------------------------------------------- palette

PAL = {
    "O": (14, 14, 18, 255),      # outline / nose / mouth
    "K": (38, 36, 44, 255),      # coat base (near-black)
    "k": (66, 62, 78, 255),      # coat highlight (wavy fur, ears)
    "D": (24, 23, 30, 255),      # coat shadow / far limbs
    "T": (166, 106, 44, 255),    # copper points
    "t": (205, 145, 80, 255),    # light copper
    "W": (242, 237, 226, 255),   # white bib / paws
    "w": (214, 205, 186, 255),   # cream shadow
    "P": (232, 138, 154, 255),   # tongue
    "p": (198, 100, 120, 255),   # tongue shadow
    "G": (186, 214, 66, 255),    # tennis ball
    "g": (140, 168, 40, 255),    # ball shadow
    "V": (250, 250, 245, 255),   # eye glint / ball seam
    "R": (240, 96, 120, 255),    # heart
    "r": (196, 60, 88, 255),     # heart shadow
    "B": (107, 150, 216, 255),   # bed plush blue
    "b": (70, 105, 170, 255),    # bed shadow blue
    "F": (168, 200, 240, 255),   # bed fuzz / inner cushion
    "J": (208, 222, 232, 150),   # jar glass
    "j": (150, 170, 185, 220),   # jar glass edge
    "U": (178, 170, 158, 255),   # rabbit toy plush fur (warm grey-tan)
    "u": (132, 124, 114, 255),   # rabbit toy fur shadow / floppy ear
    "M": (110, 74, 42, 255),     # deposit brown
    "m": (74, 48, 27, 255),      # deposit shadow
    "Y": (247, 205, 70, 255),    # party-hat yellow
    ".": (0, 0, 0, 0),           # transparent
}

LIGHTS = set("WwtTPpVUMmYR")  # colors that get a dark rim where they meet transparency


class Grid:
    def __init__(self, w=32, h=32):
        self.w, self.h = w, h
        self.g = [["." for _ in range(w)] for _ in range(h)]

    def px(self, x, y, c):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.g[y][x] = c

    def rect(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            for x in range(x0, x1 + 1):
                self.px(x, y, c)

    def ellipse(self, cx, cy, rx, ry, c):
        for y in range(int(cy - ry), int(cy + ry) + 1):
            for x in range(int(cx - rx), int(cx + rx) + 1):
                if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0:
                    self.px(x, y, c)

    def hflip(self):
        out = Grid(self.w, self.h)
        for y in range(self.h):
            for x in range(self.w):
                out.g[y][self.w - 1 - x] = self.g[y][x]
        return out

    def rim(self):
        """Give light colors a dark edge against transparency so white paws
        still read on a white desktop."""
        edges = []
        for y in range(self.h):
            for x in range(self.w):
                c = self.g[y][x]
                if c in LIGHTS:
                    for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        nx, ny = x + dx, y + dy
                        if not (0 <= nx < self.w and 0 <= ny < self.h) or self.g[ny][nx] == ".":
                            edges.append((x, y))
                            break
        for x, y in edges:
            self.g[y][x] = "O"


# ---------------------------------------------------------------- dog parts
# All poses face RIGHT; the app flips horizontally for the other direction.

def leg(g, x, top, foot, far=False, paw="W", patch=None):
    """3px-wide leg column. `far` legs are darker and 1px shorter."""
    body_c = "D" if far else "K"
    paw_c = "w" if far else paw
    bottom = foot - (1 if far else 0)
    g.rect(x, top, x + 2, bottom, body_c)
    if patch and not far:
        g.rect(x, patch[0], x + 2, patch[1], "t")
    g.rect(x, bottom - 1, x + 2, bottom, paw_c)


def tail(g, x, y, wag=0):
    g.ellipse(x, y + wag, 2.2, 2.2, "K")
    g.px(x - 1, y + wag - 1, "k")
    g.px(x + 1, y + wag - 2, "k")


def fur_skirt(g, x0, x1, y):
    """Wavy fur hanging under the body."""
    for x in range(x0, x1 + 1):
        if x % 3 != 0:
            g.px(x, y, "K")
        if x % 4 == 1:
            g.px(x, y + 1, "K")


def head(g, cx, cy, r=6.2, ear_dy=0, tongue=True, eye="open", muzzle_len=4):
    """Head circle + muzzle + long floppy ear + copper brow + eye."""
    g.ellipse(cx, cy, r, r - 0.4, "K")
    # top-of-head fur highlights
    g.px(cx - 2, cy - int(r) + 1, "k")
    g.px(cx + 1, cy - int(r), "k")
    # muzzle block in front
    mx0 = cx + 3
    g.rect(mx0, cy - 1, mx0 + muzzle_len, cy + 3, "T")
    g.rect(mx0, cy - 1, mx0 + muzzle_len - 1, cy, "t")
    # nose + mouth
    g.rect(mx0 + muzzle_len - 1, cy - 2, mx0 + muzzle_len, cy - 1, "O")
    g.rect(mx0 + 1, cy + 2, mx0 + muzzle_len - 1, cy + 2, "O")
    if tongue:
        g.rect(mx0 + 1, cy + 3, mx0 + 2, cy + 5, "P")
        g.px(mx0 + 2, cy + 5, "p")
    # eye + copper eyebrow (signature markings)
    if eye == "open":
        g.px(cx + 1, cy - 2, "V")
    else:
        g.px(cx, cy - 2, "t")
        g.px(cx + 1, cy - 2, "t")
    g.rect(cx - 1, cy - 5, cx, cy - 4, "T")
    # long floppy feathered ear, hanging over the back of the head
    ex = cx - int(r) + 1
    ear_top = cy - int(r) + 2 + ear_dy
    g.rect(ex, ear_top, ex + 3, ear_top + 9, "k")
    g.rect(ex, ear_top, ex, ear_top + 9, "K")          # back edge
    for i, x in enumerate(range(ex, ex + 4)):          # feathered tip
        g.px(x, ear_top + 10 + (i % 2), "k")
    g.px(ex + 1, ear_top + 4, "D")
    g.px(ex + 2, ear_top + 7, "D")


# ---------------------------------------------------------------- poses

def standing(leg_phase=0, body_dy=0, ear_dy=0, wag=0, tongue=True,
             carrying=False, running=False):
    """Stand/walk/run frame. leg_phase: 0..3 gait cycle (0 = neutral)."""
    g = Grid()
    base = [0, 2, 0, -2][leg_phase]
    off = base if running else base // 2 if base >= 0 else -((-base) // 2)
    lift = 1 if leg_phase in (1, 3) else 0
    tail(g, 4, 14 + body_dy, wag)
    # far legs move opposite the near legs
    leg(g, 6 - off, 23 + body_dy, 29 - lift, far=True)
    leg(g, 18 - off, 23 + body_dy, 29 - lift, far=True)
    g.ellipse(14, 19 + body_dy, 9.4, 6.0, "K")
    for x, y in ((8, 14), (12, 13), (17, 14), (10, 16), (15, 15)):
        g.px(x, y + body_dy, "k")                       # wavy coat
    fur_skirt(g, 7, 21, 25 + body_dy)
    leg(g, 8 + off, 24 + body_dy, 30 - lift, patch=(26 + body_dy, 27 + body_dy))
    leg(g, 20 + off, 24 + body_dy, 30 - lift)
    g.rect(21, 15 + body_dy, 24, 20 + body_dy, "W")     # chest bib
    g.rect(21, 20 + body_dy, 24, 20 + body_dy, "w")
    head(g, 24, 10 + body_dy, ear_dy=ear_dy, tongue=tongue)
    if carrying:
        ball_at(g, 28, 15 + body_dy)
    g.rim()
    return g


def sitting(f=0):
    g = Grid()
    tail(g, 4, 23, wag=f)
    g.ellipse(12, 24, 7.2, 6.0, "K")                    # haunch
    g.px(8, 19, "k"); g.px(13, 18, "k"); g.px(6, 22, "k")
    fur_skirt(g, 6, 17, 29)
    g.ellipse(20, 17, 5.2, 7.0, "K")                    # upright torso
    leg(g, 17, 22, 29, far=True)
    leg(g, 20, 22, 30)
    g.rect(19, 14, 23, 21, "W")                         # bib
    g.rect(19, 21, 23, 21, "w")
    head(g, 23, 8, ear_dy=f, tongue=True)
    g.rim()
    return g


def lying(f=0, asleep=False):
    g = Grid(48, 32)
    dy = f if asleep else 0                             # breathing
    tail(g, 5, 21, wag=0)
    g.ellipse(18, 24 - dy, 14.0, 5.2, "K")              # low body
    for x, y in ((10, 20), (16, 19), (24, 20), (7, 22)):
        g.px(x, y - dy, "k")
    fur_skirt(g, 6, 30, 29)
    g.ellipse(30, 22, 7.0, 6.0, "K")                    # shoulders
    # forelegs stretched forward on the ground
    g.rect(30, 26, 42, 29, "K")
    g.rect(38, 26, 43, 29, "W")
    g.rect(38, 29, 43, 29, "w")
    if asleep:
        head(g, 36, 19 + f, ear_dy=1, tongue=False, eye="closed")
    else:
        g.rect(28, 18, 33, 24, "W")                     # bib
        head(g, 36, 12, ear_dy=f, tongue=(f == 0))
    g.rim()
    return g


def front_view():
    g = Grid()
    g.ellipse(16, 22, 7.0, 7.0, "K")                    # body
    leg(g, 11, 24, 30)
    leg(g, 18, 24, 30)
    g.rect(13, 17, 18, 23, "W")                         # bib
    g.rect(13, 23, 18, 23, "w")
    g.ellipse(16, 10, 7.0, 6.6, "K")                    # head
    g.px(13, 4, "k"); g.px(18, 4, "k")
    for ex in (6, 22):                                  # both ears hang
        g.rect(ex, 7, ex + 3, 17, "k")
        g.rect(ex if ex == 6 else ex + 3, 7, ex if ex == 6 else ex + 3, 17, "K")
        g.px(ex + 1, 18, "k"); g.px(ex + 2, 19, "k")
    g.rect(12, 6, 13, 7, "T"); g.rect(18, 6, 19, 7, "T")  # brows
    g.px(13, 9, "V"); g.px(19, 9, "V")                  # eyes
    g.rect(13, 11, 18, 15, "T")                         # muzzle
    g.rect(13, 11, 18, 12, "t")
    g.rect(15, 11, 16, 12, "O")                         # nose
    g.rect(14, 14, 17, 14, "O")                         # mouth
    g.rect(15, 15, 16, 17, "P")
    g.px(16, 17, "p")
    g.rim()
    return g


def back_view():
    g = Grid()
    g.ellipse(16, 21, 7.2, 7.6, "K")                    # body from behind
    g.px(12, 15, "k"); g.px(19, 14, "k"); g.px(15, 17, "k")
    leg(g, 11, 26, 30, paw="K")
    leg(g, 18, 26, 30, paw="K")
    g.ellipse(16, 9, 6.6, 6.2, "K")                     # back of head
    g.px(13, 4, "k"); g.px(18, 5, "k")
    for ex in (7, 21):
        g.rect(ex, 6, ex + 3, 15, "D")
        g.px(ex + 1, 16, "D")
    g.rect(15, 25, 17, 29, "k")                         # tail fluff
    g.rim()
    return g


def dangling(f=0):
    """Held by the scruff: legs hanging, slightly concerned, no tongue."""
    g = Grid()
    sway = 1 if f else 0
    tail(g, 10, 16, wag=0)
    leg(g, 13 + sway, 23, 30, far=True)
    leg(g, 19 - sway, 23, 31, far=True)
    g.ellipse(18, 18, 6.4, 7.0, "K")                    # hanging body
    g.px(14, 13, "k"); g.px(20, 12, "k")
    leg(g, 14 + sway, 24, 31)
    leg(g, 20 - sway, 24, 31)
    g.rect(19, 12, 22, 18, "W")                         # bib
    head(g, 23, 7, ear_dy=-1 + f, tongue=False)
    g.rim()
    return g


# ---------------------------------------------------------------- props

def ball_at(g, cx, cy):
    g.ellipse(cx, cy, 3.2, 3.2, "G")
    g.px(cx - 1, cy + 2, "g"); g.px(cx - 2, cy + 1, "g")
    g.px(cx, cy - 2, "V"); g.px(cx + 1, cy - 1, "V"); g.px(cx + 2, cy, "V")
    g.px(cx - 1, cy - 2, "V")


SEAMS = [  # seam pixel positions per rotation frame (8x8 ball)
    [(3, 1), (4, 1), (5, 2), (6, 3)],
    [(6, 3), (6, 4), (5, 5), (4, 6)],
    [(4, 6), (3, 6), (2, 5), (1, 4)],
    [(1, 4), (1, 3), (2, 2), (3, 1)],
]


def ball_frame(rot):
    g = Grid(8, 8)
    g.ellipse(4, 4, 3.2, 3.2, "G")
    g.px(3, 6, "g"); g.px(2, 5, "g"); g.px(5, 6, "g")
    for x, y in SEAMS[rot]:
        g.px(x, y, "V")
    return g


def bed_frame():
    """Blue fuzzy dog bed: plush oval rim, lighter cushion inside, tufty edge."""
    import math
    g = Grid(52, 32)
    g.ellipse(26, 17, 24.5, 12.5, "B")                  # plush rim
    g.ellipse(26, 15, 19.0, 8.5, "b")                   # inner wall shadow
    g.ellipse(26, 16, 17.5, 7.5, "F")                   # cushion
    for i in range(40):                                 # fuzzy tufts around the rim
        a = i * math.tau / 40
        x = int(round(26 + 25.5 * math.cos(a)))
        y = int(round(17 + 13.5 * math.sin(a)))
        g.px(x, y, "F" if i % 2 == 0 else "B")
    for x, y in ((14, 27), (22, 29), (31, 29), (39, 27), (10, 24), (43, 24)):
        g.px(x, y, "b")                                 # front lip shading
    for x, y in ((20, 14), (28, 13), (34, 15), (24, 17), (31, 18)):
        g.px(x, y, "W")                                 # cushion sheen
    g.rim()
    return g


def jar_frame():
    """Glass treat jar with a copper lid and a white 'PB' label."""
    g = Grid(22, 26)
    g.rect(3, 5, 18, 24, "J")                           # glass body
    for y in range(5, 25):                              # glass edges
        g.px(3, y, "j"); g.px(18, y, "j")
    g.rect(4, 24, 17, 24, "j")
    g.rect(4, 5, 17, 5, "j")
    for x, y in ((6, 8), (10, 7), (14, 8), (8, 9), (12, 9)):
        g.px(x, y, "T")                                 # treats visible inside
    g.rect(4, 0, 17, 3, "T")                            # lid
    g.rect(4, 0, 17, 0, "t")
    g.rect(5, 11, 16, 19, "W")                          # label
    P = ["XX.", "X.X", "XX.", "X..", "X.."]
    B = ["XX.", "X.X", "XX.", "X.X", "XX."]
    for glyph, gx in ((P, 7), (B, 12)):
        for row, line in enumerate(glyph):
            for col, ch in enumerate(line):
                if ch == "X":
                    g.px(gx + col, 13 + row, "O")
    g.rim()
    return g


def treat_frame():
    """A little peanut-butter bone."""
    g = Grid(12, 8)
    g.rect(3, 3, 8, 4, "T")                             # shaft
    for cx, cy in ((2, 2), (2, 5), (9, 2), (9, 5)):     # knobs
        g.ellipse(cx, cy, 1.4, 1.4, "T")
    g.px(2, 1, "t"); g.px(9, 1, "t"); g.px(4, 3, "t"); g.px(6, 3, "t")
    g.rim()
    return g


def rabbit_frame():
    """Plush stuffed rabbit (the zoomies prize): grey-tan fur body lying
    flat, one long floppy ear trailing back, stubby round tail, bead eye,
    lighter belly patch. A toy, so it stays limp and simple."""
    g = Grid(16, 12)
    g.ellipse(6, 8, 5.6, 2.9, "U")                      # plush body lying flat
    g.rect(4, 8, 8, 9, "w")                             # lighter belly patch
    g.px(5, 7, "u"); g.px(4, 7, "u")                    # tucked-haunch stitch
    g.px(9, 9, "u"); g.px(10, 8, "u")                   # under-body shading
    g.ellipse(1.5, 8, 1.9, 1.9, "W")                    # stubby round tail
    g.ellipse(11.5, 5, 3.2, 3.0, "U")                   # round head
    g.rect(10, 1, 12, 1, "u")                           # ear root on the crown
    g.rect(6, 2, 12, 2, "u")                            # ear folded over the crown
    g.rect(4, 3, 9, 3, "u")                             # flap trailing down-back
    g.rect(3, 4, 6, 4, "u")
    g.rect(3, 5, 4, 5, "u")                             # tip resting on the rump
    g.px(12, 5, "O")                                    # tiny dark bead eye
    g.px(13, 6, "u")                                    # mouth stitch
    g.rim()
    g.px(14, 5, "p")                                    # stitched pink nose
    return g


def deposit_frame(variant=0):
    """He is a machine: treats in, piles out. A small brown coil with a
    glossy highlight — placeholder until the roadmap's hand-made pile art
    (deposit_1..3) lands. Two variants shipped as a 2-frame strip."""
    g = Grid(12, 10)
    if variant == 0:
        g.ellipse(5.5, 7.4, 4.9, 2.1, "M")              # base mound
        g.ellipse(5.5, 5.2, 3.5, 1.8, "M")              # middle tier
        g.ellipse(5.5, 3.2, 2.2, 1.4, "M")              # top tier
        g.px(6, 1, "M"); g.px(7, 1, "M")                # tip curls right
        g.px(4, 4, "m"); g.px(7, 4, "m")                # tier creases
        g.px(2, 6, "m"); g.px(9, 6, "m")
        g.rect(3, 9, 8, 9, "m")                         # ground contact
        g.px(5, 2, "t"); g.px(4, 3, "t")                # glossy highlight
        g.px(3, 5, "t"); g.px(2, 7, "t")
    else:
        g.ellipse(5.5, 7.6, 5.2, 2.0, "M")              # squat wide base
        g.ellipse(5.5, 5.4, 3.2, 1.7, "M")              # single top coil
        g.px(4, 3, "M"); g.px(3, 3, "M")                # tip flops left
        g.px(3, 6, "m"); g.px(8, 6, "m")                # crease
        g.rect(3, 9, 8, 9, "m")
        g.px(4, 4, "t"); g.px(6, 4, "t"); g.px(2, 7, "t")
    g.rim()
    return g


def heart_frame():
    g = Grid(8, 8)
    for x, y in ((1, 1), (2, 1), (5, 1), (6, 1)):
        g.px(x, y, "R")
    g.rect(0, 2, 7, 3, "R")
    g.rect(1, 4, 6, 4, "R")
    g.rect(2, 5, 5, 5, "R")
    g.rect(3, 6, 4, 6, "R")
    for x, y in ((1, 3), (2, 4), (3, 5), (4, 6)):
        g.px(x, y, "r")
    g.px(2, 2, "V")
    return g


# ---------------------------------------------------------------- wardrobe
# Placeholder accessories (single frame each). Drawn front-facing and roughly
# symmetric; the app owns ALL positioning (anchor code in PetScene/Dog), so
# nothing here bakes in an offset — real 48x48 art can swap in later.

def partyhat_frame():
    """Striped birthday cone with a pompom on top."""
    g = Grid(12, 16)
    for y in range(4, 16):                              # cone widens downward
        hw = 0.6 + (y - 4) * 0.38
        for x in range(int(round(5.5 - hw)), int(round(5.5 + hw)) + 1):
            g.px(x, y, "Y" if ((x + y) // 3) % 2 == 0 else "R")
    g.ellipse(5.5, 2, 1.8, 1.8, "V")                    # pompom
    g.rim()
    return g


def tophat_frame():
    """Black silk top hat with a red ribbon band."""
    g = Grid(14, 14)
    g.rect(3, 0, 10, 10, "K")                           # crown
    g.rect(3, 0, 10, 0, "k")                            # silk sheen on top
    g.rect(9, 1, 9, 7, "k")                             # side sheen
    g.rect(3, 8, 10, 10, "R")                           # ribbon band
    g.px(3, 9, "r"); g.px(10, 9, "r")
    g.rect(1, 11, 12, 12, "K")                          # brim
    g.px(0, 11, "k"); g.px(13, 11, "k")                 # upturned brim tips
    g.rect(2, 12, 11, 12, "D")                          # brim underside
    g.rim()
    return g


def cowboyhat_frame():
    """Tan felt hat: dented crown, wide brim curled up at the edges."""
    g = Grid(18, 10)
    g.rect(6, 1, 11, 5, "T")                            # crown
    g.px(7, 0, "T"); g.px(10, 0, "T")                   # dented top
    g.rect(7, 1, 8, 3, "t")                             # felt highlight
    g.rect(6, 6, 11, 6, "O")                            # hat band
    g.rect(1, 7, 16, 8, "T")                            # wide brim
    g.px(0, 6, "T"); g.px(17, 6, "T")                   # curled-up edges
    g.px(0, 7, "T"); g.px(17, 7, "T")
    g.rect(2, 7, 6, 7, "t")                             # brim sheen
    g.rim()
    return g


def bandana_frame():
    """Red neck kerchief: rolled band up top, polka-dot triangle hanging below."""
    g = Grid(16, 10)
    g.rect(1, 0, 14, 1, "R")                            # rolled band
    g.px(0, 1, "R"); g.px(15, 1, "R")                   # band wrapping back
    for y in range(2, 9):                               # hanging triangle
        g.rect(y - 1, y, 15 - (y - 1), y, "R")
    g.px(7, 9, "R"); g.px(8, 9, "R")                    # tip
    for x, y in ((12, 3), (11, 4), (10, 5), (9, 6), (8, 7)):
        g.px(x, y, "r")                                 # fold shading
    for x, y in ((4, 3), (9, 3), (6, 5), (11, 2), (7, 7)):
        g.px(x, y, "W")                                 # polka dots
    g.rim()
    return g


def sunglasses_frame():
    """Two dark lenses, browline bridge, temple arms out to the sides."""
    g = Grid(16, 6)
    g.rect(0, 0, 15, 0, "O")                            # browline + temple arms
    g.rect(2, 0, 6, 4, "O")                             # left lens
    g.rect(9, 0, 13, 4, "O")                            # right lens
    for x in (2, 6, 9, 13):                             # rounded lens bottoms
        g.px(x, 4, ".")
    g.rect(7, 1, 8, 1, "O")                             # bridge
    g.px(3, 1, "j"); g.px(10, 1, "j")                   # glass sheen
    g.px(4, 2, "j"); g.px(11, 2, "j")
    g.px(3, 2, "V"); g.px(10, 2, "V")                   # glint
    return g


# ---------------------------------------------------------------- output

def to_rgba_rows(grids):
    """Horizontal strip of equally-sized grids -> rows of RGBA tuples."""
    h = grids[0].h
    rows = []
    for y in range(h):
        row = []
        for g in grids:
            row.extend(PAL[c] for c in g.g[y])
        rows.append(row)
    return rows


def write_png(path, rows):
    h, w = len(rows), len(rows[0])
    raw = b"".join(
        b"\x00" + b"".join(struct.pack("4B", *px) for px in row) for row in rows
    )
    def chunk(tag, data):
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))
    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(png)


def upscale(rows, s):
    return [[px for px in row for _ in range(s)] for row in rows for _ in range(s)]


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    out = os.path.join(here, "..", "Sources", "Jumbini", "Resources", "sprites")
    preview_path = sys.argv[1] if len(sys.argv) > 1 else None

    # The dog itself now uses Alex's hand-made 8-directional art (see
    # Tools/import_jumba.py); this tool only generates the props. Pass
    # --all to also emit the original generated-dog sheets (fallback art).
    sheets = {
        "ball": [ball_frame(r) for r in range(4)],
        "heart": [heart_frame()],
        "bed": [bed_frame()],
        "jar": [jar_frame()],
        "treat": [treat_frame()],
        "rabbit": [rabbit_frame()],
        "deposit": [deposit_frame(0), deposit_frame(1)],
        "wardrobe_partyhat": [partyhat_frame()],
        "wardrobe_tophat": [tophat_frame()],
        "wardrobe_cowboyhat": [cowboyhat_frame()],
        "wardrobe_bandana": [bandana_frame()],
        "wardrobe_sunglasses": [sunglasses_frame()],
    }
    if "--all" in sys.argv:
        sheets.update({
            "idle": [standing(tongue=True, wag=0),
                     standing(tongue=True, ear_dy=1, wag=1)],
            "walk": [standing(leg_phase=i, body_dy=(i % 2), ear_dy=(i % 2), wag=i % 2)
                     for i in range(4)],
            "run": [standing(leg_phase=i, body_dy=(1 - i % 2), ear_dy=(i % 2), wag=i % 2,
                             running=True, tongue=True)
                    for i in range(4)],
            "sit": [sitting(0), sitting(1)],
            "lie": [lying(0), lying(1)],
            "sleep": [lying(0, asleep=True), lying(1, asleep=True)],
            "spin": [standing(leg_phase=1), front_view(),
                     standing(leg_phase=1).hflip(), back_view()],
            "carrywalk": [standing(leg_phase=i, body_dy=(i % 2), ear_dy=(i % 2),
                                   carrying=True, tongue=False)
                          for i in range(4)],
            "happy": [standing(ear_dy=-1, wag=-1, tongue=True),
                      standing(body_dy=-1, ear_dy=-2, wag=1, tongue=True)],
            "dangle": [dangling(0), dangling(1)],
        })

    for name, frames in sheets.items():
        write_png(os.path.join(out, f"{name}.png"), to_rgba_rows(frames))

    if preview_path:
        # Contact sheet: one animation per row, upscaled for review.
        max_w = max(sum(g.w for g in frames) for frames in sheets.values())
        all_rows = []
        for name, frames in sheets.items():
            rows = to_rgba_rows(frames)
            pad = max_w - len(rows[0])
            rows = [row + [(30, 30, 34, 255)] * pad for row in rows]
            all_rows.extend(rows)
            all_rows.append([(90, 90, 100, 255)] * max_w)  # separator
        write_png(preview_path, upscale(all_rows, 6))
        print(f"preview: {preview_path}")

    print(f"wrote {len(sheets)} sheets to {out}")


if __name__ == "__main__":
    main()
