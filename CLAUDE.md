# Working on Jumbini

A macOS desktop pet: a dog that walks along the tops of your open windows and
reacts to what your Mac is doing. AppKit and SpriteKit, SwiftPM, no SwiftUI and
no third-party UI framework. macOS 14+, Swift 6 language mode — so actor
isolation is enforced, not advisory, and anything you add that touches AppKit
or SpriteKit needs to be reachable only from the main actor.

## Running the tests

**Use `./Scripts/test.sh`. Never bare `swift test`.**

On a Mac with Command Line Tools but no full Xcode — which is this machine —
bare `swift test` compiles the test bundle and then dies at launch with
`Library not loaded: @rpath/Testing.framework`. The failure looks like a broken
test suite and is not one. `Scripts/test.sh` is a three-line wrapper that passes
the Swift Testing macro plugin path and two rpaths into
`/Library/Developer/CommandLineTools`; it takes the same arguments, so
`./Scripts/test.sh --filter DogBrainTests` works.

CI uses bare `swift test` on purpose, because its runners have full Xcode where
those flags point at the wrong toolchain. Do not "fix" the workflow to match
the script.

`swift build` emits two `ld: warning: search path ... not found` lines here.
They are environmental and pre-existing, not failures.

## Running the app

```
./Scripts/bundle.sh && open build/Jumbini.app
```

`swift build` alone produces a binary that cannot find its resources. Use
`Scripts/smoke.sh` after bundling to prove the app survives startup — every
release from v3.0 to v4.4 was built, tested, signed and shipped while crashing
about a second into launch on every Mac except the one that built it, which is
why that script exists.

## The one boundary that matters

`DogBrain.swift` is a pure state machine. It imports `Foundation` and
`CoreGraphics` and nothing else — no SpriteKit, no AppKit, and no user-facing
text. The scene feeds it events with timestamps and applies the effects it
returns.

That split is what makes the dog's behavior testable without a window, and it
is the boundary this codebase guards hardest. If you need the brain to know
something about the world, give it a property the scene keeps current (as
`bounds`, `position`, `surfaces`, `cursorPosition` and `mood` already are)
rather than letting it reach for the world itself. If you need to say something
to the user about why he did something, say it in `PetScene`, which is the only
layer that still knows a signal's name.

## Traps worth knowing before you touch them

**`Mood` is deliberately not part of `JumbiniSettings`.** `SettingsPanel.featureChanged()`
builds a fresh `JumbiniSettings` from its three checkboxes, so any field added
to that struct is reset to its default whenever a user toggles any Settings
checkbox. Scene-owned state belongs in `Mood`, which has its own keys and its
own owner.

**The idle-odds bands are normalized.** `AutonomyOdds` scales the seven bands
down proportionally if they would total more than `1 - tuning.wanderShare`, so
plain wandering always keeps a share of the roll. A consequence for tests: in
`DogBrainTests`, `makeBrain` sets `wanderShare = 0` precisely so that
`$0.hunchChance = 1` still means *certain*. Build a `BrainTuning()` directly if
you want to exercise the real 0.1 reservation.

**`ActivityMode.active` is an exact 1.0 in every column.** That identity is what
makes the existing suite a regression guard for mood work. If a previously
passing test moves after a change to the multipliers, the identity broke —
investigate rather than adjusting the test.

## Conventions

Comments explain **why**, not what. The codebase leans on this heavily: most
doc comments exist to record a decision and the failure it avoids, so a future
reader does not undo it. Match that when you add code, and when you find a
comment that no longer matches the code, fix the comment — a stale one is worse
than none.

Baseline before any change: **716 tests in 13 suites, all passing.**
