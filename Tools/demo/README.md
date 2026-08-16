# Demo capture kit

Produces the landing-page assets: nine clips, transparent hero sheets, six stills.

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
(`brew install ffmpeg`), a Swift toolchain (Command Line Tools are enough —
`stills.sh` and `spritefilm` both need `swift`, even though no capture
happens through either of them), and Screen Recording permission for
Terminal. The runner checks what it can and refuses to produce black frames
silently.

`stage-kit.sh` refuses to re-stage over a `$KIT/out` that still has footage
in it — a routine re-run (say, to pick up a rebuilt app) would otherwise
silently delete whatever hasn't been copied back yet, and four of these
shots cannot be re-shot on cue. Copy `out/` back to this repo first. If you
really do want to discard what's there and re-stage anyway, override with:

    JUMBINI_STAGE_FORCE=1 Tools/demo/stage-kit.sh

## Regenerating just the hero assets

These need no app, no permissions, and no capture account:

    Tools/demo/stills.sh
    swift run --package-path Tools/demo/spritefilm spritefilm sheet \
      --pose walk --facing east --scale 2 --out demo-assets/hero/walk-east.png

The command prints `frames=N cell=W height=H`. Drive the sheet from CSS with
`steps(N)` and a `background-size` of `calc(W * N)`.

## Regenerating animations.json

`Tools/demo/animations.json` is generated from the same animation table
`SpriteLoader` uses, so `spritefilm`'s sheets and the app can never silently
drift out of sync — `HeroSpecTests` is what enforces that. It is a dev-time
step, run only in the authoring account when the animation table changes;
the capture account never regenerates it, so `generate_animations_json.swift`
is not staged into the kit:

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
