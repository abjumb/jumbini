import Foundation
import Testing
@testable import Jumbini

@Suite struct TidyCoordinatorTests {
    @Test @MainActor func noFolderBlocksPreviewManualRunAndUndo() async {
        let fixture = CoordinatorFixture(folder: nil)

        #expect(fixture.coordinator.state.folder == nil)
        await expectCoordinatorError(.folderRequired) {
            _ = try await fixture.coordinator.makePreview()
        }
        await expectCoordinatorError(.folderRequired) {
            _ = try await fixture.coordinator.runManual()
        }
        await expectCoordinatorError(.folderRequired) {
            _ = try await fixture.coordinator.undo()
        }
        #expect(fixture.backend.planCallCount == 0)
        #expect(fixture.backend.executeSelections.isEmpty)
        #expect(fixture.backend.undoCallCount == 0)
    }

    @Test @MainActor func staleGrantDisablesTheFolderUntilItIsReplaced() async throws {
        let fixture = CoordinatorFixture(folderIsStale: true)

        #expect(fixture.coordinator.state.folder == nil)
        #expect(fixture.coordinator.state.blockingError != nil)
        await expectCoordinatorError(.staleBookmark) {
            _ = try await fixture.coordinator.makePreview()
        }

        let replacement = URL(fileURLWithPath: "/tmp/JumbiniReplacement", isDirectory: true)
        try fixture.coordinator.setFolder(replacement)
        #expect(fixture.coordinator.state.folder == replacement)
        #expect(fixture.coordinator.state.blockingError == nil)
        #expect(fixture.coordinator.state.needsPreview)
    }

    @Test @MainActor func newFolderRequiresAnInitialPreview() async throws {
        let fixture = CoordinatorFixture(folder: nil, needsPreview: false)
        let selected = URL(fileURLWithPath: "/tmp/JumbiniSelected", isDirectory: true)

        try fixture.coordinator.setFolder(selected)

        #expect(fixture.backend.savedFolders == [selected])
        #expect(fixture.coordinator.state.folder == selected)
        #expect(fixture.coordinator.state.needsPreview)
        #expect(fixture.coordinator.state.completedManualPass == false)
        #expect(fixture.coordinator.state.preferences.idleEnabled == false)
        await expectCoordinatorError(.previewRequired) {
            _ = try await fixture.coordinator.runManual()
        }
    }

    @Test @MainActor func makingPreviewWithoutExecutingLeavesTheGateClosed() async throws {
        let fixture = CoordinatorFixture(needsPreview: true)

        let preview = try await fixture.coordinator.makePreview()

        #expect(preview == fixture.backend.plan)
        #expect(fixture.coordinator.state.needsPreview)
        #expect(fixture.backend.executeSelections.isEmpty)
    }

    @Test @MainActor func ruleEditBlocksLiveRunUntilPreviewExecutes() async throws {
        let fixture = CoordinatorFixture.readyForLiveRun()
        var edited = fixture.rules
        edited.rules[0].destination = "Screen Captures"
        try fixture.coordinator.updateRules(edited)

        #expect(fixture.coordinator.state.needsPreview)
        await expectCoordinatorError(.previewRequired) {
            _ = try await fixture.coordinator.runManual()
        }
        let preview = try await fixture.coordinator.makePreview()
        _ = try await fixture.coordinator.executePreview(
            selection: Set(preview.movable.map(\.id))
        )
        #expect(fixture.coordinator.state.needsPreview == false)
        #expect(fixture.backend.savedRules.last == edited)
    }

    @Test @MainActor func recencyEditRestoresThePreviewGate() async throws {
        let fixture = CoordinatorFixture.readyForLiveRun()

        try fixture.coordinator.updateRecency(minutes: 12)

        #expect(fixture.coordinator.state.preferences.recencyMinutes == 12)
        #expect(fixture.coordinator.state.needsPreview)
        await expectCoordinatorError(.previewRequired) {
            _ = try await fixture.coordinator.runManual()
        }
    }

