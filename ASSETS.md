# Jumbini — asset manifest for the 10-spec roadmap

Everything below is art/audio that does **not** exist yet in `Sources/Jumbini/Resources/`.
Code-only specs are called out as such so nobody draws for them.

## Conventions to author against

**Dog poses** (`Resources/jumba/<state>_<direction>.png`)
- 48×48 RGBA PNG, transparent background, nearest-neighbor safe, low top-down view.
- 8 directions: `south, south-east, east, north-east, north, north-west, west, south-west`.
- Delivered as an export folder `<state-name>/rotations/<direction>.png` (+ `metadata.json`,
  export v3.1, template `dog`, 8 directions, 48×48) and registered in `EXTRA_STATES` in
  `Tools/import_jumba.py`. Same character prompt as
  `jumbini-kit/legacy-exports/sniffing_the_ground/metadata.json`.
- White backgrounds are stripped by the importer's edge flood fill — leave the outline closed.
- ⚠️ `sit_*` and `bark_*` were exported at 68×76 with less pixel density, which is why
  `SpriteLibrary` carries a `sitScale` hack. **Author every new pose at 48×48** so no new
  scale exceptions are needed.
- Mirroring is supported (`Animation.flipX`), so east/north-east/south-east art can cover the
  west side. "Min" counts below assume mirroring; "full" counts assume all 8 drawn.

**Props** (`Resources/sprites/<name>.png`)
- Horizontal strip sheets, uniform frame width, rendered at ×3. Single-frame props load via
  `singleProp`. Frame width is passed in code, so any size works — keep it small (8–48 px).

---

## 1. Barking (mostly art you already have)

| Asset | Spec | Count |
|---|---|---|
| `bark_<dir>` for S, SE, NE, N | 6-frame cycle each, 48×48 | 24 frames (min) / 48 (full 8-dir) |
| Bark FX puff | strip, 3 frames, ~16×12, small "borf" burst or speech-bubble | 3 |
| **Audio** `bark.wav` ×3 variants | 8-bit, ≤300 ms, slight pitch variation | 3 |
| **Audio** `growl.wav` (optional, for the reflection/Dock gag) | ≤600 ms | 1 |
| Mute toggle menu icon (optional — menu item text works) | 16×16 template PNG | 1 |

Existing `bark_0..5` is **east-facing only**. Mirroring gets you west, but he'll need to bark
downward at the Dock and upward at a title bar, so S and N are the real gap.

## 2. He leaves a mess

| Asset | Spec | Count |
|---|---|---|
| `deposit_1..3` pile variants | single frame, ~12×10 | 3 |
| Steam/stink wisp | strip, 3–4 frames, ~16×14, loops above a fresh pile | 4 |
| Fly (optional, for an old pile) | strip, 2 frames, 8×8 | 2 |
| Dry/faded pile variant (optional aging state) | single frame, ~12×10 | 1 |

## 3. He walks on your windows

Mostly brain/CG work, but gravity needs three new visual ideas:

| Asset | Spec | Count |
|---|---|---|
| Contact shadow blob | single frame, ~24×8, soft alpha ellipse; scaled by height in code | 1 |
| `fall_*` tumble | 4–6 frames, one axis (mirrorable), airborne legs-out | 6 |
| `land_*` impact/absorb pose | 1 frame × 4 dirs (or 8 for polish) | 4–8 |
| Dust puff on landing | strip, 4 frames, ~16×12 — **shared with #4 and #7** | 4 |
| `peek_*` hanging front-paws-over-edge (optional but the money shot) | 1 frame × S/SE/SW | 3 |

## 4. Cursor hunting, escalated

| Asset | Spec | Count |
|---|---|---|
| `stalk_<dir>` crouched creep | 2 frames × 8 dirs (5 + mirror = 10 min) | 10–16 |
| `pounce_<dir>` launch + mid-air | 2 frames × 8 dirs (5 + mirror = 10 min) | 10–16 |
| `pin_<dir>` paws-down on the cursor | 1–2 frames × 8 dirs | 8–16 |
| `prance_<dir>` proud head-high trot (optional; `run` works) | 2 frames × 8 dirs | 0–16 |
| Impact star/sparkle burst | strip, 4 frames, 16×16 — **shared with #8** | 4 |

## 5. He reacts to your machine

| Asset | Spec | Count |
|---|---|---|
| `alert_<dir>` ears-up perk | 1–2 frames × 8 dirs | 8–16 |
| `whine_<dir>` ears-down droop | 1–2 frames × 8 dirs | 8–16 |
| Emote bubble | 1 frame, 20×20 pixel speech/thought bubble the icons sit inside | 1 |
| Emote icons | 8×8 each: `!`, `?`, `zZz`, party/✓ (build done), battery bolt, moon (DND), flame/fan (thermal), gear (busy) | 8 |
| Confetti pieces | strip, 3 frames, 8×8 | 3 |
| **Audio** happy yip, whine | ≤500 ms each | 2 |

Naps reuse `sleep_*`, fan-zoomies reuse the existing zoomies path — no new art there.

## 6. Wardrobe — **the count multiplier, decide the approach first**

Two options, wildly different budgets:

- **Overlay (recommended):** each item drawn on its own 48×48 transparent canvas, registered
  to the dog's head/body in the *idle* pose. Code composites it as a child node with a
  per-(state, direction) anchor offset table. **8 files per item.**
