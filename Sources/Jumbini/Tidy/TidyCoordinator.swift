import Dispatch
import Foundation

enum TidyCoordinatorError: Error, Equatable {
    case folderRequired
    case previewRequired
    case staleBookmark
    case recoveryBlocked(String)

    /// What to put in front of the user. Every one of these is something they
    /// can act on, so none of them is worth an alert — they go in the same
    /// popover the results do.
    var message: String {
        switch self {
        case .folderRequired:
            return "Choose a folder for Jumba to tidy first."
        case .previewRequired:
            return "Take a look at the preview before Jumba moves anything."
        case .staleBookmark:
            return "macOS withdrew access to that folder. Choose it again."
        case .recoveryBlocked(let detail):
            return detail
        }
    }
}

enum TidyNotice: Equatable {
    case completed(moved: Int, skipped: Int, capped: Bool)
    case halted(moved: Int)
    case failed(String)
    case undone(Int)

    /// One line for the status-item popover. Idle passes must not interrupt, so
    /// results are reported as text rather than as an alert.
    var message: String {
        switch self {
        case .completed(let moved, let skipped, let capped):
            let moves = "Jumba moved \(moved) file\(moved == 1 ? "" : "s")"
            let skips = skipped == 0 ? "" : ", left \(skipped) alone"
            let cap = capped ? " He stopped at \(TidySafety.maximumMoves) for safety." : ""
            return moves + skips + "." + cap
        case .halted(let moved):
            return "You came back — Jumba stopped after \(moved) file\(moved == 1 ? "" : "s")."
        case .failed(let message):
            return "Jumba stopped: \(message)"
        case .undone(let count):
            return "Jumba put \(count) file\(count == 1 ? "" : "s") back."
        }
    }
}

/// What the Tidy submenu offers, as data.
///
/// The menu decides real things — whether a pass can start, whether the last one
/// can still be undone, whether the folder grant can be revoked — and none of
/// that needs AppKit to be decided or to be checked.
struct TidyMenuState: Equatable {
    var folderConfigured: Bool
    var undoCount: Int
    var idleEnabled: Bool
    var idleAvailable: Bool
    var isRunning: Bool

    init(
        folderConfigured: Bool,
        undoCount: Int,
        idleEnabled: Bool,
        idleAvailable: Bool,
        isRunning: Bool = false
    ) {
        self.folderConfigured = folderConfigured
        self.undoCount = undoCount
        self.idleEnabled = idleEnabled
        self.idleAvailable = idleAvailable
        self.isRunning = isRunning
    }

    /// A folder Tidy cannot currently reach is not a configured folder: a stale
    /// or revoked grant sends the menu back to offering setup rather than
    /// offering to tidy something it would only fail on.
    init(state: TidyCoordinator.State) {
        self.init(
            folderConfigured: state.folder != nil && state.blockingError == nil,
            undoCount: state.undoCount,
            idleEnabled: state.preferences.idleEnabled,
            idleAvailable: state.idleAvailable,
            isRunning: state.isRunning
        )
    }

    var primaryTitle: String { folderConfigured ? "Tidy Up…" : "Set Up Tidy…" }
    var undoTitle: String {
        undoCount > 0 ? "Undo Last Tidy (\(undoCount))" : "Undo Last Tidy"
    }
    var settingsTitle: String { "Tidy Settings…" }
    var idleTitle: String { "Tidy While Idle" }
    var forgetTitle: String { "Forget Folder…" }

    /// Always available: without a folder the primary item opens the picker.
    var canTidy: Bool { !isRunning }
    var canUndo: Bool { folderConfigured && undoCount > 0 && !isRunning }
    var canForgetFolder: Bool { folderConfigured && !isRunning }
    var canToggleIdle: Bool { idleAvailable && !isRunning }
    var idleIsChecked: Bool { idleEnabled && idleAvailable }
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

    /// Idle tidying is a trigger, not a rule, so switching it on does not
    /// reinstate the preview gate — but it cannot be switched on at all until a
    /// reviewed manual pass has succeeded, which is what `idleAvailable` means.
    func updateIdle(enabled: Bool) throws {
        try requireNoOperationInFlight()
        guard !enabled || state.idleAvailable else {
            throw TidyCoordinatorError.previewRequired
        }
        var preferences = state.preferences
        preferences.idleEnabled = enabled
        try dependencies.savePreferences(preferences)
        updateState { $0.preferences = preferences }
    }

    func updateIdle(minutes: Int) throws {
        try requireNoOperationInFlight()
        var preferences = state.preferences
        preferences.idleMinutes = max(minutes, 1)
        try dependencies.savePreferences(preferences)
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