    @Test @MainActor func confirmedPreviewPropagatesSelectionAndUnlocksIdleWithoutEnablingIt() async throws {
        let fixture = CoordinatorFixture(needsPreview: true, completedManualPass: false)
        let preview = try await fixture.coordinator.makePreview()
        let selectedID = try #require(preview.movable.last?.id)
        var cues: [[TidyCompletedMove]] = []
        var notices: [TidyNotice] = []
        fixture.coordinator.onSuccessfulMoves = { cues.append($0) }
        fixture.coordinator.onNotice = { notices.append($0) }

        let result = try await fixture.coordinator.executePreview(selection: [selectedID])

        #expect(fixture.backend.executeSelections == [[selectedID]])
        #expect(fixture.backend.executeTriggers == [.manual])
        #expect(result.moves.map(\.source.lastPathComponent) == ["second.png"])
        #expect(cues == [result.moves])
        #expect(notices == [.completed(moved: 1, skipped: 0, capped: false)])
        #expect(fixture.coordinator.state.needsPreview == false)
        #expect(fixture.coordinator.state.completedManualPass)
        #expect(fixture.coordinator.state.idleAvailable)
        #expect(fixture.coordinator.state.preferences.idleEnabled == false)
        #expect(fixture.coordinator.state.undoCount == 1)
    }

    @Test @MainActor func approvedManualRunPlansFreshAndSelectsEveryMovableRow() async throws {
        let fixture = CoordinatorFixture.readyForLiveRun()

        let result = try await fixture.coordinator.runManual()

        #expect(result.moves.count == 2)
        #expect(fixture.backend.planCallCount == 1)
        #expect(fixture.backend.executeSelections == [Set(fixture.backend.plan.movable.map(\.id))])
        #expect(fixture.backend.executeTriggers == [.manual])
        #expect(fixture.backend.planRanOnMainThread == [false])
        #expect(fixture.backend.executeRanOnMainThread == [false])
        #expect(fixture.backend.scopeStartCount == 1)
        #expect(fixture.backend.scopeStopCount == 1)
        #expect(fixture.backend.operationScopeDepths == [1, 1])
    }

    @Test @MainActor func previewExecutionFailureBeforePassStartPreservesTheGate() async throws {
        let fixture = CoordinatorFixture(needsPreview: true, completedManualPass: false)
        fixture.backend.executionOutcomes = [.failure(.executionFailed)]
        let preview = try await fixture.coordinator.makePreview()
        var cues: [[TidyCompletedMove]] = []
        fixture.coordinator.onSuccessfulMoves = { cues.append($0) }

        do {
            _ = try await fixture.coordinator.executePreview(
                selection: Set(preview.movable.map(\.id))
            )
            Issue.record("A pass that never starts must not be treated as reviewed")
        } catch {
            #expect(error as? CoordinatorBackend.Failure == .executionFailed)
        }

        #expect(fixture.coordinator.state.needsPreview)
        #expect(fixture.coordinator.state.completedManualPass == false)
        #expect(fixture.coordinator.state.undoCount == 0)
        #expect(cues.isEmpty)
        #expect(fixture.backend.scopeStartCount == fixture.backend.scopeStopCount)
    }

    @Test @MainActor func failedPassEmitsItsCompletedPrefixWithoutUnlockingIdle() async throws {
        let fixture = CoordinatorFixture(needsPreview: true, completedManualPass: false)
        let completed = CoordinatorBackend.completedMove(from: fixture.backend.plan.movable[0])
        let failed = TidyPassResult(
            passID: UUID(), moves: [completed], skipped: [], failures: ["disk full"],
            didHitCap: false, wasHalted: false
        )
        fixture.backend.executionOutcomes = [.result(failed)]
        let preview = try await fixture.coordinator.makePreview()
        var cues: [[TidyCompletedMove]] = []
        var notices: [TidyNotice] = []
        fixture.coordinator.onSuccessfulMoves = { cues.append($0) }
        fixture.coordinator.onNotice = { notices.append($0) }

        _ = try await fixture.coordinator.executePreview(
            selection: Set(preview.movable.map(\.id))
        )

        #expect(fixture.coordinator.state.needsPreview == false)
        #expect(fixture.coordinator.state.completedManualPass == false)
        #expect(fixture.coordinator.state.idleAvailable == false)
        #expect(fixture.coordinator.state.undoCount == 1)
        #expect(cues == [[completed]])
        #expect(notices == [.failed("disk full")])
    }

