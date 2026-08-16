# Jumbini Demo Assets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a re-runnable kit that produces nine screen-recorded clips, transparent sprite-sheet hero loops, and six stills for a Jumbini landing page.

**Architecture:** An env-gated `DemoDriver` inside the app plays a JSON timeline of beats into the live `PetScene` through the same entry points the menu and `SystemMonitor` already use, so footage is produced by shipping code paths. A separate `spritefilm` CLI composites the on-disk PNG sprites into transparent sheets with no app launch. A `capture.sh` orchestrator stages windows, records with `screencapture`, and encodes with `ffmpeg`. The pure/impure split mirrors `SystemMonitor`: clock-injected value types carry the logic and are unit-tested, a thin class shell owns the timer.

**Tech Stack:** Swift 6 (language mode v5), SwiftPM, swift-testing (`import Testing`, `@Test`, `#expect`), SpriteKit, ImageIO, bash, ffmpeg, `screencapture`, AppleScript.

**Spec:** `docs/superpowers/specs/2026-08-15-jumbini-demo-assets-design.md`

## Global Constraints

- macOS 14+, Apple Silicon. Swift tools 6.0, `swiftLanguageMode(.v5)`.
- Tests use **swift-testing**, never XCTest. Pattern: `@Test func name() { #expect(...) }` with `@testable import Jumbini`.
- `Scripts/test.sh` must stay green at every commit.
- The driver must be unreachable without `JUMBINI_DEMO` set to a readable file.
- The driver may only trigger behavior the app already has. No new dog behavior.
- Never modify the `gh-pages` branch — it holds `appcast.xml` and `Jumbini-4.2.dmg`, load-bearing for Sparkle auto-updates.
- Sprite art lives in `Sources/Jumbini/Resources/jumba/` as `<state>_<direction>.png`. Classic is unprefixed, shaggy is `shaggy_`-prefixed. Directions spelled exactly: `south south-east east north-east north north-west west south-west`.
- `SpriteLibrary.baseScale` is `2.4`, `sitScale` is `2.9`.
- Output goes to `demo-assets/`, which is gitignored. Binaries are not committed.

---

### Task 1: Demo script model and pure timeline

The value types and the clock-injected timeline. No AppKit, no timer, no app wiring — this task is pure logic and its tests, exactly like `IdleTracker` in `SystemMonitor.swift`.

**Files:**
- Create: `Sources/Jumbini/DemoDriver.swift`
- Test: `Tests/JumbiniTests/DemoDriverTests.swift`

**Interfaces:**
- Consumes: `DogCommand`, `SystemSignal`, `Trick`, `ToyKind` from `Sources/Jumbini/DogBrain.swift`.
- Produces: `DemoBeat`, `DemoBeat.Action`, `DemoScript`, `DemoTimeline`, `DemoParseError`, and `DemoScript.init(json:)`. Task 2 consumes `DemoScript` and `DemoTimeline`. Task 3 consumes `DemoScript.init(json:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/JumbiniTests/DemoDriverTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import Jumbini

// The DemoDriver class owns a Timer and a scene, so it can't run in a test
// process. Its decisions can: parsing a script and deciding which beats are
// due are both pure and clock-injected, which is what these cover.

// MARK: - Timeline

private func script(_ beats: [DemoBeat]) -> DemoScript {
    DemoScript(name: "t", duration: 10, showCursor: false, beats: beats)
}

@Test func timelineReleasesNothingBeforeTheFirstBeat() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 1.0, action: .system(.fansUp)),
    ]))
    #expect(timeline.due(at: 0.0).isEmpty)
    #expect(timeline.due(at: 0.99).isEmpty)
}

@Test func timelineReleasesABeatOnceItsTimeArrives() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 1.0, action: .system(.fansUp)),
    ]))
    #expect(timeline.due(at: 1.0) == [DemoBeat(at: 1.0, action: .system(.fansUp))])
}

@Test func timelineNeverReleasesTheSameBeatTwice() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 1.0, action: .system(.fansUp)),
    ]))
    #expect(timeline.due(at: 1.5).count == 1)
    #expect(timeline.due(at: 2.0).isEmpty)
}

// A dropped frame or a slow launch means one tick can straddle several beats.
// They must all come out, in order, rather than the late ones being skipped.
@Test func timelineCatchesUpOnEveryBeatAStallSkippedOver() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 1.0, action: .command(.sit)),
        DemoBeat(at: 2.0, action: .command(.spin)),
        DemoBeat(at: 3.0, action: .command(.zoomies)),
    ]))
    let due = timeline.due(at: 5.0)
    #expect(due.map(\.action) == [.command(.sit), .command(.spin), .command(.zoomies)])
}

@Test func timelineSortsBeatsThatArriveOutOfOrder() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 3.0, action: .command(.zoomies)),
        DemoBeat(at: 1.0, action: .command(.sit)),
    ]))
    #expect(timeline.due(at: 5.0).map(\.action) == [.command(.sit), .command(.zoomies)])
}

@Test func timelineIsFinishedOnlyAfterTheLastBeatIsOut() {
    var timeline = DemoTimeline(script: script([
        DemoBeat(at: 1.0, action: .command(.sit)),
    ]))
    #expect(!timeline.isFinished)
    _ = timeline.due(at: 1.0)
    #expect(timeline.isFinished)
}

// MARK: - Parsing

@Test func parsesASystemBeat() throws {
    let json = """
    {"name":"thermal","duration":8.0,"showCursor":false,
     "beats":[{"at":0.5,"kind":"system","signal":"fansUp"}]}
    """
    let parsed = try DemoScript(json: Data(json.utf8))
    #expect(parsed.name == "thermal")
    #expect(parsed.duration == 8.0)
    #expect(parsed.showCursor == false)
    #expect(parsed.beats == [DemoBeat(at: 0.5, action: .system(.fansUp))])
}

@Test func parsesEveryPlainCommand() throws {
    let names = ["sit", "lieDown", "spin", "fetch", "spinForever", "zoomies", "relax"]
    let expected: [DogCommand] = [.sit, .lieDown, .spin, .fetch, .spinForever, .zoomies, .relax]
    for (name, command) in zip(names, expected) {
        let json = """
        {"name":"t","duration":1,"showCursor":false,
         "beats":[{"at":0,"kind":"command","command":"\(name)"}]}
        """
        let parsed = try DemoScript(json: Data(json.utf8))
        #expect(parsed.beats.first?.action == .command(command))
    }
}

@Test func parsesTricksAndToysByTheirQualifiedNames() throws {
    let json = """
    {"name":"t","duration":1,"showCursor":false,"beats":[
      {"at":0,"kind":"command","command":"trick:Shake"},
      {"at":1,"kind":"command","command":"toy:frisbee"}
    ]}
    """
    let parsed = try DemoScript(json: Data(json.utf8))
    #expect(parsed.beats.map(\.action) == [.command(.trick(.shake)), .command(.toy(.frisbee))])
}

@Test func parsesACursorBeat() throws {
    let json = """
    {"name":"t","duration":1,"showCursor":true,
     "beats":[{"at":2,"kind":"cursor","x":800,"y":400}]}
    """
    let parsed = try DemoScript(json: Data(json.utf8))
    #expect(parsed.showCursor)
    #expect(parsed.beats.first?.action == .cursor(CGPoint(x: 800, y: 400)))
}

// A typo that silently dropped a beat would surface as a clip where nothing
// happens — after the recording session is over. Fail at parse instead.
@Test func rejectsAnUnknownSignalRatherThanSkippingIt() {
    let json = """
    {"name":"t","duration":1,"showCursor":false,
     "beats":[{"at":0,"kind":"system","signal":"fansUpp"}]}
    """
    #expect(throws: DemoParseError.unknownSignal("fansUpp")) {
        try DemoScript(json: Data(json.utf8))
    }
}

@Test func rejectsAnUnknownCommand() {
    let json = """
    {"name":"t","duration":1,"showCursor":false,
     "beats":[{"at":0,"kind":"command","command":"rollover"}]}
    """
    #expect(throws: DemoParseError.unknownCommand("rollover")) {
        try DemoScript(json: Data(json.utf8))
    }
}

@Test func rejectsAnUnknownTrick() {
    let json = """
    {"name":"t","duration":1,"showCursor":false,
     "beats":[{"at":0,"kind":"command","command":"trick:Backflip"}]}
    """
    #expect(throws: DemoParseError.unknownTrick("Backflip")) {
        try DemoScript(json: Data(json.utf8))
    }
}

@Test func rejectsAnUnknownBeatKind() {
    let json = """
    {"name":"t","duration":1,"showCursor":false,
     "beats":[{"at":0,"kind":"teleport"}]}
    """
    #expect(throws: DemoParseError.unknownKind("teleport")) {
        try DemoScript(json: Data(json.utf8))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Scripts/test.sh --filter DemoDriverTests`
