# Tidy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a production-ready, single-folder Tidy feature that previews and safely moves matching files, supports exact undo and idle runs, and lets Jumba visibly perform successful moves.

**Architecture:** A pure rule engine and read-only planner feed a journaled serial executor. A main-thread coordinator owns bookmark lifetime, preview gating, trigger state, AppKit panels, and theater-only SpriteKit cues. Filesystem correctness never depends on UI or animation.

**Tech Stack:** Swift 5 language mode, Swift Package Manager, macOS 14+, AppKit, SpriteKit, UniformTypeIdentifiers, Foundation security-scoped bookmarks, Swift Testing.

## Global Constraints

- Tidy is off until the user explicitly chooses one folder in `NSOpenPanel`.
- All source and destination URLs must remain inside the standardized, symlink-resolved chosen root.
- Enumerate only immediate children; skip ordinary directories, aliases, and symlinks; treat packages as indivisible items.
- Never delete, trash, overwrite, edit contents, compress, upload, or rename except collision suffixes ` 2`, ` 3`, and later.
- First match wins; unmatched files are never touched.
- Protect files modified within five minutes by default; the configurable floor is one minute.
- Move at most 50 items per pass and halt idle work only at file boundaries.
- Preview is mandatory on first setup and after every rule-affecting edit; preview performs zero writes.
- Keep readable rules JSON and append-only `tidy.log` in `~/Library/Application Support/Jumbini/`.
- Only the latest pass is undoable, restoring exact prior paths without overwriting.
- Manual Tidy is always available after setup; idle Tidy defaults off and unlocks after one successful manual pass.
- No Accessibility, Full Disk Access, Screen Recording, network, AI, recursive watching, or content reads.
- Animation observes successful moves and must not delay, fail, or alter filesystem execution.
- Use the existing AppKit `JumbiniPanel` style and existing carry/deposit assets.

## File structure

Create focused feature files under `Sources/Jumbini/Tidy/`; SwiftPM discovers them automatically:

- `TidyModels.swift`: Codable value types, file identity, rule/condition vocabulary, plans, results, and user-facing skip reasons.
- `TidyRuleEngine.swift`: pure matching and `UTType`-based kind classification.
- `TidyStore.swift`: rules/preferences JSON and security-scoped bookmark persistence.
- `TidyPlanner.swift`: root validation, one-level enumeration, metadata reads, open-file snapshot, collision planning.
- `TidyLedger.swift`: human ledger, atomic recovery journal, reconciliation, and latest-pass persistence.
- `TidyExecutor.swift`: serial capped moves, immediate revalidation, halting, and exact undo.
- `TidyCoordinator.swift`: preview gate, bookmark lifetime, async execution, trigger state, notices, and UI-facing state.
- `TidySettingsPanel.swift`: folder/rules/recency/idle configuration.
- `TidyRuleEditorPanel.swift`: all/any rule and condition editor.
- `TidyPreviewPanel.swift`: scrollable proposed moves, skip reasons, row opt-outs, and confirmation.
- `TidyAnimation.swift`: pure animation batching and plausible-region calculation.

Modify existing files only at their integration seams:

- `Sources/Jumbini/AppDelegate.swift`: coordinator ownership, status submenu, picker, panels, notices, monitor routing, and lifecycle cleanup.
- `Sources/Jumbini/PetScene.swift`: accept and render optional Tidy cues.
- `Sources/Jumbini/SpriteLoader.swift`: expose the existing deposit textures as a non-persistent theater prop.
- `Tests/JumbiniTests/PanelSnapshotTests.swift`: render the two Tidy panels.
- `README.md`: describe scope, safety, privacy, ledger, and undo.

---

### Task 1: Rule vocabulary and pure evaluator

**Files:**
- Create: `Sources/Jumbini/Tidy/TidyModels.swift`
- Create: `Sources/Jumbini/Tidy/TidyRuleEngine.swift`
- Create: `Tests/JumbiniTests/TidyRuleEngineTests.swift`

**Interfaces:**
- Produces: `TidyKind`, `TidyCondition`, `TidyRule`, `TidyRuleSet`, `TidyItemMetadata`, `TidySafety.maximumMoves`, and `TidyRuleEngine.firstMatch(for:rules:now:) -> TidyRule?`.
- Produces: `TidyRuleSet.defaults` in the exact order Screenshots, Images, Installers, Archives.
- Consumes: Foundation and UniformTypeIdentifiers only.

- [ ] **Step 1: Write failing model and matching tests**

Create table-driven Swift Testing cases for every condition, ordered matching,
disabled rules, all/any composition, and the unmatched invariant. The central
ordering test must be concrete:

```swift
import Foundation
import Testing
@testable import Jumbini

@Test func firstMatchingRuleWins() {
    let item = TidyItemMetadata(
        name: "client-export-final.png",
        pathExtension: "png",
        contentTypeIdentifier: "public.png",
        modifiedAt: Date(timeIntervalSince1970: 0),
        byteCount: 2_000_000,
        isPackage: false
    )
    let first = TidyRule(
        name: "Client exports", match: .all,
        conditions: [.filenameContains("export")], destination: "Client"
    )
    let second = TidyRule(
        name: "Final files", match: .all,
        conditions: [.filenameContains("final")], destination: "Final"
    )

    #expect(TidyRuleEngine.firstMatch(
        for: item, rules: [first, second], now: Date(timeIntervalSince1970: 1_000_000)
    )?.id == first.id)
}

@Test func unmatchedItemHasNoRule() {
    let item = TidyItemMetadata(
        name: "notes.xyz", pathExtension: "xyz",
        contentTypeIdentifier: nil, modifiedAt: .distantPast,
        byteCount: 12, isPackage: false
    )
    #expect(TidyRuleEngine.firstMatch(for: item, rules: TidyRuleSet.defaults.rules, now: .now) == nil)
}
```