    @Test @MainActor func anEmptyPassNeverEmitsASuccessfulMoveCue() async throws {
        let fixture = CoordinatorFixture.readyForLiveRun()
        fixture.backend.executionOutcomes = [.result(TidyPassResult(
            passID: UUID(), moves: [], skipped: [], failures: [],
            didHitCap: false, wasHalted: false
        ))]
        var cues: [[TidyCompletedMove]] = []
        fixture.coordinator.onSuccessfulMoves = { cues.append($0) }

        _ = try await fixture.coordinator.runManual()

        #expect(cues.isEmpty)
        #expect(fixture.coordinator.state.undoCount == 0)
    }

    @Test @MainActor func eachNewPassReplacesUndoAndSuccessfulUndoConsumesIt() async throws {
        let fixture = CoordinatorFixture(needsPreview: true)
        let preview = try await fixture.coordinator.makePreview()
        _ = try await fixture.coordinator.executePreview(
            selection: Set(preview.movable.map(\.id))
        )
        #expect(fixture.coordinator.state.undoCount == 2)

        let replacement = CoordinatorBackend.completedMove(from: fixture.backend.plan.movable[1])
        fixture.backend.executionOutcomes = [.result(TidyPassResult(
            passID: UUID(), moves: [replacement], skipped: [], failures: [],
            didHitCap: false, wasHalted: false
        ))]
        _ = try await fixture.coordinator.runManual()
        #expect(fixture.coordinator.state.undoCount == 1)

        var notices: [TidyNotice] = []
        fixture.coordinator.onNotice = { notices.append($0) }
        let undo = try await fixture.coordinator.undo()
        #expect(undo.restoredCount == 1)
        #expect(fixture.coordinator.state.undoCount == 0)
        #expect(notices == [.undone(1)])
    }

    @Test @MainActor func forgettingFolderClearsOnlyDerivedCoordinatorState() async throws {
        let fixture = CoordinatorFixture(needsPreview: true)
        let originalRules = fixture.coordinator.state.rules
        let preview = try await fixture.coordinator.makePreview()
        _ = try await fixture.coordinator.executePreview(
            selection: Set(preview.movable.map(\.id))
        )
        #expect(fixture.coordinator.state.undoCount == 2)

        try fixture.coordinator.forgetFolder()

        #expect(fixture.backend.forgetFolderCallCount == 1)
        #expect(fixture.coordinator.state.folder == nil)
        #expect(fixture.coordinator.state.rules == originalRules)
        #expect(fixture.coordinator.state.undoCount == 0)
        #expect(fixture.coordinator.state.needsPreview)
        #expect(fixture.coordinator.state.completedManualPass == false)
        #expect(fixture.coordinator.state.preferences.idleEnabled == false)
    }

    @Test @MainActor func forgettingFolderPreservesPersistedRulesAndLedger() throws {
        let support = try TemporaryDirectory.make()
        let chosen = try TemporaryDirectory.make()
        let store = TidyStore(directory: support.url)
        var preferences = TidyPreferences()
        preferences.needsPreview = false
        preferences.idleEnabled = true
        preferences.completedManualPass = true
        try store.saveRules(.defaults)
        try store.savePreferences(preferences)
        try store.saveFolder(chosen.url)
        let ledgerURL = support.url.appendingPathComponent("tidy.log")
        try writeFixture("existing-ledger-entry\n", to: ledgerURL)
        let ledger = TidyLedger(directory: support.url)
        let coordinator = TidyCoordinator(
            store: store,
            planner: TidyPlanner(openFiles: CoordinatorNoOpenFiles()),
            executor: TidyExecutor(
                ledger: ledger,
                openFiles: CoordinatorNoOpenFiles()
            )
        )

        try coordinator.forgetFolder()

        #expect(try store.resolveFolder() == nil)
        #expect(try store.loadRules() == .defaults)
        #expect(try String(contentsOf: ledgerURL, encoding: .utf8) == "existing-ledger-entry\n")
    }

