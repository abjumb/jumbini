# Mood Modes Design

**Status:** Approved for implementation
**Date:** 17 August 2026

## Scope and decisions

Jumba gains three persistent personality switches and a spoken caption for
every Mac-aware reaction.

1. An **activity mode** — Very Active, Active, or Sleepy — that scales how
   often he chooses each idle activity. Very Active is defined by frequent,
   longer zoomies.
2. A **Stay Lying Down** toggle that keeps him lying down until the user turns
   it off.
3. A **Follow My Cursor** mode, the alternative to ordinary wandering, that
   aims his walks at the mouse pointer.
4. A **speech bubble** carrying a short line of text whenever the machine
   makes him react, so the reason for the reaction is legible.

All three switches live in Jumba's right-click menu and persist across
launches. Behavior visible today is unchanged when the switches are at their
defaults: Active, hold off, wandering.

Four decisions were settled before design and are binding here.

- The controls live in Jumba's right-click menu, not the menu-bar dropdown and
  not the Settings panel. The Settings panel gains nothing and is not modified.
- Follow mode trails the cursor at a distance. It does not suppress naps,
  flourishes, fetch, treats, or window climbing.
- The speech bubble carries text only, and captions Mac-aware reactions only.
  It does not narrate his autonomous choices, and it does not carry an icon.
- The Stay Lying Down hold is soft. Treats, pets, commands, and toys interrupt
  it normally and he returns to lying down afterwards.

## Architecture

`DogBrain` remains a pure state machine with no SpriteKit and no AppKit. The
mood is data the scene keeps current on the brain, exactly as `bounds`,
`position`, `surfaces`, and `footOffset` already are. The brain decides what he
does with it; the scene owns the menu, the persistence, and the pixels.

Mood is a value type separate from `JumbiniSettings`. The two structs have
different owners: the Settings panel owns `JumbiniSettings`, and the scene owns
`Mood`. Keeping them apart is a correctness requirement, not a preference.
`SettingsPanel.featureChanged()` constructs a fresh `JumbiniSettings` from its
three checkboxes, so a mood field added to that struct would be reset to its
default every time a user toggled any Settings checkbox. Separate structs make
that failure impossible rather than merely avoided.

### Mood

A new file, `Sources/Jumbini/Mood.swift`, holds four small types.

`ActivityMode` is a `String`-backed, `CaseIterable` enum with cases
`veryActive`, `active`, and `sleepy`. `RoamMode` is a `String`-backed enum with
cases `wander` and `follow`. `Mood` is an `Equatable` struct of an
`ActivityMode` defaulting to `.active`, a `stayDown` Boolean defaulting to
false, and a `RoamMode` defaulting to `.wander`.

`MoodSettings` loads and saves a `Mood` through `UserDefaults` under the keys
`mood.activity`, `mood.stayDown`, and `mood.roam`. A missing key yields the
default. An unrecognized raw string yields the default rather than a failure:
a hand-edited or downgraded preferences file must never prevent the dog from
starting. The defaults deliberately differ from the `JumbiniSettings`
convention of defaulting every switch to true, because two of these three
switches are off in Jumba's existing personality.

`MoodMenuState` is a pure description of the submenu: the title and checked
state of each item, derived from a `Mood`. It contains no AppKit types and is
tested without them, following `TidyMenuState`.

### Autonomy odds

`DogBrain.leaveIdleForAutonomy` currently compares one random roll against
seven bands, each written as an inline cumulative sum one term longer than the
last. Mode multipliers cannot be layered onto that safely. Multiplying several
bands at once can drive the total past 1.0, at which point the final band —
window climbing — silently stops firing forever, and nothing in the code or the
tests would report it.

A new `AutonomyOdds` value type therefore owns the band arithmetic. It is
constructed from a `BrainTuning`, a `Mood`, and the two feature switches
(`poopEnabled`, `windowClimbingEnabled`), and it exposes the cumulative
thresholds the roll is compared against. Three properties hold.

- Feature switches zero their band, as they do today.
- The bands are computed by multiplying the baseline tuning by the mode's
  scale factors and, in follow mode, doubling the sniff band.
- If the bands would total more than `1 - wanderShare`, every band is scaled
  down proportionally so that plain wandering retains at least `wanderShare`
  of the roll. `wanderShare` is a new `BrainTuning` knob, default 0.1.

The proportional clamp preserves the relative shape of a mode under every
combination of switches, and it is what keeps window climbing reachable when
Very Active and Follow are on together.

### Activity multipliers

`ActivityMode` exposes the scale factors below. `.active` is the identity in
every column, so an existing install, a default launch, and every existing test
behave exactly as they do today.

| Scaled quantity | Very Active | Active | Sleepy |
| --- | --- | --- | --- |
| `zoomiesChance` | 4.5 | 1.0 | 0.125 |
| `sleepChance` | 0.2 | 1.0 | 3.0 |
| `sniffChance` | 1.5 | 1.0 | 0.5 |
| `flourishChance` | 1.5 | 1.0 | 0.5 |
| `idleDuration` | 0.5 | 1.0 | 2.0 |
| `zoomiesDuration` | 1.5 | 1.0 | 1.0 |

