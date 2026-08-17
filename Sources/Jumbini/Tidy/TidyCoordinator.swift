import Dispatch
import Foundation

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

@MainActor
final class TidyCoordinator {
    struct State: Equatable {
        var folder: URL?
        var rules: TidyRuleSet
        var preferences: TidyPreferences
        var isRunning: Bool
        var undoCount: Int
        var blockingError: String?

        var needsPreview: Bool { preferences.needsPreview }
        var completedManualPass: Bool { preferences.completedManualPass }
        var idleAvailable: Bool {
            folder != nil
                && blockingError == nil
                && !preferences.needsPreview
                && preferences.completedManualPass
        }
    }

    struct Dependencies: @unchecked Sendable {
        let loadRules: () throws -> TidyRuleSet
        let saveRules: (TidyRuleSet) throws -> Void
        let loadPreferences: () throws -> TidyPreferences
        let savePreferences: (TidyPreferences) throws -> Void
        let saveFolder: (URL) throws -> Void
        let resolveFolder: () throws -> TidyFolderGrant?
        let forgetFolder: () throws -> Void
        let plan: (URL, [TidyRule], Int, Date) throws -> TidyPlan
        let execute: (TidyPlan, Set<UUID>, TidyTrigger, Date) throws -> TidyPassResult
        let undo: (URL, Date) throws -> TidyUndoResult
        let startAccessing: (URL) -> Bool
        let stopAccessing: (URL) -> Void
        let now: () -> Date
    }

    private enum Block {
        case staleBookmark
        case configuration(String)

        var message: String {
            switch self {
            case .staleBookmark:
                return "The selected folder permission must be renewed."
            case .configuration(let message):
                return message
            }
        }
    }

    private let dependencies: Dependencies
    private let workQueue: DispatchQueue
    private var block: Block?
    private var preview: TidyPlan?
    private var operationInFlight = false

    private(set) var state: State
    var onStateChange: ((State) -> Void)?
    var onNotice: ((TidyNotice) -> Void)?
    var onSuccessfulMoves: (([TidyCompletedMove]) -> Void)?

    convenience init(
        store: TidyStore,
        planner: TidyPlanner,
        executor: TidyExecutor,
        now: @escaping () -> Date = Date.init
    ) {
        self.init(dependencies: Dependencies(
            loadRules: store.loadRules,
            saveRules: store.saveRules,
            loadPreferences: store.loadPreferences,
            savePreferences: store.savePreferences,
            saveFolder: store.saveFolder,
            resolveFolder: store.resolveFolder,
            forgetFolder: store.forgetFolder,
            plan: { root, rules, recencyMinutes, date in
                try planner.plan(
                    root: root,
                    rules: rules,
                    recencyMinutes: recencyMinutes,
                    now: date
                )
            },
            execute: { plan, selectedIDs, trigger, date in
                try executor.execute(
                    plan: plan,
                    selectedIDs: selectedIDs,
                    trigger: trigger,
                    now: date,
                    shouldHalt: { false },
                    didMove: { _ in }
                )
            },
            undo: executor.undoLatest,
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            stopAccessing: { $0.stopAccessingSecurityScopedResource() },
            now: now
        ))
    }

    init(
        dependencies: Dependencies,
        workQueue: DispatchQueue = DispatchQueue(label: "com.jumbini.tidy.coordinator")
    ) {
        self.dependencies = dependencies
        self.workQueue = workQueue

        var rules = TidyRuleSet.defaults
        var preferences = TidyPreferences()
        var folder: URL?
        var initialBlock: Block?

        do {
            rules = try dependencies.loadRules()
        } catch {
            initialBlock = .configuration(String(describing: error))
        }
        do {
            preferences = try dependencies.loadPreferences()
        } catch {
            initialBlock = .configuration(String(describing: error))
        }
        do {
            if let grant = try dependencies.resolveFolder() {
                if grant.isStale {
                    initialBlock = .staleBookmark
                } else {
                    folder = grant.url
                }
            }
        } catch {
            initialBlock = .staleBookmark
        }

        block = initialBlock
        state = State(
            folder: folder,
            rules: rules,
            preferences: preferences,
            isRunning: false,
            undoCount: 0,
            blockingError: initialBlock?.message
        )
    }