    @Test @MainActor func securityScopeIsBalancedAroundEachPlanningAndMutationLifetime() async throws {
        let fixture = CoordinatorFixture(needsPreview: true)

        let preview = try await fixture.coordinator.makePreview()
        _ = try await fixture.coordinator.executePreview(
            selection: Set(preview.movable.map(\.id))
        )
        _ = try await fixture.coordinator.runManual()
        _ = try await fixture.coordinator.undo()

        #expect(fixture.backend.scopeStartCount == 4)
        #expect(fixture.backend.scopeStopCount == 4)
        #expect(fixture.backend.scopeDepth == 0)
        #expect(fixture.backend.operationScopeDepths.allSatisfy { $0 == 1 })
    }

    @Test @MainActor func revokedScopeClearsFolderAndSurfacesStaleBookmark() async {
        let fixture = CoordinatorFixture.readyForLiveRun()
        fixture.backend.allowsScopeAccess = false

        await expectCoordinatorError(.staleBookmark) {
            _ = try await fixture.coordinator.runManual()
        }

        #expect(fixture.coordinator.state.folder == nil)
        #expect(fixture.coordinator.state.blockingError != nil)
        #expect(fixture.backend.scopeStartCount == 1)
        #expect(fixture.backend.scopeStopCount == 0)
    }

    @Test @MainActor func runningAndCallbackStateReturnToTheMainActor() async throws {
        let fixture = CoordinatorFixture.readyForLiveRun()
        var states: [TidyCoordinator.State] = []
        var callbacksWereOnMainThread: [Bool] = []
        fixture.coordinator.onStateChange = {
            states.append($0)
            callbacksWereOnMainThread.append(Thread.isMainThread)
        }
        fixture.coordinator.onNotice = { _ in
            callbacksWereOnMainThread.append(Thread.isMainThread)
        }
        fixture.coordinator.onSuccessfulMoves = { _ in
            callbacksWereOnMainThread.append(Thread.isMainThread)
        }

        _ = try await fixture.coordinator.runManual()

        #expect(states.contains { $0.isRunning })
        #expect(states.last?.isRunning == false)
        #expect(callbacksWereOnMainThread.allSatisfy { $0 })
        #expect(fixture.backend.planRanOnMainThread == [false])
        #expect(fixture.backend.executeRanOnMainThread == [false])
    }
}

@MainActor
private func expectCoordinatorError(
    _ expected: TidyCoordinatorError,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected coordinator error \(expected)")
    } catch {
        #expect(error as? TidyCoordinatorError == expected)
    }
}

@MainActor
private struct CoordinatorFixture {
    let backend: CoordinatorBackend
    let coordinator: TidyCoordinator

    var rules: TidyRuleSet { backend.rules }

    init(
        folder: URL? = URL(fileURLWithPath: "/tmp/JumbiniCoordinator", isDirectory: true),
        folderIsStale: Bool = false,
        needsPreview: Bool = true,
        completedManualPass: Bool = false
    ) {
        backend = CoordinatorBackend(
            folder: folder,
            folderIsStale: folderIsStale,
            needsPreview: needsPreview,
            completedManualPass: completedManualPass
        )
        coordinator = TidyCoordinator(dependencies: backend.dependencies())
    }

    static func readyForLiveRun() -> CoordinatorFixture {
        CoordinatorFixture(needsPreview: false, completedManualPass: true)
    }
}

private final class CoordinatorBackend: @unchecked Sendable {
    enum Failure: Error, Equatable {
        case executionFailed
    }

    enum ExecutionOutcome {
        case result(TidyPassResult)
        case failure(Failure)
    }

    var rules = TidyRuleSet.defaults
    var preferences: TidyPreferences
    var folderGrant: TidyFolderGrant?
    let plan: TidyPlan
    var executionOutcomes: [ExecutionOutcome] = []
    var allowsScopeAccess = true
    var undoResult = TidyUndoResult(restoredCount: 1)

    private(set) var savedRules: [TidyRuleSet] = []
    private(set) var savedPreferences: [TidyPreferences] = []
    private(set) var savedFolders: [URL] = []
    private(set) var forgetFolderCallCount = 0
    private(set) var planCallCount = 0
    private(set) var executeSelections: [Set<UUID>] = []
    private(set) var executeTriggers: [TidyTrigger] = []
    private(set) var undoCallCount = 0
    private(set) var scopeStartCount = 0
    private(set) var scopeStopCount = 0
    private(set) var scopeDepth = 0
    private(set) var operationScopeDepths: [Int] = []
    private(set) var planRanOnMainThread: [Bool] = []
    private(set) var executeRanOnMainThread: [Bool] = []