Add named tests `allRequiresEveryCondition`, `anyRequiresOneCondition`,
`disabledRuleNeverMatches`, `filenameContainsIsCaseInsensitive`,
`extensionsNormalizeDotsAndCase`, `modifiedAgeUsesInjectedClock`,
`sizeUsesDecimalMegabytes`, and `defaultPresetOrderIsSafe`.

- [ ] **Step 2: Run the focused tests and verify RED**

Run: `./Scripts/test.sh --filter TidyRuleEngineTests`

Expected: compilation fails because `TidyItemMetadata`, `TidyRule`, and
`TidyRuleEngine` do not exist.

- [ ] **Step 3: Implement Codable models and pure matching**

Use these public shapes exactly so later tasks compile against one vocabulary:

```swift
enum TidyKind: String, Codable, CaseIterable, Equatable {
    case image, screenshot, document, archive, installer, video, audio, other
}

enum TidyMatchMode: String, Codable, Equatable { case all, any }

enum TidyCondition: Codable, Equatable {
    case kind(TidyKind)
    case filenameContains(String)
    case extensions([String])
    case modifiedMoreThanDays(Int)
    case largerThanMB(Double)
}

struct TidyRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var isEnabled = true
    var match: TidyMatchMode
    var conditions: [TidyCondition]
    var destination: String
}

struct TidyRuleSet: Codable, Equatable {
    var schemaVersion = 1
    var rules: [TidyRule]
    static let defaults = TidyRuleSet(rules: [
        TidyRule(name: "Screenshots", match: .all, conditions: [.kind(.screenshot)], destination: "Screenshots"),
        TidyRule(name: "Images", match: .all, conditions: [.kind(.image)], destination: "Images"),
        TidyRule(name: "Installers", match: .any, conditions: [.extensions(["dmg", "pkg"])], destination: "Installers"),
        TidyRule(name: "Archives", match: .all, conditions: [.kind(.archive)], destination: "Archives"),
    ])
}

enum TidySafety {
    static let maximumMoves = 50
}
```

Implement screenshot detection before general image detection using the standard
macOS filename prefixes `Screenshot ` and `Screen Shot `. Use `UTType` conformance
for image, archive, movie, audio, and document kinds, with `dmg`/`pkg` taking
installer precedence. Empty condition arrays do not match. Give
`TidyCondition` an explicit discriminated JSON representation such as
`{"type":"kind","kind":"screenshot"}` and
`{"type":"extensions","values":["dmg","pkg"]}`; do not rely on Swift's
synthesized associated-enum keys because the file must remain hand-editable.

- [ ] **Step 4: Run the focused and full test suites**

Run: `./Scripts/test.sh --filter TidyRuleEngineTests && ./Scripts/test.sh`

Expected: all tests pass without warnings introduced by Tidy.

- [ ] **Step 5: Commit the rule engine**

```bash
git add Sources/Jumbini/Tidy/TidyModels.swift Sources/Jumbini/Tidy/TidyRuleEngine.swift Tests/JumbiniTests/TidyRuleEngineTests.swift
git commit -m "feat: add Tidy rule engine"
```

### Task 2: Readable persistence and folder grants

**Files:**
- Create: `Sources/Jumbini/Tidy/TidyStore.swift`
- Create: `Tests/JumbiniTests/TidyStoreTests.swift`
- Create: `Tests/JumbiniTests/TidyTestSupport.swift`

**Interfaces:**
- Consumes: `TidyRuleSet` from Task 1.
- Produces: `TidyPreferences`, `TidyFolderGrant`, and `TidyStore` methods `loadRules()`, `saveRules(_:)`, `loadPreferences()`, `savePreferences(_:)`, `saveFolder(_:)`, `resolveFolder()`, and `forgetFolder()`.

- [ ] **Step 1: Write failing JSON and bookmark tests**

Test stable formatted JSON, malformed-file preservation, preference defaults,
bookmark round-trip to a temporary directory, and complete bookmark removal:

```swift
@Test func rulesRoundTripAsReadableJSON() throws {
    let support = try TemporaryDirectory.make()
    let store = TidyStore(directory: support.url)
    try store.saveRules(.defaults)

    let data = try Data(contentsOf: support.url.appendingPathComponent("tidy-rules.json"))
    let text = try #require(String(data: data, encoding: .utf8))
    #expect(text.contains("\"schemaVersion\" : 1"))
    #expect(try store.loadRules() == .defaults)
}

@Test func forgettingFolderRemovesOnlyTheBookmark() throws {
    let support = try TemporaryDirectory.make()
    let chosen = try TemporaryDirectory.make()
    let store = TidyStore(directory: support.url)
    try store.saveRules(.defaults)
    try store.saveFolder(chosen.url)
    try store.forgetFolder()
    #expect(try store.resolveFolder() == nil)
    #expect(try store.loadRules() == .defaults)
}
```

Define `TemporaryDirectory` and fixture URL writers in
`TidyTestSupport.swift`. Use `mkdtemp`, cleanup in `deinit`, and keep every
fixture helper out of the production target. Typed fixtures are added only in
the task that introduces their production type.

- [ ] **Step 2: Run tests and verify RED**

Run: `./Scripts/test.sh --filter TidyStoreTests`

Expected: compilation fails because `TidyStore` does not exist.

- [ ] **Step 3: Implement atomic store operations**

Implement:

```swift
struct TidyPreferences: Codable, Equatable {
    var needsPreview = true
    var recencyMinutes = 5
    var idleEnabled = false
    var idleMinutes = 10
    var completedManualPass = false
}

struct TidyFolderGrant: Equatable {
    let url: URL
    let isStale: Bool
}

final class TidyStore {
    init(directory: URL? = nil, fileManager: FileManager = .default)
    func loadRules() throws -> TidyRuleSet
    func saveRules(_ rules: TidyRuleSet) throws
    func loadPreferences() throws -> TidyPreferences
    func savePreferences(_ preferences: TidyPreferences) throws
    func saveFolder(_ url: URL) throws
    func resolveFolder() throws -> TidyFolderGrant?
    func forgetFolder() throws
}
```