    func setFolder(_ url: URL) throws {
        try requireNoOperationInFlight()

        var preferences = state.preferences
        preferences.needsPreview = true
        preferences.idleEnabled = false
        preferences.completedManualPass = false
        try dependencies.savePreferences(preferences)
        preview = nil
        updateState { $0.preferences = preferences }

        try dependencies.saveFolder(url)
        if case .staleBookmark? = block {
            block = nil
        }
        updateState {
            $0.folder = url
            $0.undoCount = 0
            $0.blockingError = block?.message
        }
    }

    func forgetFolder() throws {
        try requireNoOperationInFlight()
        try dependencies.forgetFolder()

        preview = nil
        block = nil
        var preferences = state.preferences
        preferences.needsPreview = true
        preferences.idleEnabled = false
        preferences.completedManualPass = false
        updateState {
            $0.folder = nil
            $0.preferences = preferences
            $0.undoCount = 0
            $0.blockingError = nil
        }
        try dependencies.savePreferences(preferences)
    }

    func updateRules(_ rules: TidyRuleSet) throws {
        try requireNoOperationInFlight()

        var preferences = state.preferences
        preferences.needsPreview = true
        try dependencies.savePreferences(preferences)
        preview = nil
        updateState { $0.preferences = preferences }

        do {
            try dependencies.saveRules(rules)
        } catch {
            setBlock(.configuration(String(describing: error)))
            throw error
        }
        if case .configuration? = block {
            block = nil
        }
        updateState {
            $0.rules = rules
            $0.blockingError = block?.message
        }
    }

    func updateRecency(minutes: Int) throws {
        try requireNoOperationInFlight()

        var preferences = state.preferences
        preferences.recencyMinutes = max(minutes, 1)
        preferences.needsPreview = true
        try dependencies.savePreferences(preferences)
        preview = nil
        updateState { $0.preferences = preferences }
    }

    func makePreview() async throws -> TidyPlan {
        let root = try requireFolder()
        try beginOperation(isPass: false)
        defer { finishOperation(isPass: false) }

        let rules = state.rules.rules
        let recencyMinutes = state.preferences.recencyMinutes
        let date = dependencies.now()
        do {
            let plan = try await performWithAccess(to: root) { dependencies in
                try dependencies.plan(root, rules, recencyMinutes, date)
            }
            preview = plan
            return plan
        } catch {
            throw handlePlanningError(error)
        }
    }

    func executePreview(selection: Set<UUID>) async throws -> TidyPassResult {
        let root = try requireFolder()
        guard let preview else {
            throw TidyCoordinatorError.previewRequired
        }
        let date = dependencies.now()
        return try await runPass(clearsPreviewGate: true) {
            try await self.performWithAccess(to: root) { dependencies in
                try dependencies.execute(preview, selection, .manual, date)
            }
        }
    }

    func runManual() async throws -> TidyPassResult {
        let root = try requireFolder()
        guard !state.preferences.needsPreview else {
            throw TidyCoordinatorError.previewRequired
        }
        let rules = state.rules.rules
        let recencyMinutes = state.preferences.recencyMinutes
        let date = dependencies.now()
        return try await runPass(clearsPreviewGate: false) {
            try await self.performWithAccess(to: root) { dependencies in
                let plan = try dependencies.plan(root, rules, recencyMinutes, date)
                return try dependencies.execute(
                    plan,
                    Set(plan.movable.map(\.id)),
                    .manual,
                    date
                )
            }
        }
    }

    func undo() async throws -> TidyUndoResult {
        let root = try requireFolder()
        try beginOperation(isPass: true)
        defer { finishOperation(isPass: true) }

        let date = dependencies.now()
        do {
            let result = try await performWithAccess(to: root) { dependencies in
                try dependencies.undo(root, date)
            }
            updateState { $0.undoCount = 0 }
            onNotice?(.undone(result.restoredCount))
            return result
        } catch {
            let surfaced = handleOperationError(error)
            onNotice?(.failed(String(describing: surfaced)))
            throw surfaced
        }
    }