    init(
        folder: URL?,
        folderIsStale: Bool,
        needsPreview: Bool,
        completedManualPass: Bool
    ) {
        preferences = TidyPreferences(
            needsPreview: needsPreview,
            recencyMinutes: 5,
            idleEnabled: false,
            idleMinutes: 10,
            completedManualPass: completedManualPass
        )
        folderGrant = folder.map { TidyFolderGrant(url: $0, isStale: folderIsStale) }

        let root = folder ?? URL(fileURLWithPath: "/tmp/JumbiniCoordinator", isDirectory: true)
        let ruleID = rules.rules[0].id
        let modifiedAt = Date(timeIntervalSince1970: 1_000_000)
        let first = TidyPlannedMove(
            id: UUID(uuidString: "0B362A2C-9458-477C-A4E9-05B27D7F137E")!,
            source: root.appendingPathComponent("first.png"),
            destination: root.appendingPathComponent("Images/first.png"),
            sourceID: TidyFileID(device: 1, inode: 1),
            modifiedAt: modifiedAt,
            ruleID: ruleID,
            ruleName: "Images"
        )
        let second = TidyPlannedMove(
            id: UUID(uuidString: "E199890E-9929-4A8B-9CD2-BB7656499596")!,
            source: root.appendingPathComponent("second.png"),
            destination: root.appendingPathComponent("Images/second.png"),
            sourceID: TidyFileID(device: 1, inode: 2),
            modifiedAt: modifiedAt,
            ruleID: ruleID,
            ruleName: "Images"
        )
        plan = TidyPlan(root: root, movable: [first, second], skipped: [])
    }

    func dependencies() -> TidyCoordinator.Dependencies {
        TidyCoordinator.Dependencies(
            loadRules: { self.rules },
            saveRules: {
                self.rules = $0
                self.savedRules.append($0)
            },
            loadPreferences: { self.preferences },
            savePreferences: {
                self.preferences = $0
                self.savedPreferences.append($0)
            },
            saveFolder: {
                self.savedFolders.append($0)
                self.folderGrant = TidyFolderGrant(url: $0, isStale: false)
            },
            resolveFolder: { self.folderGrant },
            forgetFolder: {
                self.forgetFolderCallCount += 1
                self.folderGrant = nil
            },
            plan: { _, _, _, _ in
                self.planCallCount += 1
                self.planRanOnMainThread.append(Thread.isMainThread)
                self.operationScopeDepths.append(self.scopeDepth)
                return self.plan
            },
            execute: { plan, selection, trigger, _ in
                self.executeSelections.append(selection)
                self.executeTriggers.append(trigger)
                self.executeRanOnMainThread.append(Thread.isMainThread)
                self.operationScopeDepths.append(self.scopeDepth)
                if !self.executionOutcomes.isEmpty {
                    switch self.executionOutcomes.removeFirst() {
                    case .result(let result):
                        return result
                    case .failure(let error):
                        throw error
                    }
                }
                let moves = plan.movable
                    .filter { selection.contains($0.id) }
                    .map(Self.completedMove(from:))
                return TidyPassResult(
                    passID: UUID(), moves: moves, skipped: plan.skipped, failures: [],
                    didHitCap: false, wasHalted: false
                )
            },
            undo: { _, _ in
                self.undoCallCount += 1
                self.operationScopeDepths.append(self.scopeDepth)
                return self.undoResult
            },
            startAccessing: { _ in
                self.scopeStartCount += 1
                if self.allowsScopeAccess {
                    self.scopeDepth += 1
                }
                return self.allowsScopeAccess
            },
            stopAccessing: { _ in
                self.scopeStopCount += 1
                self.scopeDepth -= 1
            },
            now: { Date(timeIntervalSince1970: 2_000_000_000) }
        )
    }

    static func completedMove(from move: TidyPlannedMove) -> TidyCompletedMove {
        TidyCompletedMove(
            source: move.source,
            destination: move.destination,
            fileID: move.sourceID,
            ruleID: move.ruleID,
            ruleName: move.ruleName
        )
    }
}

private struct CoordinatorNoOpenFiles: TidyOpenFileDetecting {
    func openPaths(under root: URL) -> Set<String> { [] }
}