Expected: compile failure — `cannot find 'DemoBeat' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/Jumbini/DemoDriver.swift`:

```swift
import Foundation
import CoreGraphics

// MARK: - Pure timeline logic
//
// Same shape as SystemMonitor's trackers: the decisions are pure and
// clock-injected, so they are unit-tested without a Mac underneath. The
// impure half — the timer and the scene — lives in DemoDriver at the bottom.

/// One scripted moment. Every action resolves to a call the app already
/// makes; the driver cannot express anything the dog can't already do.
struct DemoBeat: Equatable {
    enum Action: Equatable {
        case command(DogCommand)
        case system(SystemSignal)
        case cursor(CGPoint)
        case wait
    }

    let at: TimeInterval
    let action: Action
}

enum DemoParseError: Error, Equatable {
    case unknownKind(String)
    case unknownSignal(String)
    case unknownCommand(String)
    case unknownTrick(String)
    case unknownToy(String)
    case malformed(String)
}

struct DemoScript: Equatable {
    let name: String
    let duration: TimeInterval
    /// Whether the recorder should draw the pointer. Distinct from the
    /// `.cursor` beat action, which moves it.
    let showCursor: Bool
    let beats: [DemoBeat]
}

extension DemoScript {
    init(json data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = root["name"] as? String,
              let duration = root["duration"] as? Double,
              let rawBeats = root["beats"] as? [[String: Any]] else {
            throw DemoParseError.malformed("expected name, duration and beats")
        }
        self.init(
            name: name,
            duration: duration,
            showCursor: root["showCursor"] as? Bool ?? false,
            beats: try rawBeats.map(DemoBeat.init(json:))
        )
    }
}

extension DemoBeat {
    init(json object: [String: Any]) throws {
        guard let at = object["at"] as? Double else {
            throw DemoParseError.malformed("beat without an `at`")
        }
        let kind = object["kind"] as? String ?? ""
        switch kind {
        case "wait":
            self.init(at: at, action: .wait)
        case "system":
            let name = object["signal"] as? String ?? ""
            guard let signal = SystemSignal(demoName: name) else {
                throw DemoParseError.unknownSignal(name)
            }
            self.init(at: at, action: .system(signal))
        case "command":
            let name = object["command"] as? String ?? ""
            self.init(at: at, action: .command(try DogCommand(demoName: name)))
        case "cursor":
            guard let x = object["x"] as? Double, let y = object["y"] as? Double else {
                throw DemoParseError.malformed("cursor beat without x and y")
            }
            self.init(at: at, action: .cursor(CGPoint(x: x, y: y)))
        default:
            throw DemoParseError.unknownKind(kind)
        }
    }
}

extension SystemSignal {
    /// Spelled exactly like the case names, so a script reads like the code.
    init?(demoName name: String) {
        switch name {
        case "buildFinished": self = .buildFinished
        case "idleBegan": self = .idleBegan
        case "idleEnded": self = .idleEnded
        case "fansUp": self = .fansUp
        case "batteryLow": self = .batteryLow
        case "batteryNormal": self = .batteryNormal
        case "dndOn": self = .dndOn
        case "dndOff": self = .dndOff
        default: return nil
        }
    }
}

extension DogCommand {
    /// Plain cases by name; the two with payloads as `trick:<Title>` and
    /// `toy:<kind>`. Tricks use the enum's raw value, which is the menu title.
    init(demoName name: String) throws {
        if let rest = name.dropPrefixIfPresent("trick:") {
            guard let trick = Trick(rawValue: String(rest)) else {
                throw DemoParseError.unknownTrick(String(rest))
            }
            self = .trick(trick)
            return
        }
        if let rest = name.dropPrefixIfPresent("toy:") {
            switch rest {
            case "frisbee": self = .toy(.frisbee)
            case "squeaky": self = .toy(.squeaky)
            case "rope": self = .toy(.rope)
            default: throw DemoParseError.unknownToy(String(rest))
            }
            return
        }
        switch name {
        case "sit": self = .sit
        case "lieDown": self = .lieDown
        case "spin": self = .spin
        case "fetch": self = .fetch
        case "spinForever": self = .spinForever
        case "zoomies": self = .zoomies
        case "relax": self = .relax
        default: throw DemoParseError.unknownCommand(name)
        }
    }
}

private extension String {
    func dropPrefixIfPresent(_ prefix: String) -> Substring? {
        hasPrefix(prefix) ? dropFirst(prefix.count) : nil
    }
}

/// Hands out beats whose time has come. Clock-injected: the caller decides
/// what "now" means, so a test can jump straight to t=5 and a slow launch
/// can't skip a beat.
struct DemoTimeline {
    private let beats: [DemoBeat]
    private var nextIndex = 0

    init(script: DemoScript) {
        // Stable sort by time: a script author listing beats out of order
        // gets the obvious behaviour rather than a silently dropped beat.
        self.beats = script.beats.enumerated()
            .sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }
            .map(\.element)
    }

    var isFinished: Bool { nextIndex >= beats.count }

    /// Every beat due at or before `elapsed` that hasn't been handed out yet.
    mutating func due(at elapsed: TimeInterval) -> [DemoBeat] {
        var out: [DemoBeat] = []
        while nextIndex < beats.count, beats[nextIndex].at <= elapsed {
            out.append(beats[nextIndex])
            nextIndex += 1
        }
        return out
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Scripts/test.sh --filter DemoDriverTests`
Expected: PASS, 14 tests.

- [ ] **Step 5: Run the whole suite**

Run: `Scripts/test.sh`
Expected: PASS, no regressions.

- [ ] **Step 6: Commit**

```bash
git add Sources/Jumbini/DemoDriver.swift Tests/JumbiniTests/DemoDriverTests.swift
git commit -m "Add demo script model and pure timeline"
```

---

### Task 2: Driver shell, env gating, and app wiring

The impure half plus the two touch points in existing code. `PetScene.receive(_:)` is already internal so ambient signals need no change there; commands need a small extraction out of the `@objc private` menu handler.

**Files:**
- Modify: `Sources/Jumbini/DemoDriver.swift` (append the `DemoDriver` class)
- Modify: `Sources/Jumbini/PetScene.swift:2196-2204` (extract `perform(_:)` from `commandChosen`)
- Modify: `Sources/Jumbini/AppDelegate.swift:27-51` (start the driver), `:53-58` (stop it)
- Test: `Tests/JumbiniTests/DemoDriverTests.swift` (append gating tests)

**Interfaces:**
- Consumes: `DemoScript`, `DemoTimeline` from Task 1.
- Produces: `DemoDriver.fromEnvironment(_:) -> DemoDriver?`, `DemoDriver.onBeat: ((DemoBeat) -> Void)?`, `DemoDriver.start()`, `DemoDriver.stop()`, and `PetScene.perform(_ command: DogCommand)`.

- [ ] **Step 1: Write the failing gating tests**

Append to `Tests/JumbiniTests/DemoDriverTests.swift`:

```swift
// MARK: - Gating
//
// The one property that matters for a shipping app: a normal launch cannot
// reach the driver. Everything else about it is a convenience.

@Test func noDriverWithoutTheEnvironmentVariable() {
    #expect(DemoDriver.fromEnvironment([:]) == nil)
}

@Test func noDriverWhenTheScriptPathDoesNotExist() {
    let env = ["JUMBINI_DEMO": "/nonexistent/path/to/nowhere.json"]
    #expect(DemoDriver.fromEnvironment(env) == nil)
}

@Test func noDriverWhenTheScriptIsNotValidJSON() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("bad-\(UUID().uuidString).json")
    try Data("not json at all".utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(DemoDriver.fromEnvironment(["JUMBINI_DEMO": url.path]) == nil)
}

@Test func driverIsBuiltFromAValidScriptOnDisk() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("good-\(UUID().uuidString).json")
    let json = """
    {"name":"probe","duration":4.0,"showCursor":true,
     "beats":[{"at":1,"kind":"command","command":"sit"}]}
    """
    try Data(json.utf8).write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }

    let driver = DemoDriver.fromEnvironment(["JUMBINI_DEMO": url.path])
    #expect(driver?.script.name == "probe")
    #expect(driver?.script.duration == 4.0)
    #expect(driver?.script.showCursor == true)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `Scripts/test.sh --filter DemoDriverTests`
Expected: compile failure — `cannot find 'DemoDriver' in scope`.

- [ ] **Step 3: Append the driver shell**

Append to `Sources/Jumbini/DemoDriver.swift`:

```swift
// MARK: - The impure half
//
// Mirrors SystemMonitor: a timer, a closure the app layer wires to the
// scene, and a stop(). Nothing here decides anything.