    private func runPass(
        clearsPreviewGate: Bool,
        operation: () async throws -> TidyPassResult
    ) async throws -> TidyPassResult {
        try beginOperation(isPass: true)
        defer { finishOperation(isPass: true) }

        var passReturned = false
        do {
            let result = try await operation()
            passReturned = true
            if clearsPreviewGate {
                preview = nil
            }
            publish(result)

            var preferences = state.preferences
            if clearsPreviewGate {
                preferences.needsPreview = false
            }
            if result.failures.isEmpty && !result.wasHalted {
                preferences.completedManualPass = true
            }
            try await perform { dependencies in
                try dependencies.savePreferences(preferences)
            }
            updateState { $0.preferences = preferences }
            return result
        } catch {
            let surfaced: Error
            if passReturned {
                setBlock(.configuration(String(describing: error)))
                surfaced = error
            } else {
                surfaced = handleOperationError(error)
                onNotice?(.failed(String(describing: surfaced)))
            }
            throw surfaced
        }
    }

    private func publish(_ result: TidyPassResult) {
        updateState { $0.undoCount = result.moves.count }
        if !result.moves.isEmpty {
            onSuccessfulMoves?(result.moves)
        }

        if result.wasHalted {
            onNotice?(.halted(moved: result.moves.count))
        } else if !result.failures.isEmpty {
            onNotice?(.failed(result.failures.joined(separator: "\n")))
        } else {
            onNotice?(.completed(
                moved: result.moves.count,
                skipped: result.skipped.count,
                capped: result.didHitCap
            ))
        }
    }

    private func requireFolder() throws -> URL {
        if let block {
            switch block {
            case .staleBookmark:
                throw TidyCoordinatorError.staleBookmark
            case .configuration(let message):
                throw TidyCoordinatorError.recoveryBlocked(message)
            }
        }
        guard let folder = state.folder else {
            throw TidyCoordinatorError.folderRequired
        }
        return folder
    }

    private func requireNoOperationInFlight() throws {
        guard !operationInFlight else {
            throw TidyCoordinatorError.recoveryBlocked("Tidy is already running.")
        }
    }

    private func beginOperation(isPass: Bool) throws {
        try requireNoOperationInFlight()
        operationInFlight = true
        if isPass {
            updateState { $0.isRunning = true }
        }
    }

    private func finishOperation(isPass: Bool) {
        operationInFlight = false
        if isPass {
            updateState { $0.isRunning = false }
        }
    }

    private func perform<Value>(
        _ operation: @escaping (Dependencies) throws -> Value
    ) async throws -> Value {
        let dependencies = dependencies
        return try await withCheckedThrowingContinuation { continuation in
            workQueue.async {
                continuation.resume(with: Result {
                    try operation(dependencies)
                })
            }
        }
    }

    private func performWithAccess<Value>(
        to root: URL,
        _ operation: @escaping (Dependencies) throws -> Value
    ) async throws -> Value {
        try await perform { dependencies in
            guard dependencies.startAccessing(root) else {
                throw TidyCoordinatorError.staleBookmark
            }
            defer { dependencies.stopAccessing(root) }
            return try operation(dependencies)
        }
    }

    private func handlePlanningError(_ error: Error) -> Error {
        if let coordinatorError = error as? TidyCoordinatorError {
            return handleOperationError(coordinatorError)
        }
        if let planError = error as? TidyPlanError {
            switch planError {
            case .unsafeRoot:
                setBlock(.staleBookmark)
            case .unsafeDestination, .duplicateRuleID:
                setBlock(.configuration(String(describing: planError)))
            case .enumerationFailed:
                break
            }
        }
        return error
    }

    private func handleOperationError(_ error: Error) -> Error {
        if let coordinatorError = error as? TidyCoordinatorError {
            if coordinatorError == .staleBookmark {
                preview = nil
                setBlock(.staleBookmark)
                updateState { $0.folder = nil }
            }
            return coordinatorError
        }
        if error is TidyRecoveryError {
            let message = String(describing: error)
            setBlock(.configuration(message))
            return TidyCoordinatorError.recoveryBlocked(message)
        }
        return error
    }

    private func setBlock(_ block: Block?) {
        self.block = block
        updateState { $0.blockingError = block?.message }
    }

    private func updateState(_ update: (inout State) -> Void) {
        var next = state
        update(&next)
        guard next != state else { return }
        state = next
        onStateChange?(next)
    }
}