- **Baked:** re-export every dog state wearing the item. ~7 states × 8 dirs = 56 files *per
  item*. Only do this for the raincoat if the overlay reads badly on the run cycle.

| Item | Type | Files (overlay) |
|---|---|---|
| Beanie | head | 8 |
| Cowboy hat | head | 8 |
| Party hat | head (doubles as the #5 build-finish celebration) | 8 |
| Top hat | head | 8 |
| Bandana | neck | 8 |
| Sunglasses | face (S/SE/E/NE only — invisible from behind) | 4 |
| Raincoat | body — **needs sit + sleep + run variants**, budget 3 extra sets | 8 (+24) |
| **Subtotal** | | **52–76** |

Plus, if head position shifts too much to fake with an offset, per-item `sit` and `sleep`
overlays: **+16 per item**.

Weather extras for the raincoat trigger:
| Rain droplet | strip, 3 frames, 4×8 | 3 |
| Puddle | single frame, ~20×6 | 1 |

Menu thumbnails: none needed — the bed menu already renders the sprite itself at 30 pt.

## 7. Toy box

| Asset | Spec | Count |
|---|---|---|
| Frisbee spin | strip, 4 frames, 16×16 (face-on → edge-on) | 4 |
| Frisbee in-mouth | 1 frame, edge-on, 16×8 | 1 |
| Squeaky toy (rubber chicken or bone) | 1 frame, 16×16 | 1 |
| Squeaky toy squash frames | strip, 3 frames, 16×16 | 3 |
| `shakeToy_<dir>` head thrash | 3 frames × 4 dirs (min) / 8 dirs | 12–24 |
| Tug rope, 3-part stretchable | left cap 8×10, tileable middle 8×10, right cap 8×10 | 3 |
| Tug rope taut/frayed variant | same 3 parts, strained look | 3 |
| `brace_<dir>` leaning-back tug pose | 2 frames × 8 dirs (5 + mirror = 10 min) | 10–16 |
| Mid-air catch pose (mouth open) | 1 frame × 8 dirs — can reuse `pounce` from #4 | 0–8 |
| **Audio** squeak, rope strain/grunt | ≤400 ms each | 2 |

## 8. Trick training

| Asset | Spec | Count |
|---|---|---|
| `paw_<dir>` shake / offered paw | 2 frames × 5 dirs + mirror | 10 |
| `highfive_<dir>` raised paw | 2 frames × 5 dirs + mirror | 10 |
| `playdead_*` on his back, legs up | 1–2 frames × 2 axes (mirrorable) | 4 |
| `rollover_*` | 5–6 frames, one axis, mirrorable | 6 |
| Trick-unlocked badge | 1 frame, 16×16 rosette/star | 1 |
| Sparkle burst | **reuse from #4** | 0 |
| **Audio** unlock chime | ≤500 ms | 1 |

## 9. Multi-monitor roaming — **no new assets**

Pure `NSScreen` / window-geometry work. Optionally a 12×12 edge arrow to hint which display
he wandered to; not required.

## 10. Jumbini Cam

| Asset | Spec | Count |
|---|---|---|
| Bitmap font atlas | 8×8 glyph strip: A–Z, a–z, 0–9, `: . , ' ! ? -`, space (~96 glyphs) — **or** license a pixel TTF and skip this | 1 sheet |
| Caption plate / polaroid frame | 9-slice PNG, ~48×48 with 8 px corners | 1 |
| Paw-print watermark | 1 frame, 16×16 | 1 |
| Camera flash overlay | can be code (white fade) — skip unless you want a shaped flare | 0–1 |
| **Audio** shutter click | ≤200 ms | 1 |
| Menu bar "cam armed" icon variant (optional) | 16×16 + 32×32 template pair | 2 |

---

## Shared / cross-cutting (draw once, used by several specs)

- Contact shadow blob (#3, #7 frisbee flight)
- Dust puff (#3 landing, #4 pounce, #7 tug)
- Sparkle/star burst (#4 catch, #8 unlock)
- Emote bubble + icon set (#1 bark target, #5 system status)
- Party hat (#5 celebration, #6 wardrobe)
- Audio bus + a single mute toggle covering every sound below

## Totals

| Bucket | Minimum (mirrored, lean) | Full quality (all 8 dirs, all variants) |
|---|---|---|
| Dog pose frames | ~110 | ~230 |
| Props / FX frames | ~40 | ~50 |
| Wardrobe overlays | 52 | ~140 |
| Font / UI | ~100 glyphs + 4 | same |
| Audio clips | 11 | 14 |

## Two decisions that move these numbers most

1. **Wardrobe layering.** Overlay + anchor table ≈ 52 files. Baking items into every pose is
   ~500. Overlay is the right call; keep every wardrobe piece drawn on the idle-registered
   48×48 canvas so the anchor table is the only thing that changes per pose.
2. **Direction count for rarely-seen poses.** `play dead`, `roll over`, `fall`, and the tug
   brace are read almost entirely side-on. Authoring those east-only and mirroring (exactly
   what `bark` does today) cuts the dog-frame budget roughly in half with no visible loss.

## Specs with zero art dependency

#9 (multi-monitor) entirely, and the bulk of #3 (`CGWindowListCopyWindowInfo` + surface
model), #5 (system event sources), #8 (persistence/progression), and #10's capture path.