/// Plays a scripted timeline into the running scene. Built ONLY when
/// `JUMBINI_DEMO` names a readable, parseable script — a normal launch
/// never has one, so a normal launch never has a driver.
///
/// This exists so the landing-page footage can be re-shot on demand. Every
/// beat it plays goes through the same entry point as a menu click or a
/// SystemMonitor signal, so what gets filmed is the shipping behaviour and
/// not a special demo mode of the dog.
final class DemoDriver {
    let script: DemoScript
    /// Delivered on the main thread, like SystemMonitor.onSignal.
    var onBeat: ((DemoBeat) -> Void)?
    /// Called once when the script's duration is up.
    var onFinish: (() -> Void)?

    private var timeline: DemoTimeline
    private var timer: Timer?
    private var startedAt: Date?

    /// Beats are checked 30 times a second — fine enough that a beat lands
    /// within a frame or two of its mark at 60fps capture.
    private static let tick: TimeInterval = 1.0 / 30.0

    init(script: DemoScript) {
        self.script = script
        self.timeline = DemoTimeline(script: script)
    }

    /// The gate. A missing variable, an unreadable file, or a script that
    /// doesn't parse all mean the same thing: no driver, app behaves normally.
    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DemoDriver? {
        guard let path = environment["JUMBINI_DEMO"] else { return nil }
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        guard let script = try? DemoScript(json: data) else { return nil }
        return DemoDriver(script: script)
    }

