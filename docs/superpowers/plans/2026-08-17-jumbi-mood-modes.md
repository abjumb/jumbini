# Mood Modes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give Jumba three persistent personality switches in his right-click
menu — an activity mode, a stay-lying-down hold, and a follow-the-cursor roam
mode — and replace the icon on every Mac-aware reaction with a spoken caption.

**Architecture:** `DogBrain` stays a pure state machine. A new `Mood` value type
is kept current on the brain exactly as `bounds`, `position`, and `surfaces`
already are; the scene owns the menu, the `UserDefaults` persistence, and the
pixels. The seven autonomy bands move out of `leaveIdleForAutonomy` into an
`AutonomyOdds` value type that applies the mode multipliers and clamps the total
so plain wandering always keeps a share of the roll.

**Tech Stack:** Swift 5 language mode, SwiftPM (`swift build`, `swift test`),
swift-testing (`@Test` / `#expect`), SpriteKit, AppKit.

**Spec:** `docs/superpowers/specs/2026-08-17-jumbi-mood-modes-design.md`

## Global Constraints

- `DogBrain.swift` must not import SpriteKit or AppKit. It imports `Foundation`
  and `CoreGraphics` only. No user-facing text belongs in it.
- `ActivityMode.active` is the identity in every multiplier column. A default
  install, a default launch, and every existing test must behave exactly as they
  do today. The existing suite is the regression guard — it must pass unchanged
  after every task.
- `JumbiniSettings`, `SettingsPanel`, `AppDelegate`, and `EmoteBubble` are not
  modified by this plan. `Mood` is deliberately a separate struct from
  `JumbiniSettings`, because `SettingsPanel.featureChanged()` rebuilds
  `JumbiniSettings` from its three checkboxes and would reset any mood field
  added there.
- `UserDefaults` keys, exactly: `mood.activity`, `mood.stayDown`, `mood.roam`.
- Menu copy, exactly: `Mood`, `Very Active`, `Active`, `Sleepy`,
  `Stay Lying Down`, `Follow My Cursor`.
- Caption copy is fixed by the spec's table and is reproduced verbatim in Task 6.
- New `BrainTuning` knob defaults, exactly: `wanderShare = 0.1`,
  `followStandoff = 120`, `followMill = 90`.
- Mood defaults, exactly: `activity = .active`, `stayDown = false`,
  `roam = .wander`. Note this deliberately breaks the `JumbiniSettings`
  convention of defaulting every switch to `true`.
- Build with `swift build`; test with `swift test`. Both must be clean before
  every commit. `swift build` emits two `ld: warning: search path ... not found`
  lines on this machine — those are pre-existing and are not failures.

---

## File Structure

**New files**

| File | Responsibility |
| --- | --- |
| `Sources/Jumbini/Mood.swift` | `ActivityMode`, `RoamMode`, `Mood`, `MoodSettings`, `MoodMenuState`. No SpriteKit, no AppKit. |
| `Sources/Jumbini/SpeechBubble.swift` | The `SKNode` bubble, plus `ReactionCaption` — the signal→text mapping. |
| `Tests/JumbiniTests/MoodTests.swift` | `MoodSettings` round trip and defaults; `MoodMenuState` titles and checkmarks. |
| `Tests/JumbiniTests/SpeechBubbleTests.swift` | Caption coverage for every `SystemSignal`; hold duration scaling. |

**Modified files**

| File | Change |
| --- | --- |
| `Sources/Jumbini/DogBrain.swift` | `SystemSignal: CaseIterable`; three new `BrainTuning` knobs; `AutonomyOdds`; `var mood`; `var cursorPosition`; `setMood(_:at:)`; `idlePause()`, `zoomiesTimeout()`, `lieDeadline(at:)`, `settle(at:)`, `roamTarget()`, `clampToBounds(_:)`. |
| `Sources/Jumbini/PetScene.swift` | Mood submenu, mood persistence, per-frame cursor feed, speech captions replacing `emoteIcon(for:)`. |
| `Tests/JumbiniTests/DogBrainTests.swift` | Mood behavior tests, added by Tasks 2–5. |
| `README.md` | The three behavior tables the spec names. |

**Task order and why:** Task 1 is standalone data. Task 2 is a behavior-preserving
refactor that must land before any multiplier can be applied safely. Tasks 3, 4,
and 5 are the three brain behaviors, each independently testable. Task 6 is the
bubble end to end. Task 7 is the AppKit glue that makes Tasks 1–5 reachable by a
user. Task 8 is documentation.

---

### Task 1: Mood value types, persistence, and menu state

Pure data. No brain and no scene changes, so nothing user-visible changes yet.

**Files:**
- Create: `Sources/Jumbini/Mood.swift`
- Test: `Tests/JumbiniTests/MoodTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces:
  - `enum ActivityMode: String, CaseIterable, Equatable { case veryActive, active, sleepy }`
    with `Double` properties `sleepScale`, `flourishScale`, `zoomiesScale`,
    `sniffScale`, `idleScale`, `zoomiesDurationScale`, and `var menuTitle: String`.
  - `enum RoamMode: String, Equatable { case wander, follow }`
  - `struct Mood: Equatable` with `var activity: ActivityMode`, `var stayDown: Bool`,
    `var roam: RoamMode`, and a memberwise `init(activity:stayDown:roam:)` where
    every parameter has the default value.
  - `enum MoodSettings` with
    `static func load(from: UserDefaults = .standard) -> Mood` and
    `static func save(_ mood: Mood, to: UserDefaults = .standard)`.
  - `struct MoodMenuState: Equatable` with `init(mood: Mood)`,
    `static let submenuTitle: String`, nested
    `struct Item: Equatable { var title: String; var isChecked: Bool }`,
    and `var activityItems: [Item]`, `var stayDownItem: Item`, `var followItem: Item`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/JumbiniTests/MoodTests.swift`:

```swift
import Foundation
import Testing
@testable import Jumbini

private func isolatedDefaults() -> (UserDefaults, String) {
    let name = "JumbiniTests.mood.\(UUID().uuidString)"
    return (UserDefaults(suiteName: name)!, name)
}

// MARK: - Persistence

@Test func aFreshInstallGetsJumbasExistingPersonality() {
    let (defaults, name) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }

    // Deliberately NOT the JumbiniSettings "everything on" convention: two of
    // these three switches are off in the personality that ships today.
    #expect(MoodSettings.load(from: defaults) == Mood())
    #expect(Mood().activity == .active)
    #expect(Mood().stayDown == false)
    #expect(Mood().roam == .wander)
}

@Test func moodRoundTripsThroughDefaults() {
    let (defaults, name) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    let expected = Mood(activity: .sleepy, stayDown: true, roam: .follow)

    MoodSettings.save(expected, to: defaults)

    #expect(MoodSettings.load(from: defaults) == expected)
}

@Test func everyActivityModeSurvivesTheRoundTrip() {
    for mode in ActivityMode.allCases {
        let (defaults, name) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        MoodSettings.save(Mood(activity: mode), to: defaults)

        #expect(MoodSettings.load(from: defaults).activity == mode)
    }
}

@Test func anUnreadableStoredModeFallsBackToTheDefault() {
    let (defaults, name) = isolatedDefaults()
    defer { defaults.removePersistentDomain(forName: name) }
    // A hand-edited or downgraded preferences file must never stop the dog.
    defaults.set("hyperactive", forKey: "mood.activity")
    defaults.set("teleport", forKey: "mood.roam")

    let mood = MoodSettings.load(from: defaults)

    #expect(mood.activity == .active)
    #expect(mood.roam == .wander)
}

// MARK: - Multipliers

@Test func activeIsTheIdentityInEveryColumn() {
    let active = ActivityMode.active
    #expect(active.sleepScale == 1)
    #expect(active.flourishScale == 1)
    #expect(active.zoomiesScale == 1)
    #expect(active.sniffScale == 1)
    #expect(active.idleScale == 1)
    #expect(active.zoomiesDurationScale == 1)
}

@Test func veryActiveIsHyperAndSleepyIsNot() {
    #expect(ActivityMode.veryActive.zoomiesScale > ActivityMode.active.zoomiesScale)
    #expect(ActivityMode.sleepy.zoomiesScale < ActivityMode.active.zoomiesScale)
    #expect(ActivityMode.veryActive.sleepScale < ActivityMode.active.sleepScale)
    #expect(ActivityMode.sleepy.sleepScale > ActivityMode.active.sleepScale)
    // Shorter pauses when hyper, longer when sleepy.
    #expect(ActivityMode.veryActive.idleScale < 1)
    #expect(ActivityMode.sleepy.idleScale > 1)
}

@Test func theShippingBaselineProducesTheDesignedOdds() {
    let tuning = BrainTuning()
    #expect(abs(tuning.zoomiesChance * ActivityMode.veryActive.zoomiesScale - 0.36) < 0.0001)
    #expect(abs(tuning.sleepChance * ActivityMode.veryActive.sleepScale - 0.03) < 0.0001)
    #expect(abs(tuning.zoomiesChance * ActivityMode.sleepy.zoomiesScale - 0.01) < 0.0001)
    #expect(abs(tuning.sleepChance * ActivityMode.sleepy.sleepScale - 0.45) < 0.0001)
}

// MARK: - Menu state

@Test func theMenuChecksExactlyTheChosenActivity() {
    let state = MoodMenuState(mood: Mood(activity: .sleepy))

    #expect(state.activityItems.map(\.title) == ["Very Active", "Active", "Sleepy"])
    #expect(state.activityItems.filter(\.isChecked).map(\.title) == ["Sleepy"])
}

@Test func theTogglesReportTheirOwnState() {
    let off = MoodMenuState(mood: Mood())
    #expect(off.stayDownItem == MoodMenuState.Item(title: "Stay Lying Down", isChecked: false))
    #expect(off.followItem == MoodMenuState.Item(title: "Follow My Cursor", isChecked: false))

    let on = MoodMenuState(mood: Mood(stayDown: true, roam: .follow))
    #expect(on.stayDownItem.isChecked)
    #expect(on.followItem.isChecked)
    // The hold is named apart from the momentary "Lie Down" command above it.
    #expect(on.stayDownItem.title != "Lie Down")
}

@Test func theSubmenuIsCalledMood() {
    #expect(MoodMenuState.submenuTitle == "Mood")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MoodTests`
Expected: FAIL to compile — `cannot find 'Mood' in scope`, `cannot find
'MoodSettings' in scope`, `cannot find 'ActivityMode' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Jumbini/Mood.swift`:

```swift
import Foundation

/// How much energy Jumba has, as multipliers over `BrainTuning`.
///
/// `.active` is the identity in every column. That is the point: an existing
/// install, a default launch, and every test written before moods existed all
/// take arithmetic that is bit-for-bit what it always was.
enum ActivityMode: String, CaseIterable, Equatable {
    case veryActive, active, sleepy

    /// Multiplier on `BrainTuning.sleepChance`.
    var sleepScale: Double {
        switch self {
        case .veryActive: 0.2
        case .active: 1
        case .sleepy: 3
        }
    }

    /// Multiplier on `BrainTuning.flourishChance` (the idle spin).
    var flourishScale: Double {
        switch self {
        case .veryActive: 1.5
        case .active: 1
        case .sleepy: 0.5
        }
    }

    /// Multiplier on `BrainTuning.zoomiesChance`. Very Active is defined by
    /// this number: 8% becomes 36%, which is what "a lot of zoomies" means.
    var zoomiesScale: Double {
        switch self {
        case .veryActive: 4.5
        case .active: 1
        case .sleepy: 0.125
        }
    }

    /// Multiplier on `BrainTuning.sniffChance` (the cursor hunt).
    var sniffScale: Double {
        switch self {
        case .veryActive: 1.5
        case .active: 1
        case .sleepy: 0.5
        }
    }

    /// Multiplier on the pause between activities. Below 1 means he gets bored
    /// sooner and therefore does more things per minute.
    var idleScale: Double {
        switch self {
        case .veryActive: 0.5
        case .active: 1
        case .sleepy: 2
        }
    }

    /// Multiplier on how long a zoomies burst lasts, wherever it started —
    /// the autonomous roll, the hot-fans reaction, or the explicit command.
    var zoomiesDurationScale: Double {
        switch self {
        case .veryActive: 1.5
        case .active: 1
        case .sleepy: 1
        }
    }

    var menuTitle: String {
        switch self {
        case .veryActive: "Very Active"
        case .active: "Active"
        case .sleepy: "Sleepy"
        }
    }
}

/// What an ordinary walk aims at: a random spot, or your cursor.
enum RoamMode: String, Equatable {
    case wander, follow
}

/// The three persistent switches from Jumba's right-click menu.
///
/// Deliberately NOT part of `JumbiniSettings`, and not for tidiness:
/// `SettingsPanel.featureChanged()` builds a fresh `JumbiniSettings` out of its
/// three checkboxes, so a mood field living there would be reset to its default
/// every time somebody toggled any Settings checkbox. Separate structs with
/// separate owners make that bug impossible instead of merely avoided.
struct Mood: Equatable {
    var activity: ActivityMode
    var stayDown: Bool
    var roam: RoamMode

    init(
        activity: ActivityMode = .active,
        stayDown: Bool = false,
        roam: RoamMode = .wander
    ) {
        self.activity = activity
        self.stayDown = stayDown
        self.roam = roam
    }
}

/// `UserDefaults` storage for a `Mood`.
///
/// Unlike `JumbiniSettings`, a missing key means the DEFAULT rather than
/// `true`: two of these three switches are off in the personality that ships
/// today, so an upgrading user must find Jumba exactly as they left him.
/// An unrecognised raw string also means the default — a hand-edited or
/// downgraded preferences file must never be able to stop the dog starting.
enum MoodSettings {
    private enum Key {
        static let activity = "mood.activity"
        static let stayDown = "mood.stayDown"
        static let roam = "mood.roam"
    }

    static func load(from defaults: UserDefaults = .standard) -> Mood {
        var mood = Mood()
        if let raw = defaults.string(forKey: Key.activity),
           let activity = ActivityMode(rawValue: raw) {
            mood.activity = activity
        }
        mood.stayDown = (defaults.object(forKey: Key.stayDown) as? Bool) ?? false
        if let raw = defaults.string(forKey: Key.roam),
           let roam = RoamMode(rawValue: raw) {
            mood.roam = roam
        }
        return mood
    }

    static func save(_ mood: Mood, to defaults: UserDefaults = .standard) {
        defaults.set(mood.activity.rawValue, forKey: Key.activity)
        defaults.set(mood.stayDown, forKey: Key.stayDown)
        defaults.set(mood.roam.rawValue, forKey: Key.roam)
    }
}

/// What the Mood submenu offers, as data.
///
/// Which item carries a checkmark is a decision, and decisions do not need
/// AppKit to be made or to be checked. Follows `TidyMenuState`.
struct MoodMenuState: Equatable {
    struct Item: Equatable {
        var title: String
        var isChecked: Bool
    }

    static let submenuTitle = "Mood"

    var mood: Mood

    init(mood: Mood) {
        self.mood = mood
    }

    /// In declaration order — most energetic first, which is also menu order.
    var activityItems: [Item] {
        ActivityMode.allCases.map {
            Item(title: $0.menuTitle, isChecked: $0 == mood.activity)
        }
    }

    /// Named apart from the momentary "Lie Down" command sitting above it in
    /// the same menu: one is an order, this one is a hold.
    var stayDownItem: Item {
        Item(title: "Stay Lying Down", isChecked: mood.stayDown)
    }

    var followItem: Item {
        Item(title: "Follow My Cursor", isChecked: mood.roam == .follow)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MoodTests`
Expected: PASS, 9 tests.

Then run the whole suite to confirm nothing else moved:
Run: `swift test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/Jumbini/Mood.swift Tests/JumbiniTests/MoodTests.swift
git commit -m "Add the Mood value type, its storage, and its menu state

Three persistent switches — activity, the lie-down hold, and roam mode —
as data only. Nothing reads them yet.

Kept apart from JumbiniSettings on purpose: SettingsPanel.featureChanged()
rebuilds that struct from its three checkboxes, so a mood field there would
be reset whenever a user toggled any Settings checkbox.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Extract `AutonomyOdds` — behavior-preserving

`leaveIdleForAutonomy` compares one roll against seven bands written as inline
cumulative sums, each one term longer than the last. Multipliers cannot be
layered onto that safely: several scaled bands can total past 1.0, at which
point the last band — window climbing — silently stops firing forever, and
nothing reports it. This task moves the arithmetic into a value type with a
clamp, and changes no behavior at all.

**Files:**
- Modify: `Sources/Jumbini/DogBrain.swift` — add `wanderShare` to `BrainTuning`
  (after `var wanderMargin` at line 196), add `struct AutonomyOdds` immediately
  after the `BrainTuning` struct closes, and rewrite `leaveIdleForAutonomy`
  (lines 1003–1068).
- Test: `Tests/JumbiniTests/DogBrainTests.swift` (append)

**Interfaces:**
- Consumes: `BrainTuning` (Task 0 / existing).
- Produces:
  - `BrainTuning.wanderShare: Double` (default `0.1`).
  - `struct AutonomyOdds` with
    `init(tuning: BrainTuning, poopEnabled: Bool, windowClimbingEnabled: Bool)`
    and the cumulative `Double` thresholds
    `sleepBand`, `flourishBand`, `zoomiesBand`, `sniffBand`, `hunchBand`,
    `barkBand`, `perchBand`. Task 3 adds a `mood:` parameter to this init.
- Behavior contract: with the shipping defaults the bands total 0.60 against a
  ceiling of 0.90, so the clamp is inert and every threshold is computed by the
  same left-to-right sum as today. The refactor is bit-for-bit **in the app**.

**Read this before you start — the clamp changes what the test helper means.**

About forty existing tests force a band to certainty (`$0.hunchChance = 1`,
`$0.sniffChance = 1.0`, `makePercher`'s `perchChance = 1`, …) and rely on
"a chance of 1.0 always fires". A ceiling of `1 - 0.1` turns every one of those
into a 90% band, and the suite starts failing a tenth of the time with no
explanation. That is not acceptable collateral, and it is not a reason to drop
the clamp either — the product default of 0.1 is what keeps window climbing
reachable under Very Active + Follow.

The resolution is Step 5 below: `makeBrain` opts out with `wanderShare = 0`, so
a single band at 1.0 gives `total == ceiling == 1.0`, the clamp stays inert, and
those tests are bit-for-bit unchanged. Tests that want to exercise the clamp
build a `BrainTuning()` directly and get the 0.1 default. One test —
`thePerchBandSitsBeneathTheOlderAutonomyBands` — sets *two* bands to 1.0 for a
total of 2.0, which no ceiling can leave alone, and is rewritten in Step 6.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/JumbiniTests/DogBrainTests.swift`:

```swift
// MARK: - Autonomy odds (the seven idle bands)

@Test func theShippingBandsAreOrderedAndUnclamped() {
    let odds = AutonomyOdds(
        tuning: BrainTuning(), poopEnabled: true, windowClimbingEnabled: true
    )
    let tuning = BrainTuning()

    // The cumulative thresholds are exactly today's inline sums.
    #expect(odds.sleepBand == tuning.sleepChance)
    #expect(odds.flourishBand == tuning.sleepChance + tuning.flourishChance)
    #expect(odds.zoomiesBand
        == tuning.sleepChance + tuning.flourishChance + tuning.zoomiesChance)
    #expect(odds.sniffBand == tuning.sleepChance + tuning.flourishChance
        + tuning.zoomiesChance + tuning.sniffChance)
    #expect(odds.hunchBand == tuning.sleepChance + tuning.flourishChance
        + tuning.zoomiesChance + tuning.sniffChance + tuning.hunchChance)
    #expect(odds.barkBand == tuning.sleepChance + tuning.flourishChance
        + tuning.zoomiesChance + tuning.sniffChance + tuning.hunchChance
        + tuning.barkAtNothingChance)
    #expect(odds.perchBand == tuning.sleepChance + tuning.flourishChance
        + tuning.zoomiesChance + tuning.sniffChance + tuning.hunchChance
        + tuning.barkAtNothingChance + tuning.perchChance)
}

@Test func aDisabledFeatureZeroesItsBandWithoutMovingTheOthers() {
    let tuning = BrainTuning()
    let noPoop = AutonomyOdds(
        tuning: tuning, poopEnabled: false, windowClimbingEnabled: true
    )
    #expect(noPoop.hunchBand == noPoop.sniffBand, "the hunch band is closed")
    #expect(noPoop.sleepBand == tuning.sleepChance, "bands above it are untouched")

    let noClimb = AutonomyOdds(
        tuning: tuning, poopEnabled: true, windowClimbingEnabled: false
    )
    #expect(noClimb.perchBand == noClimb.barkBand, "the climb band is closed")
}

@Test func wanderingAlwaysKeepsItsShareOfTheRoll() {
    // Absurd tuning: every band maxed. Without the clamp the total would be
    // 7.0 and the last band would be unreachable forever.
    var tuning = BrainTuning()
    tuning.sleepChance = 1
    tuning.flourishChance = 1
    tuning.zoomiesChance = 1
    tuning.sniffChance = 1
    tuning.hunchChance = 1
    tuning.barkAtNothingChance = 1
    tuning.perchChance = 1

    let odds = AutonomyOdds(
        tuning: tuning, poopEnabled: true, windowClimbingEnabled: true
    )

    #expect(odds.perchBand <= 1 - tuning.wanderShare + 0.0001)
    #expect(odds.perchBand > odds.barkBand, "the climb band is still reachable")
    #expect(odds.sleepBand > 0)
}

@Test func theClampKeepsEveryBandInProportion() {
    var tuning = BrainTuning()
    tuning.sleepChance = 0.5
    tuning.zoomiesChance = 1.0 // twice the sleep band

    let odds = AutonomyOdds(
        tuning: tuning, poopEnabled: false, windowClimbingEnabled: false
    )
    let sleep = odds.sleepBand
    let zoomies = odds.zoomiesBand - odds.flourishBand

    #expect(abs(zoomies / sleep - 2) < 0.0001, "shape survives the scaling")
}

@Test func zeroedBandsDoNotDivideByZero() {
    var tuning = BrainTuning()
    tuning.sleepChance = 0
    tuning.flourishChance = 0
    tuning.zoomiesChance = 0
    tuning.sniffChance = 0
    tuning.hunchChance = 0
    tuning.barkAtNothingChance = 0
    tuning.perchChance = 0

    let odds = AutonomyOdds(
        tuning: tuning, poopEnabled: true, windowClimbingEnabled: true
    )

    #expect(odds.perchBand == 0, "a dog with nothing to do just wanders")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DogBrainTests`