Use `.prettyPrinted`, `.sortedKeys`, and atomic writes. Clamp decoded recency to
at least 1 and idle minutes to at least 1. Store bookmark bytes in
`tidy-folder.bookmark` using `.withSecurityScope`; resolve with
`.withSecurityScope` and return the stale flag. Do not auto-replace malformed
JSON. Create the support directory only from a mutating save call, never from a
load or preview.

- [ ] **Step 4: Run focused and full tests**

Run: `./Scripts/test.sh --filter TidyStoreTests && ./Scripts/test.sh`

Expected: all pass.

- [ ] **Step 5: Commit persistence**

```bash
git add Sources/Jumbini/Tidy/TidyStore.swift Tests/JumbiniTests/TidyStoreTests.swift Tests/JumbiniTests/TidyTestSupport.swift
git commit -m "feat: persist Tidy rules and folder grants"
```

### Task 3: Read-only planner and containment

**Files:**
- Create: `Sources/Jumbini/Tidy/TidyPlanner.swift`
- Create: `Tests/JumbiniTests/TidyPlannerTests.swift`
- Modify: `Sources/Jumbini/Tidy/TidyModels.swift`
- Modify: `Tests/JumbiniTests/TidyTestSupport.swift`

**Interfaces:**
- Consumes: `TidyRuleEngine`, `TidyRuleSet`, and injected `Date`.
- Produces: `TidyFileID`, `TidyPlanRow`, `TidyPlan`, `TidyPlanError`, `TidyOpenFileDetecting`, `SystemTidyOpenFileDetector`, and `TidyPlanner.plan(root:rules:recencyMinutes:now:) throws -> TidyPlan`.

- [ ] **Step 1: Write failing planner safety tests**

Use real temporary directories. Assert preview planning creates no destination
folders or support files. Add explicit tests for immediate-child enumeration,
ordinary-directory skip, package atomicity, symlink/alias skip, recent-file
skip, unmatched skip, open-path skip, traversal destination rejection, absolute
destination rejection, root symlink resolution, and collision names.

```swift
@Test func unsafeDestinationInvalidatesWholePlan() throws {
    let root = try TemporaryDirectory.make()
    try Data("x".utf8).write(to: root.url.appendingPathComponent("photo.png"))
    let rule = TidyRule(
        name: "Escape", match: .all,
        conditions: [.extensions(["png"])], destination: "../Outside"
    )

    #expect(throws: TidyPlanError.unsafeDestination("../Outside")) {
        try TidyPlanner(openFiles: StubOpenFiles(paths: [])).plan(
            root: root.url, rules: [rule], recencyMinutes: 1,
            now: Date(timeIntervalSinceNow: 3_600)
        )
    }
    #expect(FileManager.default.fileExists(atPath: root.url.appendingPathComponent("Outside").path) == false)
}

@Test func collisionSuffixPrecedesExtension() throws {
    let plan = try fixturePlan(sourceName: "photo.png", existing: ["Images/photo.png"], destination: "Images")
    #expect(plan.movable.first?.destination.lastPathComponent == "photo 2.png")
}
```

- [ ] **Step 2: Run planner tests and verify RED**

Run: `./Scripts/test.sh --filter TidyPlannerTests`

Expected: compilation fails because `TidyPlanner` and `TidyPlan` do not exist.

- [ ] **Step 3: Implement identity, plan rows, validation, and enumeration**

Use these stable interfaces:

```swift
struct TidyFileID: Codable, Hashable, Equatable {
    let device: UInt64
    let inode: UInt64
}

enum TidySkipReason: String, Codable, Equatable {
    case unmatched, recent, alias, symbolicLink, ordinaryDirectory
    case openByAnotherProcess, unreadableMetadata
}

struct TidyPlannedMove: Identifiable, Equatable {
    let id: UUID
    let source: URL
    let destination: URL
    let sourceID: TidyFileID
    let modifiedAt: Date
    let ruleID: UUID
    let ruleName: String
}

struct TidySkippedItem: Identifiable, Equatable {
    let id: UUID
    let source: URL
    let reason: TidySkipReason
}

struct TidyPlan: Equatable {
    let root: URL
    let movable: [TidyPlannedMove]
    let skipped: [TidySkippedItem]
    var exceedsCap: Bool { movable.count > TidySafety.maximumMoves }
}

enum TidyPlanError: Error, Equatable {
    case unsafeRoot(URL)
    case unsafeDestination(String)
    case enumerationFailed(String)
}

protocol TidyOpenFileDetecting {
    func openPaths(under root: URL) -> Set<String>
}
```

Read `lstat` device/inode identity without following a symlink. Use
`URLResourceValues` for type, size, dates, package, alias, and symlink flags.
Validate destination as exactly one non-hidden component and verify containment
with `resolved.path == root.path || resolved.path.hasPrefix(root.path + "/")`.
Reserve planned destination names in a `Set<String>` so within-batch collisions
also suffix safely.

Add `TidyPlan.fixture(moveCount:)` to `TidyTestSupport.swift` now that Task 3
defines `TidyPlan`.

Implement `SystemTidyOpenFileDetector` with `/usr/sbin/lsof -Fn +d <root>`.
Parse only `n/path` records, standardize paths, and return an empty set if the
tool is absent or exits unsuccessfully. Treat a package as open if any returned
path is equal to or nested under the package path.

- [ ] **Step 4: Run planner and full tests**

Run: `./Scripts/test.sh --filter TidyPlannerTests && ./Scripts/test.sh`

Expected: all pass, and temporary roots contain only test fixtures.

- [ ] **Step 5: Commit the planner**

```bash
git add Sources/Jumbini/Tidy/TidyModels.swift Sources/Jumbini/Tidy/TidyPlanner.swift Tests/JumbiniTests/TidyPlannerTests.swift Tests/JumbiniTests/TidyTestSupport.swift
git commit -m "feat: plan safe Tidy moves"
```

### Task 4: Ledger and crash-recovery journal