    func start() {
        guard timer == nil else { return }
        startedAt = Date()
        let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
            self?.fire()
        }
        // .common so the beats keep landing while a menu is tracking.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func fire() {
        guard let startedAt else { return }
        let elapsed = Date().timeIntervalSince(startedAt)
        for beat in timeline.due(at: elapsed) {
            onBeat?(beat)
        }
        if elapsed >= script.duration {
            stop()
            onFinish?()
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `Scripts/test.sh --filter DemoDriverTests`
Expected: PASS, 18 tests (14 from Task 1 plus these 4).

- [ ] **Step 5: Extract the command entry point in PetScene**

In `Sources/Jumbini/PetScene.swift`, replace the body of `commandChosen` (currently at 2196-2204) with a call to a new internal method. Replace:

```swift
    @objc private func commandChosen(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DogCommand else { return }
        let effects = brain.handle(.command(command), at: lastTime)
        apply(effects: effects)
        // `handleCommand` returns nothing for exactly one reason: he's in
        // your arms and taking no orders. A shrug beats a menu item that
        // silently does nothing.
        if effects.isEmpty { showEmote("icon_question") }
    }
```

with:

```swift
    @objc private func commandChosen(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? DogCommand else { return }
        perform(command)
    }

    /// Run a command as though it had been picked from his right-click menu.
    /// Not private: the demo driver plays scripted commands through here, so
    /// recorded footage goes down the same path a real click does.
    func perform(_ command: DogCommand) {
        let effects = brain.handle(.command(command), at: lastTime)
        apply(effects: effects)
        // `handleCommand` returns nothing for exactly one reason: he's in
        // your arms and taking no orders. A shrug beats a menu item that
        // silently does nothing.
        if effects.isEmpty { showEmote("icon_question") }
    }
```

- [ ] **Step 6: Wire the driver in AppDelegate**

In `Sources/Jumbini/AppDelegate.swift`, add the stored property next to `systemMonitor` (near line 22):

```swift
    // Demo capture: nil on every normal launch. See DemoDriver.fromEnvironment.
    private var demoDriver: DemoDriver?
```

Add the start call in `applicationDidFinishLaunching`, immediately after `startSystemMonitor()` and before the Jumbini Cam block:

```swift
        // Demo capture block: no-op unless JUMBINI_DEMO names a script.
        startDemoDriver()
        // Demo capture block end.
```

Add the teardown in `applicationWillTerminate`, after the `systemMonitor` lines:

```swift
        demoDriver?.stop()
        demoDriver = nil
```

Add the method next to `startSystemMonitor()`:

```swift
    /// Landing-page capture only. Returns immediately on a normal launch
    /// because `fromEnvironment` finds no JUMBINI_DEMO to act on.
    private func startDemoDriver() {
        guard let driver = DemoDriver.fromEnvironment() else { return }
        driver.onBeat = { [weak self] beat in
            guard let self, let scene = self.scene else { return }
            switch beat.action {
            case .command(let command):
                scene.perform(command)
            case .system(let signal):
                scene.receive(signal)
            case .cursor(let point):
                // Warping needs no Accessibility permission, unlike posting
                // a synthetic move event. Top-left origin, like the display.
                CGWarpMouseCursorPosition(point)
            case .wait:
                break
            }
        }
        driver.onFinish = { NSApp.terminate(nil) }
        driver.start()
        demoDriver = driver
    }
```

- [ ] **Step 7: Verify the app still builds and behaves**

Run: `swift build && Scripts/test.sh`
Expected: build succeeds, full suite passes.

Then confirm the gate by hand — launch normally and check the driver never engages:

Run: `swift run Jumbini`
Expected: the dog appears and behaves exactly as before; right-click commands still work. Quit with ⌘Q.

- [ ] **Step 8: Commit**

```bash
git add Sources/Jumbini/DemoDriver.swift Sources/Jumbini/PetScene.swift \
        Sources/Jumbini/AppDelegate.swift Tests/JumbiniTests/DemoDriverTests.swift
git commit -m "Add env-gated demo driver and wire it to the scene"
```

---

### Task 3: The nine shot scripts, with a test that they are real

JSON timelines plus a test that every one of them parses and names only real enum cases. Without that test a typo surfaces as a clip where nothing happens, discovered after the recording session.

**Files:**
- Create: `Tools/demo/shots/climb.json`, `thermal.json`, `build-party.json`, `quiet.json`, `fetch.json`, `toys.json`, `tricks.json`, `pounce.json`, `charm.json`
- Test: `Tests/JumbiniTests/DemoShotsTests.swift`

**Interfaces:**
- Consumes: `DemoScript.init(json:)` from Task 1.
- Produces: the shot files, consumed by `capture.sh` in Task 6 by filename.

- [ ] **Step 1: Write the failing test**

Create `Tests/JumbiniTests/DemoShotsTests.swift`:

```swift
import Testing
import Foundation
@testable import Jumbini

// The shot scripts are the input to a recording session that a human sits
// through. A typo in a signal name would parse as "no beat here" and show up
// as a clip where the dog does nothing — after the session. So they are
// validated as part of the build instead.

private let shotsDirectory: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()   // JumbiniTests
    .deletingLastPathComponent()   // Tests
    .deletingLastPathComponent()   // repo root
    .appendingPathComponent("Tools/demo/shots")

private func shotURLs() throws -> [URL] {
    try FileManager.default
        .contentsOfDirectory(at: shotsDirectory, includingPropertiesForKeys: nil)
        .filter { $0.pathExtension == "json" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

@Test func everyShotInTheDirectoryParses() throws {
    let urls = try shotURLs()
    #expect(!urls.isEmpty)
    for url in urls {
        let data = try Data(contentsOf: url)
        // Throws on an unknown signal, command, trick, toy or kind.
        _ = try DemoScript(json: data)
    }
}

@Test func theNinePlannedShotsAreAllPresent() throws {
    let names = try Set(shotURLs().map { $0.deletingPathExtension().lastPathComponent })
    let planned: Set<String> = [
        "climb", "thermal", "build-party", "quiet",
        "fetch", "toys", "tricks", "pounce", "charm",
    ]
    #expect(names == planned)
}

@Test func everyBeatLandsInsideItsClipDuration() throws {
    for url in try shotURLs() {
        let script = try DemoScript(json: Data(contentsOf: url))
        for beat in script.beats {
            #expect(beat.at >= 0, "\(script.name): beat at \(beat.at) is negative")
            #expect(
                beat.at <= script.duration,
                "\(script.name): beat at \(beat.at) is past the \(script.duration)s end"
            )
        }
    }
}

@Test func scriptNamesMatchTheirFilenames() throws {
    for url in try shotURLs() {
        let script = try DemoScript(json: Data(contentsOf: url))
        #expect(script.name == url.deletingPathExtension().lastPathComponent)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test.sh --filter DemoShotsTests`
Expected: FAIL — the shots directory does not exist.

- [ ] **Step 3: Create the ambient shot scripts**

These four are the ones that cannot be filmed any other way.

`Tools/demo/shots/thermal.json`:

```json
{
  "name": "thermal",
  "duration": 8.0,
  "showCursor": false,
  "beats": [
    { "at": 1.0, "kind": "system", "signal": "fansUp" }
  ]
}
```

`Tools/demo/shots/build-party.json`:

```json
{
  "name": "build-party",
  "duration": 7.0,
  "showCursor": false,
  "beats": [
    { "at": 1.5, "kind": "system", "signal": "buildFinished" }
  ]
}
```

`Tools/demo/shots/quiet.json`:

```json
{
  "name": "quiet",
  "duration": 12.0,
  "showCursor": false,
  "beats": [
    { "at": 1.0, "kind": "system", "signal": "batteryLow" },
    { "at": 5.0, "kind": "system", "signal": "idleBegan" },
    { "at": 10.0, "kind": "system", "signal": "idleEnded" }
  ]
}
```

`Tools/demo/shots/climb.json` — the flagship. The dog's own climb decision is 5%, so the beats here settle him first and the runner's window motion (Task 6) supplies the ride and the shake-off:

```json
{
  "name": "climb",
  "duration": 15.0,
  "showCursor": false,
  "beats": [
    { "at": 0.5, "kind": "cursor", "x": 1600, "y": 900 },
    { "at": 1.0, "kind": "command", "command": "relax" },
    { "at": 14.5, "kind": "wait" }
  ]
}
```

- [ ] **Step 4: Create the play shot scripts**

`Tools/demo/shots/fetch.json` — the throw target is a left-click the runner supplies; the cursor beat puts the pointer where the ball should land:

```json
{
  "name": "fetch",
  "duration": 12.0,
  "showCursor": true,
  "beats": [
    { "at": 1.0, "kind": "command", "command": "fetch" },
    { "at": 2.0, "kind": "cursor", "x": 1700, "y": 500 },
    { "at": 11.5, "kind": "wait" }
  ]
}
```

`Tools/demo/shots/toys.json`:

```json
{
  "name": "toys",
  "duration": 14.0,
  "showCursor": true,
  "beats": [
    { "at": 0.5, "kind": "command", "command": "toy:frisbee" },
    { "at": 1.5, "kind": "cursor", "x": 1500, "y": 600 },
    { "at": 6.0, "kind": "command", "command": "toy:squeaky" },
    { "at": 10.0, "kind": "command", "command": "toy:rope" }
  ]
}
```

`Tools/demo/shots/tricks.json`:

```json
{
  "name": "tricks",
  "duration": 10.0,
  "showCursor": false,
  "beats": [
    { "at": 0.8, "kind": "command", "command": "trick:Shake" },
    { "at": 3.0, "kind": "command", "command": "trick:High Five" },
    { "at": 5.2, "kind": "command", "command": "trick:Play Dead" },
    { "at": 7.6, "kind": "command", "command": "trick:Roll Over" }
  ]
}
```

- [ ] **Step 5: Create the character shot scripts**

`Tools/demo/shots/pounce.json` — he trots to the pointer, switches to the sniff pose within ~60pt, and a finished sniff escalates to stalk-and-pounce six times in ten. The cursor walk is what draws him in:

```json
{
  "name": "pounce",
  "duration": 10.0,
  "showCursor": true,
  "beats": [
    { "at": 0.5, "kind": "cursor", "x": 900, "y": 700 },
    { "at": 2.5, "kind": "cursor", "x": 1100, "y": 640 },
    { "at": 4.0, "kind": "cursor", "x": 1180, "y": 700 },
    { "at": 5.5, "kind": "cursor", "x": 1120, "y": 760 },
    { "at": 7.0, "kind": "cursor", "x": 1200, "y": 720 }
  ]
}
```

`Tools/demo/shots/charm.json` — petting and dragging are real mouse input the runner supplies; the beats cover what can be commanded:

```json
{
  "name": "charm",
  "duration": 14.0,
  "showCursor": true,
  "beats": [
    { "at": 0.5, "kind": "command", "command": "sit" },
    { "at": 4.0, "kind": "command", "command": "relax" },
    { "at": 8.0, "kind": "command", "command": "spin" },
    { "at": 11.0, "kind": "command", "command": "lieDown" }
  ]
}
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `Scripts/test.sh --filter DemoShotsTests`
Expected: PASS, 4 tests.

- [ ] **Step 7: Run the whole suite**

Run: `Scripts/test.sh`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add Tools/demo/shots Tests/JumbiniTests/DemoShotsTests.swift
git commit -m "Add the nine demo shot scripts and validate them in tests"
```

---

### Task 4: Hero animation specs and the drift guard

`spritefilm` must animate the hero at the same rate as the app or the landing page slowly stops matching the product. The full animation table can't be extracted cleanly — most poses resolve through `make(...) ?? make(...)` fallback chains that depend on which PNGs exist on disk. The five poses the hero needs (`idle`, `walk`, `run`, `sit`, `spin`) have no fallbacks, so only those are extracted.

**Files:**
- Modify: `Sources/Jumbini/SpriteLoader.swift:105-125` (extract the five fallback-free cases)
- Create: `Tools/demo/animations.json`
- Test: `Tests/JumbiniTests/HeroSpecTests.swift`

**Interfaces:**
- Consumes: `Facing`, `DogAnimation`, `SpriteLibrary.baseScale` from `SpriteLoader.swift`.
- Produces: `AnimationSpec` (with `frames: [String]`, `fps: Double`, `scale: CGFloat`) and `SpriteLibrary.heroSpec(for:facing:) -> AnimationSpec?`. Task 5's `spritefilm` reads `Tools/demo/animations.json`, which this task's test pins to `heroSpec`.

- [ ] **Step 1: Write the failing test**

Create `Tests/JumbiniTests/HeroSpecTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
@testable import Jumbini

// spritefilm renders the landing page's hero loops from the same PNGs the app
// uses, and has to run them at the same rate — otherwise the dog on the
// website drifts out of step with the dog in the product, one release at a
// time, and nobody notices. The CLI reads animations.json; this pins that file
// to SpriteLibrary so the build fails instead of the marketing.

@Test func walkIsTheTwoRunFramesAtFourFrames() {
    #expect(
        SpriteLibrary.heroSpec(for: .walk, facing: .south)
            == AnimationSpec(frames: ["run1_south", "run2_south"], fps: 4, scale: 2.4)
    )
}

@Test func runReusesTheWalkFramesFasterRatherThanNewArt() {
    let walk = SpriteLibrary.heroSpec(for: .walk, facing: .east)
    let run = SpriteLibrary.heroSpec(for: .run, facing: .east)
    #expect(walk?.frames == run?.frames)
    #expect(run?.fps == 13)
}

@Test func sitCarriesItsOwnScaleBecauseTheArtWasExportedSmaller() {
    #expect(
        SpriteLibrary.heroSpec(for: .sit, facing: .south)
            == AnimationSpec(frames: ["sit_south"], fps: 1, scale: 2.9)
    )
}

@Test func spinCyclesAllEightIdleRotations() {
    let spec = SpriteLibrary.heroSpec(for: .spin, facing: .south)
    #expect(spec?.frames == [
        "idle_south", "idle_south-west", "idle_west", "idle_north-west",
        "idle_north", "idle_north-east", "idle_east", "idle_south-east",
    ])
    #expect(spec?.fps == 24)
}

@Test func posesWithFallbackChainsAreDeliberatelyNotHeroSpecs() {
    // .pounce, .stalk, .peek and friends resolve against what's on disk, so
    // they can't be described by a static table. Asking is nil, not a crash.
    #expect(SpriteLibrary.heroSpec(for: .pounce, facing: .south) == nil)
    #expect(SpriteLibrary.heroSpec(for: .peek, facing: .south) == nil)
}

// MARK: - The drift guard itself

private let animationsJSON: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Tools/demo/animations.json")

@Test func spritefilmsTableMatchesTheAppForEveryPoseAndDirection() throws {
    let data = try Data(contentsOf: animationsJSON)
    let table = try #require(
        JSONSerialization.jsonObject(with: data) as? [String: [String: [String: Any]]]
    )

    let poses: [(String, DogAnimation)] = [
        ("idle", .idle), ("walk", .walk), ("run", .run), ("sit", .sit), ("spin", .spin),
    ]

    for (poseName, animation) in poses {
        let byDirection = try #require(table[poseName], "animations.json is missing \(poseName)")
        for facing in Facing.allCases {
            let expected = try #require(SpriteLibrary.heroSpec(for: animation, facing: facing))
            let actual = try #require(
                byDirection[facing.fileSuffix],
                "animations.json is missing \(poseName)/\(facing.fileSuffix)"
            )
            #expect(actual["frames"] as? [String] == expected.frames)
            #expect(actual["fps"] as? Double == expected.fps)
            #expect(CGFloat(actual["scale"] as? Double ?? -1) == expected.scale)
        }
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `Scripts/test.sh --filter HeroSpecTests`
Expected: compile failure — `cannot find 'AnimationSpec' in scope`.

- [ ] **Step 3: Extract the spec type in SpriteLoader**

In `Sources/Jumbini/SpriteLoader.swift`, add above `final class SpriteLibrary`:

```swift
/// Frame list, rate and scale for a pose, with no textures attached.
///
/// Only the poses that resolve to exactly one filename per frame get one of
/// these. Most of the table falls back — `make(["pounce_\(d)"]) ?? make(["run2_\(d)"])`
/// — and what a fallback resolves to depends on which PNGs are on disk, which
/// a static description can't capture. The five that don't fall back are the
/// five the landing page's hero loops need, and pulling them out is what lets
/// `Tools/demo/spritefilm` render them at the app's own rate.
struct AnimationSpec: Equatable {
    let frames: [String]
    let fps: Double
    let scale: CGFloat
}
```

Add inside `SpriteLibrary`, next to `animation(for:facing:)`:

```swift
    /// The fallback-free poses, described rather than rendered. nil for every
    /// pose whose art resolves against what's on disk.
    static func heroSpec(for dogAnimation: DogAnimation, facing: Facing) -> AnimationSpec? {
        let d = facing.fileSuffix
        switch dogAnimation {
        case .idle:
            return AnimationSpec(frames: ["idle_\(d)"], fps: 1, scale: baseScale)
        case .walk:
            return AnimationSpec(frames: ["run1_\(d)", "run2_\(d)"], fps: 4, scale: baseScale)
        case .run:
            return AnimationSpec(frames: ["run1_\(d)", "run2_\(d)"], fps: 13, scale: baseScale)
        case .sit:
            return AnimationSpec(frames: ["sit_\(d)"], fps: 1, scale: sitScale)
        case .spin:
            let cycle = [Facing.south, .southWest, .west, .northWest,
                         .north, .northEast, .east, .southEast]
            return AnimationSpec(
                frames: cycle.map { "idle_\($0.fileSuffix)" }, fps: 24, scale: baseScale
            )
        default:
            return nil
        }
    }
```

Change `sitScale` from `private static let` to `static let` so `heroSpec` and the test can read it. Then rewrite those five cases in `animation(for:facing:)` to go through the spec, so there is one source of truth:

```swift
        case .idle, .walk, .run, .sit, .spin:
            guard let spec = Self.heroSpec(for: dogAnimation, facing: facing) else { return nil }
            return make(spec.frames, fps: spec.fps, scale: spec.scale)
```

Delete the individual `.idle`, `.walk`, `.run`, `.sit`, `.spin` cases this replaces. Leave `.carryWalk`, `.lie`, `.sleep`, `.dangle` and everything else exactly as they are — `.carryWalk` shares frames with walk but at 6fps and is not a hero pose, and `.dangle` borrows `sit_south` at `sitScale` regardless of facing.

- [ ] **Step 4: Generate animations.json**

Create `Tools/demo/animations.json` with all five poses across all eight directions. Generate it rather than hand-typing 40 entries — from the repo root:

```bash
swift Tools/demo/generate_animations_json.swift > Tools/demo/animations.json
```

Create `Tools/demo/generate_animations_json.swift`:

```swift
// Emits animations.json from the same table SpriteLibrary uses. Standalone so
// it can run without building the app; HeroSpecTests is what keeps the two
// honest with each other.
import Foundation

let directions = ["south", "south-east", "east", "north-east",
                  "north", "north-west", "west", "south-west"]
let spinCycle = ["south", "south-west", "west", "north-west",
                 "north", "north-east", "east", "south-east"]
let baseScale = 2.4
let sitScale = 2.9

func spec(pose: String, d: String) -> [String: Any] {
    switch pose {
    case "idle": return ["frames": ["idle_\(d)"], "fps": 1.0, "scale": baseScale]
    case "walk": return ["frames": ["run1_\(d)", "run2_\(d)"], "fps": 4.0, "scale": baseScale]
    case "run":  return ["frames": ["run1_\(d)", "run2_\(d)"], "fps": 13.0, "scale": baseScale]
    case "sit":  return ["frames": ["sit_\(d)"], "fps": 1.0, "scale": sitScale]
    case "spin": return ["frames": spinCycle.map { "idle_\($0)" }, "fps": 24.0, "scale": baseScale]
    default: fatalError("unknown pose \(pose)")
    }
}

var table: [String: [String: [String: Any]]] = [:]
for pose in ["idle", "walk", "run", "sit", "spin"] {
    var byDirection: [String: [String: Any]] = [:]
    for d in directions { byDirection[d] = spec(pose: pose, d: d) }
    table[pose] = byDirection
}

let data = try JSONSerialization.data(
    withJSONObject: table, options: [.prettyPrinted, .sortedKeys]
)
FileHandle.standardOutput.write(data)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `Scripts/test.sh --filter HeroSpecTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Run the whole suite**

Run: `Scripts/test.sh`
Expected: PASS. The `SpriteLoader` rewrite is covered by the existing suite plus this one.

- [ ] **Step 7: Commit**

```bash
git add Sources/Jumbini/SpriteLoader.swift Tools/demo/animations.json \
        Tools/demo/generate_animations_json.swift Tests/JumbiniTests/HeroSpecTests.swift
git commit -m "Extract fallback-free animation specs and pin spritefilm's table to them"
```

---

### Task 5: spritefilm — the offline sprite compositor

A standalone SwiftPM package, deliberately not a target of the app package: adding a second executable would put it in `swift build`, CI, and `bundle.sh`'s path for no benefit. It shares nothing with the app but the PNGs on disk and `animations.json`, which Task 4's test already pins.

**Files:**
- Create: `Tools/demo/spritefilm/Package.swift`
- Create: `Tools/demo/spritefilm/Sources/spritefilm/main.swift`
- Create: `Tools/demo/spritefilm/Sources/spritefilm/SheetBuilder.swift`
- Test: `Tools/demo/spritefilm/Tests/spritefilmTests/SheetBuilderTests.swift`

**Interfaces:**
- Consumes: `Tools/demo/animations.json` (Task 4), `Sources/Jumbini/Resources/jumba/*.png`.
- Produces: the `spritefilm` executable with subcommands `sheet`, `still`, `contact`. Task 7 calls it for the stills.

- [ ] **Step 1: Write the failing test**

Create `Tools/demo/spritefilm/Tests/spritefilmTests/SheetBuilderTests.swift`:

```swift
import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import spritefilm

// A sprite sheet is driven by CSS `steps()`, which assumes every cell is
// exactly the same width and that they are laid out left to right with no
// padding. Get either wrong and the dog jitters horizontally as he walks.

private func solidImage(width: Int, height: Int) -> CGImage {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()!
}

@Test func sheetWidthIsCellWidthTimesFrameCount() throws {
    let frames = [solidImage(width: 48, height: 48), solidImage(width: 48, height: 48)]
    let sheet = try SheetBuilder.sheet(from: frames, scale: 1)
    #expect(sheet.width == 96)
    #expect(sheet.height == 48)
}

// Frames are not all the same size on disk — sit was exported at 38px where
// idle is 46px. Cells must still be uniform or steps() drifts.
@Test func unevenFramesArePaddedIntoUniformCells() throws {
    let frames = [solidImage(width: 40, height: 30), solidImage(width: 48, height: 48)]
    let sheet = try SheetBuilder.sheet(from: frames, scale: 1)
    #expect(sheet.width == 96)
    #expect(sheet.height == 48)
}

@Test func scaleMultipliesEveryCell() throws {
    let frames = [solidImage(width: 48, height: 48)]
    let sheet = try SheetBuilder.sheet(from: frames, scale: 2)
    #expect(sheet.width == 96)
    #expect(sheet.height == 96)
}

@Test func theSheetKeepsItsAlphaChannel() throws {
    let frames = [solidImage(width: 48, height: 48)]
    let sheet = try SheetBuilder.sheet(from: frames, scale: 1)
    // Spell the enum out — a bare `.none` here resolves against Optional.
    #expect(sheet.alphaInfo != CGImageAlphaInfo.none)
    #expect(sheet.alphaInfo != CGImageAlphaInfo.noneSkipLast)
}

@Test func anEmptyFrameListIsAnError() {
    #expect(throws: SheetError.noFrames) {
        _ = try SheetBuilder.sheet(from: [], scale: 1)
    }
}

@Test func contactSheetLaysOutAGrid() throws {
    let frames = (0..<8).map { _ in solidImage(width: 48, height: 48) }
    let contact = try SheetBuilder.contactSheet(from: frames, columns: 4, scale: 1)
    #expect(contact.width == 192)
    #expect(contact.height == 96)
}
```

- [ ] **Step 2: Create the package skeleton and run the test to verify it fails**

Create `Tools/demo/spritefilm/Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

// Deliberately its own package rather than a target of the app's: adding a
// second executable to Jumbini's Package.swift would drag it into `swift
// build`, CI and bundle.sh for no benefit. The only thing shared with the app
// is the PNGs on disk and Tools/demo/animations.json, which HeroSpecTests pins.
let package = Package(
    name: "spritefilm",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "spritefilm", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(
            name: "spritefilmTests",
            dependencies: ["spritefilm"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
```

Run: `Scripts/test.sh --package-path Tools/demo/spritefilm`
Expected: FAIL — `cannot find 'SheetBuilder' in scope`.

- [ ] **Step 3: Write SheetBuilder**

Create `Tools/demo/spritefilm/Sources/spritefilm/SheetBuilder.swift`:

```swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum SheetError: Error, Equatable {
    case noFrames
    case missingArt(String)
    case cannotWrite(String)
    case cannotDecode(String)
}

enum SheetBuilder {
    /// A horizontal strip of uniform cells, which is what CSS `steps()`
    /// expects: cell width is the widest frame, so every step advances by the
    /// same distance and the dog doesn't slide around inside his own box.
    /// Frames are centred horizontally and sit on a common baseline, because
    /// the art is not all the same size — sit was exported at 38px where idle
    /// is 46px.
    static func sheet(from frames: [CGImage], scale: CGFloat) throws -> CGImage {
        guard !frames.isEmpty else { throw SheetError.noFrames }

        let cellWidth = Int((CGFloat(frames.map(\.width).max()!) * scale).rounded())
        let cellHeight = Int((CGFloat(frames.map(\.height).max()!) * scale).rounded())

        let context = try makeContext(width: cellWidth * frames.count, height: cellHeight)
        // Nearest-neighbour: this is pixel art, and smoothing turns it to mush.
        context.interpolationQuality = .none

        for (index, frame) in frames.enumerated() {
            let width = CGFloat(frame.width) * scale
            let height = CGFloat(frame.height) * scale
            let x = CGFloat(index * cellWidth) + (CGFloat(cellWidth) - width) / 2
            context.draw(frame, in: CGRect(x: x, y: 0, width: width, height: height))
        }

        guard let image = context.makeImage() else {
            throw SheetError.cannotWrite("sheet")
        }
        return image
    }

    /// A grid, for the eight-rotation contact sheet that shows the art off.
    static func contactSheet(from frames: [CGImage], columns: Int, scale: CGFloat) throws -> CGImage {
        guard !frames.isEmpty else { throw SheetError.noFrames }

        let cellWidth = Int((CGFloat(frames.map(\.width).max()!) * scale).rounded())
        let cellHeight = Int((CGFloat(frames.map(\.height).max()!) * scale).rounded())
        let rows = Int(ceil(Double(frames.count) / Double(columns)))

        let context = try makeContext(width: cellWidth * columns, height: cellHeight * rows)
        context.interpolationQuality = .none

        for (index, frame) in frames.enumerated() {
            let column = index % columns
            // CoreGraphics is bottom-up; fill the grid top-down so the
            // directions read in the order a human expects.
            let row = rows - 1 - (index / columns)
            let width = CGFloat(frame.width) * scale
            let height = CGFloat(frame.height) * scale
            let x = CGFloat(column * cellWidth) + (CGFloat(cellWidth) - width) / 2
            let y = CGFloat(row * cellHeight)
            context.draw(frame, in: CGRect(x: x, y: y, width: width, height: height))
        }

        guard let image = context.makeImage() else {
            throw SheetError.cannotWrite("contact sheet")
        }
        return image
    }

    private static func makeContext(width: Int, height: Int) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw SheetError.cannotWrite("\(width)x\(height)")
        }
        return context
    }

    static func load(_ url: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw SheetError.missingArt(url.lastPathComponent)
        }
        return image
    }

    static func write(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw SheetError.cannotWrite(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SheetError.cannotWrite(url.path)
        }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `Scripts/test.sh --package-path Tools/demo/spritefilm`
Expected: PASS, 6 tests.

- [ ] **Step 5: Write the CLI**

Create `Tools/demo/spritefilm/Sources/spritefilm/main.swift`:

```swift
import Foundation
import CoreGraphics

// spritefilm — renders the landing page's transparent hero assets straight
// from the app's PNGs. No app launch, no window server, no permissions.
//
//   spritefilm sheet   --pose walk --facing east --coat classic --scale 2 --out walk.png
//   spritefilm still   --pose idle --facing south --coat classic --scale 4 --out hero@2x.png
//   spritefilm contact --pose idle --coat classic --scale 2 --out rotations.png

struct Options {
    var pose = "walk"
    var facing = "east"
    var coat = "classic"
    var scale: CGFloat = 2
    var out = URL(fileURLWithPath: "out.png")
    var artDirectory = URL(fileURLWithPath: "Sources/Jumbini/Resources/jumba")
    var animations = URL(fileURLWithPath: "Tools/demo/animations.json")
}

let directions = ["south", "south-east", "east", "north-east",
                  "north", "north-west", "west", "south-west"]

func parse(_ arguments: [String]) -> (String, Options) {
    var options = Options()
    guard arguments.count > 1 else { return ("help", options) }
    let subcommand = arguments[1]
    var index = 2
    while index + 1 < arguments.count {
        let flag = arguments[index], value = arguments[index + 1]
        switch flag {
        case "--pose": options.pose = value
        case "--facing": options.facing = value
        case "--coat": options.coat = value
        case "--scale": options.scale = CGFloat(Double(value) ?? 2)
        case "--out": options.out = URL(fileURLWithPath: value)
        case "--art": options.artDirectory = URL(fileURLWithPath: value)
        case "--animations": options.animations = URL(fileURLWithPath: value)
        default: break
        }
        index += 2
    }
    return (subcommand, options)
}

/// Classic art is unprefixed, every other coat is `<coat>_`-prefixed, and
/// they all share one folder.
func filename(_ frame: String, coat: String) -> String {
    coat == "classic" ? "\(frame).png" : "\(coat)_\(frame).png"
}

/// Only `pair` takes a second coat, so it stays out of `Options`.
func parseCoat2(_ arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: "--coat2"), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func frames(pose: String, facing: String, options: Options) throws -> [String] {
    let data = try Data(contentsOf: options.animations)
    guard let table = try JSONSerialization.jsonObject(with: data)
            as? [String: [String: [String: Any]]],
          let spec = table[pose]?[facing],
          let list = spec["frames"] as? [String] else {
        throw SheetError.missingArt("\(pose)/\(facing) in animations.json")
    }
    return list
}

func images(_ names: [String], options: Options) throws -> [CGImage] {
    try names.map { name in
        let url = options.artDirectory
            .appendingPathComponent(filename(name, coat: options.coat))
        return try SheetBuilder.load(url)
    }
}

let (subcommand, options) = parse(CommandLine.arguments)

do {
    switch subcommand {
    case "sheet":
        let names = try frames(pose: options.pose, facing: options.facing, options: options)
        let sheet = try SheetBuilder.sheet(
            from: try images(names, options: options), scale: options.scale
        )
        try SheetBuilder.write(sheet, to: options.out)
        // The CSS consumer needs the cell count and width; print them rather
        // than making the caller open the PNG in an editor to find out.
        print("frames=\(names.count) cell=\(sheet.width / names.count) height=\(sheet.height)")

    case "still":
        let names = try frames(pose: options.pose, facing: options.facing, options: options)
        let first = try images([names[0]], options: options)
        try SheetBuilder.write(
            try SheetBuilder.sheet(from: first, scale: options.scale), to: options.out
        )
        print("wrote \(options.out.lastPathComponent)")

    case "contact":
        let names = try directions.map { direction -> String in
            try frames(pose: options.pose, facing: direction, options: options)[0]
        }
        let contact = try SheetBuilder.contactSheet(
            from: try images(names, options: options), columns: 4, scale: options.scale
        )
        try SheetBuilder.write(contact, to: options.out)
        print("wrote \(options.out.lastPathComponent)")

    case "pair":
        // Two coats of the same pose, side by side. `--coat` is the left one,
        // `--coat2` the right; the coats comparison still is the only caller.
        var second = options
        second.coat = parseCoat2(CommandLine.arguments) ?? "shaggy"
        let name = try frames(pose: options.pose, facing: options.facing, options: options)[0]
        let left = try images([name], options: options)
        let right = try images([name], options: second)
        let paired = try SheetBuilder.contactSheet(
            from: left + right, columns: 2, scale: options.scale
        )
        try SheetBuilder.write(paired, to: options.out)
        print("wrote \(options.out.lastPathComponent)")

    default:
        print("""
        spritefilm — transparent hero assets from Jumbini's sprite art

          sheet   --pose <idle|walk|run|sit|spin> --facing <direction> [--coat classic]
                  [--scale 2] --out <file.png>
          still   --pose <pose> --facing <direction> [--coat classic] [--scale 4] --out <file.png>
          contact --pose <pose> [--coat classic] [--scale 2] --out <file.png>
          pair    --pose <pose> --facing <direction> [--coat classic] [--coat2 shaggy]
                  [--scale 5] --out <file.png>

        Run from the repo root, or pass --art and --animations.
        """)
    }
} catch {
    FileHandle.standardError.write(Data("spritefilm: \(error)\n".utf8))
    exit(1)
}
```

- [ ] **Step 6: Verify the CLI produces a real sheet**

From the repo root:

```bash
mkdir -p demo-assets/hero
swift run --package-path Tools/demo/spritefilm spritefilm sheet \
  --pose walk --facing east --scale 2 --out demo-assets/hero/walk-east.png
```

Expected: prints `frames=2 cell=<n> height=<n>`, and `demo-assets/hero/walk-east.png` exists with a transparent background. Open it and confirm the dog is not cut off or smoothed.

- [ ] **Step 7: Commit**

```bash
git add Tools/demo/spritefilm
git commit -m "Add spritefilm: transparent hero sheets from the sprite art"
```

---

### Task 6: The capture runner

The orchestrator that produces the clips. It runs in the throwaway account, so it must be self-contained and complete unattended.

**Files:**
- Create: `Tools/demo/capture.sh`
- Create: `Tools/demo/stage-windows.applescript`
- Modify: `.gitignore`

**Interfaces:**
- Consumes: `Tools/demo/shots/*.json` (Task 3), a built `Jumbini.app`, `ffmpeg`.
- Produces: `demo-assets/clips/<name>.mp4`, `.webm`, `.jpg` for each of the nine shots.

- [ ] **Step 1: Install ffmpeg and confirm the capture primitives**

```bash
brew install ffmpeg
ffmpeg -version | head -1
```

Then verify the two assumptions the runner rests on, because both change its shape if they are wrong:

```bash
# Does screencapture take a duration flag?
screencapture -v -V 3 /tmp/probe.mov && ls -la /tmp/probe.mov
```

Expected: a ~3 second `.mov`. **If `-V` is unsupported on this macOS build, the runner must background `screencapture -v` and `kill -INT` it on a timer instead** — implement that fallback rather than working around it elsewhere.

```bash
# Confirm the display is a single screen; the overlay spans the union of all
# displays and ScreenLayout's dead zones can put the dog outside the crop.
system_profiler SPDisplaysDataType | grep -c Resolution
```

Expected: `1`. If not, disconnect the extra display before recording.

- [ ] **Step 2: Ignore the output directory**

Add to `.gitignore`:

```
demo-assets/
```

- [ ] **Step 3: Write the window staging script**

Create `Tools/demo/stage-windows.applescript`. Uses each app's own scripting dictionary, so no Accessibility permission is needed:

```applescript
-- Stage two neutral windows for the climb shot and put them at known
-- positions, so the crop and the dog's climb target are both predictable.
-- Bounds are {left, top, right, bottom} in top-left-origin screen points.

on run argv
	set theAction to item 1 of argv

	if theAction is "open" then
		tell application "TextEdit"
			activate
			if (count of documents) is 0 then make new document
			set bounds of window 1 to {320, 260, 1180, 760}
		end tell
		tell application "Finder"
			activate
			set bounds of Finder window 1 to {1240, 420, 1900, 860}
		end tell

	else if theAction is "move" then
		-- A gentle ride: small steps, well under the ~180pt-per-poll
		-- threshold that shakes him off.
		tell application "TextEdit"
			repeat with offset from 1 to 12
				set bounds of window 1 to {320 + (offset * 14), 260, 1180 + (offset * 14), 760}
				delay 0.12
			end repeat
		end tell

	else if theAction is "yank" then
		-- Past the threshold in one poll. This is the shot.
		tell application "TextEdit"
			set bounds of window 1 to {900, 260, 1760, 760}
		end tell

	else if theAction is "close" then
		tell application "TextEdit" to close every document saving no
		tell application "Finder" to close every window
	end if
end run
```

- [ ] **Step 4: Write the runner**

Create `Tools/demo/capture.sh`:

```bash
#!/bin/bash
# Records the landing-page clips. Runs unattended in the capture account.
#
#   ./capture.sh            # every shot
#   ./capture.sh climb      # one shot
#
# Needs: a built Jumbini.app, ffmpeg, and Screen Recording permission for
# whatever terminal is running this. Grant it once, in System Settings >
# Privacy & Security > Screen Recording, then re-run.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
SHOTS="$HERE/shots"
OUT="${JUMBINI_DEMO_OUT:-$ROOT/demo-assets/clips}"
RAW="$OUT/raw"
APP="${JUMBINI_APP:-$ROOT/build/Jumbini.app}"
BIN="$APP/Contents/MacOS/Jumbini"

# Crop applied to every clip: a 1600x900 window of the screen, offset so the
# staged windows sit inside it. Retina doubles these at capture time.
CROP_W=1600; CROP_H=900; CROP_X=200; CROP_Y=200
DELIVER_W=1440

die() { echo "capture: $*" >&2; exit 1; }

command -v ffmpeg >/dev/null || die "ffmpeg missing. Run: brew install ffmpeg"
[ -x "$BIN" ] || die "no app at $BIN. Build it with Scripts/bundle.sh first."
mkdir -p "$RAW"

# A black recording means the permission was never granted, and it is far
# better to find that out now than after nine takes.
probe="$RAW/.permission-probe.mov"
screencapture -v -V 1 "$probe" >/dev/null 2>&1 || true
[ -s "$probe" ] || die "screencapture produced nothing — grant Screen Recording permission and re-run"
rm -f "$probe"

shots=("$@")
if [ ${#shots[@]} -eq 0 ]; then
  shots=(climb thermal build-party quiet fetch toys tricks pounce charm)
fi

original_dnd_note="Do Not Disturb is left on for the session; turn it off when you are done."
echo "capture: enabling Do Not Disturb — $original_dnd_note"
shortcuts run "Turn On Do Not Disturb" 2>/dev/null \
  || echo "capture: could not toggle DND automatically; do it by hand before continuing"

for shot in "${shots[@]}"; do
  script="$SHOTS/$shot.json"
  [ -f "$script" ] || die "no shot script at $script"

  duration=$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1]))['duration'])" "$script")
  show_cursor=$(/usr/bin/python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('showCursor',False))" "$script")

  echo "capture: $shot (${duration}s)"

  # A pile left by the previous take would sit in the corner of this one.
  # Defaults are the only state the dog persists (coat, bed, wardrobe).
  defaults delete com.alex.jumbini 2>/dev/null || true

  osascript "$HERE/stage-windows.applescript" open
  sleep 1

  JUMBINI_DEMO="$script" "$BIN" &
  app_pid=$!
  # The scene needs to exist before the first beat lands.
  sleep 2

  cursor_flag=""
  [ "$show_cursor" = "True" ] && cursor_flag="-C"

  # shellcheck disable=SC2086
  screencapture -v $cursor_flag -V "$duration" "$RAW/$shot.mov" &
  rec_pid=$!

  # The flagship needs the window moved underneath him mid-take.
  if [ "$shot" = "climb" ]; then
    sleep 6
    osascript "$HERE/stage-windows.applescript" move
    sleep 1
    osascript "$HERE/stage-windows.applescript" yank
  fi

  wait $rec_pid
  kill "$app_pid" 2>/dev/null || true
  wait "$app_pid" 2>/dev/null || true
  osascript "$HERE/stage-windows.applescript" close

  echo "capture: encoding $shot"
  filter="crop=${CROP_W}*2:${CROP_H}*2:${CROP_X}*2:${CROP_Y}*2,scale=${DELIVER_W}:-2:flags=lanczos"

  ffmpeg -y -loglevel error -i "$RAW/$shot.mov" \
    -vf "$filter" -r 30 \
    -c:v libx264 -profile:v high -pix_fmt yuv420p -crf 23 \
    -movflags +faststart -an "$OUT/$shot.mp4"

  ffmpeg -y -loglevel error -i "$RAW/$shot.mov" \
    -vf "$filter" -r 30 \
    -c:v libvpx-vp9 -crf 34 -b:v 0 -row-mt 1 -an "$OUT/$shot.webm"

  ffmpeg -y -loglevel error -ss 1 -i "$RAW/$shot.mov" \
    -vf "$filter" -frames:v 1 -q:v 3 "$OUT/$shot.jpg"

  size=$(stat -f%z "$OUT/$shot.mp4")
  if [ "$size" -gt 2097152 ]; then
    echo "capture: WARNING $shot.mp4 is $((size / 1024))KB, over the 2MB budget"
  fi
done

echo "capture: done. Clips in $OUT"
echo "capture: review each one before publishing — a spontaneous wander can"
echo "capture: walk into a take, and the fix is to re-run that shot."
```

Make it executable:

```bash
chmod +x Tools/demo/capture.sh
```

- [ ] **Step 5: Test the runner on the cheapest shot**

Build the app bundle, then record one short clip:

```bash
Scripts/bundle.sh
Tools/demo/capture.sh thermal
```

Expected: `demo-assets/clips/thermal.mp4`, `.webm` and `.jpg` exist, the mp4 is under 2MB, and playing it shows the dog getting the flame bubble and going into zoomies. If the video is black, Screen Recording permission was not granted.

- [ ] **Step 6: Commit**

```bash
git add Tools/demo/capture.sh Tools/demo/stage-windows.applescript .gitignore
git commit -m "Add the demo capture runner and window staging"
```

---

### Task 7: The stills

Six images. Four come from `spritefilm` with no app running; two have to be captured from the live app because they are screenshots of real UI.

**Files:**
- Create: `Tools/demo/stills.sh`

**Interfaces:**
- Consumes: `spritefilm` (Task 5).
- Produces: `demo-assets/stills/*.png`.

- [ ] **Step 1: Write the stills script**

Create `Tools/demo/stills.sh`:

```bash
#!/bin/bash
# The six landing-page stills. Four are rendered offline from the sprite art;
# two are screenshots of live UI and need the app running.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${JUMBINI_DEMO_OUT:-$ROOT/demo-assets/stills}"
FILM=(swift run --package-path "$HERE/spritefilm" spritefilm)

mkdir -p "$OUT"
cd "$ROOT"

echo "stills: hero"
"${FILM[@]}" still --pose idle --facing south --scale 6 --out "$OUT/hero@2x.png"

echo "stills: rotations contact sheet"
"${FILM[@]}" contact --pose idle --scale 3 --out "$OUT/rotations.png"

echo "stills: coats, side by side"
"${FILM[@]}" pair --pose idle --facing south --coat classic --coat2 shaggy \
  --scale 5 --out "$OUT/coats.png"

echo
echo "stills: the remaining three are screenshots of live UI and cannot be rendered."
echo "stills: with Jumbini running:"
echo "stills:   1. wardrobe.png  — open the Wardrobe menu, then: screencapture -iw $OUT/wardrobe.png"
echo "stills:   2. menubar.png   — open the menu bar menu, then: screencapture -iw $OUT/menubar.png"
echo "stills:   3. jumbini-cam.png — press ⌥⇧J, then paste the clipboard into Preview and save"
echo "stills: done. Offline stills are in $OUT"
```

```bash
chmod +x Tools/demo/stills.sh
```

- [ ] **Step 2: Run it and check the output**

```bash
Tools/demo/stills.sh
open demo-assets/stills
```

Expected: `hero@2x.png`, `rotations.png`, `coats.png` all present, transparent, crisp with no smoothing. `rotations.png` should be a 4×2 grid of the eight directions; `coats.png` should be classic on the left, shaggy on the right.

- [ ] **Step 3: Capture the three live-UI stills by hand**

Follow the instructions the script prints. `jumbini-cam.png` must come from the real ⌥⇧J feature rather than a mock — it is a product screenshot.

- [ ] **Step 4: Commit**

```bash
git add Tools/demo/stills.sh
git commit -m "Add the stills script"
```

---

### Task 8: Stage the kit for the capture account, and document it

The capture account cannot read this repo — home directories are `0700` — so the kit gets copied to `/Users/Shared`. This task makes that one command and writes down what the operator does.

**Files:**
- Create: `Tools/demo/stage-kit.sh`
- Create: `Tools/demo/README.md`

**Interfaces:**
- Consumes: everything from Tasks 3-7.
- Produces: `/Users/Shared/jumbini-demo/` containing the app, the scripts, and the art.

- [ ] **Step 1: Write the staging script**

Create `Tools/demo/stage-kit.sh`:

```bash
#!/bin/bash
# Copies everything the capture account needs into /Users/Shared, because it
# cannot read this repo — home directories are 0700.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
KIT="/Users/Shared/jumbini-demo"
APP="$ROOT/build/Jumbini.app"

[ -d "$APP" ] || { echo "stage: no app at $APP — run Scripts/bundle.sh first" >&2; exit 1; }

rm -rf "$KIT"
mkdir -p "$KIT/Tools/demo" "$KIT/Sources/Jumbini/Resources"

cp -R "$APP" "$KIT/Jumbini.app"
cp -R "$HERE/shots" "$HERE/spritefilm" "$KIT/Tools/demo/"
cp "$HERE/capture.sh" "$HERE/stills.sh" "$HERE/stage-windows.applescript" \
   "$HERE/animations.json" "$KIT/Tools/demo/"
cp -R "$ROOT/Sources/Jumbini/Resources/jumba" "$KIT/Sources/Jumbini/Resources/"
cp "$HERE/README.md" "$KIT/README.md"

# Everyone can read and run it; only the staging user can change it.
chmod -R a+rX "$KIT"

cat <<EOF
stage: kit ready at $KIT

Now, in the capture account:
  1. Log in (single display, nothing else running).
  2. Terminal: cd $KIT && JUMBINI_APP=$KIT/Jumbini.app JUMBINI_DEMO_OUT=$KIT/out/clips Tools/demo/capture.sh
  3. Grant Screen Recording when asked, then run it again.
  4. Output lands in $KIT/out — copy it back and review every clip.
EOF
```

```bash
chmod +x Tools/demo/stage-kit.sh
```

- [ ] **Step 2: Write the operator README**

Create `Tools/demo/README.md`:

```markdown
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
(`brew install ffmpeg`), and Screen Recording permission for Terminal. The
runner checks all three and refuses to produce black frames silently.

## Regenerating just the hero assets

These need no app, no permissions, and no capture account:

    Tools/demo/stills.sh
    swift run --package-path Tools/demo/spritefilm spritefilm sheet \
      --pose walk --facing east --scale 2 --out demo-assets/hero/walk-east.png

The command prints `frames=N cell=W height=H`. Drive the sheet from CSS with
`steps(N)` and a `background-size` of `calc(W * N)`.

## Editing a shot

Shot timelines are JSON in `shots/`. `Scripts/test.sh --filter DemoShotsTests`
validates every one of them against the real enum cases, so a typo fails the
build rather than producing a clip where nothing happens.

## What this never touches

The `gh-pages` branch. It holds `appcast.xml` and the shipped DMG, which are
load-bearing for Sparkle auto-updates on machines already in the field.
```

- [ ] **Step 3: Verify staging works**

```bash
Scripts/bundle.sh
Tools/demo/stage-kit.sh
ls -la /Users/Shared/jumbini-demo
```

Expected: the kit exists with `Jumbini.app`, `Tools/demo/`, the `jumba` art, and `README.md`.

- [ ] **Step 4: Run the full suite one last time**

Run: `Scripts/test.sh && Scripts/test.sh --package-path Tools/demo/spritefilm`
Expected: both suites pass.

- [ ] **Step 5: Commit**

```bash
git add Tools/demo/stage-kit.sh Tools/demo/README.md
git commit -m "Add kit staging for the capture account and operator docs"
```

---

## Self-Review

**Spec coverage.** Every spec section maps to a task: the cross-account constraint to Task 8, permissions to Tasks 6 and 8, the driver and its gating to Tasks 1-2, the `PetScene` extraction to Task 2, the shot list to Tasks 3 and 6, `spritefilm` and the drift guard to Tasks 4-5, output formats to Task 6, stills to Task 7, the `.gitignore` decision to Task 6, and the testing requirements throughout.

**Known deltas from the spec, both deliberate:**

1. The spec said the app diff was one new file plus the `PetScene` extraction. Task 4 adds a third touch point — `SpriteLoader.swift` — because the drift guard the spec asked for cannot be built without a texture-free description of the animation table. It is scoped to the five fallback-free poses to keep it small.
2. The spec described the drift guard as comparing `spritefilm` to `SpriteLibrary` directly. Because `spritefilm` is a separate package, the comparison runs through `animations.json` as the shared contract instead. Same guarantee, no cross-package import.

**Open risk carried into execution.** Task 6 Step 1 verifies `screencapture -V`. If that flag is unsupported the runner needs the background-and-signal fallback, which is called out at the point of failure rather than discovered mid-session.