Against the shipping baseline those factors produce a 36 percent zoomies roll
and a 3 percent nap roll in Very Active, and a 1 percent zoomies roll and a 45
percent nap roll in Sleepy. Very Active shortens the pause between activities
to 1 to 2.5 seconds and lengthens a zoomies burst to 15 seconds; Sleepy
lengthens the pause to 4 to 10 seconds.

`hunchChance`, `barkAtNothingChance`, and `perchChance` are not scaled by mode.
Each is governed by its own feature switch and reads as a distinct habit rather
than a level of energy.

`zoomiesDuration` is scaled wherever zoomies begin, which includes the
`fansUp` system reaction and the explicit Zoomies command, not only the
autonomous roll. A Very Active dog has longer zoomies for every reason he gets
them.

### Stay Lying Down

`mood.stayDown` changes where idle leads. When the idle timer fires and the
hold is on, the brain settles him instead of rolling for an activity: he walks
to his bed and lies down when he has one, and lies down where he stands when he
does not. This reuses the existing `.lieDown` command path.

While the hold is on, `.lyingDown` carries no deadline. A single new private
helper returns `nil` when the hold is on and `now + tuning.lieTimeout`
otherwise, and every site that currently sets the lie timeout calls it. Without
this, the 90-second timeout would expire and he would visibly stand up and flop
down again every 90 seconds.

The hold is soft. Treats, pets, provocations, tricks, toys, fetch, tug,
pickups, and every menu command interrupt it exactly as they interrupt lying
down today, and the next idle returns him to the floor. A "Sit" command issued
while the hold is on holds the sit for its full `sitTimeout`; the hold applies
at the idle that follows, not instantly.

`setMood(_:at:)` reconciles a change immediately, following the established
shape of `disableBathroomBreaks(at:)` and `disableSystemReactions(at:)`.

- Turning the hold on when he is already lying down clears the lie deadline and
  changes nothing else. He is where the hold wants him; re-entering the state
  would restart the animation for no reason.
- Turning the hold on settles him now if he is idle, wandering, or sitting.
  This set is deliberately narrower than the brain's existing `isCalm`, which
  also admits `.lyingDown`; that case is handled above. In any other state the
  hold takes effect at the next idle. The rule exists so that changing a menu
  setting can never pull him off a window title bar, out of the user's hands,
  or off a chase.
- Turning the hold off gets him up whenever `restReason` is nil and he is
  lying down or walking to his bed to lie down. A nap or lie-down caused by a
  system signal is left alone: `restReason` marks it, and its own wake-up
  signal is what gets him back up, matching how `riseFromRest` already
  distinguishes causes. A lie-down caused by an explicit `.lieDown` command is
  NOT left alone, and can't be — `handleCommand` clears `restReason` on every
  command, so a command-caused lie looks exactly like a hold-caused one by the
  time `setMood` sees it. That turns out to be the right call on its own
  terms anyway: under the hold, a command lie has no clock either (the hold
  suppresses `lieTimeout` the same way for both), so leaving it in place would
  strand him with nothing left to end it. Getting him up is the only choice
  that doesn't.
- A change to activity or roam has no immediate effect. Both alter the next
  roll only. Zoomies already in progress end on their own schedule.

The hold does not set `restReason`. It is user-caused, so the system wake-up
signals must not act on it.

### Follow My Cursor

`DogBrain` gains `var cursorPosition: CGPoint?`, kept current by the scene each
frame in `update(_:)` beside `bounds` and `position`. `PetScene` already
computes the cursor's scene location every frame for hover detection, so the
value is free. It is `nil` when the location is unknown.

Follow mode replaces the wander target, not the walk. When the idle roll falls
through to wandering, the target is a point on the line from the dog to the
cursor, stopping `followStandoff` short of it. When he is already within that
standoff, the target is a random point within `followMill` of his current
position, so he mills about beside the pointer instead of crossing the screen
to reach a pointer that is already next to him. Both are new `BrainTuning`
knobs, defaulting to 120 and 90 points respectively.

Every target passes through `onSolidGround` and the existing margin clamp, as
all computed targets in the brain already do. With `cursorPosition` nil, follow
mode falls back to `wanderTarget()` unchanged.

Because the walk is an ordinary `.moveTo` toward a fixed point, a cursor that
moves mid-walk is not chased; he arrives, idles, and re-aims on the next roll.
That laziness is the intended character. The per-frame chase already exists as
the sniff, stalk, and pounce hunt, and follow mode doubles the sniff band so
that hunt becomes his common idle activity rather than an occasional one.

Follow mode suppresses nothing else. Naps, spins, bathroom breaks, barking,
window climbing, fetch, and treats are unaffected.

### Speech bubbles

A new file, `Sources/Jumbini/SpeechBubble.swift`, defines an `SKNode`
subclass built from a rounded `SKShapeNode` with a small downward tail and a
wrapping `SKLabelNode`. The bubble sizes itself to its text, wraps to at most
two lines at a maximum width of 180 points, and uses the rounded system font
with a Menlo fallback, matching the existing Jumbini Cam caption helper. No
pixel font is bundled in the app and none is added.