**Files:**
- Create: `Sources/Jumbini/Tidy/TidyLedger.swift`
- Create: `Tests/JumbiniTests/TidyLedgerTests.swift`
- Modify: `Tests/JumbiniTests/TidyTestSupport.swift`

**Interfaces:**
- Consumes: `TidyFileID` and planned source/destination/rule information.
- Produces: `TidyCompletedMove`, `TidyPassRecord`, `TidyPassStatus`, and `TidyLedger.begin(_:)`, `recordIntent(_:)`, `recordCompletion(_:)`, `recordSkip(_:)`, `recordFailure(_:)`, `recordCap(passID:)`, `recordUndo(_:)`, `finish(_:)`, `loadLatestPass()`, `consumeUndo()`, and `reconcile()`.

- [ ] **Step 1: Write failing audit and recovery tests**

Test exact plain-text fields for move, skip, failure, cap, and undo records;
atomic JSON round-trip; intent-before-completion; latest-pass replacement; undo
consumption; repair when only the destination exists; and refusal to guess when
both paths exist.

```swift
@Test func completedMoveIsHumanReadableAndRecoverable() throws {
    let support = try TemporaryDirectory.make()
    let ledger = TidyLedger(directory: support.url)
    let pass = TidyPassRecord.started(trigger: .manual, at: Date(timeIntervalSince1970: 1))
    let move = TidyCompletedMove.fixture(source: "/Desktop/a.png", destination: "/Desktop/Images/a.png")

    try ledger.begin(pass)
    try ledger.recordIntent(move, in: pass.id)
    try ledger.recordCompletion(move, in: pass.id)
    try ledger.finish(pass.id, status: .completed)

    let text = try String(contentsOf: support.url.appendingPathComponent("tidy.log"), encoding: .utf8)
    #expect(text.contains("MOVE"))
    #expect(text.contains("/Desktop/a.png"))
    #expect(try ledger.loadLatestPass()?.moves == [move])
}
```

- [ ] **Step 2: Run ledger tests and verify RED**

Run: `./Scripts/test.sh --filter TidyLedgerTests`

Expected: compilation fails because `TidyLedger` does not exist.

- [ ] **Step 3: Implement append-only audit and atomic journal**

Define:

```swift
enum TidyTrigger: String, Codable, Equatable { case manual, idle }
enum TidyPassStatus: String, Codable, Equatable { case running, completed, halted, failed, undone }

struct TidyCompletedMove: Codable, Equatable {
    let source: URL
    let destination: URL
    let fileID: TidyFileID
    let ruleID: UUID
    let ruleName: String
}

struct TidyPassRecord: Codable, Equatable, Identifiable {
    let id: UUID
    let trigger: TidyTrigger
    let startedAt: Date
    var status: TidyPassStatus
    var intendedMove: TidyCompletedMove?
    var moves: [TidyCompletedMove]
    var undoAvailable: Bool

    static func started(trigger: TidyTrigger, at date: Date) -> TidyPassRecord
}
```

Write journal updates to `tidy-last-pass.json.tmp`, synchronize the file handle,
then replace `tidy-last-pass.json`. Append ledger lines through a file handle and
call `synchronize()` before returning. Percent-encode control characters in paths
so one item cannot forge multiple ledger lines. `reconcile()` returns a typed
blocking error when both/neither source and destination exist; when exactly the
destination exists, promote the intent into `moves` and append a `RECOVERED`
line.

Add `TidyCompletedMove.fixture(index:)` and
`TidyCompletedMove.fixture(source:destination:)` to
`TidyTestSupport.swift` now that Task 4 defines `TidyCompletedMove`.

- [ ] **Step 4: Run focused and full tests**

Run: `./Scripts/test.sh --filter TidyLedgerTests && ./Scripts/test.sh`

Expected: all pass.

- [ ] **Step 5: Commit journaling**

```bash
git add Sources/Jumbini/Tidy/TidyLedger.swift Tests/JumbiniTests/TidyLedgerTests.swift Tests/JumbiniTests/TidyTestSupport.swift
git commit -m "feat: journal Tidy passes"
```

### Task 5: Capped executor and exact undo

**Files:**
- Create: `Sources/Jumbini/Tidy/TidyExecutor.swift`
- Create: `Tests/JumbiniTests/TidyExecutorTests.swift`
- Modify: `Sources/Jumbini/Tidy/TidyModels.swift`

**Interfaces:**
- Consumes: reviewed `TidyPlan`, `TidyLedger`, root URL, selected row IDs, injected clock, `TidyOpenFileDetecting`, and halt closure.
- Produces: `TidyPassResult`, `TidyUndoResult`, `TidyFileOperating`, `SystemTidyFileOperator`, `TidyExecutor.execute(plan:selectedIDs:trigger:now:shouldHalt:didMove:) throws -> TidyPassResult`, and `undoLatest(root:now:) throws -> TidyUndoResult`.

- [ ] **Step 1: Write failing real-filesystem executor tests**

Add named tests for: selected rows only, destination creation at execution,
source revalidation, recent recheck, no overwrite under a late collision, exactly
50 of 4,000 candidates, halt at a boundary, unexpected error yields undoable
partial pass, journal failure moves nothing, exact reverse order undo, occupied
source aborts undo without moves, changed destination identity aborts undo, and
successful undo consumes availability.

```swift
@Test func hardCapMovesExactlyFifty() throws {
    let fixture = try ExecutorFixture(fileCount: 4_000)
    let result = try fixture.executor.execute(
        plan: fixture.plan, selectedIDs: Set(fixture.plan.movable.map(\.id)),
        trigger: .manual, now: .now, shouldHalt: { false }, didMove: { _ in }
    )
    #expect(result.moves.count == 50)
    #expect(result.didHitCap)
    #expect(fixture.destinationChildren.count == 50)
}

@Test func undoConflictMovesNothing() throws {
    let fixture = try ExecutorFixture(fileCount: 2)
    _ = try fixture.runAll()
    try Data("new occupant".utf8).write(to: fixture.sourceURLs[0])
    #expect(throws: TidyUndoError.sourceOccupied(fixture.sourceURLs[0])) {
        try fixture.executor.undoLatest(root: fixture.root, now: .now)
    }
    #expect(fixture.destinationChildren.count == 2)
}
```