Expected: FAIL to compile — `cannot find 'AutonomyOdds' in scope` and
`value of type 'BrainTuning' has no member 'wanderShare'`.

- [ ] **Step 3: Add the tuning knob**

In `Sources/Jumbini/DogBrain.swift`, immediately after
`var wanderMargin: CGFloat = 60` (line 196), insert:

```swift
    /// The slice of every idle roll that plain wandering keeps no matter what.
    /// The autonomy bands are scaled down proportionally if they would eat
    /// into it — see `AutonomyOdds`.
    var wanderShare: Double = 0.1
```

- [ ] **Step 4: Add `AutonomyOdds`**

In `Sources/Jumbini/DogBrain.swift`, immediately after the closing brace of
`struct BrainTuning`, insert:

```swift
/// The cumulative thresholds one idle roll is compared against.
///
/// This used to be seven inline sums inside `leaveIdleForAutonomy`, each a term
/// longer than the last. That was survivable while the numbers were constants
/// and fatal the moment they could be scaled: several bands multiplied at once
/// can total past 1.0, and then the LAST band — window climbing, the rarest and
/// most delightful thing he does — silently never fires again. Nothing in the
/// code or the tests would say a word about it.
///
/// So the arithmetic lives here, where the invariant can be stated and tested:
/// whatever the tuning and whatever the switches, plain wandering keeps at
/// least `tuning.wanderShare` of the roll, and every band stays in proportion.
struct AutonomyOdds {
    /// Cumulative thresholds, low to high. A roll below `sleepBand` naps; a
    /// roll below `flourishBand` but not `sleepBand` spins; and so on.
    let sleepBand: Double
    let flourishBand: Double
    let zoomiesBand: Double
    let sniffBand: Double
    let hunchBand: Double
    let barkBand: Double
    let perchBand: Double

    init(tuning: BrainTuning, poopEnabled: Bool, windowClimbingEnabled: Bool) {
        // A feature switched off closes its band; the bands around it do not
        // move, exactly as before.
        let widths = [
            tuning.sleepChance,
            tuning.flourishChance,
            tuning.zoomiesChance,
            tuning.sniffChance,
            poopEnabled ? tuning.hunchChance : 0,
            tuning.barkAtNothingChance,
            windowClimbingEnabled ? tuning.perchChance : 0,
        ]
        let total = widths.reduce(0, +)
        let ceiling = max(0, 1 - tuning.wanderShare)
        // `total > ceiling` is also the divide-by-zero guard: a zero total can
        // never exceed a non-negative ceiling.
        let scale = total > ceiling ? ceiling / total : 1

        // Summed left to right, in the same order as the code this replaces,
        // so the un-clamped case (scale == 1) is bit-for-bit what it was.
        sleepBand = widths[0] * scale
        flourishBand = sleepBand + widths[1] * scale
        zoomiesBand = flourishBand + widths[2] * scale
        sniffBand = zoomiesBand + widths[3] * scale
        hunchBand = sniffBand + widths[4] * scale
        barkBand = hunchBand + widths[5] * scale
        perchBand = barkBand + widths[6] * scale
    }
}
```

- [ ] **Step 5: Rewrite `leaveIdleForAutonomy` to read the bands**

Replace the whole body of `leaveIdleForAutonomy` (lines 1003–1068 — from
`let roll = Double.random` down to and including the final
`return [.play(.walk), .moveTo(wanderTarget(), speed: tuning.walkSpeed)]`) with:

```swift
        let roll = Double.random(in: 0..<1, using: &rng)
        let odds = AutonomyOdds(
            tuning: tuning,
            poopEnabled: poopEnabled,
            windowClimbingEnabled: windowClimbingEnabled
        )
        if roll < odds.sleepBand {
            if let bed = bedPosition {
                // Naps happen in the bed when he has one.
                state = .goingToBed(.sleep)
                deadline = nil
                return [.play(.walk), .moveTo(bed, speed: tuning.walkSpeed)]
            }
            state = .sleeping
            deadline = now + random(in: tuning.sleepDuration)
            return [.play(.sleep)]
        }
        if roll < odds.flourishBand {
            state = .spinning
            deadline = now + tuning.spinDuration
            return [.play(.spin)]
        }
        if roll < odds.zoomiesBand {
            state = .zoomies
            deadline = now + tuning.zoomiesDuration
            return [.play(.run), .startZoomies]
        }
        if roll < odds.sniffBand {
            state = .sniffingMouse
            deadline = now + random(in: tuning.sniffDuration)
            return [.play(.walk), .startSniffing]
        }
        if roll < odds.hunchBand {
            state = .hunching
            deadline = now + tuning.hunchDuration
            return [.play(.hunch)]
        }
        if roll < odds.barkBand {
            // Something at the screen edge (the Dock? his reflection?) needs
            // telling off. A small step toward the edge turns him to face it;
            // .arrived from that hop is ignored while barking.
            // The cooldown is a property of barking, not of one trigger: a
            // provoked bark must silence this band too, or he double-barks.
            if lastBark.map({ now - $0 >= tuning.barkCooldown }) ?? true {
                lastBark = now
                barkReturn = nil
                state = .barking
                deadline = now + tuning.barkDuration
                return [.moveTo(nearestEdgeNudge(), speed: tuning.walkSpeed),
                        .play(.bark), .playSound("growl")]
            }
            // Still cooling down: fall through to a wander instead.
        }
        if roll < odds.perchBand {
            // The rarest idle break: climb onto one of your windows and trot
            // along the title bar. Needs a window to climb — with none in
            // reach the roll quietly becomes an ordinary wander rather than
            // disturbing the cumulative bands below it.
            if let surface = perchableSurface() {
                return startPerchApproach(to: surface)
            }
        }
        state = .wandering
        deadline = nil
        return [.play(.walk), .moveTo(wanderTarget(), speed: tuning.walkSpeed)]
```

The two now-unused locals `activeHunchChance` and `activePerchChance` are gone —
`AutonomyOdds` owns that decision.

- [ ] **Step 5: Opt the brain test helper out of the reserved wander share**

In `Tests/JumbiniTests/DogBrainTests.swift`, in `makeBrain` (line ~11), add one
line beside the other zeroed knobs — after `tuning.idleDuration = 3...3`:

```swift
    // A test that says `$0.hunchChance = 1` means CERTAIN. The shipping
    // wanderShare would quietly make it 90%, and forty tests would start
    // failing one time in ten for no visible reason. Tests that want to
    // exercise the clamp build a BrainTuning() directly and get the real 0.1.
    tuning.wanderShare = 0
```

With `wanderShare = 0`, a single band at 1.0 gives `total == ceiling == 1.0`,
`total > ceiling` is false, `scale` is 1, and the arithmetic is untouched.

- [ ] **Step 6: Rewrite the one test that sets two bands to certainty**

`thePerchBandSitsBeneathTheOlderAutonomyBands` (line ~2205) sets both
`sleepChance` and `perchChance` to 1, a total of 2.0. No normalization can
leave that alone, and the point it makes — the older band still wins the tie —
is a statement about band ORDER, which is now directly checkable. Replace the
whole test with:

```swift
@Test func thePerchBandSitsBeneathTheOlderAutonomyBands() {
    // Both bands maxed. Normalization splits the roll between them, and the
    // band that was there first takes the LOWER half — so adding the perch
    // can't quietly steal a nap.
    var tuning = BrainTuning()
    tuning.wanderShare = 0
    tuning.flourishChance = 0
    tuning.zoomiesChance = 0
    tuning.sniffChance = 0
    tuning.hunchChance = 0
    tuning.barkAtNothingChance = 0
    tuning.sleepChance = 1
    tuning.perchChance = 1

    let odds = AutonomyOdds(
        tuning: tuning, poopEnabled: true, windowClimbingEnabled: true
    )

    #expect(abs(odds.sleepBand - 0.5) < 0.0001, "sleep owns the lower half")
    #expect(abs(odds.perchBand - 1) < 0.0001, "the perch owns what's left")

    // And a roll that lands in the lower half really does nap.
    let brain = makeBrain { tune in
        tune.sleepChance = 1
        tune.perchChance = 1
        tune.sleepDuration = 10...10
    }
    brain.surfaces = [perchable]
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 3.1)
    #expect(brain.state != .wandering,
            "whichever half the seed lands in, the roll is spoken for; got \(brain.state)")
}
```

Note `makeBrain` sets `wanderShare = 0` (Step 5), so the two certainties
normalize to a clean 50/50 rather than leaking a wander band.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `swift test --filter DogBrainTests`
Expected: PASS — the five new tests, the rewritten one, and every other
pre-existing `DogBrainTests` test unchanged. Any *other* pre-existing failure
means the refactor was not behavior-preserving; do not proceed past it.

Run: `swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Jumbini/DogBrain.swift Tests/JumbiniTests/DogBrainTests.swift
git commit -m "Move the seven idle bands into AutonomyOdds

Behavior-preserving in the app: with the shipping tuning the bands total 0.60
against a 0.90 ceiling, the clamp is inert, and the thresholds are the same
left-to-right sums as before.

The clamp is the point. Scaled bands can total past 1.0, and the band that
silently dies first is the last one — window climbing. Nothing would have
reported it.

The test helper opts out of the reserved wander share. Forty tests force a band
to certainty and mean it; a 0.9 ceiling would have made each of them a 90% band
and the suite would have failed one time in ten with nothing to point at.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Activity modes on the brain

**Files:**
- Modify: `Sources/Jumbini/DogBrain.swift` — `var mood` on `DogBrain` (beside
  `poopEnabled` at line 326), `mood:` on the `AutonomyOdds` init, and the two
  scaled durations.
- Test: `Tests/JumbiniTests/DogBrainTests.swift` (append)

**Interfaces:**
- Consumes: `Mood`, `ActivityMode` (Task 1); `AutonomyOdds` (Task 2).
- Produces:
  - `DogBrain.mood: Mood` — a plain `var`, default `Mood()`, kept current by the
    scene exactly like `bounds` and `position`.
  - `AutonomyOdds.init(tuning:mood:poopEnabled:windowClimbingEnabled:)` — the
    `mood:` parameter is added in second position.
  - Private `DogBrain.idlePause() -> TimeInterval` and
    `DogBrain.zoomiesTimeout() -> TimeInterval`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/JumbiniTests/DogBrainTests.swift`:

```swift
// MARK: - Activity modes

/// A brain whose idle roll lands inside a band that only a mode can open.
/// `roll` is drawn first from the same generator every time, so a band that
/// widens under a mode is the only variable.
private func makeMoodBrain(mood: Mood, seed: UInt64 = 7) -> DogBrain {
    let brain = makeBrain(seed: seed) { tuning in
        tuning.sleepChance = 0.15
        tuning.flourishChance = 0
        tuning.zoomiesChance = 0.08
        tuning.sniffChance = 0
    }
    brain.mood = mood
    return brain
}

/// Roll the idle timer over and report where he ended up, for many seeds.
private func idleOutcomes(mood: Mood, seeds: ClosedRange<UInt64> = 1...200) -> [DogState] {
    seeds.map { seed in
        let brain = makeMoodBrain(mood: mood, seed: seed)
        _ = brain.handle(.tick, at: 0)
        _ = brain.handle(.tick, at: 100)
        return brain.state
    }
}

@Test func anExplicitlyActiveMoodChangesNothing() {
    // The regression guard in a single test: the default brain and an
    // explicitly .active brain walk the same path from the same seed.
    for seed in UInt64(1)...25 {
        let plain = makeBrain(seed: seed) { $0.zoomiesChance = 0.5 }
        let active = makeBrain(seed: seed) { $0.zoomiesChance = 0.5 }
        active.mood = Mood(activity: .active)

        _ = plain.handle(.tick, at: 0)
        _ = active.handle(.tick, at: 0)
        let plainEffects = plain.handle(.tick, at: 100)
        let activeEffects = active.handle(.tick, at: 100)

        #expect(plainEffects == activeEffects, "seed \(seed)")
        #expect(plain.state == active.state, "seed \(seed)")
    }
}

@Test func veryActiveGetsFarMoreZoomies() {
    let veryActive = idleOutcomes(mood: Mood(activity: .veryActive))
        .filter { $0 == .zoomies }.count
    let active = idleOutcomes(mood: Mood(activity: .active))
        .filter { $0 == .zoomies }.count

    #expect(veryActive > active * 2, "very active: \(veryActive), active: \(active)")
}

@Test func sleepyNapsMoreAndZoomiesLess() {
    let sleepy = idleOutcomes(mood: Mood(activity: .sleepy))
    let active = idleOutcomes(mood: Mood(activity: .active))

    #expect(sleepy.filter { $0 == .sleeping }.count
        > active.filter { $0 == .sleeping }.count)
    #expect(sleepy.filter { $0 == .zoomies }.count
        < active.filter { $0 == .zoomies }.count)
}

@Test func veryActiveGetsBoredSooner() {
    let hyper = makeBrain { $0.idleDuration = 4...4 }
    hyper.mood = Mood(activity: .veryActive)
    _ = hyper.handle(.tick, at: 0)
    // 4s scaled by 0.5 = 2s, so 2.1 is past the timer and 1.9 is not.
    #expect(hyper.handle(.tick, at: 1.9) == [])
    _ = hyper.handle(.tick, at: 2.1)
    #expect(hyper.state != .idle, "a hyper dog is bored in half the time")

    let sleepy = makeBrain { $0.idleDuration = 4...4 }
    sleepy.mood = Mood(activity: .sleepy)
    _ = sleepy.handle(.tick, at: 0)
    // 4s scaled by 2.0 = 8s.
    #expect(sleepy.handle(.tick, at: 7.9) == [])
    _ = sleepy.handle(.tick, at: 8.1)
    #expect(sleepy.state != .idle, "a sleepy dog takes twice as long")
}

@Test func veryActiveLengthensEveryZoomiesBurst() {
    // The autonomous roll.
    let rolled = makeBrain { $0.zoomiesChance = 1 }
    rolled.mood = Mood(activity: .veryActive)
    _ = rolled.handle(.tick, at: 0)
    _ = rolled.handle(.tick, at: 100)
    #expect(rolled.state == .zoomies)
    // 10s baseline x 1.5 = 15s.
    #expect(rolled.handle(.tick, at: 114) == [], "still running at 14s")
    _ = rolled.handle(.tick, at: 116)
    #expect(rolled.state != .zoomies, "over by 16s")

    // The hot-fans reaction takes the same scaling.
    let hot = makeBrain()
    hot.mood = Mood(activity: .veryActive)
    _ = hot.handle(.system(.fansUp), at: 0)
    #expect(hot.state == .zoomies)
    #expect(hot.handle(.tick, at: 14) == [])
    _ = hot.handle(.tick, at: 16)
    #expect(hot.state != .zoomies)

    // And so does the explicit command.
    let told = makeBrain()
    told.mood = Mood(activity: .veryActive)
    _ = told.handle(.command(.zoomies), at: 0)
    #expect(told.state == .zoomies)
    #expect(told.handle(.tick, at: 14) == [])
    _ = told.handle(.tick, at: 16)
    #expect(told.state != .zoomies)
}

@Test func modeDoesNotTouchTheHabitBands() {
    let tuning = BrainTuning()
    for mode in ActivityMode.allCases {
        let odds = AutonomyOdds(
            tuning: tuning,
            mood: Mood(activity: mode),
            poopEnabled: true,
            windowClimbingEnabled: true
        )
        let hunch = odds.hunchBand - odds.sniffBand
        let bark = odds.barkBand - odds.hunchBand
        let perch = odds.perchBand - odds.barkBand

        // Each is governed by its own feature switch and reads as a habit,
        // not a level of energy. Unclamped in all three modes.
        #expect(abs(hunch - tuning.hunchChance) < 0.0001, "\(mode)")
        #expect(abs(bark - tuning.barkAtNothingChance) < 0.0001, "\(mode)")
        #expect(abs(perch - tuning.perchChance) < 0.0001, "\(mode)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DogBrainTests`
Expected: FAIL to compile — `value of type 'DogBrain' has no member 'mood'`, and
`extra argument 'mood' in call` on the `AutonomyOdds` init.

- [ ] **Step 3: Add `mood` to the brain**

In `Sources/Jumbini/DogBrain.swift`, immediately after
`var windowClimbingEnabled = true` (line 327), insert:

```swift
    /// The three persistent switches from his right-click menu, kept current
    /// by the scene exactly like `bounds` and `position`. The brain reads them;
    /// the scene owns the menu, the storage, and the pixels.
    ///
    /// Set this directly only before he is running. Once he is, go through
    /// `setMood(_:at:)` so a change can take effect on the dog you can see.
    var mood = Mood()
```

- [ ] **Step 4: Apply the multipliers in `AutonomyOdds`**

Change the `AutonomyOdds` init signature and the `widths` array:

```swift
    init(
        tuning: BrainTuning,
        mood: Mood,
        poopEnabled: Bool,
        windowClimbingEnabled: Bool
    ) {
        // A feature switched off closes its band; the bands around it do not
        // move, exactly as before. `.active` scales every column by 1.0, which
        // is exact in binary floating point — the identity really is identical.
        let activity = mood.activity
        let widths = [
            tuning.sleepChance * activity.sleepScale,
            tuning.flourishChance * activity.flourishScale,
            tuning.zoomiesChance * activity.zoomiesScale,
            tuning.sniffChance * activity.sniffScale,
            poopEnabled ? tuning.hunchChance : 0,
            tuning.barkAtNothingChance,
            windowClimbingEnabled ? tuning.perchChance : 0,
        ]
```

The rest of the init — `total`, `ceiling`, `scale`, and the seven assignments —
is unchanged.

Then update **every** existing `AutonomyOdds(` call site to pass `mood: Mood()`
as the second argument, so they keep compiling and keep asserting the un-scaled
baseline. Run `grep -n "AutonomyOdds(" Sources/Jumbini/DogBrain.swift
Tests/JumbiniTests/DogBrainTests.swift` to find them — there are seven from
Task 2 (six in the tests, one in `leaveIdleForAutonomy`), and the one in
`leaveIdleForAutonomy` gets `mood: mood` instead, in Step 5 below.

- [ ] **Step 5: Feed the mood in, and scale the two durations**

In `leaveIdleForAutonomy`, add the `mood:` argument:

```swift
        let odds = AutonomyOdds(
            tuning: tuning,
            mood: mood,
            poopEnabled: poopEnabled,
            windowClimbingEnabled: windowClimbingEnabled
        )
```

Add two helpers next to `random(in:)` near the bottom of the file (line ~1620):

```swift
    /// How long he stays idle before picking something to do. A hyper dog gets
    /// bored in half the time, a sleepy one takes twice as long.
    private func idlePause() -> TimeInterval {
        random(in: tuning.idleDuration) * mood.activity.idleScale
    }

    /// How long a zoomies burst lasts. Scaled wherever zoomies BEGIN — the
    /// autonomous roll, the hot-fans reaction, and the explicit command — so a
    /// Very Active dog has longer zoomies for every reason he gets them.
    private func zoomiesTimeout() -> TimeInterval {
        tuning.zoomiesDuration * mood.activity.zoomiesDurationScale
    }
```

Replace both `random(in: tuning.idleDuration)` call sites with `idlePause()`:
- line 478, in `handleTick`: `deadline = now + idlePause()`
- line 997, in `enterIdle`: `deadline = now + idlePause()`

Replace all three `tuning.zoomiesDuration` call sites with `zoomiesTimeout()`:
- line 694, the `.zoomies` command in `handleCommand`
- line 929, the `.fansUp` case in `handleSystemSignal`
- line 1025, the zoomies band in `leaveIdleForAutonomy`

