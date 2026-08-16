# Jumbini demo assets — design

**Date:** 2026-08-15
**Status:** approved, pending implementation plan

## Goal

Produce the static and motion assets for a Jumbini landing page, plus the tooling to
regenerate them on every release. The page itself is out of scope — this delivers files
and a re-runnable capture kit.

## Scope

**In scope**

- Nine screen-recorded clips of the real app on a real desktop, in `.mp4` and `.webm`
  with poster frames.
- Transparent-background hero loops as sprite sheets with a CSS snippet.
- Six still images.
- An env-gated demo driver inside the app that makes the captures deterministic.
- An offline sprite compositor.
- A capture runner that produces every clip unattended.

**Out of scope**

- The landing page: markup, styling, hosting, domain.
- Any change to `gh-pages`. That branch holds `appcast.xml` and `Jumbini-4.2.dmg`, which
  are load-bearing for Sparkle auto-updates on machines already in the field.
- Changing what the dog does. The driver triggers existing behavior; it never adds any.

## Constraints that shape the design

### Captures run in a different user account than the one authoring this

Screen capture on macOS only works within the active GUI session, and home directories are
`0700`, so the authoring account can neither drive nor read a throwaway account's session.

Consequently the capture kit is **self-contained and staged to `/Users/Shared/jumbini-demo/`**,
and is run by the operator from the throwaway account's Terminal with a single command. It
must complete unattended: stage windows, launch, record, encode, verify, write output.

This constraint is also what makes the kit re-runnable at each release, which was the
motivation for the driver in the first place.

### Permissions

- **Screen Recording** must be granted to the recording Terminal, once, on first run. The
  runner detects the denial case and exits with an explanatory message rather than
  producing black frames.
- **No Accessibility permission is required.** Window staging uses each app's own AppleScript
  dictionary (`set bounds of window 1`), and cursor moves use `CGWarpMouseCursorPosition`
  from inside the app. Both work without it.
- Do Not Disturb is enabled by the runner for the duration so notification banners cannot
  land in a take.

### Tooling

`ffmpeg` is installed via Homebrew and is the only external dependency. The runner checks
for it up front and fails with the install command if it is absent. Capture itself uses the
system `screencapture`; `ffmpeg` handles trim, crop, scale, loop points, and encoding.

## Architecture

Four components, three of them new files under `Tools/demo/`.

```
Sources/Jumbini/DemoDriver.swift    in-app, env-gated timeline player
Tools/demo/spritefilm/              Swift CLI: PNG sprites -> sheets + stills
Tools/demo/capture.sh               orchestrator, runs in the throwaway account
Tools/demo/shots/*.json             one timeline per clip, version controlled
demo-assets/                        output; gitignored unless asked otherwise
```

### Component: DemoDriver

A timeline player. It reads a JSON file of beats and plays them into the live scene at
wall-clock offsets.

Every beat resolves to a call the app already makes:

| Beat kind | Resolves to |
|---|---|
| `command` | `PetScene.perform(_ command: DogCommand)` |
| `system` | `PetScene.receive(_ signal: SystemSignal)` |
| `cursor` | `CGWarpMouseCursorPosition` |
| `wait` | no-op, advances the clock |

`receive(_:)` is already internal, because `SystemMonitor` calls it from the app layer, so
ambient signals need no change to `PetScene` at all. Thermal zoomies filmed this way are
produced by the shipping code path, not a mock of it.

**The driver cannot make the dog do anything he cannot already do.** It removes waiting;
it does not fabricate behavior. This matters because the footage is a product claim.

**Gating.** The driver is constructed only when `JUMBINI_DEMO` names a readable file:

```swift
guard let path = ProcessInfo.processInfo.environment["JUMBINI_DEMO"] else { return nil }
```

A unit test asserts the factory returns `nil` with the variable unset, and returns `nil`
with it set to a nonexistent path.

### Component: spritefilm

A Swift CLI reading `Sources/Jumbini/Resources/jumba/*.png` and writing sprite sheets,
transparent stills, and contact sheets through ImageIO. No app launch, no permissions, no
window server.

**Drift guard.** `SpriteLibrary.animation(for:facing:)` owns the real frame lists, frame
rates, and scales — `walk` is `run1`/`run2` at 4fps, `run` is the same pair at 13fps,
`spin` is the eight idle rotations at 24fps, `baseScale` is 2.4 and `sitScale` is 2.9. If
spritefilm duplicates those numbers they will drift and the hero loop will stop matching
the app. spritefilm therefore declares its animation table in JSON, and a unit test in the
existing test target cross-checks that table against `SpriteLibrary`. A mismatch fails the
build rather than shipping a hero that animates at the wrong speed.

Both coats live in one folder distinguished by prefix — `idle_south.png` is classic,
`shaggy_idle_south.png` is shaggy — so the coat is a prefix argument.

### Component: capture.sh

Per clip: stage windows, launch the app with `JUMBINI_DEMO` set, wait for the scene, start
`screencapture -v`, hold for the clip duration, stop, quit the app, then hand the `.mov` to
ffmpeg for trim, crop, scale, and encode.

It restores the desktop between clips so one take cannot contaminate the next — in
particular the dog leaves piles that persist, and a stray pile in the corner of the
flagship climb shot is exactly the kind of thing that gets noticed after publishing.