- [ ] **Step 2: Run executor tests and verify RED**

Run: `./Scripts/test.sh --filter TidyExecutorTests`

Expected: compilation fails because `TidyExecutor` does not exist.

- [ ] **Step 3: Implement serial moves and revalidation**

Use:

```swift
struct TidyPassResult: Equatable {
    let passID: UUID
    let moves: [TidyCompletedMove]
    let skipped: [TidySkippedItem]
    let failures: [String]
    let didHitCap: Bool
    let wasHalted: Bool
}

struct TidyUndoResult: Equatable {
    let restoredCount: Int
}

enum TidyUndoError: Error, Equatable {
    case unavailable
    case sourceOccupied(URL)
    case destinationChanged(URL)
    case rollbackFailed(String)
}

protocol TidyFileOperating {
    func createDirectory(at url: URL) throws
    func moveItem(at source: URL, to destination: URL) throws
    func itemExists(at url: URL) -> Bool
}

final class TidyExecutor {
    func execute(
        plan: TidyPlan,
        selectedIDs: Set<UUID>,
        trigger: TidyTrigger,
        now: Date,
        shouldHalt: () -> Bool,
        didMove: (TidyCompletedMove) -> Void
    ) throws -> TidyPassResult
    func undoLatest(root: URL, now: Date) throws -> TidyUndoResult
}
```

Use `TidySafety.maximumMoves` as the single cap constant; do not duplicate the
literal in the executor or UI.

Preflight root containment and journal availability before creating folders.
Take a fresh open-path snapshot immediately before execution. Before each move,
check halt, cap, `lstat` identity, modification date, link flags, detectable-open
status, root containment, and destination existence. Recompute a collision
suffix when needed. Call `recordIntent`, perform `moveItem`, call
`recordCompletion`, then invoke `didMove`. Record every skip, failure, and cap
event in the ledger. On an error, finish the completed prefix as `.failed` and
return/throw a typed result that preserves undo.

Undo first validates every recorded move in reverse: destination identity must
match and every source must be free. Perform reverse moves serially. If one
fails, move already-restored items forward again in original order; record
`UNDO_FAILED` and keep undo eligibility. Only a complete reversal records each
`UNDO`, marks `.undone`, and consumes eligibility.

- [ ] **Step 4: Run focused and full tests**

Run: `./Scripts/test.sh --filter TidyExecutorTests && ./Scripts/test.sh`

Expected: all pass and the 4,000-file test reports exactly 50 moves.

- [ ] **Step 5: Commit execution and undo**

```bash
git add Sources/Jumbini/Tidy/TidyModels.swift Sources/Jumbini/Tidy/TidyExecutor.swift Tests/JumbiniTests/TidyExecutorTests.swift
git commit -m "feat: execute and undo safe Tidy passes"
```

### Task 6: Coordinator, preview gate, and manual workflow

**Files:**
- Create: `Sources/Jumbini/Tidy/TidyCoordinator.swift`
- Create: `Tests/JumbiniTests/TidyCoordinatorTests.swift`

**Interfaces:**
- Consumes: `TidyStore`, `TidyPlanner`, `TidyExecutor`, and closures for notices and successful-move cues.
- Produces: `TidyCoordinator.State`, `setFolder(_:)`, `forgetFolder()`, `updateRules(_:)`, `updateRecency(minutes:)`, `makePreview()`, `executePreview(selection:)`, `runManual()`, and `undo()`.

- [ ] **Step 1: Write failing state-machine tests**

Test no-folder behavior, stale grants, initial preview requirement, every
rule-affecting update restoring the gate, preview cancellation leaving the gate,
row selection propagation, confirmed manual success clearing the gate and
unlocking idle, direct manual run after approval, new pass replacing undo, and
forget-folder clearing state without deleting rules or ledger.

```swift
@Test @MainActor func ruleEditBlocksLiveRunUntilPreviewExecutes() async throws {
    let fixture = CoordinatorFixture.readyForLiveRun()
    var edited = fixture.rules
    edited.rules[0].destination = "Screen Captures"
    try fixture.coordinator.updateRules(edited)

    #expect(fixture.coordinator.state.needsPreview)
    do {
        _ = try await fixture.coordinator.runManual()
        Issue.record("A rule edit must block an unpreviewed live run")
    } catch {
        #expect(error as? TidyCoordinatorError == .previewRequired)
    }
    let preview = try fixture.coordinator.makePreview()
    _ = try await fixture.coordinator.executePreview(selection: Set(preview.movable.map(\.id)))
    #expect(fixture.coordinator.state.needsPreview == false)
}
```

- [ ] **Step 2: Run coordinator tests and verify RED**

Run: `./Scripts/test.sh --filter TidyCoordinatorTests`

Expected: compilation fails because `TidyCoordinator` does not exist.

- [ ] **Step 3: Implement main-thread orchestration**

Define UI-facing state:

```swift
@MainActor
final class TidyCoordinator {
    struct State: Equatable {
        var folder: URL?
        var rules: TidyRuleSet
        var preferences: TidyPreferences
        var isRunning: Bool
        var undoCount: Int
        var blockingError: String?
    }

    var onStateChange: ((State) -> Void)?
    var onNotice: ((TidyNotice) -> Void)?
    var onSuccessfulMoves: (([TidyCompletedMove]) -> Void)?
}

enum TidyCoordinatorError: Error, Equatable {
    case folderRequired
    case previewRequired
    case staleBookmark
    case recoveryBlocked(String)
}

enum TidyNotice: Equatable {
    case completed(moved: Int, skipped: Int, capped: Bool)
    case halted(moved: Int)
    case failed(String)
    case undone(Int)
}
```

