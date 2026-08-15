<div align="center">

<img src="icon/app-icon-final/icon_256x256" width="128" alt="Jumbini app icon">

# Jumbini

**A pixel-art dog who lives on your macOS desktop.**

Jumba is a tricolor spaniel mix. He wanders across your screen, naps in his bed, chases a
tennis ball, begs for peanut butter, gets the zoomies, and follows your cursor around
sniffing it. He sits on top of every window and clicks straight through, so he never gets
in the way of the app you are actually using.

[Download the latest release](https://github.com/abjumb/jumbini/releases/latest) ·
[Build from source](#build-from-source) · [How it works](#architecture)

</div>

---

## Install

**Requirements:** macOS 14 (Sonoma) or newer, Apple Silicon.

1. Grab `Jumbini.dmg` from the [latest release](https://github.com/abjumb/jumbini/releases/latest).
2. Open the DMG and drag **Jumbini** to Applications.
3. **First launch: right-click the app and choose Open**, then confirm.

That third step matters. The app is ad-hoc signed, not notarized by Apple, so a plain
double-click gets you a "cannot be opened" dialog instead of a dog. Right-click → Open is
the one-time bypass; after that it launches normally.

Jumbini has no Dock icon and no window. When it is running you get a dog on screen and a
small pixel-dog icon in your menu bar. Everything else lives in that menu.

## Meet Jumba

He runs his own life. Every few seconds of standing around, he rolls the dice and picks
something to do:

| What he does | How likely | How long |
|---|---|---|
| Wander somewhere new | 49% | until he arrives |
| Nap (in his bed if he has one) | 15% | 10-20s |
| Spin in place, for no reason | 10% | 0.9s |
| Sniff your cursor around the screen | 12% | 100-140s |
| Zoomies | 8% | 10s |
| Hunch over and do his business | 6% | 2.5s |

The sniffing one is the sleeper hit: he trots toward wherever your pointer is, and once he
is within about 60 points he switches to the nose-down sniff pose and keeps tracking it.
Zoomies means bouncing off the edges of your screen at 900 points per second with his
fur rabbit in his mouth.

## Controls

Everything is mouse-driven, directly on the dog and his stuff.

### The dog

| Do this | Get this |
|---|---|
| Left-click him | Pet him. Hearts float up, then he settles back down |
| Click and drag him | Pick him up. He dangles from the cursor until you let go |
| Right-click him | Command menu: Sit, Lie Down, Spin, Spin Forever, Zoomies!, Fetch |

While he is mid-Spin-Forever, the first menu item becomes **Stop Spinning**.

### Fetch

1. Right-click him → **Fetch**. He sits and waits.
2. **Left-click anywhere on screen.** The ball arcs to that spot.
3. He sprints after it, picks it up, carries it back to where he was standing, drops it,
   and does a little bark of celebration.

Changed your mind? Right-click anywhere while he is waiting and the fetch is off. He also
gives up on his own after 10 seconds.

### The peanut butter jar (bottom-right)

| Do this | Get this |
|---|---|
| Click the jar | Take a treat. It rides your cursor |
| Click again anywhere | Drop the treat. He drops everything and sprints for it |
| Drop it back on the jar | Put it away, no harm done |
| Drag the jar | Move the jar (hold ⌥ to start the drag instantly) |

Peanut butter outranks everything: naps, fetch, commands, all of it. He eats it, gets
hearts, and then, about a second later, hunches over. Treats go straight through him.

Only one treat exists at a time. Drop a second one and he switches targets. Interrupt him
mid-chase with a command and the abandoned treat quietly vanishes.

### The bed (bottom-right)

| Do this | Get this |
|---|---|
| Drag it | Move the bed. If he was already walking to it, he re-routes mid-stride |
| Right-click it | Pick from 12 beds (plus the built-in fuzzy one) |

Bed choice sticks between launches. **Lie Down** and naps both send him to the bed if he
has one, and he settles into the cushion rather than standing on it.

### Menu bar

- **Hunger: ██████████ 100%** — a bottomless dog. This meter has never moved and never
  will. It is the joke.
- **Treats eaten: N (no effect)** — counts up forever, does nothing, see above.
- **Pause** — hides the overlay and freezes the scene. Click **Resume** to bring him back.
- **Leave Jumbini Behind** (⌘Q) — quit.

## Build from source

No Xcode needed. Command Line Tools and Swift 6 are enough.

```bash
git clone https://github.com/abjumb/jumbini.git
cd jumbini
./Scripts/bundle.sh          # → build/Jumbini.app
open build/Jumbini.app
```

`bundle.sh` does a release build, assembles the `.app` around it with `Scripts/Info.plist`
and the icon, copies in the SwiftPM resource bundle (all the sprites), and ad-hoc signs
the result.

Other scripts:

```bash
./Scripts/test.sh            # run the test suite (59 tests)
./Scripts/dmg.sh             # → build/Jumbini.dmg, drag-to-Applications layout
```

While iterating, the relaunch loop is:

```bash
pkill -x Jumbini; ./Scripts/bundle.sh && open build/Jumbini.app && pgrep -x Jumbini
```

### Run the tests

```bash
./Scripts/test.sh
```

Use the script, not bare `swift test`. Swift Testing under Command Line Tools needs an
explicit macro plugin path and two rpaths into `/Library/Developer/CommandLineTools`, and
the script bakes those flags in. Extra arguments pass straight through
(`./Scripts/test.sh --filter zoomies`).

## Architecture

The whole design is one split: **decisions live in a pure state machine, rendering lives in
SpriteKit, and they talk in values.**

```
                  events                    effects
   PetScene  ───────────────►  DogBrain  ───────────────►  PetScene
  (SpriteKit)  .tick             (pure)      .play(.run)     (SpriteKit)
               .petted                       .moveTo(p, 90)
               .treatDropped(at:)            .startZoomies
               .arrived                      .showHearts
```

`DogBrain` imports Foundation and CoreGraphics, nothing else. Every frame the scene feeds
it an event plus a timestamp, and it hands back a list of `DogEffect` values for the scene
to apply. It never touches a node, a texture, or a clock.

That buys determinism. The brain's randomness comes from an injected
`RandomNumberGenerator` (a SplitMix64 seeded per test) and its timing comes from
timestamps the caller passes in, so a test can wind the clock forward and assert on exact
state transitions with zero flake and zero sleeping. All 59 tests build a brain with
`makeBrain(seed:tune:)`, zero out every autonomy probability, enable exactly one, and
check what happens.

### Files

| File | Lines | What lives there |
|---|---|---|
| `Sources/Jumbini/DogBrain.swift` | 438 | The state machine. 17 states, 10 events, 16 effects, every tuning knob |
| `Sources/Jumbini/PetScene.swift` | 629 | Applies effects, owns all mouse input, zoomies bounce physics, cursor-sniff stepping, click-through |
| `Sources/Jumbini/Dog.swift` | 119 | The dog sprite: plays animations in whichever of 8 directions he faces, walks to targets, reports arrival |
| `Sources/Jumbini/SpriteLoader.swift` | 184 | `Facing` (8 directions) and `SpriteLibrary` (texture cache, nearest-neighbor, strip-sheet slicing) |
| `Sources/Jumbini/OverlayWindow.swift` | 31 | Borderless non-activating `NSPanel` at status-bar level, click-through by default |
| `Sources/Jumbini/AppDelegate.swift` | 122 | Menu bar item, pause, hunger gag, screen-resolution changes |
| `Sources/Jumbini/Ball.swift` | 71 | Tennis ball: throw arc, bounce, landing callback |
| `Tests/JumbiniTests/DogBrainTests.swift` | 672 | 59 deterministic behavior tests |

### Two details worth knowing

**Click-through is recomputed every frame.** The overlay window sets
`ignoresMouseEvents = true` almost always, so your clicks land in your real apps. Once per
frame `PetScene` checks whether the cursor is over the dog, the jar, or the bed (or a drag
or an armed throw is in flight) and flips the flag. That is why he never eats a click you
meant for Xcode.

**The window never takes focus.** It is a `nonactivatingPanel` that refuses to become key
or main, so petting the dog does not steal your cursor out of the editor you are typing
in. It also joins all Spaces and floats over full-screen apps.

## Art pipeline

Jumba's own art is hand-made: 8 rotations for each of `idle`, `run1`, `run2`, `sit`,
`sleep`, `sniff`, and `hunch`, plus a 6-frame east-facing `bark` cycle that the app mirrors
for west-facing poses. It lives in `Sources/Jumbini/Resources/jumba/` as
`<state>_<direction>.png`.

```bash
python3 Tools/import_jumba.py /path/to/export
```

`import_jumba.py` takes AI-export folders shaped like `<state>/rotations/<direction>.png`,
strips the baked-in white background with a border flood fill (the dark outline protects
interior whites like his chest blaze and socks), and flattens everything into the resource
folder. Pure stdlib, including a hand-rolled PNG codec, no dependencies. New states get
registered in the `EXTRA_STATES` map at the top.

`Resources/jumba/` is the durable copy of that art. The importer skips any source folder
that is not present, so re-running it with a partial export is safe.

The props (ball, heart, bed, jar, treat, rabbit) are generated code, not drawings:

```bash
python3 Tools/make_sprites.py
```

Run it without `--all`. That flag also regenerates procedural placeholder art for the dog
himself, which nothing uses anymore.

## Project layout

```
Sources/Jumbini/           app code
  Resources/jumba/         hand-made dog sprites, 8 directions per state
  Resources/sprites/       generated props + 12 bed variants
  Resources/Icons/         menu bar icon (16 and 32 px)
Tests/JumbiniTests/        59 deterministic brain tests
Tools/                     import_jumba.py, make_sprites.py
Scripts/                   test.sh, bundle.sh, dmg.sh, Info.plist
icon/                      app icon sources and iconsets
```

## Contributing

One rule that matters: **behavior changes are test-first.** Anything that touches how Jumba
decides what to do starts with a failing test in `DogBrainTests.swift`, then the
implementation. The brain is pure and deterministic specifically so this is cheap.

Rendering and input code in `PetScene` has no tests. Verify those by hand: rebundle,
relaunch, and actually play with the dog.

Adding a case to `DogEffect` breaks `PetScene`'s exhaustive switch, which is intentional.
Stub the new case so the package compiles, then wire it up for real.

## Known limitations

- **Not notarized.** Ad-hoc signed only, so recipients need the right-click → Open dance.
- **Apple Silicon only.** A universal binary would need `--arch` work in `bundle.sh`.
- **Main display only.** He lives on `NSScreen.main` and does not roam to a second monitor.
- **Version strings lag.** `Scripts/Info.plist` still says 1.0 while the release tag is v3.0.

## License

Code is MIT. See [LICENSE](LICENSE).

The artwork is not. Jumba is a real dog, the pixel art is of him, and it stays his:
everything under `Resources/jumba/`, the bed variants, the icons, the art export folders,
and the reference photo are all rights reserved. The generated props (ball, heart, jar,
treat, rabbit, and the built-in bed) come out of `Tools/make_sprites.py` and are MIT like
the rest of the code.

Fork it, build it, reuse the code. If you ship something derived from it, replace the dog.