(Leave `tuning.sleepDuration` and every other duration alone.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter DogBrainTests`
Expected: PASS, including every pre-existing test — `.active` is the identity, so
none of them may move.

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/Jumbini/DogBrain.swift Tests/JumbiniTests/DogBrainTests.swift
git commit -m "Scale the idle bands and durations by the activity mode

Very Active turns an 8% zoomies roll into 36% and halves the pause between
activities; Sleepy triples naps and doubles the pause. Active multiplies every
column by 1.0, so the existing suite passes unmoved — that is the regression
guard, not a coincidence.

Zoomies length scales wherever zoomies begin, including the hot-fans reaction
and the explicit command, not just the autonomous roll.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: The Stay Lying Down hold

**Files:**
- Modify: `Sources/Jumbini/DogBrain.swift` — `lieDeadline(at:)` applied at the
  five lie sites, `settle(at:)`, the idle short-circuit, and `setMood(_:at:)`.
- Test: `Tests/JumbiniTests/DogBrainTests.swift` (append)

**Interfaces:**
- Consumes: `Mood` (Task 1); `DogBrain.mood` (Task 3).
- Produces:
  - `DogBrain.setMood(_ newMood: Mood, at now: TimeInterval) -> [DogEffect]` —
    the only supported way to change the mood of a running dog. Task 7 calls it.
  - Private `lieDeadline(at:) -> TimeInterval?` and `settle(at:) -> [DogEffect]`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/JumbiniTests/DogBrainTests.swift`:

```swift
// MARK: - Stay Lying Down (the soft hold)

@Test func theHoldSendsEveryIdleBackToTheFloor() {
    let brain = makeBrain { $0.zoomiesChance = 1 } // he'd zoom without the hold
    brain.mood = Mood(stayDown: true)

    _ = brain.handle(.tick, at: 0)
    let effects = brain.handle(.tick, at: 100)

    #expect(brain.state == .lyingDown)
    #expect(effects.contains(.play(.lie)))
}

@Test func theHeldDogNeverGetsBackUpOnHisOwn() {
    let brain = makeBrain()
    brain.mood = Mood(stayDown: true)
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 100)
    #expect(brain.state == .lyingDown)

    // Way past the 90s lie timeout: without a cleared deadline he'd stand up
    // and flop down again every 90 seconds, which reads as a twitch.
    #expect(brain.handle(.tick, at: 500) == [])
    #expect(brain.state == .lyingDown)
}

@Test func theHoldUsesTheBedWhenHeHasOne() {
    let brain = makeBrain()
    brain.bedPosition = CGPoint(x: 120, y: 80)
    brain.mood = Mood(stayDown: true)

    _ = brain.handle(.tick, at: 0)
    let effects = brain.handle(.tick, at: 100)

    #expect(brain.state == .goingToBed(.lie))
    #expect(moveTarget(in: effects)?.point == CGPoint(x: 120, y: 80))

    // And the lie he arrives into carries no deadline either.
    _ = brain.handle(.arrived, at: 110)
    #expect(brain.state == .lyingDown)
    #expect(brain.handle(.tick, at: 400) == [])
    #expect(brain.state == .lyingDown)
}

@Test func theHoldIsSoftEnoughForATreat() {
    let brain = makeBrain()
    brain.mood = Mood(stayDown: true)
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 100)
    #expect(brain.state == .lyingDown)

    // A treat interrupts exactly as it interrupts an ordinary lie-down...
    _ = brain.handle(.treatDropped(at: CGPoint(x: 200, y: 200)), at: 110)
    #expect(brain.state == .chasingTreat)
    _ = brain.handle(.arrived, at: 115)
    #expect(brain.state == .eating)

    // ...and the next idle puts him back on the floor.
    _ = brain.handle(.tick, at: 130)
    #expect(brain.state == .idle)
    _ = brain.handle(.tick, at: 200)
    #expect(brain.state == .lyingDown, "the hold reasserts itself at the next idle")
}

@Test func aSitCommandHoldsForItsFullTimeoutFirst() {
    let brain = makeBrain()
    brain.mood = Mood(stayDown: true)
    _ = brain.handle(.command(.sit), at: 0)
    #expect(brain.state == .sitting)

    // 60s sitTimeout: the hold applies at the idle that follows, not instantly.
    #expect(brain.handle(.tick, at: 30) == [])
    #expect(brain.state == .sitting)
    _ = brain.handle(.tick, at: 61)
    #expect(brain.state == .idle)
    _ = brain.handle(.tick, at: 100)
    #expect(brain.state == .lyingDown)
}

// MARK: - setMood reconciliation

@Test func turningTheHoldOnSettlesACalmDogNow() {
    for calm in [DogState.idle, .wandering, .sitting] {
        let brain = makeBrain()
        switch calm {
        case .wandering:
            _ = brain.handle(.tick, at: 0)
            _ = brain.handle(.tick, at: 100)
        case .sitting:
            _ = brain.handle(.command(.sit), at: 0)
        default:
            break
        }
        #expect(brain.state == calm, "setup for \(calm)")

        let effects = brain.setMood(Mood(stayDown: true), at: 200)

        #expect(brain.state == .lyingDown, "from \(calm)")
        #expect(effects.contains(.stopMoving), "from \(calm)")
        #expect(effects.contains(.play(.lie)), "from \(calm)")
    }
}

@Test func turningTheHoldOnNeverPullsHimOffALedge() {
    // makePercher's perchChance of 1 is a certainty again thanks to the
    // wanderShare = 0 in makeBrain, so this is deterministic: he is on his way
    // to a window and nowhere near calm.
    let brain = makePercher()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 100)
    let busy = brain.state
    #expect(busy != .idle && busy != .wandering && busy != .sitting,
            "he's off climbing, not in a state the hold may interrupt; got \(busy)")

    let effects = brain.setMood(Mood(stayDown: true), at: 110)

    #expect(effects.isEmpty, "a menu click is not an emergency")
    #expect(brain.state == busy, "the hold waits for the next idle")
}

@Test func turningTheHoldOnWhileHesAlreadyDownJustClearsTheClock() {
    let brain = makeBrain()
    _ = brain.handle(.command(.lieDown), at: 0)
    #expect(brain.state == .lyingDown)

    let effects = brain.setMood(Mood(stayDown: true), at: 10)

    #expect(effects.isEmpty, "no reason to restart the animation he's already in")
    #expect(brain.state == .lyingDown)
    #expect(brain.handle(.tick, at: 500) == [], "but the 90s clock is gone")
    #expect(brain.state == .lyingDown)
}

@Test func turningTheHoldOffGetsHimUp() {
    let brain = makeBrain()
    brain.mood = Mood(stayDown: true)
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 100)
    #expect(brain.state == .lyingDown)

    let effects = brain.setMood(Mood(stayDown: false), at: 110)

    #expect(brain.state == .idle)
    #expect(effects.contains(.play(.idle)))
}

@Test func turningTheHoldOffLeavesASystemCausedRestAlone() {
    let brain = makeBrain()
    brain.mood = Mood(stayDown: true)
    // The battery put him down, not the hold.
    _ = brain.handle(.system(.batteryLow), at: 0)
    #expect(brain.state == .lyingDown)

    let effects = brain.setMood(Mood(stayDown: false), at: 10)

    #expect(effects.isEmpty, "batteryNormal owns this one, not the menu")
    #expect(brain.state == .lyingDown)
}

@Test func changingActivityOrRoamHasNoImmediateEffect() {
    let brain = makeBrain()
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 100)
    let before = brain.state

    #expect(brain.setMood(Mood(activity: .veryActive, roam: .follow), at: 110) == [])
    #expect(brain.state == before, "both alter the next roll only")
    #expect(brain.mood.activity == .veryActive, "but the mood is stored")
    #expect(brain.mood.roam == .follow)
}

@Test func theHoldIsUserCausedSoWakeUpSignalsIgnoreIt() {
    let brain = makeBrain()
    brain.mood = Mood(stayDown: true)
    _ = brain.handle(.tick, at: 0)
    _ = brain.handle(.tick, at: 100)
    #expect(brain.state == .lyingDown)

    // The charger going in must not haul up a dog the USER put down.
    #expect(brain.handle(.system(.batteryNormal), at: 110) == [])
    #expect(brain.state == .lyingDown)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DogBrainTests`
Expected: FAIL to compile — `value of type 'DogBrain' has no member 'setMood'`.

- [ ] **Step 3: Add the lie deadline helper and apply it at all five sites**

In `Sources/Jumbini/DogBrain.swift`, add next to `random(in:)` near the bottom:

```swift
    /// When he should get back up from a lie — `nil` while the hold is on.
    ///
    /// One helper instead of five edits: the 90-second timeout is set from the
    /// bed arrival, the lie-down command, the battery conserve, the end of a
    /// bark, and the end of a petting session. Miss one and the held dog stands
    /// up and flops down again every 90 seconds, which looks like a twitch.
    private func lieDeadline(at now: TimeInterval) -> TimeInterval? {
        mood.stayDown ? nil : now + tuning.lieTimeout
    }
```

Replace `deadline = now + tuning.lieTimeout` with `deadline = lieDeadline(at: now)`
at all five sites:
- line 572, `handleArrived` → `case .goingToBed(.lie)`
- line 668, `handleCommand` → `case .lieDown`, the no-bed branch
- line 973, `restfulLie`
- line 1082, `endBarking` → `case .lyingDown`
- line 1099, `endPetting` → `case .lyingDown`

(`grep -n "tuning.lieTimeout" Sources/Jumbini/DogBrain.swift` must return nothing
afterwards.)

- [ ] **Step 4: Add `settle(at:)` and short-circuit the idle roll**

Add `settle(at:)` immediately above `leaveIdleForAutonomy`:

```swift
    /// Put him on the floor — the bed if he has one, where he stands if not.
    /// The destination of the Stay Lying Down hold, and deliberately the same
    /// path the `.lieDown` command takes.
    ///
    /// Consumes no random numbers: the hold must be perfectly predictable, and
    /// a roll spent here would shift every later roll in the session.
    private func settle(at now: TimeInterval) -> [DogEffect] {
        if let bed = bedPosition {
            state = .goingToBed(.lie)
            deadline = nil
            return [.play(.walk), .moveTo(bed, speed: tuning.walkSpeed)]
        }
        state = .lyingDown
        deadline = lieDeadline(at: now)
        return [.play(.lie)]
    }
```

At the very top of `leaveIdleForAutonomy`, before `let roll = ...`, insert:

```swift
        // The hold changes where idle LEADS. Everything else about the brain is
        // untouched, which is why a treat, a toy, or a command still interrupts
        // it normally — they just find him back on the floor at the next idle.
        if mood.stayDown { return settle(at: now) }
```

- [ ] **Step 5: Add `setMood(_:at:)`**

Add immediately after `disableBathroomBreaks(at:)` (line 472), following the same
shape as its two neighbours:

```swift
    /// Change the mood of a running dog and reconcile it with what he is doing.
    ///
    /// Activity and roam alter the next roll only — there is nothing to
    /// reconcile, and cutting a zoomies burst short because a menu item was
    /// ticked would be worse than waiting. The hold is the one that can be
    /// out of step with the dog on screen right now.
    func setMood(_ newMood: Mood, at now: TimeInterval) -> [DogEffect] {
        let previous = mood
        mood = newMood
        guard previous.stayDown != newMood.stayDown else { return [] }

        if newMood.stayDown {
            switch state {
            case .lyingDown:
                // Already where the hold wants him. Just stop the clock —
                // re-entering the state would restart the animation for
                // nothing.
                deadline = nil
                return []
            case .idle, .wandering, .sitting:
                return [.stopMoving] + settle(at: now)
            default:
                // Mid-chase, in your arms, or up on a title bar. Ticking a
                // menu item must never yank him off a ledge, so the hold
                // waits for the next idle.
                return []
            }
        }

        // Hold released. Get him up only if the hold is what was keeping him
        // down: a rest the MACHINE caused belongs to its own wake-up signal,
        // the way `riseFromRest` already distinguishes causes. Any other lie
        // is held by definition while the hold is on — `lieDeadline` gave it
        // no clock — so leaving it would strand him there.
        guard restReason == nil else { return [] }
        switch state {
        case .lyingDown:
            return enterIdle(at: now)
        case .goingToBed(.lie):
            return [.stopMoving] + enterIdle(at: now)
        default:
            return []
        }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter DogBrainTests`
Expected: PASS, including every pre-existing test — the hold is off by default,
so nothing already written may move.

Run: `swift test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/Jumbini/DogBrain.swift Tests/JumbiniTests/DogBrainTests.swift
git commit -m "Add the Stay Lying Down hold

The hold changes where idle leads: he settles instead of rolling for an
activity, and the lie carries no deadline so he does not stand up and flop back
down every 90 seconds.

Soft on purpose. Treats, toys, pets, and commands interrupt it exactly as they
interrupt an ordinary lie-down; a dog that will not take a treat looks broken
rather than obedient. Turning it on mid-chase or mid-perch waits for the next
idle — a menu click should never pull him off a ledge.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Follow My Cursor

**Files:**
- Modify: `Sources/Jumbini/DogBrain.swift` — `var cursorPosition`, the follow
  factor in `AutonomyOdds`, `roamTarget()`, `clampToBounds(_:)`, and the wander
  call site in `leaveIdleForAutonomy`.
- Test: `Tests/JumbiniTests/DogBrainTests.swift` (append)

**Interfaces:**
- Consumes: `Mood`, `RoamMode` (Task 1); `AutonomyOdds` (Tasks 2–3).
- Produces:
  - `DogBrain.cursorPosition: CGPoint?` — kept current by the scene each frame.
    `nil` means unknown, and follow mode falls back to ordinary wandering.
  - `BrainTuning.followStandoff: CGFloat` (default `120`) and
    `BrainTuning.followMill: CGFloat` (default `90`).
  - Private `roamTarget() -> CGPoint` and `clampToBounds(_:) -> CGPoint`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/JumbiniTests/DogBrainTests.swift`:

```swift
// MARK: - Follow My Cursor

/// A brain that will fall through to an ordinary walk on its first idle roll.
private func makeRoamer(roam: RoamMode, cursor: CGPoint?, seed: UInt64 = 3) -> DogBrain {
    let brain = makeBrain(seed: seed) // every band is zeroed by makeBrain
    brain.mood = Mood(roam: roam)
    brain.cursorPosition = cursor
    return brain
}

private func firstWalkTarget(_ brain: DogBrain) -> CGPoint? {
    _ = brain.handle(.tick, at: 0)
    let effects = brain.handle(.tick, at: 100)
    return moveTarget(in: effects)?.point
}

@Test func followAimsAtTheCursorAndStopsShort() {
    // Dog at (400, 300), cursor 400pt to the right.
    let brain = makeRoamer(roam: .follow, cursor: CGPoint(x: 800, y: 300))

    let target = firstWalkTarget(brain)

    #expect(brain.state == .wandering)
    #expect(target != nil)
    if let target {
        let gap = hypot(800 - target.x, 300 - target.y)
        #expect(abs(gap - brain.tuning.followStandoff) < 1,
                "he stops a standoff short, got a gap of \(gap)")
        #expect(target.x > 400, "and he moved toward it")
    }
}

@Test func followMillsAboutWhenTheCursorIsAlreadyClose() {
    // Cursor 40pt away — well inside the 120pt standoff.
    let brain = makeRoamer(roam: .follow, cursor: CGPoint(x: 440, y: 300))

    let target = firstWalkTarget(brain)

    #expect(target != nil)
    if let target {
        let step = hypot(target.x - 400, target.y - 300)
        #expect(step <= brain.tuning.followMill * 1.5,
                "a small mill, not a march across the screen; got \(step)")
    }
}

@Test func followWithNoCursorIsOrdinaryWandering() {
    // Same seed, same everything, cursor unknown: he must behave exactly as a
    // wandering dog, not freeze and not walk to the origin.
    let follow = makeRoamer(roam: .follow, cursor: nil, seed: 11)
    let wander = makeRoamer(roam: .wander, cursor: nil, seed: 11)

    #expect(firstWalkTarget(follow) == firstWalkTarget(wander))
    #expect(follow.state == .wandering)
}

@Test func followTargetsStayInsideTheMargins() {
    // Cursors well off every edge of the 800x600 world.
    let corners = [
        CGPoint(x: -900, y: -900), CGPoint(x: 1800, y: 1800),
        CGPoint(x: -900, y: 1800), CGPoint(x: 1800, y: -900),
    ]
    for cursor in corners {
        let brain = makeRoamer(roam: .follow, cursor: cursor)
        let target = firstWalkTarget(brain)

        #expect(target != nil, "cursor \(cursor)")
        if let target {
            let margin = brain.tuning.wanderMargin
            #expect(target.x >= margin && target.x <= 800 - margin, "cursor \(cursor)")
            #expect(target.y >= margin && target.y <= 600 - margin, "cursor \(cursor)")
        }
    }
}

@Test func followKeepsHimOutOfTheHolesBetweenDisplays() {
    let brain = makeRoamer(roam: .follow, cursor: CGPoint(x: 700, y: 500))
    // Only the left half of the world is a display; the cursor is in the void.
    brain.roamableRects = [CGRect(x: 0, y: 0, width: 400, height: 600)]

    let target = firstWalkTarget(brain)

    #expect(target != nil)
    if let target {
        #expect(target.x <= 400, "he stops at the edge of the world, got \(target)")
    }
}

@Test func followMakesTheCursorHuntHisCommonIdleActivity() {
    var tuning = BrainTuning()
    tuning.sniffChance = 0.12
    let wandering = AutonomyOdds(
        tuning: tuning, mood: Mood(roam: .wander),
        poopEnabled: true, windowClimbingEnabled: true
    )
    let following = AutonomyOdds(
        tuning: tuning, mood: Mood(roam: .follow),
        poopEnabled: true, windowClimbingEnabled: true
    )

    let wanderSniff = wandering.sniffBand - wandering.zoomiesBand
    let followSniff = following.sniffBand - following.zoomiesBand
    #expect(abs(followSniff - wanderSniff * 2) < 0.0001, "the sniff band doubles")
}

@Test func veryActiveAndFollowTogetherStillLeaveRoomToClimb() {
    // The composition that motivated the clamp: both switches on, every
    // feature enabled. Window climbing is the last band and dies first.
    let odds = AutonomyOdds(
        tuning: BrainTuning(),
        mood: Mood(activity: .veryActive, roam: .follow),
        poopEnabled: true,
        windowClimbingEnabled: true
    )

    #expect(odds.perchBand > odds.barkBand, "the climb band is still reachable")
    #expect(odds.perchBand <= 1 - BrainTuning().wanderShare + 0.0001)
    #expect(odds.sleepBand > 0, "and he can still nap")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter DogBrainTests`
Expected: FAIL to compile — `value of type 'DogBrain' has no member
'cursorPosition'` and `value of type 'BrainTuning' has no member 'followStandoff'`.

- [ ] **Step 3: Add the two tuning knobs**

In `Sources/Jumbini/DogBrain.swift`, immediately after the `wanderShare` knob
added in Task 2, insert:

```swift
    /// How far short of your cursor a follow walk stops. Close enough to be
    /// company, far enough not to sit on the thing you are clicking.
    var followStandoff: CGFloat = 120
    /// How far he mills about when the cursor is already inside the standoff.
    var followMill: CGFloat = 90
```

- [ ] **Step 4: Add `cursorPosition` to the brain**

Immediately after the `var mood = Mood()` property added in Task 3, insert:

```swift
    /// Where the cursor is in scene coordinates, kept current by the scene each
    /// frame — it already computes this for hover detection, so it is free.
    ///
    /// `nil` means unknown (no window to convert through), and follow mode
    /// falls back to ordinary wandering rather than walking to the origin.
    var cursorPosition: CGPoint?
```

- [ ] **Step 5: Double the sniff band in follow mode**

In `AutonomyOdds.init`, change the sniff width to:

```swift
            // Follow mode doubles the cursor hunt. The per-frame chase already
            // exists as sniff → stalk → pounce, and follow mode is what makes
            // it his common idle activity rather than an occasional one.
            tuning.sniffChance * activity.sniffScale * (mood.roam == .follow ? 2 : 1),
```

- [ ] **Step 6: Add `roamTarget()` and `clampToBounds(_:)`**

Add both immediately after `wanderTarget()` (which ends at line ~1542):

```swift
    /// Where an ordinary walk goes: a random spot, or a spot near your cursor.
    ///
    /// Follow REPLACES the target, not the walk. It is an ordinary `.moveTo`
    /// toward a fixed point, so a cursor that moves mid-walk is not chased —
    /// he arrives, idles, and re-aims on the next roll. That laziness is the
    /// character: a pet that never stops walking at you is a nuisance in about
    /// ninety seconds.
    private func roamTarget() -> CGPoint {
        guard mood.roam == .follow, let cursor = cursorPosition else {
            return wanderTarget()
        }
        let dx = cursor.x - position.x
        let dy = cursor.y - position.y
        let distance = hypot(dx, dy)
        guard distance > tuning.followStandoff else {
            // Already beside the pointer. Mill about rather than cross the
            // screen to reach something that is right here — and `distance`
            // can be 0, so this is the divide-by-zero guard too.
            let mill = tuning.followMill
            return onSolidGround(clampToBounds(CGPoint(
                x: position.x + CGFloat.random(in: -mill...mill, using: &rng),
                y: position.y + CGFloat.random(in: -mill...mill, using: &rng)
            )))
        }
        let travel = distance - tuning.followStandoff
        return onSolidGround(clampToBounds(CGPoint(
            x: position.x + dx / distance * travel,
            y: position.y + dy / distance * travel
        )))
    }

    /// Pull a computed point inside the roaming margin. `wanderTarget()` gets
    /// this for free by sampling inside the margin; a point aimed at something
    /// outside the world — your cursor on another display, say — does not.
    private func clampToBounds(_ point: CGPoint) -> CGPoint {
        let margin = tuning.wanderMargin
        return CGPoint(
            x: min(max(point.x, margin), max(margin, bounds.width - margin)),
            y: min(max(point.y, margin), max(margin, bounds.height - margin))
        )
    }
```

- [ ] **Step 7: Aim the wander at `roamTarget()`**

In `leaveIdleForAutonomy`, change the final return to:

```swift
        state = .wandering
        deadline = nil
        return [.play(.walk), .moveTo(roamTarget(), speed: tuning.walkSpeed)]
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --filter DogBrainTests`
Expected: PASS. `followWithNoCursorIsOrdinaryWandering` is the guard that the
default path is untouched — `roamTarget()` calls straight through to
`wanderTarget()` and consumes the same random numbers in the same order.

Run: `swift test`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add Sources/Jumbini/DogBrain.swift Tests/JumbiniTests/DogBrainTests.swift
git commit -m "Add Follow My Cursor as an alternative to wandering

Follow swaps the wander TARGET, not the walk: his walks aim at your pointer and
stop 120pt short, and he mills about when he is already beside it. Naps, spins,
fetch, treats, and window climbing all still work.

The sniff band doubles in follow mode, so the stalk-and-pounce hunt that already
exists becomes his common idle activity. That composition with Very Active is
exactly what the AutonomyOdds clamp was extracted for.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Speech bubbles on Mac-aware reactions

**Files:**
- Create: `Sources/Jumbini/SpeechBubble.swift`
- Modify: `Sources/Jumbini/DogBrain.swift` line 53 — `SystemSignal: CaseIterable`
- Modify: `Sources/Jumbini/PetScene.swift` lines 646–677 — delete
  `emoteIcon(for:)`, rewrite `emote(for:acted:)`, add `showSpeech(_:)`
- Test: `Tests/JumbiniTests/SpeechBubbleTests.swift`

**Interfaces:**
- Consumes: `SystemSignal` (existing).
- Produces:
  - `enum ReactionCaption` with
    `static func text(for signal: SystemSignal, acted: Bool) -> String?`
    (`nil` = say nothing).
  - `final class SpeechBubble: SKNode` with `init(text: String)`,
    `static func hold(for text: String) -> TimeInterval`, and `func play()`.
- Not changed: `EmoteBubble`, which still draws the `icon_question` shrug for a
  refused command at `PetScene.swift:2431`. That is not a Mac-aware reaction.

- [ ] **Step 1: Write the failing tests**

Create `Tests/JumbiniTests/SpeechBubbleTests.swift`:

```swift
import Foundation
import Testing
@testable import Jumbini

@Test func everySignalHeActsOnSaysSomething() {
    for signal in SystemSignal.allCases {
        let caption = ReactionCaption.text(for: signal, acted: true)
        #expect(caption?.isEmpty == false, "\(signal) acted on but said nothing")
    }
}

@Test func theCaptionsAreTheOnesTheDesignAgreed() {
    #expect(ReactionCaption.text(for: .buildFinished, acted: true) == "Build's done!")
    #expect(ReactionCaption.text(for: .fansUp, acted: true) == "Your Mac's hot!")
    #expect(ReactionCaption.text(for: .batteryLow, acted: true) == "Battery's low…")
    #expect(ReactionCaption.text(for: .dndOn, acted: true) == "Focus on. Shh.")
    #expect(ReactionCaption.text(for: .idleBegan, acted: true) == "You've been gone a while…")
    #expect(ReactionCaption.text(for: .idleEnded, acted: true) == "You're back!")
    #expect(ReactionCaption.text(for: .batteryNormal, acted: true) == "Charging again!")
    #expect(ReactionCaption.text(for: .dndOff, acted: true) == "Focus off!")
}

@Test func newsHeWasTooBusyForSaysSoInsteadOfNothing() {
    // The brain parks these (deferSignal) and comes back to them. Saying so
    // beats leaving the user wondering why nothing happened.
    for signal in [SystemSignal.buildFinished, .fansUp, .batteryLow, .dndOn, .idleBegan] {
        #expect(ReactionCaption.text(for: signal, acted: false) == "Busy — one sec!", "\(signal)")
    }
}

@Test func theAllClearSignalsStaySilentUnlessTheyRousedHim() {
    // Preserves today's behavior: the charger going in is not news unless it
    // actually got him up.
    for signal in [SystemSignal.idleEnded, .batteryNormal, .dndOff] {
        #expect(ReactionCaption.text(for: signal, acted: false) == nil, "\(signal)")
    }
}

@Test func aLongerLineStaysUpLonger() {
    let short = SpeechBubble.hold(for: "You're back!")
    let long = SpeechBubble.hold(for: "You've been gone a while…")

    #expect(long > short, "a longer caption needs longer to read")
    #expect(short >= 1.4, "even the shortest line gets a beat")
}

@Test func theHoldIsCapped() {
    let epic = String(repeating: "a", count: 500)

    #expect(SpeechBubble.hold(for: epic) == 3.2, "he is not writing an essay")
}

@Test @MainActor func theBubbleBuildsAndCarriesItsText() {
    let bubble = SpeechBubble(text: "Build's done!")

    #expect(bubble.calculateAccumulatedFrame().width > 0)
    // +2 for the 1pt stroke on each side of the plate.
    #expect(bubble.calculateAccumulatedFrame().width <= SpeechBubble.maxWidth + 2)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SpeechBubbleTests`
Expected: FAIL to compile — `cannot find 'ReactionCaption' in scope`,
`cannot find 'SpeechBubble' in scope`, and `type 'SystemSignal' has no member
'allCases'`.

- [ ] **Step 3: Make `SystemSignal` exhaustively enumerable**

In `Sources/Jumbini/DogBrain.swift`, change line 53:

```swift
enum SystemSignal: Equatable, CaseIterable {
```

(This is why the caption test can prove no signal was forgotten. It costs
nothing: the enum has no associated values.)

- [ ] **Step 4: Write `SpeechBubble.swift`**

Create `Sources/Jumbini/SpeechBubble.swift`:

```swift
import AppKit
import SpriteKit

/// What Jumba says about a machine signal.
///
/// The words live here rather than in `DogBrain` on purpose: the brain has no
/// UI in it and no user-facing text, and `DogEffect` is deliberately
/// signal-agnostic — by the time the effects come back, nothing in them says
/// WHY he did that. `PetScene.receive(_:)` is the one place that still knows
/// the signal's name, so that is where the caption is chosen.
///
/// The switch is exhaustive over `SystemSignal` with no `default`, so a signal
/// added later is a compile error rather than a dog who silently says nothing
/// about it.
enum ReactionCaption {
    /// A short line of text, or `nil` for "say nothing at all".
    ///
    /// - Parameter acted: whether the brain acted on the signal or parked it.
    ///   Parked news is worth saying so about; an all-clear that roused nobody
    ///   is not worth saying anything about.
    static func text(for signal: SystemSignal, acted: Bool) -> String? {
        switch signal {
        case .buildFinished: acted ? "Build's done!" : busy
        case .fansUp: acted ? "Your Mac's hot!" : busy
        case .batteryLow: acted ? "Battery's low…" : busy
        case .dndOn: acted ? "Focus on. Shh." : busy
        case .idleBegan: acted ? "You've been gone a while…" : busy
        // The all-clear signals. Silent unless they genuinely got him up,
        // which is exactly what the icon version did.
        case .idleEnded: acted ? "You're back!" : nil
        case .batteryNormal: acted ? "Charging again!" : nil
        case .dndOff: acted ? "Focus off!" : nil
        }
    }

    /// News that arrived while he was mid-fetch. The brain parks it
    /// (`deferSignal`) and comes back to it; this is the dog admitting so.
    private static let busy = "Busy — one sec!"
}

/// A speech bubble with a short line of text in it — the spoken half of the
/// system-reactions feature.
///
/// `EmoteBubble` is the older, iconographic sibling and is still used for the
/// `icon_question` shrug when a command is refused. This one exists because an
/// icon cannot say WHY: a flame over his head means the machine got hot only if
/// you already knew that is what the flame meant.
///
/// Deliberately ignorant, like `EmoteBubble`: it knows nothing about
/// `SystemSignal` or about why it was asked for. The scene picks the words.
final class SpeechBubble: SKNode {
    /// Widest the bubble gets before the text wraps. He stands ~115pt tall, so
    /// much more than this stops being a bubble over a dog and starts being a
    /// dialog box with a dog under it.
    static let maxWidth: CGFloat = 180
    private static let fontSize: CGFloat = 11
    private static let padX: CGFloat = 10
    private static let padY: CGFloat = 7
    private static let corner: CGFloat = 9
    private static let tail: CGFloat = 7

    /// How long the bubble hangs there before drifting off. Scaled to the
    /// length of the line so a longer caption is actually readable, and capped
    /// so he never blocks the screen for an awkwardly long time.
    static func hold(for text: String) -> TimeInterval {
        min(1.4 + 0.05 * Double(text.count), 3.2)
    }

    private let text: String

    init(text: String) {
        self.text = text
        super.init()

        let label = SKLabelNode(fontNamed: Self.fontName)
        label.text = text
        label.fontSize = Self.fontSize
        label.fontColor = NSColor(white: 0.1, alpha: 1)
        label.numberOfLines = 2
        label.lineBreakMode = .byTruncatingTail
        label.preferredMaxLayoutWidth = Self.maxWidth - Self.padX * 2
        label.horizontalAlignmentMode = .center
        label.verticalAlignmentMode = .center
        label.zPosition = 1

        // Size the bubble to the text, not the other way round: "Focus off!"
        // in a 180pt plate would read as a missing string.
        let textSize = label.calculateAccumulatedFrame().size
        let width = min(textSize.width + Self.padX * 2, Self.maxWidth)
        let height = textSize.height + Self.padY * 2

        let plate = SKShapeNode(
            rect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
            cornerRadius: Self.corner
        )
        plate.fillColor = NSColor(white: 0.98, alpha: 0.96)
        plate.strokeColor = NSColor(white: 0.35, alpha: 0.9)
        plate.lineWidth = 1
        addChild(plate)

        // A small tail so it reads as speech rather than a floating label.
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -Self.tail, y: -height / 2 + 1))
        path.addLine(to: CGPoint(x: 0, y: -height / 2 - Self.tail))
        path.addLine(to: CGPoint(x: Self.tail, y: -height / 2 + 1))
        path.closeSubpath()
        let tailNode = SKShapeNode(path: path)
        tailNode.fillColor = plate.fillColor
        tailNode.strokeColor = plate.strokeColor
        tailNode.lineWidth = 1
        addChild(tailNode)

        addChild(label)

        alpha = 0
        setScale(0.6)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Pop in, hold, float up and fade, then take itself off the scene.
    /// The same choreography as `EmoteBubble`, so the two never look like
    /// different features.
    func play() {
        run(.sequence([
            .group([
                .fadeIn(withDuration: 0.12),
                .scale(to: 1, duration: 0.16),
            ]),
            .wait(forDuration: Self.hold(for: text)),
            .group([
                .moveBy(x: 0, y: 34, duration: 0.5),
                .fadeOut(withDuration: 0.5),
            ]),
            .removeFromParent(),
        ]))
    }

    /// The rounded system font, with Menlo and then the plain system font as
    /// fallbacks — the same ladder `PetScene.camCaptionFont` climbs, so the
    /// bubble and the cam caption are recognisably the same voice. No pixel
    /// font is bundled in the app and none is added for this.
    private static let fontName: String = {
        let system = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        if let rounded = system.fontDescriptor.withDesign(.rounded),
           let font = NSFont(descriptor: rounded, size: fontSize) {
            return font.fontName
        }
        return NSFont(name: "Menlo", size: fontSize)?.fontName ?? system.fontName
    }()
}
```

- [ ] **Step 5: Run the new tests to verify they pass**

Run: `swift test --filter SpeechBubbleTests`
Expected: PASS, 7 tests.

- [ ] **Step 6: Speak the captions from the scene**

In `Sources/Jumbini/PetScene.swift`, delete `emoteIcon(for:)` entirely (lines
646–657, the `// MARK: - Emotes` comment block through the closing brace) and
replace `emote(for:acted:)` (lines 659–677) so the region reads:

```swift
    // MARK: - Emotes

    /// Caption a system signal out loud, going by what he did with it:
    ///
    /// - news he acted on says what happened — the build, the fans, Focus, the
    ///   battery, the fact that you wandered off;
    /// - news that arrived while he was mid-fetch says he is busy: the brain
    ///   parks it (`deferSignal`) and comes back to it, and saying so beats
    ///   leaving the user wondering why nothing happened;
    /// - the all-clear signals (the human's back, the charger's in, Focus off)
    ///   stay silent unless they genuinely got him up.
    ///
    /// This used to be an icon. An icon cannot say WHY, which is the whole
    /// point of the feature — see `ReactionCaption`.
    private func emote(for signal: SystemSignal, acted: Bool) {
        guard let caption = ReactionCaption.text(for: signal, acted: acted) else { return }
        showSpeech(caption)
    }

    /// Float a line of text off the top of his head. Offset to one side so it
    /// doesn't fight the hearts, which rise straight up from the same line,
    /// then pulled back on screen if that offset would hang it off an edge.
    private func showSpeech(_ text: String) {
        let bubble = SpeechBubble(text: text)
        let halfWidth = bubble.calculateAccumulatedFrame().width / 2
        let margin: CGFloat = 8
        bubble.position = CGPoint(
            x: min(max(dog.position.x + 30, halfWidth + margin),
                   max(halfWidth + margin, size.width - halfWidth - margin)),
            y: dog.position.y + dog.size.height / 2 + 14
        )
        bubble.zPosition = 21 // just above the hearts (20)
        addChild(bubble)
        bubble.play()
    }
```

`showEmote(_:)` stays exactly as it is — the refused-command shrug at line 2431
still uses it.

- [ ] **Step 7: Verify the whole suite and the build**

Run: `swift build`
Expected: `Build complete!` with no errors. If the compiler reports
`emoteIcon` as unused or missing, it was not fully deleted.

Run: `swift test`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/Jumbini/SpeechBubble.swift Sources/Jumbini/DogBrain.swift \
        Sources/Jumbini/PetScene.swift Tests/JumbiniTests/SpeechBubbleTests.swift
git commit -m "Say why he reacted, instead of showing an icon

A flame over his head means the machine got hot only if you already knew that
is what the flame meant. The bubble now carries the words.

The caption is chosen in PetScene.receive(_:), the one place that still knows a
signal's name — DogEffect is deliberately signal-agnostic, so the brain stays
free of user-facing text. SystemSignal gains CaseIterable so a signal added
later is a failing test rather than a dog with nothing to say.

EmoteBubble is untouched and still draws the refused-command shrug.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: The Mood submenu, persistence, and the cursor feed

Everything built so far is unreachable by a user until this lands.

**Files:**
- Modify: `Sources/Jumbini/PetScene.swift` — a stored `mood`, seeding the brain
  at line 169, the per-frame cursor feed in `update(_:)` at line 584, the
  submenu in `rightMouseDown(with:)` at line 2337, and the three action handlers.

**Interfaces:**
- Consumes: `Mood`, `MoodSettings`, `MoodMenuState`, `ActivityMode`, `RoamMode`
  (Task 1); `DogBrain.mood`, `DogBrain.cursorPosition`, `DogBrain.setMood(_:at:)`
  (Tasks 3–5).
- Produces: nothing other tasks consume.

- [ ] **Step 1: Store the mood and seed the brain with it**

In `Sources/Jumbini/PetScene.swift`, add a stored property beside the scene's
other persisted state (near `windowClimbingEnabled`):

```swift
    /// The three persistent switches from his right-click menu. The scene owns
    /// these outright — they are never routed through JumbiniSettings, whose
    /// panel rebuilds that struct from its checkboxes and would reset them.
    private var mood = MoodSettings.load()
```

In `didMove(to:)`, immediately after
`brain.windowClimbingEnabled = initialSettings.windowClimbingEnabled` (line 169):

```swift
        // Direct assignment, not setMood: there is nothing to reconcile with a
        // dog who has not started yet.
        brain.mood = mood
```

- [ ] **Step 2: Feed the cursor to the brain every frame**

Add a helper next to `mouseLocationInScene()` (line 2108):

```swift
    /// The cursor in scene coordinates, or nil when there is no window to
    /// convert through. `mouseLocationInScene()` returns a (-1, -1) sentinel in
    /// that case, which is a fine place for a hover test and a terrible place
    /// to send a dog.
    private func cursorScenePoint() -> CGPoint? {
        guard let window = overlayWindow, let view else { return nil }
        return view.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), to: self)
    }
```

In `update(_:)`, immediately after `brain.position = dog.position` (line 584):

```swift
        // Free: the hover test below already asks the window server for this.
        brain.cursorPosition = cursorScenePoint()
```

- [ ] **Step 3: Build the submenu**

Add these three members near `tricksMenuItem()` (line 2348):

```swift
    /// The Mood submenu: how much energy he has, whether he stays down, and
    /// whether his walks aim at your cursor. Which item carries a checkmark is
    /// decided by `MoodMenuState`, which is tested without AppKit.
    private func moodMenuItem() -> NSMenuItem {
        let state = MoodMenuState(mood: mood)
        let moodItem = NSMenuItem(title: MoodMenuState.submenuTitle, action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (mode, entry) in zip(ActivityMode.allCases, state.activityItems) {
            let item = NSMenuItem(
                title: entry.title, action: #selector(activityChosen(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = ActivityChoice(mode: mode)
            item.state = entry.isChecked ? .on : .off
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let stay = NSMenuItem(
            title: state.stayDownItem.title, action: #selector(stayDownToggled), keyEquivalent: ""
        )
        stay.target = self
        stay.state = state.stayDownItem.isChecked ? .on : .off
        submenu.addItem(stay)
        let follow = NSMenuItem(
            title: state.followItem.title, action: #selector(followToggled), keyEquivalent: ""
        )
        follow.target = self
        follow.state = state.followItem.isChecked ? .on : .off
        submenu.addItem(follow)
        moodItem.submenu = submenu
        return moodItem
    }

    /// `representedObject` needs a class, and ActivityMode is an enum —
    /// the same dance `ToyChoice` does two screens down.
    private final class ActivityChoice: NSObject {
        let mode: ActivityMode
        init(mode: ActivityMode) { self.mode = mode }
    }

    /// Save the new mood and reconcile it with the dog on screen right now.
    /// One funnel for all three items so persistence can never be forgotten.
    private func changeMood(_ transform: (inout Mood) -> Void) {
        var updated = mood
        transform(&updated)
        guard updated != mood else { return }
        mood = updated
        MoodSettings.save(mood)
        apply(effects: brain.setMood(mood, at: lastTime))
    }

    @objc private func activityChosen(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? ActivityChoice else { return }
        changeMood { $0.activity = choice.mode }
    }

    @objc private func stayDownToggled() {
        changeMood { $0.stayDown.toggle() }
    }

    @objc private func followToggled() {
        changeMood { $0.roam = $0.roam == .follow ? .wander : .follow }
    }
```

In `rightMouseDown(with:)`, insert the submenu after the separator and before
Tricks — change line 2336–2337 from

```swift
        menu.addItem(.separator())
        menu.addItem(tricksMenuItem())
```

to

```swift
        menu.addItem(.separator())
        menu.addItem(moodMenuItem())
        menu.addItem(tricksMenuItem())
```

- [ ] **Step 4: Verify the build and the suite**

Run: `swift build`
Expected: `Build complete!`

Run: `swift test`
Expected: PASS. The menu wiring itself has no unit test — `NSMenu` construction
needs a running app — but `MoodTests` already proves the titles and the
checkmark logic, and `DogBrainTests` proves what `setMood` does.

- [ ] **Step 5: Verify by hand, in the running app**

Run: `swift run Jumbini`

Check each of these, and do not commit until all six pass:

1. Right-click Jumba. A **Mood** submenu sits between the separator and Tricks,
   with Very Active / Active / Sleepy (Active checked), a separator, then
   Stay Lying Down and Follow My Cursor (both unchecked).
2. Pick **Very Active**, wait a minute. Zoomies come often and last noticeably
   longer. Re-open the menu: the checkmark is on Very Active.
3. Tick **Stay Lying Down** while he is wandering. He stops, lies down, and
   stays down. Drop a treat: he gets up, eats it, and goes back down.
4. Untick it: he gets up.
5. Tick **Follow My Cursor**, move the pointer somewhere else, and wait for his
   next walk. He heads toward the pointer and stops short of it. He still naps
   and still climbs windows.
6. Quit and relaunch. Every choice survived.

- [ ] **Step 6: Commit**

```bash
git add Sources/Jumbini/PetScene.swift
git commit -m "Put the Mood submenu in Jumba's right-click menu

Three activity modes with radio checkmarks, then the two toggles. Picks save to
UserDefaults immediately and go through brain.setMood so the dog on screen
reconciles with them at once.

The scene also starts feeding the brain the cursor position each frame, which it
already computed for hover detection.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Update the README

The README documents Jumba's odds, his Mac-aware reactions, and his right-click
command list. All three now describe something that is no longer true.

**Files:**
- Modify: `README.md` — the odds table near line 74, the reactions table near
  line 119, the command list near line 209, and the zoomies sentences near
  lines 9, 32, and 82.

- [ ] **Step 1: Read the three regions**

Run: `grep -n "Zoomies\|zoomies\|thermally stressed\|Spin Forever" README.md`

Read each region before editing. The line numbers above are from the state of
the file at the time this plan was written and will have drifted.

- [ ] **Step 2: Update the odds table**

The table near line 74 lists per-idle chances (`Zoomies | 8% | 10s`). Add a note
directly beneath it:

```markdown
Those are his odds on the **Active** setting, which is the default. **Very
Active** multiplies the zoomies roll by 4.5 (8% becomes 36%), makes each burst
half again as long, cuts his sleep roll to a fifth, and halves the pause between
activities. **Sleepy** does the reverse: naps triple, zoomies all but stop, and
he takes twice as long to get bored. Hunching, barking at nothing, and window
climbing are the same in every mode — each is a habit with its own switch, not a
level of energy.
```

- [ ] **Step 3: Update the reactions table**

The table near line 119 maps machine events to behavior (`The machine gets
thermally stressed | Zoomies. He is not helping`). Add beneath it:

```markdown
Each of these now comes with a speech bubble saying what happened — "Your Mac's
hot!", "Build's done!", "Battery's low…" — so a dog who suddenly loses his mind
is a joke rather than a bug. News that arrives while he is mid-fetch gets
"Busy — one sec!": the brain parks it and comes back to it.
```

- [ ] **Step 4: Update the command list**

The sentence near line 209 reads "The command list is Sit, Lie Down, Spin, Spin
Forever, Zoomies!, and Fetch." Add after it:

```markdown
Below those is a **Mood** submenu, and unlike the commands its settings stick.
Pick how much energy he has — Very Active, Active, or Sleepy. Tick **Stay Lying
Down** and he lies down and stays there until you untick it; he will still get
up for a treat or a game of fetch, then flop back down. Tick **Follow My Cursor**
and his walks aim at your pointer instead of a random spot, stopping a
comfortable distance short, and he hunts the cursor far more often.
```

- [ ] **Step 5: Verify**

Run: `swift test`
Expected: PASS. (`AppVersionTests` and `HeroSpecTests` read repository files;
confirm neither parses the regions edited above.)

Read the three edited regions once more and confirm every number matches
`ActivityMode` in `Sources/Jumbini/Mood.swift`.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "Document the mood modes and the spoken reactions

The odds table, the reactions table, and the right-click command list all
described behavior this branch changed.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>"
```

---

## Definition of done

- `swift build` and `swift test` are clean.
- Every pre-existing `DogBrainTests` test passes unmodified — `.active`, the
  hold off, and `.wander` are the defaults, so nothing written before this
  branch may have moved.
- The six manual checks in Task 7 Step 5 pass in the running app.
- `JumbiniSettings.swift`, `SettingsPanel.swift`, `AppDelegate.swift`, and
  `EmoteBubble.swift` are unchanged: `git diff --stat origin/main` must not
  list them.