Balance `startAccessingSecurityScopedResource()` and
`stopAccessingSecurityScopedResource()` with `defer` across planning and
execution. Execute filesystem work on one private serial `DispatchQueue`; return
state updates to the main actor. A reviewed preview may clear `needsPreview`
only after a pass starts successfully. A successful manual pass sets
`completedManualPass = true`; it does not automatically enable idle.
After execution completes, invoke `onSuccessfulMoves` once with exactly
`TidyPassResult.moves`; an empty or failed-before-first-move pass emits nothing.

- [ ] **Step 4: Run coordinator and full tests**

Run: `./Scripts/test.sh --filter TidyCoordinatorTests && ./Scripts/test.sh`

Expected: all pass.

- [ ] **Step 5: Commit coordination**

```bash
git add Sources/Jumbini/Tidy/TidyCoordinator.swift Tests/JumbiniTests/TidyCoordinatorTests.swift
git commit -m "feat: coordinate Tidy previews and passes"
```

### Task 7: Native Tidy settings, rule editor, and preview panels

**Files:**
- Create: `Sources/Jumbini/Tidy/TidySettingsPanel.swift`
- Create: `Sources/Jumbini/Tidy/TidyRuleEditorPanel.swift`
- Create: `Sources/Jumbini/Tidy/TidyPreviewPanel.swift`
- Create: `Tests/JumbiniTests/TidyPanelTests.swift`
- Modify: `Tests/JumbiniTests/PanelSnapshotTests.swift`

**Interfaces:**
- Consumes: `TidyCoordinator.State`, `TidyRule`, `TidyPlan`, and callbacks supplied by `AppDelegate`.
- Produces: `TidySettingsPanel.render(state:)`, `TidyRuleEditorPanel.edit(_:)`, and `TidyPreviewPanel.show(plan:)` with selected IDs returned on confirmation.

- [ ] **Step 1: Write failing catalog and panel-state tests**

Test rule row order, add/remove/reorder callbacks, all/any control mapping,
condition editor values, one-minute recency floor, idle disabled before manual
success, full source/destination accessibility labels, skip reason labels, row
opt-out, cap message, Cancel callback, and confirm selection.

```swift
@Test @MainActor func previewConfirmationReturnsOnlyCheckedRows() throws {
    let plan = TidyPlan.fixture(moveCount: 3)
    let panel = TidyPreviewPanel()
    var confirmed: Set<UUID>?
    panel.onConfirm = { confirmed = $0 }
    panel.show(plan: plan)
    panel.setSelected(false, for: plan.movable[1].id)
    panel.confirmForTesting()
    #expect(confirmed == [plan.movable[0].id, plan.movable[2].id])
}
```

- [ ] **Step 2: Run panel tests and verify RED**

Run: `./Scripts/test.sh --filter TidyPanelTests`

Expected: compilation fails because the Tidy panels do not exist.

- [ ] **Step 3: Build the panels with existing PanelKit components**

`TidySettingsPanel` uses the existing 720×480 sidebar/card shell with sections
`Overview`, `Rules`, and `Automation`. Overview shows the folder and
`Choose Folder…`/`Forget Folder…`; Rules uses a scrollable vertical list with
enable checkbox, name, concise condition summary, destination, up/down, edit,
and remove controls plus `Add Rule…`; Automation exposes recency and idle
minute steppers, with idle unavailable until `completedManualPass`.

`TidyRuleEditorPanel` uses an `NSPopUpButton` for all/any, destination text
field, and one row per condition. Each row has a condition-type popup and exactly
one typed control: kind popup, filename field, comma-separated extension field,
integer day stepper, or decimal MB field. Save validates nonempty conditions,
positive thresholds, and `TidyPlanner.validateDestination(_:)` before invoking
`onSave`.

`TidyPreviewPanel` uses a flipped document view inside `NSScrollView`; each move
row has a checkbox and two selectable, non-truncated path labels. Skips show a
disabled checkbox and reason. The footer contains Cancel and
`Let Jumba tidy`; `plan.exceedsCap` adds the exact message “Jumba will stop after
50 files for safety.”

Add opt-in snapshots named `tidy-settings` and `tidy-preview` using the existing
`JUMBINI_SNAPSHOT` path in `PanelSnapshotTests.swift`.

- [ ] **Step 4: Run panel tests, snapshots, and full tests**

Run: `./Scripts/test.sh --filter TidyPanelTests && JUMBINI_SNAPSHOT=1 ./Scripts/test.sh --filter PanelSnapshotTests && ./Scripts/test.sh`

Expected: tests pass; snapshot output contains renders for both new panels.

- [ ] **Step 5: Commit panels**

```bash
git add Sources/Jumbini/Tidy/TidySettingsPanel.swift Sources/Jumbini/Tidy/TidyRuleEditorPanel.swift Sources/Jumbini/Tidy/TidyPreviewPanel.swift Tests/JumbiniTests/TidyPanelTests.swift Tests/JumbiniTests/PanelSnapshotTests.swift
git commit -m "feat: add Tidy setup and preview panels"
```

### Task 8: Status menu, folder picker, notices, and lifecycle integration

**Files:**
- Modify: `Sources/Jumbini/AppDelegate.swift`
- Create: `Tests/JumbiniTests/TidyMenuTests.swift`

**Interfaces:**
- Consumes: coordinator and panels from Tasks 6–7.
- Produces: the user-visible Tidy submenu and explicit folder-selection workflow.

- [ ] **Step 1: Write failing menu model tests**

Extract a pure `TidyMenuState` in `TidyCoordinator.swift` and test exact titles,
enabled states, idle checkmark, undo count, and no-folder setup title:

```swift
@Test func unconfiguredMenuOffersSetupWithoutUndo() {
    let menu = TidyMenuState(
        folderConfigured: false, undoCount: 0,
        idleEnabled: false, idleAvailable: false
    )
    #expect(menu.primaryTitle == "Set Up Tidy…")
    #expect(menu.canUndo == false)
    #expect(menu.canForgetFolder == false)
}

@Test func configuredMenuShowsUndoCount() {
    let menu = TidyMenuState(
        folderConfigured: true, undoCount: 12,
        idleEnabled: false, idleAvailable: true
    )
    #expect(menu.primaryTitle == "Tidy Up…")
    #expect(menu.undoTitle == "Undo Last Tidy (12)")
}
```

