# Demo capture kit

Produces the landing-page assets: nine clips, four transparent hero sheets with
their CSS, and six stills.

The two halves are produced in different places, and it matters which:

| Half | Where | Needs |
|---|---|---|
| Nine clips (`capture.sh`) | the throwaway **capture account** | `ffmpeg`, three permissions, a built app |
| Hero sheets + CSS + stills (`stills.sh`) | the **authoring account**, from this repo | a Swift toolchain |

Only the capture half is staged into `/Users/Shared/jumbini-demo`. The offline
half needs no app, no permissions and no capture account, so it stays here.

## Why it works this way

Screen capture only works inside the active GUI session, and macOS home
directories are `0700`. The account that authors this repo therefore cannot
record the clean account the footage is shot in. So the kit is staged to
`/Users/Shared/jumbini-demo` and run from the capture account instead.

The dog is driven by `DemoDriver`, which is inert unless `JUMBINI_DEMO` names a
readable script. Every beat goes through the same entry point as a menu click
or a `SystemMonitor` signal, so the footage shows shipping behaviour. The
driver cannot make him do anything he can't already do — it only removes the
waiting, which matters because four of the best moments (thermal zoomies, the
build party, the battery whine, sleep and wake) cannot be staged on a real
machine on cue.

## Running it

From this repo, in the authoring account:

    Scripts/bundle.sh
    Tools/demo/stage-kit.sh

Then log into the capture account and follow the instructions it printed.

Requirements in the capture account: a single display, `ffmpeg`
(`brew install ffmpeg`), and three one-time permission grants — all of them
for whatever terminal runs `capture.sh`, in System Settings > Privacy &
Security:

| Grant | Pane | Without it |
|---|---|---|
| Screen Recording | Screen Recording | every frame is black |
| Automation → **TextEdit** | Automation → (your terminal) | the staged windows fail |
| Automation → **Finder** | Automation → (your terminal) | the staged windows fail |

The Automation grants are easy to miss: macOS asks separately for every app an
AppleScript talks to, and the dialog appears the first time an event is sent —
which, unattended, means it blocks and then fails with `-1712` partway through
take one. `capture.sh` therefore probes both apps with a harmless read-only
event before it records anything, so a missing grant fails in the first second
and names the app. Screen Recording is checked the same way, by measuring a
one-second probe recording's brightness rather than trusting that it exists.

Nothing else is needed. `capture.sh` uses only tools that ship with macOS
(`plutil`, `perl`, `osascript`, `screencapture`, `shortcuts`) plus `ffmpeg`;
in particular there is no Swift and no `python3` requirement, because the
offline assets are not built here.

`stage-kit.sh` refuses to re-stage over a `$KIT/out` that still has footage
in it — a routine re-run (say, to pick up a rebuilt app) would otherwise
silently delete whatever hasn't been copied back yet, and four of these
shots cannot be re-shot on cue. Copy `out/` back to this repo first. If you
really do want to discard what's there and re-stage anyway, override with:

    JUMBINI_STAGE_FORCE=1 Tools/demo/stage-kit.sh

## The hero sheets and the stills

Run in the **authoring account**, from this repo. No app, no permissions, no
capture account — which is exactly why they are not in the staged kit, and why
running them there could never have worked: the kit is `chmod a+rX` and owned
by the staging user, so `swift run` cannot create its `.build` inside it.

    Tools/demo/stills.sh

That writes:

- `demo-assets/hero/` — `walk-east.png`, `run-east.png`, `idle-south.png`,
  `sit-south.png`, and `hero.css`.
- `demo-assets/stills/` — `hero@2x.png`, `rotations.png`, `coats.png`, and
  instructions for the three that are screenshots of live UI.

Override the destinations with `JUMBINI_HERO_OUT` and `JUMBINI_STILLS_OUT`.
(`JUMBINI_DEMO_OUT` belongs to `capture.sh` and means the clips directory.)

`hero.css` is generated, never hand-edited. Cell size and frame count come
from `spritefilm sheet`'s own `frames=N cell=W height=H` output, and the frame
rate from `animations.json`, so a `steps()` loop on the website runs at the
rate the app plays the same animation. `idle` and `sit` are single frames in
the app's table, so they get a static rule and no `@keyframes`.

The sheets render at `JUMBINI_HERO_SCALE` (default 2) output pixels per pixel
of source art, nearest-neighbour, and the CSS declares one CSS pixel per image
pixel. That is a 1x asset on purpose: for pixel art what matters is landing on
an integer multiple of the source grid, not on the device pixel ratio. To
render bigger, re-run with `JUMBINI_HERO_SCALE=4` — the PNGs and every number
in `hero.css` scale together. The generated file explains this at the top so
whoever assembles the page does not have to guess.

To render one sheet by hand:

    swift run --package-path Tools/demo/spritefilm spritefilm sheet \
      --pose walk --facing east --scale 2 --out demo-assets/hero/walk-east.png

## Regenerating animations.json

`Tools/demo/animations.json` is generated from the same animation table
`SpriteLoader` uses, so `spritefilm`'s sheets, `hero.css` and the app can never
silently drift out of sync — `HeroSpecTests` is what enforces that. It is a
dev-time step, run only in the authoring account when the animation table
changes. Neither it nor the table it produces is staged into the capture kit,
because nothing in the recording half reads either one:

    swift Tools/demo/generate_animations_json.swift > Tools/demo/animations.json

Run it from the repo root, then re-run `Scripts/test.sh --filter HeroSpecTests`
to confirm the new table still matches `SpriteLoader`.

## Editing a shot

Shot timelines are JSON in `shots/`. `Scripts/test.sh --filter DemoShotsTests`
validates every one of them against the real enum cases, so a typo fails the
build rather than producing a clip where nothing happens.

## What this never touches

The `gh-pages` branch. It holds `appcast.xml` and the shipped DMG, which are
load-bearing for Sparkle auto-updates on machines already in the field.