Choreography matches `EmoteBubble`: pop in over 0.12 seconds while scaling up
over 0.16, hold, then drift up 34 points and fade over 0.5 seconds before
removing itself. The hold is `1.4 + 0.05 × characters` seconds, capped at 3.2,
so a longer caption stays readable.

`PetScene` positions it at the anchor `showEmote` uses — 30 points right of the
dog and 14 above his head — clamped horizontally so a wide bubble near a screen
edge stays on screen. It renders at `zPosition` 21, and the trick badge
continues to rise on the opposite side.

`EmoteBubble` is unchanged and remains in use for the `icon_question` shrug
shown when a command is refused, which is not a Mac-aware reaction.

The caption is chosen in `PetScene.receive(_:)`. That is the only place that
still knows a signal's name — `DogEffect` is deliberately signal-agnostic — so
captioning there keeps `DogBrain` free of user-facing text. The existing
`emoteIcon(for:)` mapping is replaced by a caption mapping over an exhaustive
switch on `SystemSignal`, which makes a future signal a compile error rather
than a silent omission.

| Signal | He acts on it | He is busy |
| --- | --- | --- |
| `buildFinished` | Build's done! | Busy — one sec! |
| `fansUp` | Your Mac's hot! | Busy — one sec! |
| `batteryLow` | Battery's low… | Busy — one sec! |
| `dndOn` | Focus on. Shh. | Busy — one sec! |
| `idleBegan` | You've been gone a while… | Busy — one sec! |
| `idleEnded` | You're back! | silent |
| `batteryNormal` | Charging again! | silent |
| `dndOff` | Focus off! | silent |

The busy column is the existing deferred-signal case, shown today as a gear
icon. The three all-clear signals stay silent unless they actually roused him,
which preserves today's behavior.

### Menu

Jumba's right-click menu gains one submenu, placed after the command list and
the separator and before Tricks.

```
Mood ▸  Very Active
        Active            •
        Sleepy
        ──────────
        Stay Lying Down   ☐
        Follow My Cursor  ☐
```

The three activity items are mutually exclusive and show a checkmark on the
active one. The two toggles show their own checkmarks. "Stay Lying Down" is
named to distinguish the persistent hold from the momentary "Lie Down" command
already in the menu above it.

Choosing any item updates the scene's `Mood`, saves it through `MoodSettings`,
and calls `brain.setMood(_:at:)`, applying the effects that come back. The
scene loads the saved mood at initialization and applies it to the brain there
too.

## Testing

Brain behavior is tested through `DogBrain` with a seeded `SplitMix64` and
injected tuning, as `DogBrainTests` already does.

- Active is the identity: with the default mood, the existing suite passes
  unchanged. A dedicated test asserts that an explicitly `.active` mood
  produces the same state sequence as no mood change at all.
- Each mode shifts outcomes: at a fixed seed and a roll value chosen to land
  inside a band, Very Active reaches zoomies where Active wanders, and Sleepy
  reaches sleep where Active wanders.
- Very Active lengthens a zoomies burst, for the autonomous roll and for the
  `fansUp` signal.
- The clamp holds: with Very Active and Follow both on and every feature switch
  enabled, the bands total no more than `1 - wanderShare`, and the window-climb
  band is still reachable.
- The hold routes idle to lying down, with no deadline set, and reaches the bed
  when one exists.
- The hold is soft: a treat dropped during the hold interrupts it, he eats, and
  the next idle returns him to lying down.
- Turning the hold on while he is perched does not change his state; turning it
  on while he is idle settles him.
- Turning the hold off while he is held down gets him up, and turning it off
  during a system-caused nap leaves that nap alone.
- Follow aims within `followStandoff` of the cursor, mills within `followMill`
  when the cursor is already close, keeps every target on solid ground, and
  falls back to wandering when `cursorPosition` is nil.

`MoodTests` covers `MoodSettings` defaults, a save and load round trip, and an
unrecognized raw string falling back to the default; and `MoodMenuState`
titles and checkmarks for each mood. Neither needs AppKit.

`SpeechBubbleTests` asserts that every `SystemSignal` maps to a non-empty
caption in both the acted and busy columns where one is specified, that the
three all-clear signals are silent when they did not rouse him, and that the
hold duration grows with length and respects its cap.

## Files

New: `Sources/Jumbini/Mood.swift`, `Sources/Jumbini/SpeechBubble.swift`,
`Tests/JumbiniTests/MoodTests.swift`,
`Tests/JumbiniTests/SpeechBubbleTests.swift`.

Changed: `Sources/Jumbini/DogBrain.swift` for the mood property, the cursor
position, `setMood(_:at:)`, the `AutonomyOdds` extraction, the roam target, and
the lie deadline helper; `Sources/Jumbini/PetScene.swift` for the submenu, the
persistence, the per-frame cursor feed, and the captions;
`Tests/JumbiniTests/DogBrainTests.swift`; and `README.md`, whose behavior
tables describe the odds, the Mac-aware reactions, and the right-click command
list that this work changes.

Untouched: `JumbiniSettings`, `SettingsPanel`, `AppDelegate`, `EmoteBubble`.