- [ ] **Step 2: Run menu tests and verify RED**

Run: `./Scripts/test.sh --filter TidyMenuTests`

Expected: compilation fails because `TidyMenuState` does not exist.

- [ ] **Step 3: Integrate coordinator and menu actions**

In `AppDelegate`, add retained coordinator/settings/preview panels and menu item
references. Initialize Tidy after the overlay exists, call journal reconciliation,
and subscribe to coordinator state changes. Add one `Tidy` submenu containing:

```text
Set Up Tidy… / Tidy Up…
Undo Last Tidy (N)
—
Tidy Settings…
Tidy While Idle
Forget Folder…
```

`selectTidyFolder` presents an `NSOpenPanel` configured with
`canChooseDirectories = true`, `canChooseFiles = false`,
`allowsMultipleSelection = false`, and prompt `Choose`. Its accessory view has
Desktop and Downloads shortcut buttons that set `directoryURL`; neither shortcut
accepts the choice without the user pressing Choose. Cancelling leaves every
other feature untouched.

Primary action selects a folder when absent, opens preview when gated, and runs
directly when approved. Forget Folder asks one confirmation because it revokes
the grant, then calls the coordinator. Present results with an
`NSUserNotification`-free in-app `NSPopover` anchored to the status item so idle
runs do not steal focus.

Define `TidyMenuState` with the initializer used by the tests and computed
`primaryTitle`, `undoTitle`, `canUndo`, `canForgetFolder`, `idleEnabled`, and
`idleAvailable` properties. `TidyCoordinator.State` maps to it without importing
AppKit, keeping menu policy testable.

- [ ] **Step 4: Run tests, build, and smoke the app**

Run: `./Scripts/test.sh --filter TidyMenuTests && ./Scripts/test.sh && swift build && ./Scripts/bundle.sh && ./Scripts/smoke.sh`

Expected: all commands succeed and launching the untouched app produces no
folder or TCC prompt.

- [ ] **Step 5: Commit menu integration**

```bash
git add Sources/Jumbini/AppDelegate.swift Sources/Jumbini/Tidy/TidyCoordinator.swift Tests/JumbiniTests/TidyMenuTests.swift
git commit -m "feat: integrate Tidy with the menu bar"
```

### Task 9: Idle, session-lock, display-sleep, and return handling

**Files:**
- Modify: `Sources/Jumbini/Tidy/TidyCoordinator.swift`
- Modify: `Sources/Jumbini/AppDelegate.swift`
- Modify: `Sources/Jumbini/SystemMonitor.swift`
- Create: `Tests/JumbiniTests/TidyTriggerTests.swift`

**Interfaces:**
- Consumes: existing `SystemSignal.idleBegan`/`.idleEnded` and `NSWorkspace` session/display notifications.
- Produces: `TidyIdleTracker` pure transitions and coordinator methods `receive(_:)`, `sessionBecameUnavailable()`, and `sessionBecameAvailable()`.

- [ ] **Step 1: Write failing trigger transition tests**

Test default-off, locked/asleep suppression, ten-minute threshold, early return
cancellation, one fire per idle interval, return-during-pass halt request,
idle-disabled behavior, and a fresh interval after wake.

```swift
@Test func lockedSessionNeverFiresIdlePass() {
    var tracker = TidyIdleTracker(threshold: 600)
    tracker.sessionAvailable = false
    #expect(tracker.receive(.idleBegan, at: 0) == .none)
    #expect(tracker.tick(at: 700) == .none)
}

@Test func returningDuringRunRequestsBoundaryHalt() {
    var tracker = TidyIdleTracker(threshold: 600)
    tracker.isRunningIdlePass = true
    #expect(tracker.receive(.idleEnded, at: 700) == .haltAtBoundary)
}
```

- [ ] **Step 2: Run trigger tests and verify RED**

Run: `./Scripts/test.sh --filter TidyTriggerTests`

Expected: compilation fails because `TidyIdleTracker` does not exist.

- [ ] **Step 3: Implement trigger state and workspace observation**

Use a pure action enum `.none`, `.schedule(after:)`, `.cancelPending`,
`.startPass`, and `.haltAtBoundary`. Because `SystemMonitor` reports idle at its
existing two-minute threshold, expose that value as
`SystemMonitor.idleSignalThreshold` and schedule only the remaining configured
interval:
`max(0, preferences.idleMinutes * 60 - SystemMonitor.idleSignalThreshold)`.

In `AppDelegate`, route idle signals to Tidy even when system-reaction emotes are
disabled. Keep `SystemMonitor` alive when either system reactions or enabled
Tidy idle needs it. Observe `NSWorkspace.sessionDidResignActiveNotification`,
`sessionDidBecomeActiveNotification`, `screensDidSleepNotification`, and
`screensDidWakeNotification`. Resign/sleep cancels pending work and prevents a
pass; active/wake only rearms state and never starts a pass directly.

- [ ] **Step 4: Run trigger, monitor, and full tests**

Run: `./Scripts/test.sh --filter TidyTriggerTests && ./Scripts/test.sh --filter SystemMonitorTests && ./Scripts/test.sh`

Expected: all pass.

- [ ] **Step 5: Commit idle triggering**

```bash
git add Sources/Jumbini/Tidy/TidyCoordinator.swift Sources/Jumbini/AppDelegate.swift Sources/Jumbini/SystemMonitor.swift Tests/JumbiniTests/TidyTriggerTests.swift
git commit -m "feat: run Tidy safely while idle"
```

### Task 10: Theater-only carry and deposit animation