## Demo script format

```json
{
  "name": "thermal",
  "duration": 8.0,
  "showCursor": true,
  "beats": [
    { "at": 0.5, "kind": "system",  "signal": "fansUp" },
    { "at": 7.0, "kind": "system",  "signal": "batteryNormal" }
  ]
}
```

`at` is seconds from scene start. `showCursor` controls whether `screencapture` is passed
`-C` — on for the clips where he chases the pointer, off elsewhere so a stray arrow does
not sit in frame. It is distinct from the `cursor` beat kind, which moves the pointer.

Signal and command names match the Swift enum cases exactly (`fansUp`, `buildFinished`,
`idleBegan`, `idleEnded`, `batteryLow`, `batteryNormal`, `dndOn`, `dndOff`; `sit`,
`lieDown`, `spin`, `fetch`, `spinForever`, `zoomies`, `relax`, `trick(_:)`, `toy(_:)`).
Unknown names are a hard parse error, not a silent skip — a typo that quietly drops a beat
would show up as a clip where nothing happens, after the recording.

## Shot list

Nine clips, roughly 100 seconds of footage.

| Clip | Length | Content |
|---|---|---|
| `climb` | 15s | Walks to a staged window, hops the title bar, patrols, leans over the edge to look down, rides the window as it moves, then a hard drag shakes him off — falls, squashes on landing, gets up. |
| `thermal` | 8s | `fansUp` → flame bubble → zoomies bouncing off the screen edges. |
| `build-party` | 7s | `buildFinished` → yip, hearts, confetti, party-hat bubble. |
| `quiet` | 12s | `batteryLow` → whine and lie down; then `idleBegan` → curls up, `idleEnded` → wakes. |
| `fetch` | 12s | Fetch command, ball arc, sprint, pick up, carry back, drop, flourish. |
| `toys` | 14s | Frisbee, squeaky, tug rope. |
| `tricks` | 10s | Shake, high five, play dead, roll over. |
| `pounce` | 10s | Cursor moves, he trots over, nose-down sniff, stalk, freeze, pounce. |
| `charm` | 14s | Petting hearts, dangle from cursor, hunch and the pile drying with flies, a hat, a coat swap. |

`climb` is the flagship and the hardest: it needs staged windows at known positions and
scripted window motion at two speeds — slow enough to ride, then past the ~180pt-per-poll
threshold that shakes him off. Window motion is driven by AppleScript `set bounds`.

## Output

Everything lands in `demo-assets/`, which is added to `.gitignore`. The binaries are not
committed to `main` without an explicit decision to do so — they belong wherever the
landing page is built, and a repo that ships a 20MB DMG through `gh-pages` does not also
need the raw footage in its history.

**Clips.** Captured at native 2x, delivered 1440px wide. Each clip ships as:

- `.mp4` — h.264 High, `yuv420p`, `+faststart`
- `.webm` — VP9
- `.jpg` — poster frame

Seamless loop points where the motion allows it. Budget under 2MB per clip; the runner
prints the size of anything that exceeds it rather than silently shipping a 9MB hero.

**Transparent hero.** Sprite sheets for walk, idle, run, and sit, plus a CSS `steps()`
snippet. A sprite sheet rather than a video with an alpha channel: alpha video splits along
HEVC-in-Safari versus VP9-in-Chrome, while a sheet is universal, a fraction of the size,
crisp at any DPI, and can be paused or reversed from CSS. For a desktop-pet product the dog
should live on the page rather than inside a video box.

**Stills.**

| File | Purpose |
|---|---|
| `hero@2x.png` | Transparent hero dog. |
| `rotations.png` | The eight-direction contact sheet — the evidence for the hand-drawn claim. |
| `coats.png` | Classic and shaggy side by side. |
| `wardrobe.png` | The hats. |
| `menubar.png` | The hunger-meter joke. |
| `jumbini-cam.png` | Real `⌥⇧J` output, captured from the app rather than mocked. |

## Testing and acceptance

- `swift test` stays green. The existing suite is the regression net for the `PetScene`
  extraction.
- New test: the driver is `nil` without `JUMBINI_DEMO`, and `nil` with it pointing nowhere.
- New test: spritefilm's animation table matches `SpriteLibrary`.
- New test: every JSON in `Tools/demo/shots/` parses and names only real enum cases.
- Manual acceptance: launching the app normally shows no behavioral difference, and the
  menu-driven commands still work after the `commandChosen` extraction.

The kit is done when one command in the throwaway account yields all nine clips, all
formats, all stills, with no manual intervention beyond granting Screen Recording once.

## Risks

- **`screencapture -v` duration flag.** The design assumes `-V <seconds>`; if it behaves
  differently the runner falls back to backgrounding the capture and stopping it on a
  timer. Verify early, it changes the runner's shape.
- **Retina and multi-display.** The app builds one overlay across the union of all
  displays. The throwaway account should run a single display, or `ScreenLayout` dead zones
  may put the dog somewhere the crop does not cover.
- **Clip determinism is timing-based, not frame-locked.** Beats fire on a wall clock while
  the dog's own idle chooser keeps rolling, so a take can be interrupted by a spontaneous
  wander. The runner records each clip and the operator reviews before publishing; a bad
  take is re-run rather than repaired.
