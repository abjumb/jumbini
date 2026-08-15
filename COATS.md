# Coats — the custom dog art format

A **coat** is a folder of sprites that replaces Jumba's artwork. Drop one in
and it appears in the app's **Coat** menu; pick **Classic** and Jumba is back,
immediately, with no relaunch.

Nothing in this format depends on how the art was made. Hand-pixel it, render
it, trace it off a photo — the app only ever reads PNGs from a folder. It never
generates art, and it makes no network calls to load a coat.

---

## Where coats go

```
~/Library/Application Support/Jumbini/coats/<coat-id>/
```

`<coat-id>` is the folder name. It is the coat's identity: it is what gets
saved when you select the coat, so renaming the folder later loses the
selection (the app falls back to Classic). Use something stable and
filesystem-safe — `nova`, `mabel-2026`.

Folders named `classic` or `shaggy` are ignored, so a coat cannot displace the
bundled art.

Create the directory if it isn't there yet:

```sh
mkdir -p ~/Library/Application\ Support/Jumbini/coats
```

## Folder layout

```
nova/
  coat.json          # optional, see below
  idle_south.png
  idle_south-east.png
  ...
```

Every sprite is `<state>_<direction>.png`, flat in the coat folder — no
subdirectories. There is no prefix on the filenames; the folder is what keeps
one coat's art apart from another's.

**`idle_south.png` is mandatory.** A folder without it is not treated as a coat
at all: it won't appear in the menu, and no error is raised. That is also the
image used as the coat's menu thumbnail.

## Directions

Eight, spelled exactly like this:

```
south  south-east  east  north-east  north  north-west  west  south-west
```

All eight are needed for every state you supply. The app does not mirror east
art onto the west side for coat sprites — mirroring exists only for the legacy
6-frame bark strip, which coats don't use.

## States

Seventeen states are read by the app. Supply all seventeen, in all eight
directions — **136 PNGs** — for a dog that never falls back to Jumba.

| State | When it plays |
|---|---|
| `idle` | standing still; also the spin cycle and half of every bark |
| `run1`, `run2` | the two-frame gait — walking, running, carrying |
| `sit` | sitting; also how he's drawn while picked up |
| `sleep` | lying down and sleeping |
| `bark` | mouth open, alternated with `idle` to make a yap |
| `sniff` | nose to the ground |
| `hunch` | crouched |
| `stalk` | low, creeping |
| `pounce` | mid-leap |
| `paw` | offering a paw |
| `highfive` | paw raised high |
| `playdead` | flopped on his side |
| `brace` | dug in, leaning back (tug of war) |
| `fall` | airborne, legs out |
| `land` | absorbing a landing |
| `peek` | nose over an edge, looking down |

### What happens if you leave a state out

Resolution is **all-or-nothing per animation**. If a coat is missing even one
frame of a cycle, the whole cycle comes from Jumba's classic art rather than
alternating coats mid-gait.

The practical consequence: **an omitted state does not fall back to another
pose of your dog — it falls back to Jumba.** A coat with no `stalk` shows your
dog everywhere except stalking, where it briefly shows Jumba. This is why all
seventeen are worth drawing even though only `idle_south` is enforced.

### Two states nothing has art for yet

`rollover` and `shaketoy` are wired into the app but no art exists for them,
including Jumba's — they currently borrow other poses. A coat that supplies
`rollover_<direction>` or `shaketoy_<direction>` lights them up for that coat.
Purely optional.

### States you may see elsewhere but should not draw

`alert`, `whine`, `pin` and `growl` are imported into Jumba's own resources but
no code reads them. Drawing them for a coat has no effect today.

## Canvas and pixels

- **48×48 RGBA PNG**, 8-bit.
- **Transparent background.** Deliver it already transparent — do not rely on
  background removal.
- **A closed, hard, dark outline**, 1px, no anti-aliasing against the
  transparent edge. This matters more than it sounds: the importer's
  background-stripping pass floods inward from the border and is stopped by the
  outline. A single-pixel gap in a light-coated dog lets the fill through and
  erases the sprite. If you author transparent as instructed, that pass never
  runs — but a closed outline also keeps the art crisp under nearest-neighbor
  scaling.
- **Low top-down view**, consistent across every state and direction, so the
  dog doesn't change camera when he changes pose.
- Same eye colour, markings, ear length and body proportion in all of them. The
  app draws these back-to-back at up to 13fps; anything inconsistent reads as a
  flicker.

Author at 48×48 unless you have a reason not to — see `scales` below for the
escape hatch, and `ASSETS.md` for why it exists.

## `coat.json` (optional)

```json
{
  "name": "Nova",
  "scales": { "sit": 3.1 }
}
```

| Key | Meaning |
|---|---|
| `name` | Menu title. Defaults to the folder name. |
| `scales` | Per-state render scale, overriding the app's default for that state. |

A malformed `coat.json` is ignored rather than fatal — the coat still loads at
default scale. The sprites are what matter.

### When you need `scales`

The app renders 48×48 art at ×2.4. If one of your states is drawn at a
different canvas size or fills less of its canvas than the rest, it will look
the wrong size next to the others, and `scales` is where you correct it.

Jumba himself needs this: 41 of his states are 48×48 but his three sitting
poses were exported at 68×76 with lower pixel density, which is why the app
carries a built-in `sit` scale tuned to his art specifically. If your `sit` is
drawn at a normal 48×48 density, you may need to set `"sit"` back down. Start
without a manifest, look at him sitting, and add an override only if he
changes size.

## Installing and reverting

1. Copy the folder into `~/Library/Application Support/Jumbini/coats/`.
2. Open the Jumbini menu → **Coat**. The new coat is listed; no relaunch
   needed — the folder is rescanned each time the menu opens.
3. Select it. The dog redraws on the spot.
4. To go back, select **Classic**. One click, immediate.

Deleting a coat folder while it's selected is safe: at the next launch the app
finds it missing and quietly returns to Classic.