**Files:**
- Create: `Sources/Jumbini/Tidy/TidyAnimation.swift`
- Modify: `Sources/Jumbini/AppDelegate.swift`
- Modify: `Sources/Jumbini/PetScene.swift`
- Modify: `Sources/Jumbini/SpriteLoader.swift`
- Create: `Tests/JumbiniTests/TidyAnimationTests.swift`

**Interfaces:**
- Consumes: successful `TidyCompletedMove` callbacks and `ScreenLayout`.
- Produces: `TidyAnimationCue`, `TidyAnimationBatcher`, `TidyAnimationRegion.point(for:layout:)`, and `PetScene.enqueueTidy(_:)`.

- [ ] **Step 1: Write failing pure animation-policy tests**

Test deterministic points for a path, points constrained to a real display,
first-three individual cues, one batch cue for the remainder, reduced-motion
suppression, paused suppression, and a hard maximum theater duration.

```swift
@Test func fiftyMovesBecomeThreeIndividualCuesAndOneBatch() {
    let moves = (0..<50).map(TidyCompletedMove.fixture(index:))
    let cues = TidyAnimationBatcher.cues(for: moves, reduceMotion: false, overlayVisible: true)
    #expect(cues.count == 4)
    #expect(cues.prefix(3).allSatisfy { $0.count == 1 })
    #expect(cues.last?.count == 47)
    #expect(cues.reduce(0) { $0 + $1.duration } <= 12)
}

@Test func reducedMotionProducesNoCues() {
    #expect(TidyAnimationBatcher.cues(
        for: [.fixture(index: 0)], reduceMotion: true, overlayVisible: true
    ).isEmpty)
}
```

- [ ] **Step 2: Run animation tests and verify RED**

Run: `./Scripts/test.sh --filter TidyAnimationTests`

Expected: compilation fails because `TidyAnimationBatcher` does not exist.

- [ ] **Step 3: Implement optional scene cues**

Hash the source path with a stable FNV-1a function, choose a point inside
`layout.sceneFrames`, and inset it 80 points from display edges. Individual cues
last at most 2.5 seconds; the aggregate batch cue lasts at most 4 seconds.

`PetScene.enqueueTidy(_:)` returns immediately after adding an `SKAction`
sequence to a dedicated action key. The sequence moves the dog toward the cue
point using `.carryWalk`, briefly shows a temporary node using one of
`deposit_1`, `deposit_2`, or `deposit_3`, then returns to `.idle`. It does not
create a persistent pile or send a `DogEvent`. If another interaction removes
the action, no completion is reported back to Tidy.

In `AppDelegate`, suppress cue creation when `isPaused`, the overlay is hidden,
or `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` is true. After
execution returns, pass only `TidyPassResult.moves` to the batcher through
`coordinator.onSuccessfulMoves`; filesystem execution never waits for cue
completion.

- [ ] **Step 4: Run animation, scene, and full tests**

Run: `./Scripts/test.sh --filter TidyAnimationTests && ./Scripts/test.sh --filter DogBrainTests && ./Scripts/test.sh && ./Scripts/bundle.sh && ./Scripts/smoke.sh`

Expected: all pass; pause and Reduce Motion paths produce no cues while fixture
moves still complete.

- [ ] **Step 5: Commit animation**

```bash
git add Sources/Jumbini/Tidy/TidyAnimation.swift Sources/Jumbini/PetScene.swift Sources/Jumbini/SpriteLoader.swift Sources/Jumbini/AppDelegate.swift Tests/JumbiniTests/TidyAnimationTests.swift
git commit -m "feat: animate Jumba tidying files"
```

### Task 11: Documentation and ship verification

**Files:**
- Modify: `README.md`
- Modify if verification reveals a defect: only the smallest source/test files responsible for that defect.

**Interfaces:**
- Consumes: the completed feature.
- Produces: user documentation and a clean, reviewable, release-buildable branch.

- [ ] **Step 1: Add README usage and privacy documentation**

Document that Tidy is opt-in, one-folder-scoped, first-match-wins, nonrecursive,
preview-gated, capped at 50, never deletes/overwrites/uploads/reads contents,
stores `tidy-rules.json` and `tidy.log` in Application Support, and supports only
last-pass undo. Include `Tidy → Forget Folder…` as the revocation path.

- [ ] **Step 2: Run formatting and static checks**

Run: `git diff --check && swift build`

Expected: no whitespace errors and a successful debug build.

- [ ] **Step 3: Run the complete automated verification**

Run: `./Scripts/test.sh && swift build -c release && ./Scripts/bundle.sh && ./Scripts/smoke.sh`

Expected: every test passes, the release binary builds, `build/Jumbini.app`
assembles, and the bundled process remains alive through the smoke interval.

- [ ] **Step 4: Perform targeted manual safety checks in a disposable folder**

Create a folder under `.context/tidy-manual/`, populate it with a screenshot,
image, empty DMG fixture, ZIP, recent file, symlink, package directory, and 55
collision-prone files. Through the bundled app verify: cancel writes nothing;
opted-out rows stay put; recent/symlink/package rules behave as specified; 50
moves and five remain; Undo restores exact names; pause and Reduce Motion do not
block moves; returning during idle halts at a boundary; Forget Folder removes
authorization and leaves files unchanged. Remove only `.context/tidy-manual/`
after recording results in the final handoff.

- [ ] **Step 5: Review the branch against the target**

Run: `git status --short && git diff --stat origin/main...HEAD && git diff --check origin/main...HEAD && git log --oneline origin/main..HEAD`

Expected: only Tidy implementation, tests, design/plan documents, and README
changes; no build artifacts or unrelated edits.

- [ ] **Step 6: Commit documentation and any verified corrections**

```bash
git add README.md
git commit -m "docs: explain Tidy safety and privacy"
```

- [ ] **Step 7: Prepare the shipping handoff**

Report commits, test/build/smoke results, manual-check results, and remaining
platform verification for Desktop TCC behavior on the minimum supported macOS
14 installation. Do not push a version tag or publish a GitHub release without
a separate explicit user confirmation because that triggers signing,
notarization, Sparkle publication, and distribution.
